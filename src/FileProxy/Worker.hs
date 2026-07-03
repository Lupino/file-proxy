{-# LANGUAGE BlockArguments    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module FileProxy.Worker
  ( ApiConfig (..)
  , ApiError (..)
  , DeleteOptions (..)
  , FileEntry (..)
  , ListOptions (..)
  , DownloadRange (..)
  , UploadBegin (..)
  , UploadChunkResult (..)
  , UploadFinishResult (..)
  , UploadMeta (..)
  , UploadStatus (..)
  , apiDeletePath
  , apiDownloadChunk
  , apiDownloadInfo
  , apiListDirectory
  , apiPutFile
  , apiSha256Sum
  , apiStatPath
  , apiUploadBegin
  , apiUploadChunk
  , apiUploadFinish
  , apiUploadStatus
  , parseUploadChunkName
  , resolveUserPath
  , sha256Bytes
  , sha256File
  , someFunc
  , uploadIdFor
  ) where

import           Control.Monad         (forM, forM_, unless, void, when)
import           Crypto.Hash.SHA256    (hash, hashlazy)
import           Data.Aeson            (FromJSON (..), ToJSON (..), Value,
                                        eitherDecodeStrict', encode, object,
                                        withObject, (.:), (.:?), (.=))
import           Data.Aeson.Types      (Pair)
import qualified Data.ByteString       as BS
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy  as LB
import           Data.List             (sortOn)
import           Data.Maybe            (fromMaybe)
import           Data.String           (fromString)
import           Data.Time.Clock       (UTCTime)
import           Metro.Class           (Transport)
import qualified Metro.TP.RSA          as RSA (RSAMode (AES), configClient)
import           Metro.TP.Socket       (socket)
import           Options.Applicative
import           Periodic.Trans.Job    (JobT, name, workDone_, workload)
import           Periodic.Trans.Worker (WorkerT, addFunc,
                                        startWorkerTWithSignalWithAuth, work)
import           Periodic.Types        (ClientIdentity (ClientIdentity))
import           System.Directory      (createDirectoryIfMissing,
                                        doesDirectoryExist, doesFileExist,
                                        doesPathExist, getDirectoryContents,
                                        getFileSize, getModificationTime,
                                        removeDirectory, removeFile,
                                        removePathForcibly,
                                        renameDirectory, renameFile)
import           System.Environment    (lookupEnv)
import           System.Exit           (exitFailure)
import           System.FilePath       (dropTrailingPathSeparator,
                                        isAbsolute, joinPath, splitDirectories,
                                        takeDirectory, (</>))
import qualified System.IO             as IO
import           UnliftIO

data Flags = Flags
  { hostPort       :: String
  , rootPath       :: FilePath
  , workThread     :: Int
  , rsaPrivatePath :: FilePath
  , rsaPublicPath  :: FilePath
  , rsaMode        :: RSA.RSAMode
  , clientName     :: Maybe String
  , clientToken    :: Maybe String
  , allowDelete    :: Bool
  }

data ApiConfig = ApiConfig
  { cfgRoot        :: FilePath
  , cfgAllowDelete :: Bool
  } deriving (Eq, Show)

data ApiError = ApiError
  { errorCode    :: String
  , errorMessage :: String
  } deriving (Eq, Show)

instance ToJSON ApiError where
  toJSON ApiError {..} =
    object ["code" .= errorCode, "message" .= errorMessage]

ok :: [Pair] -> Value
ok fields = object $ ("ok" .= True) : fields

err :: String -> String -> Value
err code message =
  object ["ok" .= False, "error" .= ApiError code message]

jsonBytes :: ToJSON a => a -> B.ByteString
jsonBytes = LB.toStrict . encode

jsonValue :: Value -> B.ByteString
jsonValue = jsonBytes

flags :: Maybe String -> Maybe String -> Maybe String -> Maybe String -> Maybe String -> Maybe RSA.RSAMode -> Maybe Bool -> Parser Flags
flags mHost mClientName mClientToken mRsaPrivate mRsaPublic mRsaMode mAllowDelete =
  mkFlags
    <$> strOption (long "host" <> short 'H' <> metavar "HOST" <> showDefault <> value (fromMaybe "unix:///tmp/periodic.sock" mHost) <> help "Periodic server address [$PERIODIC_PORT].")
    <*> strOption (long "root" <> short 'r' <> metavar "ROOT" <> showDefault <> value "." <> help "FileSystem root path.")
    <*> option auto (long "thread" <> short 't' <> metavar "INT" <> showDefault <> value 10 <> help "Work thread.")
    <*> strOption (long "rsa-private-path" <> metavar "PATH" <> showDefault <> value (fromMaybe "" mRsaPrivate) <> help "RSA private key file path [$PERIODIC_RSA_PRIVATE_PATH].")
    <*> strOption (long "rsa-public-path" <> metavar "PATH" <> showDefault <> value (fromMaybe "public_key.pem" mRsaPublic) <> help "RSA public key file or directory [$PERIODIC_RSA_PUBLIC_PATH].")
    <*> option auto (long "rsa-mode" <> metavar "MODE" <> showDefault <> value (fromMaybe RSA.AES mRsaMode) <> help "RSA mode: Plain, RSA, or AES [$PERIODIC_RSA_MODE].")
    <*> optional (strOption (long "client-name" <> metavar "NAME" <> value (fromMaybe "" mClientName) <> help "Auth client name [$PERIODIC_CLIENT_NAME]."))
    <*> optional (strOption (long "client-token" <> metavar "TOKEN" <> value (fromMaybe "" mClientToken) <> help "Auth client token [$PERIODIC_CLIENT_TOKEN]."))
    <*> switch (long "allow-delete" <> help "Allow delete-path to remove files and directories [$FILE_PROXY_ALLOW_DELETE].")
  where
    mkFlags hostPort rootPath workThread rsaPrivatePath rsaPublicPath rsaMode clientName clientToken cliAllowDelete =
      Flags
        { hostPort = hostPort
        , rootPath = rootPath
        , workThread = workThread
        , rsaPrivatePath = rsaPrivatePath
        , rsaPublicPath = rsaPublicPath
        , rsaMode = rsaMode
        , clientName = clientName
        , clientToken = clientToken
        , allowDelete = cliAllowDelete || fromMaybe False mAllowDelete
        }

someFunc :: IO ()
someFunc = do
  envHost <- lookupEnv "PERIODIC_PORT"
  envClientName <- lookupEnv "PERIODIC_CLIENT_NAME"
  envClientToken <- lookupEnv "PERIODIC_CLIENT_TOKEN"
  envRsaPrivate <- lookupEnv "PERIODIC_RSA_PRIVATE_PATH"
  envRsaPublic <- lookupEnv "PERIODIC_RSA_PUBLIC_PATH"
  envRsaMode <- traverse readRsaMode =<< lookupEnv "PERIODIC_RSA_MODE"
  envAllowDelete <- fmap parseBool <$> lookupEnv "FILE_PROXY_ALLOW_DELETE"

  parsedFlags@Flags {..} <- execParser $ opts envHost envClientName envClientToken envRsaPrivate envRsaPublic envRsaMode envAllowDelete
  auth <- requireAuthPair parsedFlags
  let cfg = ApiConfig rootPath allowDelete

  case rsaPrivatePath of
    "" -> startWorkerTWithSignalWithAuth auth Nothing (pure ()) (socket hostPort) $ registerWorkers cfg workThread
    _ -> do
      genTP <- RSA.configClient rsaMode rsaPrivatePath rsaPublicPath
      startWorkerTWithSignalWithAuth auth Nothing (pure ()) (genTP $ socket hostPort) $ registerWorkers cfg workThread
  where
    opts h n t priv pub mode del =
      info (flags h n t priv pub mode del <**> helper) (fullDesc <> header "file-proxy - a file proxy worker" )

registerWorkers :: (Transport tp, MonadUnliftIO m) => ApiConfig -> Int -> WorkerT tp m ()
registerWorkers cfg thread = do
  void $ addFunc (fromString "get-file") $ getFile cfg
  void $ addFunc (fromString "put-file") $ putFile cfg
  void $ addFunc (fromString "get-directory") $ getDirectory cfg
  void $ addFunc (fromString "stat-path") $ statPath cfg
  void $ addFunc (fromString "sha256sum") $ sha256Sum cfg
  void $ addFunc (fromString "make-directory") $ makeDirectory cfg
  void $ addFunc (fromString "delete-path") $ deletePath cfg
  void $ addFunc (fromString "move-path") $ movePath cfg
  void $ addFunc (fromString "copy-path") $ copyPath cfg
  void $ addFunc (fromString "download-info") $ downloadInfo cfg
  void $ addFunc (fromString "download-chunk") $ downloadChunk cfg
  void $ addFunc (fromString "upload-begin") $ uploadBegin cfg
  void $ addFunc (fromString "upload-chunk") $ uploadChunk cfg
  void $ addFunc (fromString "upload-status") $ uploadStatus cfg
  void $ addFunc (fromString "upload-finish") $ uploadFinish cfg
  void $ addFunc (fromString "upload-abort") $ uploadAbort cfg
  work thread

requireAuthPair :: Flags -> IO (Maybe ClientIdentity)
requireAuthPair Flags {clientName = Nothing, clientToken = Nothing} = pure Nothing
requireAuthPair Flags {clientName = Just "", clientToken = Just ""} = pure Nothing
requireAuthPair Flags {clientName = Just n, clientToken = Just t}
  | not (null n) && not (null t) = pure $ Just $ ClientIdentity (B.pack n) (B.pack t)
requireAuthPair _ = do
  putStrLn "Error: --client-name and --client-token must be provided together"
  exitFailure

readRsaMode :: String -> IO RSA.RSAMode
readRsaMode raw =
  case reads raw of
    [(mode, "")] -> pure mode
    _            -> putStrLn ("Error: invalid PERIODIC_RSA_MODE: " ++ raw) >> exitFailure

parseBool :: String -> Bool
parseBool raw = raw `elem` ["1", "true", "TRUE", "yes", "YES", "on", "ON"]

data FileEntry = FileEntry
  { entryName       :: String
  , entryPath       :: FilePath
  , entryType       :: String
  , entrySize       :: Maybe Integer
  , entryModifiedAt :: UTCTime
  , entrySha256     :: Maybe String
  , entryChildren   :: Maybe [FileEntry]
  } deriving (Eq, Show)

instance ToJSON FileEntry where
  toJSON FileEntry {..} =
    object
      [ "name" .= entryName
      , "path" .= entryPath
      , "type" .= entryType
      , "size" .= entrySize
      , "modifiedAt" .= entryModifiedAt
      , "sha256" .= entrySha256
      , "children" .= entryChildren
      ]

data ListOptions = ListOptions
  { listRecursive :: Bool
  , listMaxDepth  :: Maybe Int
  } deriving (Eq, Show)

instance FromJSON ListOptions where
  parseJSON = withObject "ListOptions" $ \o ->
    ListOptions
      <$> fmap (fromMaybe False) (o .:? "recursive")
      <*> o .:? "maxDepth"

defaultListOptions :: ListOptions
defaultListOptions = ListOptions False Nothing

data DeleteOptions = DeleteOptions
  { deleteRecursive :: Bool
  } deriving (Eq, Show)

instance FromJSON DeleteOptions where
  parseJSON = withObject "DeleteOptions" $ \o ->
    DeleteOptions <$> fmap (fromMaybe False) (o .:? "recursive")

data MoveOptions = MoveOptions
  { moveTo        :: FilePath
  , moveOverwrite :: Bool
  } deriving (Eq, Show)

instance FromJSON MoveOptions where
  parseJSON = withObject "MoveOptions" $ \o ->
    MoveOptions <$> o .: "to" <*> fmap (fromMaybe False) (o .:? "overwrite")

data CopyOptions = CopyOptions
  { copyTo        :: FilePath
  , copyOverwrite :: Bool
  , copyRecursive :: Bool
  } deriving (Eq, Show)

instance FromJSON CopyOptions where
  parseJSON = withObject "CopyOptions" $ \o ->
    CopyOptions
      <$> o .: "to"
      <*> fmap (fromMaybe False) (o .:? "overwrite")
      <*> fmap (fromMaybe False) (o .:? "recursive")

data DownloadRange = DownloadRange
  { downloadOffset :: Integer
  , downloadSize   :: Integer
  } deriving (Eq, Show)

instance FromJSON DownloadRange where
  parseJSON = withObject "DownloadRange" $ \o ->
    DownloadRange <$> o .: "offset" <*> o .: "size"

data UploadBegin = UploadBegin
  { beginSize      :: Integer
  , beginSha256    :: String
  , beginChunkSize :: Maybe Int
  } deriving (Eq, Show)

instance FromJSON UploadBegin where
  parseJSON = withObject "UploadBegin" $ \o ->
    UploadBegin <$> o .: "size" <*> o .: "sha256" <*> o .:? "chunkSize"

data UploadMeta = UploadMeta
  { metaUploadId  :: String
  , metaPath      :: FilePath
  , metaSize      :: Integer
  , metaSha256    :: String
  , metaChunkSize :: Int
  } deriving (Eq, Show)

instance ToJSON UploadMeta where
  toJSON UploadMeta {..} =
    object
      [ "uploadId" .= metaUploadId
      , "path" .= metaPath
      , "size" .= metaSize
      , "sha256" .= metaSha256
      , "chunkSize" .= metaChunkSize
      ]

instance FromJSON UploadMeta where
  parseJSON = withObject "UploadMeta" $ \o ->
    UploadMeta
      <$> o .: "uploadId"
      <*> o .: "path"
      <*> o .: "size"
      <*> o .: "sha256"
      <*> o .: "chunkSize"

data ChunkRecord = ChunkRecord
  { chunkOffset :: Integer
  , chunkSize   :: Integer
  , chunkSha256 :: String
  } deriving (Eq, Show)

instance ToJSON ChunkRecord where
  toJSON ChunkRecord {..} =
    object ["offset" .= chunkOffset, "size" .= chunkSize, "sha256" .= chunkSha256]

instance FromJSON ChunkRecord where
  parseJSON = withObject "ChunkRecord" $ \o ->
    ChunkRecord <$> o .: "offset" <*> o .: "size" <*> o .: "sha256"

data UploadStatus = UploadStatus
  { statusUploadId       :: String
  , statusPath           :: FilePath
  , statusSize           :: Integer
  , statusSha256         :: String
  , statusChunkSize      :: Int
  , statusReceivedRanges :: [(Integer, Integer)]
  , statusNextOffset     :: Integer
  } deriving (Eq, Show)

instance ToJSON UploadStatus where
  toJSON UploadStatus {..} =
    object
      [ "ok" .= True
      , "uploadId" .= statusUploadId
      , "path" .= statusPath
      , "size" .= statusSize
      , "sha256" .= statusSha256
      , "chunkSize" .= statusChunkSize
      , "receivedRanges" .= map rangeObject statusReceivedRanges
      , "nextOffset" .= statusNextOffset
      ]
    where
      rangeObject (start, end) = object ["start" .= start, "end" .= end]

data UploadChunkResult = UploadChunkResult
  { chunkResultStatus :: UploadStatus
  , chunkResultSize   :: Integer
  , chunkResultSha256 :: String
  , chunkResultOffset :: Integer
  } deriving (Eq, Show)

instance ToJSON UploadChunkResult where
  toJSON UploadChunkResult {..} =
    object
      [ "ok" .= True
      , "uploadId" .= statusUploadId chunkResultStatus
      , "offset" .= chunkResultOffset
      , "size" .= chunkResultSize
      , "chunkSha256" .= chunkResultSha256
      , "nextOffset" .= statusNextOffset chunkResultStatus
      , "receivedRanges" .= map rangeObject (statusReceivedRanges chunkResultStatus)
      ]
    where
      rangeObject (start, end) = object ["start" .= start, "end" .= end]

data UploadFinishResult = UploadFinishResult
  { finishPath       :: FilePath
  , finishSize       :: Integer
  , finishSha256     :: String
  , finishModifiedAt :: UTCTime
  } deriving (Eq, Show)

instance ToJSON UploadFinishResult where
  toJSON UploadFinishResult {..} =
    object
      [ "ok" .= True
      , "path" .= finishPath
      , "size" .= finishSize
      , "sha256" .= finishSha256
      , "modifiedAt" .= finishModifiedAt
      ]

resolveUserPath :: FilePath -> FilePath -> Either ApiError FilePath
resolveUserPath root raw
  | null raw || raw == "." = Right root
  | isAbsolute raw = Left $ ApiError "invalid_path" "absolute paths are not allowed"
  | any (== "..") parts = Left $ ApiError "invalid_path" "path traversal is not allowed"
  | any (== ".file-proxy") parts = Left $ ApiError "invalid_path" ".file-proxy is reserved"
  | otherwise = Right $ root </> joinPath parts
  where
    parts = filter (`notElem` ["", "."]) $ map dropTrailingPathSeparator $ splitDirectories raw

safeResolve :: ApiConfig -> FilePath -> IO (Either ApiError FilePath)
safeResolve ApiConfig {..} raw =
  pure $ resolveUserPath cfgRoot raw

sha256Bytes :: BS.ByteString -> String
sha256Bytes = B.unpack . B16.encode . hash

sha256File :: FilePath -> IO String
sha256File path = B.unpack . B16.encode . hashlazy <$> LB.readFile path

metadataFor :: FilePath -> FilePath -> IO (Either ApiError FileEntry)
metadataFor base path = do
  isFile <- doesFileExist path
  isDir <- doesDirectoryExist path
  if isFile then do
    size <- getFileSize path
    modifiedAt <- getModificationTime path
    digest <- sha256File path
    pure $ Right $ FileEntry (basename path) (relativeName base path) "file" (Just size) modifiedAt (Just digest) Nothing
  else if isDir then do
    modifiedAt <- getModificationTime path
    pure $ Right $ FileEntry (basename path) (relativeName base path) "directory" Nothing modifiedAt Nothing (Just [])
  else
    pure $ Left $ ApiError "not_found" "path does not exist"

basename :: FilePath -> String
basename = last . splitDirectories

relativeName :: FilePath -> FilePath -> FilePath
relativeName base path =
  case stripPrefixPath base path of
    "" -> "."
    rel -> rel

stripPrefixPath :: FilePath -> FilePath -> FilePath
stripPrefixPath base path =
  let baseParts = splitDirectories base
      pathParts = splitDirectories path
  in joinPath $ drop (length baseParts) pathParts

apiStatPath :: ApiConfig -> FilePath -> IO Value
apiStatPath cfg raw = do
  resolved <- safeResolve cfg raw
  case resolved of
    Left e -> pure $ err (errorCode e) (errorMessage e)
    Right path -> do
      meta <- metadataFor (cfgRoot cfg) path
      pure $ case meta of
        Left e -> err (errorCode e) (errorMessage e)
        Right entry -> ok ["path" .= raw, "entry" .= entry]

apiDownloadInfo :: ApiConfig -> FilePath -> IO Value
apiDownloadInfo cfg raw = do
  resolved <- safeResolve cfg raw
  case resolved of
    Left e -> pure $ err (errorCode e) (errorMessage e)
    Right path -> do
      isFile <- doesFileExist path
      if not isFile then pure $ err "not_found" "file does not exist"
      else do
        size <- getFileSize path
        digest <- sha256File path
        modifiedAt <- getModificationTime path
        pure $ ok ["path" .= raw, "size" .= size, "sha256" .= digest, "modifiedAt" .= modifiedAt]

apiDownloadChunk :: ApiConfig -> FilePath -> DownloadRange -> IO (Either ApiError BS.ByteString)
apiDownloadChunk cfg raw DownloadRange {..} = do
  resolved <- safeResolve cfg raw
  case resolved of
    Left e -> pure $ Left e
    Right path
      | downloadOffset < 0 -> pure $ Left $ ApiError "invalid_range" "offset must be non-negative"
      | downloadSize <= 0 -> pure $ Left $ ApiError "invalid_range" "size must be positive"
      | downloadSize > fromIntegral (maxBound :: Int) -> pure $ Left $ ApiError "range_too_large" "size is too large"
      | otherwise -> do
        isFile <- doesFileExist path
        if not isFile then pure $ Left $ ApiError "not_found" "file does not exist"
        else do
          fileSize <- getFileSize path
          if downloadOffset >= fileSize then pure $ Left $ ApiError "range_out_of_bounds" "offset is past end of file"
          else do
            let available = fileSize - downloadOffset
                bytesToRead = fromIntegral $ min downloadSize available
            Right <$> IO.withBinaryFile path IO.ReadMode \h -> do
              IO.hSeek h IO.AbsoluteSeek downloadOffset
              BS.hGet h bytesToRead

apiPutFile :: ApiConfig -> FilePath -> BS.ByteString -> IO Value
apiPutFile cfg raw bs = do
  resolved <- safeResolve cfg raw
  case resolved of
    Left e -> pure $ err (errorCode e) (errorMessage e)
    Right path -> do
      createDirectoryIfMissing True $ takeDirectory path
      BS.writeFile path bs
      size <- getFileSize path
      modifiedAt <- getModificationTime path
      pure $ ok ["path" .= raw, "size" .= size, "sha256" .= sha256Bytes bs, "modifiedAt" .= modifiedAt]

apiListDirectory :: ApiConfig -> FilePath -> ListOptions -> IO Value
apiListDirectory cfg raw opts = do
  resolved <- safeResolve cfg raw
  case resolved of
    Left e -> pure $ err (errorCode e) (errorMessage e)
    Right path -> do
      isDir <- doesDirectoryExist path
      if not isDir
        then pure $ err "not_directory" "path is not a directory"
        else do
          entries <- listEntries (cfgRoot cfg) path opts 0
          pure $ ok ["path" .= raw, "entries" .= entries]

listEntries :: FilePath -> FilePath -> ListOptions -> Int -> IO [FileEntry]
listEntries base dir ListOptions {..} depth = do
  names <- filter (`notElem` [".", "..", ".file-proxy"]) <$> getDirectoryContents dir
  fmap sortEntries $ forM names \entryName -> do
    let path = dir </> entryName
    isFile <- doesFileExist path
    isDir <- doesDirectoryExist path
    modifiedAt <- getModificationTime path
    if isFile then do
      size <- getFileSize path
      digest <- sha256File path
      pure $ FileEntry entryName (relativeName base path) "file" (Just size) modifiedAt (Just digest) Nothing
    else if isDir then do
      children <- if listRecursive && maybe True (depth <) listMaxDepth
                    then Just <$> listEntries base path ListOptions {..} (depth + 1)
                    else pure $ Just []
      pure $ FileEntry entryName (relativeName base path) "directory" Nothing modifiedAt Nothing children
    else
      pure $ FileEntry entryName (relativeName base path) "other" Nothing modifiedAt Nothing Nothing
  where
    sortEntries = sortOn entryName

apiSha256Sum :: ApiConfig -> FilePath -> ListOptions -> IO Value
apiSha256Sum cfg raw opts = do
  resolved <- safeResolve cfg raw
  case resolved of
    Left e -> pure $ err (errorCode e) (errorMessage e)
    Right path -> do
      isFile <- doesFileExist path
      isDir <- doesDirectoryExist path
      if isFile then do
        size <- getFileSize path
        digest <- sha256File path
        pure $ ok ["path" .= raw, "size" .= size, "sha256" .= digest]
      else if isDir && listRecursive opts then do
        entries <- collectFileManifest (cfgRoot cfg) path
        pure $ ok ["path" .= raw, "files" .= entries]
      else if isDir
        then pure $ err "is_directory" "directory sha256sum requires recursive=true"
        else pure $ err "not_found" "path does not exist"

collectFileManifest :: FilePath -> FilePath -> IO [Value]
collectFileManifest base dir = do
  names <- filter (`notElem` [".", "..", ".file-proxy"]) <$> getDirectoryContents dir
  fmap concat $ forM names \entryName -> do
    let path = dir </> entryName
    isFile <- doesFileExist path
    isDir <- doesDirectoryExist path
    if isFile then do
      size <- getFileSize path
      digest <- sha256File path
      pure [object ["path" .= relativeName base path, "size" .= size, "sha256" .= digest]]
    else if isDir then collectFileManifest base path
    else pure []

apiDeletePath :: ApiConfig -> FilePath -> DeleteOptions -> IO Value
apiDeletePath ApiConfig {cfgAllowDelete = False} _ _ =
  pure $ err "delete_disabled" "delete-path is disabled; start worker with --allow-delete to enable it"
apiDeletePath cfg raw DeleteOptions {..} = do
  resolved <- safeResolve cfg raw
  case resolved of
    Left e -> pure $ err (errorCode e) (errorMessage e)
    Right path -> do
      isFile <- doesFileExist path
      isDir <- doesDirectoryExist path
      if isFile then removeFile path >> pure (ok ["path" .= raw, "deleted" .= True])
      else if isDir && deleteRecursive then removePathForcibly path >> pure (ok ["path" .= raw, "deleted" .= True])
      else if isDir then removeDirectory path >> pure (ok ["path" .= raw, "deleted" .= True])
      else pure $ err "not_found" "path does not exist"

apiMakeDirectory :: ApiConfig -> FilePath -> IO Value
apiMakeDirectory cfg raw = do
  resolved <- safeResolve cfg raw
  case resolved of
    Left e -> pure $ err (errorCode e) (errorMessage e)
    Right path -> do
      createDirectoryIfMissing True path
      apiStatPath cfg raw

apiMovePath :: ApiConfig -> FilePath -> MoveOptions -> IO Value
apiMovePath cfg raw MoveOptions {..} = do
  src <- safeResolve cfg raw
  dst <- safeResolve cfg moveTo
  case (src, dst) of
    (Left e, _) -> pure $ err (errorCode e) (errorMessage e)
    (_, Left e) -> pure $ err (errorCode e) (errorMessage e)
    (Right fromPath, Right toPath) -> do
      isFile <- doesFileExist fromPath
      isDir <- doesDirectoryExist fromPath
      destExists <- doesPathExist toPath
      if not isFile && not isDir then pure $ err "not_found" "source path does not exist"
      else if destExists && not moveOverwrite then pure $ err "exists" "destination already exists"
      else do
        when destExists $ removePathForcibly toPath
        createDirectoryIfMissing True $ takeDirectory toPath
        if isDir then renameDirectory fromPath toPath else renameFile fromPath toPath
        pure $ ok ["from" .= raw, "to" .= moveTo]

apiCopyPath :: ApiConfig -> FilePath -> CopyOptions -> IO Value
apiCopyPath cfg raw CopyOptions {..} = do
  src <- safeResolve cfg raw
  dst <- safeResolve cfg copyTo
  case (src, dst) of
    (Left e, _) -> pure $ err (errorCode e) (errorMessage e)
    (_, Left e) -> pure $ err (errorCode e) (errorMessage e)
    (Right fromPath, Right toPath) -> do
      isFile <- doesFileExist fromPath
      isDir <- doesDirectoryExist fromPath
      destExists <- doesPathExist toPath
      if not isFile && not isDir then pure $ err "not_found" "source path does not exist"
      else if destExists && not copyOverwrite then pure $ err "exists" "destination already exists"
      else if isDir && not copyRecursive then pure $ err "recursive_required" "copying a directory requires recursive=true"
      else do
        when destExists $ removePathForcibly toPath
        if isFile then copyOneFile fromPath toPath else copyDirectoryRecursive fromPath toPath
        pure $ ok ["from" .= raw, "to" .= copyTo]

copyOneFile :: FilePath -> FilePath -> IO ()
copyOneFile src dst = do
  createDirectoryIfMissing True $ takeDirectory dst
  BS.readFile src >>= BS.writeFile dst

copyDirectoryRecursive :: FilePath -> FilePath -> IO ()
copyDirectoryRecursive src dst = do
  createDirectoryIfMissing True dst
  names <- filter (`notElem` [".", "..", ".file-proxy"]) <$> getDirectoryContents src
  forM_ names \entryName -> do
    let s = src </> entryName
        d = dst </> entryName
    isFile <- doesFileExist s
    isDir <- doesDirectoryExist s
    if isFile then copyOneFile s d
    else when isDir $ copyDirectoryRecursive s d

uploadsRoot :: ApiConfig -> FilePath
uploadsRoot ApiConfig {..} = cfgRoot </> ".file-proxy" </> "uploads"

uploadPaths :: ApiConfig -> String -> (FilePath, FilePath, FilePath)
uploadPaths cfg uploadId =
  let dir = uploadsRoot cfg </> uploadId
  in (dir, dir </> "meta.json", dir </> "data.bin")

chunksPath :: ApiConfig -> String -> FilePath
chunksPath cfg uploadId =
  let (dir, _, _) = uploadPaths cfg uploadId
  in dir </> "chunks.json"

uploadIdFor :: FilePath -> UploadBegin -> String
uploadIdFor raw UploadBegin {..} =
  take 32 $ sha256Bytes $ B.pack $ raw ++ "\n" ++ show beginSize ++ "\n" ++ beginSha256

apiUploadBegin :: ApiConfig -> FilePath -> UploadBegin -> IO Value
apiUploadBegin cfg raw begin@UploadBegin {..} = do
  resolved <- safeResolve cfg raw
  case resolved of
    Left e -> pure $ err (errorCode e) (errorMessage e)
    Right _
      | beginSize < 0 -> pure $ err "invalid_size" "upload size must be non-negative"
      | not (validSha256Hex beginSha256) -> pure $ err "invalid_sha256" "file sha256 is invalid"
      | maybe False (<= 0) beginChunkSize -> pure $ err "invalid_chunk_size" "chunkSize must be positive"
      | otherwise -> do
      let uploadId = uploadIdFor raw begin
          chunkSize = fromMaybe (8 * 1024 * 1024) beginChunkSize
          meta = UploadMeta uploadId raw beginSize beginSha256 chunkSize
          (dir, metaFile, dataFile) = uploadPaths cfg uploadId
      createDirectoryIfMissing True dir
      metaExists <- doesFileExist metaFile
      if metaExists then do
        existing <- readJsonFile metaFile
        case existing of
          Right existingMeta | existingMeta == meta -> do
            repairUploadDataFile cfg uploadId dataFile beginSize
            toJSON <$> buildUploadStatus cfg existingMeta
          Right _ -> pure $ err "upload_conflict" "existing upload metadata differs"
          Left msg -> pure $ err "invalid_upload_state" msg
      else do
        ensureUploadDataFile dataFile beginSize
        writeJsonFile metaFile meta
        writeJsonFile (chunksPath cfg uploadId) ([] :: [ChunkRecord])
        toJSON <$> buildUploadStatus cfg meta

parseUploadChunkName :: FilePath -> Either ApiError (String, Integer, String)
parseUploadChunkName raw =
  case splitDirectories raw of
    [uploadId, offsetRaw, chunkDigest] ->
      if not $ validUploadId uploadId then Left $ ApiError "invalid_upload_id" "upload id is invalid"
      else if not $ validSha256Hex chunkDigest then Left $ ApiError "invalid_sha256" "chunk sha256 is invalid"
      else case reads offsetRaw of
             [(offset, "")] | offset >= 0 -> Right (uploadId, offset, chunkDigest)
             _ -> Left $ ApiError "invalid_offset" "upload chunk offset must be a non-negative integer"
    _ -> Left $ ApiError "invalid_chunk_name" "upload-chunk name must be <uploadId>/<offset>/<chunkSha256>"

validUploadId :: String -> Bool
validUploadId raw =
  length raw == 32 && all isHex raw

validSha256Hex :: String -> Bool
validSha256Hex raw =
  length raw == 64 && all isHex raw

isHex :: Char -> Bool
isHex c =
  ('0' <= c && c <= '9') || ('a' <= c && c <= 'f') || ('A' <= c && c <= 'F')

apiUploadChunk :: ApiConfig -> FilePath -> BS.ByteString -> IO Value
apiUploadChunk cfg raw bs =
  case parseUploadChunkName raw of
    Left e -> pure $ err (errorCode e) (errorMessage e)
    Right (uploadId, offset, expectedChunkSha) -> do
      loaded <- loadUpload cfg uploadId
      case loaded of
        Left e -> pure $ err (errorCode e) (errorMessage e)
        Right meta@UploadMeta {..} -> do
          let actualSha = sha256Bytes bs
              size = fromIntegral $ BS.length bs
          if actualSha /= expectedChunkSha then pure $ err "chunk_checksum_mismatch" "chunk sha256 does not match upload-chunk name"
          else if size <= 0 then pure $ err "invalid_chunk_size" "chunk must not be empty"
          else if offset + size > metaSize then pure $ err "chunk_out_of_range" "chunk extends past expected upload size"
          else do
            chunks <- readChunks cfg uploadId
            case findChunkConflict offset size actualSha chunks of
              Just code -> pure $ err code "chunk overlaps existing uploaded data"
              Nothing -> do
                let (_, _, dataFile) = uploadPaths cfg uploadId
                    hasRecord = any (sameChunk offset size actualSha) chunks
                    end = offset + size
                rangeExists <- uploadDataRangeExists dataFile end
                let existing = hasRecord && rangeExists
                unless existing do
                  ensureUploadDataFile dataFile metaSize
                  IO.withBinaryFile dataFile IO.ReadWriteMode \h -> do
                    IO.hSeek h IO.AbsoluteSeek offset
                    BS.hPut h bs
                  let updated = if hasRecord then chunks else ChunkRecord offset size actualSha : chunks
                  writeJsonFile (chunksPath cfg uploadId) updated
                status <- buildUploadStatus cfg meta
                pure $ toJSON $ UploadChunkResult status size actualSha offset

apiUploadStatus :: ApiConfig -> String -> IO Value
apiUploadStatus cfg uploadId = do
  withValidUploadId uploadId do
    loaded <- loadUpload cfg uploadId
    case loaded of
      Left e -> pure $ err (errorCode e) (errorMessage e)
      Right meta -> toJSON <$> buildUploadStatus cfg meta

apiUploadFinish :: ApiConfig -> String -> IO Value
apiUploadFinish cfg uploadId = do
  withValidUploadId uploadId do
    loaded <- loadUpload cfg uploadId
    case loaded of
      Left e -> pure $ err (errorCode e) (errorMessage e)
      Right meta@UploadMeta {..} -> do
        status <- buildUploadStatus cfg meta
        if statusNextOffset status /= metaSize then
          pure $ err "upload_incomplete" "upload has missing chunks"
        else do
          let (dir, _, dataFile) = uploadPaths cfg uploadId
          actualSize <- getFileSize dataFile
          actualSha <- sha256File dataFile
          if actualSize /= metaSize then pure $ err "size_mismatch" "uploaded file size does not match metadata"
          else if actualSha /= metaSha256 then pure $ err "checksum_mismatch" "uploaded file sha256 does not match metadata"
          else do
            resolved <- safeResolve cfg metaPath
            case resolved of
              Left e -> pure $ err (errorCode e) (errorMessage e)
              Right target -> do
                createDirectoryIfMissing True $ takeDirectory target
                exists <- doesPathExist target
                when exists $ removePathForcibly target
                renameFile dataFile target
                removePathForcibly dir
                modifiedAt <- getModificationTime target
                pure $ toJSON $ UploadFinishResult metaPath actualSize actualSha modifiedAt

apiUploadAbort :: ApiConfig -> String -> IO Value
apiUploadAbort cfg uploadId = do
  withValidUploadId uploadId do
    let (dir, _, _) = uploadPaths cfg uploadId
    exists <- doesPathExist dir
    if exists then removePathForcibly dir >> pure (ok ["uploadId" .= uploadId, "aborted" .= True])
    else pure $ err "not_found" "upload session does not exist"

withValidUploadId :: String -> IO Value -> IO Value
withValidUploadId uploadId ioAction =
  if validUploadId uploadId then ioAction
  else pure $ err "invalid_upload_id" "upload id is invalid"

loadUpload :: ApiConfig -> String -> IO (Either ApiError UploadMeta)
loadUpload cfg uploadId = do
  let (_, metaFile, _) = uploadPaths cfg uploadId
  exists <- doesFileExist metaFile
  if not exists then pure $ Left $ ApiError "not_found" "upload session does not exist"
  else do
    decoded <- readJsonFile metaFile
    pure $ case decoded of
      Left msg -> Left $ ApiError "invalid_upload_state" msg
      Right meta -> Right meta

buildUploadStatus :: ApiConfig -> UploadMeta -> IO UploadStatus
buildUploadStatus cfg UploadMeta {..} = do
  chunks <- readChunks cfg metaUploadId
  let ranges = mergeRanges $ map (\ChunkRecord {..} -> (chunkOffset, chunkOffset + chunkSize)) chunks
      next = contiguousOffset ranges
  pure $ UploadStatus metaUploadId metaPath metaSize metaSha256 metaChunkSize ranges next

readChunks :: ApiConfig -> String -> IO [ChunkRecord]
readChunks cfg uploadId = do
  let path = chunksPath cfg uploadId
  exists <- doesFileExist path
  if not exists then pure []
  else do
    decoded <- readJsonFile path
    pure $ either (const []) id decoded

findChunkConflict :: Integer -> Integer -> String -> [ChunkRecord] -> Maybe String
findChunkConflict offset size digest chunks =
  case filter overlaps chunks of
    [] -> Nothing
    [ChunkRecord o s d] | o == offset && s == size && d == digest -> Nothing
    _ -> Just "chunk_conflict"
  where
    end = offset + size
    overlaps ChunkRecord {..} =
      offset < chunkOffset + chunkSize && chunkOffset < end

sameChunk :: Integer -> Integer -> String -> ChunkRecord -> Bool
sameChunk offset size digest ChunkRecord {..} =
  chunkOffset == offset && chunkSize == size && chunkSha256 == digest

ensureUploadDataFile :: FilePath -> Integer -> IO ()
ensureUploadDataFile path size =
  IO.withBinaryFile path IO.ReadWriteMode \h ->
    IO.hSetFileSize h size

repairUploadDataFile :: ApiConfig -> String -> FilePath -> Integer -> IO ()
repairUploadDataFile cfg uploadId path size = do
  chunks <- readChunks cfg uploadId
  rangeExists <- uploadDataRangeExists path $ maxChunkEnd chunks
  when (not rangeExists) $
    writeJsonFile (chunksPath cfg uploadId) ([] :: [ChunkRecord])
  ensureUploadDataFile path size

uploadDataRangeExists :: FilePath -> Integer -> IO Bool
uploadDataRangeExists path end = do
  exists <- doesFileExist path
  if not exists
    then pure $ end == 0
    else do
      size <- getFileSize path
      pure $ size >= end

maxChunkEnd :: [ChunkRecord] -> Integer
maxChunkEnd chunks =
  maximum $ 0 : map (\ChunkRecord {..} -> chunkOffset + chunkSize) chunks

mergeRanges :: [(Integer, Integer)] -> [(Integer, Integer)]
mergeRanges =
  reverse . foldl' insertRange [] . sortOn fst
  where
    insertRange [] r = [r]
    insertRange acc@(lastRange:rest) r@(start, end)
      | start <= snd lastRange = (fst lastRange, max (snd lastRange) end) : rest
      | otherwise = r : acc

contiguousOffset :: [(Integer, Integer)] -> Integer
contiguousOffset ranges =
  foldl' step 0 $ sortOn fst ranges
  where
    step pos (start, end)
      | start <= pos = max pos end
      | otherwise = pos

readJsonFile :: FromJSON a => FilePath -> IO (Either String a)
readJsonFile path = eitherDecodeStrict' <$> BS.readFile path

writeJsonFile :: ToJSON a => FilePath -> a -> IO ()
writeJsonFile path payload = BS.writeFile path $ LB.toStrict $ encode payload

getFile :: (Transport tp, MonadUnliftIO m) => ApiConfig -> JobT tp m ()
getFile cfg = do
  raw <- name
  resolved <- liftIO $ safeResolve cfg raw
  case resolved of
    Left e -> liftIO $ ioError $ userError $ errorMessage e
    Right path -> do
      exists <- liftIO $ doesFileExist path
      unless exists $ liftIO $ ioError $ userError "file does not exist"
      bs <- liftIO $ BS.readFile path
      void $ workDone_ bs

putFile :: (Transport tp, MonadUnliftIO m) => ApiConfig -> JobT tp m ()
putFile cfg = do
  raw <- name
  bs <- workload
  rsp <- liftIO $ apiPutFile cfg raw bs
  void $ workDone_ $ jsonValue rsp

getDirectory :: (Transport tp, MonadUnliftIO m) => ApiConfig -> JobT tp m ()
getDirectory cfg = do
  raw <- name
  opts <- decodeOptionalWorkload defaultListOptions
  rsp <- liftIO $ apiListDirectory cfg raw opts
  void $ workDone_ $ jsonValue rsp

statPath :: (Transport tp, MonadUnliftIO m) => ApiConfig -> JobT tp m ()
statPath cfg = do
  raw <- name
  rsp <- liftIO $ apiStatPath cfg raw
  void $ workDone_ $ jsonValue rsp

downloadInfo :: (Transport tp, MonadUnliftIO m) => ApiConfig -> JobT tp m ()
downloadInfo cfg = do
  raw <- name
  rsp <- liftIO $ apiDownloadInfo cfg raw
  void $ workDone_ $ jsonValue rsp

downloadChunk :: (Transport tp, MonadUnliftIO m) => ApiConfig -> JobT tp m ()
downloadChunk cfg = do
  raw <- name
  decoded <- decodeRequiredWorkload
  rsp <- case decoded of
    Left e -> pure $ Left $ ApiError "invalid_workload" e
    Right rangeOpts -> liftIO $ apiDownloadChunk cfg raw rangeOpts
  case rsp of
    Left e -> liftIO $ ioError $ userError $ errorCode e ++ ": " ++ errorMessage e
    Right bs -> void $ workDone_ bs

sha256Sum :: (Transport tp, MonadUnliftIO m) => ApiConfig -> JobT tp m ()
sha256Sum cfg = do
  raw <- name
  opts <- decodeOptionalWorkload defaultListOptions
  rsp <- liftIO $ apiSha256Sum cfg raw opts
  void $ workDone_ $ jsonValue rsp

makeDirectory :: (Transport tp, MonadUnliftIO m) => ApiConfig -> JobT tp m ()
makeDirectory cfg = do
  raw <- name
  rsp <- liftIO $ apiMakeDirectory cfg raw
  void $ workDone_ $ jsonValue rsp

deletePath :: (Transport tp, MonadUnliftIO m) => ApiConfig -> JobT tp m ()
deletePath cfg = do
  raw <- name
  opts <- decodeOptionalWorkload $ DeleteOptions False
  rsp <- liftIO $ apiDeletePath cfg raw opts
  void $ workDone_ $ jsonValue rsp

movePath :: (Transport tp, MonadUnliftIO m) => ApiConfig -> JobT tp m ()
movePath cfg = do
  raw <- name
  opts <- decodeRequiredWorkload
  rsp <- case opts of
    Left e -> pure $ err "invalid_workload" e
    Right moveOpts -> liftIO $ apiMovePath cfg raw moveOpts
  void $ workDone_ $ jsonValue rsp

copyPath :: (Transport tp, MonadUnliftIO m) => ApiConfig -> JobT tp m ()
copyPath cfg = do
  raw <- name
  opts <- decodeRequiredWorkload
  rsp <- case opts of
    Left e -> pure $ err "invalid_workload" e
    Right copyOpts -> liftIO $ apiCopyPath cfg raw copyOpts
  void $ workDone_ $ jsonValue rsp

uploadBegin :: (Transport tp, MonadUnliftIO m) => ApiConfig -> JobT tp m ()
uploadBegin cfg = do
  raw <- name
  decoded <- decodeRequiredWorkload
  rsp <- case decoded of
    Left e -> pure $ err "invalid_workload" e
    Right begin -> liftIO $ apiUploadBegin cfg raw begin
  void $ workDone_ $ jsonValue rsp

uploadChunk :: (Transport tp, MonadUnliftIO m) => ApiConfig -> JobT tp m ()
uploadChunk cfg = do
  raw <- name
  bs <- workload
  rsp <- liftIO $ apiUploadChunk cfg raw bs
  void $ workDone_ $ jsonValue rsp

uploadStatus :: (Transport tp, MonadUnliftIO m) => ApiConfig -> JobT tp m ()
uploadStatus cfg = do
  raw <- name
  rsp <- liftIO $ apiUploadStatus cfg raw
  void $ workDone_ $ jsonValue rsp

uploadFinish :: (Transport tp, MonadUnliftIO m) => ApiConfig -> JobT tp m ()
uploadFinish cfg = do
  raw <- name
  rsp <- liftIO $ apiUploadFinish cfg raw
  void $ workDone_ $ jsonValue rsp

uploadAbort :: (Transport tp, MonadUnliftIO m) => ApiConfig -> JobT tp m ()
uploadAbort cfg = do
  raw <- name
  rsp <- liftIO $ apiUploadAbort cfg raw
  void $ workDone_ $ jsonValue rsp

decodeOptionalWorkload :: (Transport tp, MonadUnliftIO m, FromJSON a) => a -> JobT tp m a
decodeOptionalWorkload fallback = do
  bs <- workload
  if BS.null bs then pure fallback
  else case eitherDecodeStrict' bs of
    Right decoded -> pure decoded
    Left _ -> pure fallback

decodeRequiredWorkload :: (Transport tp, MonadUnliftIO m, FromJSON a) => JobT tp m (Either String a)
decodeRequiredWorkload = eitherDecodeStrict' <$> workload
