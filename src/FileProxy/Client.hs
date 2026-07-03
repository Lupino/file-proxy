{-# LANGUAGE BlockArguments    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE RecordWildCards   #-}

module FileProxy.Client
  ( clientMain
  , defaultChunkSize
  , downloadMetaPath
  , downloadPartPath
  , finishDownload
  , isHiddenPath
  , nextChunkSize
  , prepareDownloadPart
  , recordDownloadProgress
  , writeDownloadChunk
  ) where

import           Control.Monad          (forM, forM_, unless, when)
import           Control.Monad.IO.Class (liftIO)
import qualified Control.Exception      as E
import           Data.Aeson             (FromJSON (..), ToJSON (..), Value,
                                         eitherDecodeStrict', encode, object,
                                         withObject, (.:), (.:?), (.=))
import           Data.Aeson.Types       (parseMaybe)
import qualified Data.ByteString        as BS
import qualified Data.ByteString.Char8  as B
import qualified Data.ByteString.Lazy   as LB
import qualified Data.ByteString.Lazy.Char8 as LBC
import           Data.Maybe             (fromMaybe)
import           Data.String            (fromString)
import           FileProxy.Worker       (prefixFunctionName, sha256Bytes,
                                         sha256File)
import           Metro.Class            (Transport)
import qualified Metro.TP.RSA           as RSA (RSAMode (AES), configClient)
import           Metro.TP.Socket        (socket)
import           Options.Applicative
import           Periodic.Trans.Client  (ClientT, open, openWithAuth, runClientT,
                                         runJob)
import           Periodic.Types         (ClientIdentity (ClientIdentity),
                                         Workload (Workload))
import           System.Directory       (createDirectoryIfMissing,
                                         doesDirectoryExist, doesFileExist,
                                         doesPathExist,
                                         getDirectoryContents, getFileSize,
                                         removeFile, renameFile)
import           System.Environment     (lookupEnv)
import           System.Exit            (die)
import           System.FilePath        (makeRelative, splitDirectories,
                                         takeDirectory, takeFileName, (</>))
import qualified System.IO              as IO
import           System.Posix.Files     (createNamedPipe)
import           Text.Read              (readMaybe)
import           UnliftIO.Exception     (finally)

data DownloadMeta = DownloadMeta
  { downloadMetaSize       :: Integer
  , downloadMetaSha256     :: String
  , downloadMetaNextOffset :: Integer
  }
  deriving (Eq, Show)

instance ToJSON DownloadMeta where
  toJSON DownloadMeta {..} =
    object
      [ "size" .= downloadMetaSize
      , "sha256" .= downloadMetaSha256
      , "nextOffset" .= downloadMetaNextOffset
      ]

instance FromJSON DownloadMeta where
  parseJSON = withObject "DownloadMeta" \o ->
    DownloadMeta <$> o .: "size" <*> o .: "sha256" <*> o .: "nextOffset"

data GlobalOptions = GlobalOptions
  { optHost           :: String
  , optRsaPrivatePath :: FilePath
  , optRsaPublicPath  :: FilePath
  , optRsaMode        :: RSA.RSAMode
  , optClientName     :: Maybe String
  , optClientToken    :: Maybe String
  , optFuncPrefix     :: String
  , optCommand        :: Command
  }

data Command
  = CmdGet FilePath FilePath Int
  | CmdPut FilePath FilePath Int
  | CmdList FilePath Bool (Maybe Int) Int
  | CmdStat FilePath Int
  | CmdSha256 FilePath Bool Int
  | CmdMkdir FilePath Int
  | CmdMove FilePath FilePath Bool Int
  | CmdCopy FilePath FilePath Bool Bool Int
  | CmdRemove FilePath Bool Int
  | CmdUpload FilePath FilePath Int Int
  | CmdDownload FilePath FilePath Int Int
  | CmdUploadDir FilePath FilePath Bool Int Int
  | CmdDownloadDir FilePath FilePath Bool Int Int

data RemoteEntry = RemoteEntry
  { remoteEntryPath     :: FilePath
  , remoteEntryType     :: String
  , remoteEntrySize     :: Maybe Integer
  , remoteEntrySha256   :: Maybe String
  , remoteEntryChildren :: Maybe [RemoteEntry]
  } deriving (Eq, Show)

instance FromJSON RemoteEntry where
  parseJSON = withObject "RemoteEntry" \o ->
    RemoteEntry
      <$> o .: "path"
      <*> o .: "type"
      <*> o .:? "size"
      <*> o .:? "sha256"
      <*> o .:? "children"

defaultChunkSize :: Int
defaultChunkSize = 1024 * 1024

clientMain :: IO ()
clientMain = do
  envHost <- lookupNonEmptyEnv "PERIODIC_PORT"
  envRsaPrivate <- lookupNonEmptyEnv "PERIODIC_RSA_PRIVATE_PATH"
  envRsaPublic <- lookupNonEmptyEnv "PERIODIC_RSA_PUBLIC_PATH"
  envRsaMode <- lookupReadEnv "PERIODIC_RSA_MODE" >>= either die (pure . fromMaybe RSA.AES)
  envClientName <- lookupNonEmptyEnv "PERIODIC_CLIENT_NAME"
  envClientToken <- lookupNonEmptyEnv "PERIODIC_CLIENT_TOKEN"
  envFuncPrefix <- lookupNonEmptyEnv "PERIODIC_FUNC_PREFIX"
  opts <- execParser $ parserInfo envHost envRsaPrivate envRsaPublic envRsaMode envClientName envClientToken envFuncPrefix
  validateHost $ optHost opts
  runWithConnection opts $ processCommand (optFuncPrefix opts) $ optCommand opts

parserInfo
  :: Maybe String
  -> Maybe FilePath
  -> Maybe FilePath
  -> RSA.RSAMode
  -> Maybe String
  -> Maybe String
  -> Maybe String
  -> ParserInfo GlobalOptions
parserInfo envHost envRsaPrivate envRsaPublic envRsaMode envClientName envClientToken envFuncPrefix =
  info (globalParser envHost envRsaPrivate envRsaPublic envRsaMode envClientName envClientToken envFuncPrefix <**> helper)
    (fullDesc <> header "file-proxy-client - file-oriented client for a file-proxy worker")

globalParser
  :: Maybe String
  -> Maybe FilePath
  -> Maybe FilePath
  -> RSA.RSAMode
  -> Maybe String
  -> Maybe String
  -> Maybe String
  -> Parser GlobalOptions
globalParser envHost envRsaPrivate envRsaPublic envRsaMode envClientName envClientToken envFuncPrefix =
  GlobalOptions
    <$> strOption (long "host" <> short 'H' <> metavar "HOST" <> showDefault <> value (fromMaybe "unix:///tmp/periodic.sock" envHost) <> help "Periodic server address [$PERIODIC_PORT].")
    <*> strOption (long "rsa-private-path" <> metavar "PATH" <> showDefault <> value (fromMaybe "" envRsaPrivate) <> help "RSA private key file path [$PERIODIC_RSA_PRIVATE_PATH].")
    <*> strOption (long "rsa-public-path" <> metavar "PATH" <> showDefault <> value (fromMaybe "public_key.pem" envRsaPublic) <> help "RSA public key file or directory [$PERIODIC_RSA_PUBLIC_PATH].")
    <*> option auto (long "rsa-mode" <> metavar "MODE" <> showDefault <> value envRsaMode <> help "RSA mode: Plain, RSA, or AES [$PERIODIC_RSA_MODE].")
    <*> optional (strOption (long "client-name" <> metavar "NAME" <> value (fromMaybe "" envClientName) <> help "Auth client name [$PERIODIC_CLIENT_NAME]."))
    <*> optional (strOption (long "client-token" <> metavar "TOKEN" <> value (fromMaybe "" envClientToken) <> help "Auth client token [$PERIODIC_CLIENT_TOKEN]."))
    <*> strOption (long "prefix" <> metavar "PREFIX" <> showDefault <> value (fromMaybe "" envFuncPrefix) <> help "Prefix for worker function names [$PERIODIC_FUNC_PREFIX].")
    <*> commandParser

commandParser :: Parser Command
commandParser = hsubparser
  ( command "get" (info (getParser <**> helper) (progDesc "Download one file with get-file"))
 <> command "put" (info (putParser <**> helper) (progDesc "Upload one file with put-file"))
 <> command "ls" (info (listParser <**> helper) (progDesc "List a remote directory"))
 <> command "stat" (info (statParser <**> helper) (progDesc "Read remote path metadata"))
 <> command "sha256" (info (sha256Parser <**> helper) (progDesc "Calculate remote SHA-256"))
 <> command "mkdir" (info (mkdirParser <**> helper) (progDesc "Create a remote directory"))
 <> command "mv" (info (moveParser <**> helper) (progDesc "Move a remote path"))
 <> command "cp" (info (copyParser <**> helper) (progDesc "Copy a remote path"))
 <> command "rm" (info (removeParser <**> helper) (progDesc "Delete a remote path"))
 <> command "upload" (info (uploadParser <**> helper) (progDesc "Upload a file with resumable chunks"))
 <> command "download" (info (downloadParser <**> helper) (progDesc "Download a file with resumable chunks"))
 <> command "upload-dir" (info (uploadDirParser <**> helper) (progDesc "Upload a local directory"))
 <> command "download-dir" (info (downloadDirParser <**> helper) (progDesc "Download a remote directory"))
  )

getParser, putParser, listParser, statParser, sha256Parser, mkdirParser, moveParser, copyParser, removeParser, uploadParser, downloadParser, uploadDirParser, downloadDirParser :: Parser Command
getParser = CmdGet <$> remoteArg <*> localArg <*> timeoutOpt
putParser = CmdPut <$> localArg <*> remoteArg <*> timeoutOpt
listParser = CmdList <$> remoteArg <*> recursiveOpt <*> optional (option auto (long "max-depth" <> metavar "N" <> help "Maximum recursive depth")) <*> timeoutOpt
statParser = CmdStat <$> remoteArg <*> timeoutOpt
sha256Parser = CmdSha256 <$> remoteArg <*> recursiveOpt <*> timeoutOpt
mkdirParser = CmdMkdir <$> remoteArg <*> timeoutOpt
moveParser = CmdMove <$> remoteArg <*> remoteArgTo <*> overwriteOpt <*> timeoutOpt
copyParser = CmdCopy <$> remoteArg <*> remoteArgTo <*> overwriteOpt <*> recursiveOpt <*> timeoutOpt
removeParser = CmdRemove <$> remoteArg <*> recursiveOpt <*> timeoutOpt
uploadParser = CmdUpload <$> localArg <*> remoteArg <*> chunkSizeOpt <*> timeoutOpt
downloadParser = CmdDownload <$> remoteArg <*> localArg <*> chunkSizeOpt <*> timeoutOpt
uploadDirParser = CmdUploadDir <$> localArg <*> remoteArg <*> excludeHiddenOpt <*> chunkSizeOpt <*> timeoutOpt
downloadDirParser = CmdDownloadDir <$> remoteArg <*> localArg <*> excludeHiddenOpt <*> chunkSizeOpt <*> timeoutOpt

remoteArg :: Parser FilePath
remoteArg = strArgument (metavar "REMOTE")

remoteArgTo :: Parser FilePath
remoteArgTo = strArgument (metavar "TO")

localArg :: Parser FilePath
localArg = strArgument (metavar "LOCAL")

recursiveOpt :: Parser Bool
recursiveOpt = switch (long "recursive" <> short 'r' <> help "Enable recursive operation")

excludeHiddenOpt :: Parser Bool
excludeHiddenOpt = switch (long "exclude-hidden" <> help "Skip hidden files and directories")

overwriteOpt :: Parser Bool
overwriteOpt = switch (long "overwrite" <> help "Overwrite an existing destination")

chunkSizeOpt :: Parser Int
chunkSizeOpt = option auto (long "chunk-size" <> metavar "BYTES" <> showDefault <> value defaultChunkSize <> help "Transfer chunk size")

timeoutOpt :: Parser Int
timeoutOpt = option auto (long "timeout" <> metavar "SECONDS" <> showDefault <> value 300 <> help "Periodic job timeout")

runWithConnection :: GlobalOptions -> (forall tp. Transport tp => ClientT tp IO ()) -> IO ()
runWithConnection GlobalOptions {..} clientAction = do
  auth <- requireAuthPair optClientName optClientToken
  if null optRsaPrivatePath
    then do
      clientEnv <- maybe (open (socket optHost)) (openWithAuth (socket optHost)) auth
      runClientT clientEnv clientAction
    else do
      genTP <- RSA.configClient optRsaMode optRsaPrivatePath optRsaPublicPath
      clientEnv <- maybe (open (genTP $ socket optHost)) (openWithAuth (genTP $ socket optHost)) auth
      runClientT clientEnv clientAction

processCommand :: Transport tp => String -> Command -> ClientT tp IO ()
processCommand prefix (CmdGet remote local timeoutSecs) = do
  bs <- runRawJob prefix "get-file" remote emptyWorkload timeoutSecs
  liftClientIO $ do
    createDirectoryIfMissing True $ takeDirectory local
    BS.writeFile local bs
processCommand prefix (CmdPut local remote timeoutSecs) = do
  bs <- liftClientIO $ BS.readFile local
  runJsonJob prefix "put-file" remote (Workload bs) timeoutSecs >>= liftClientIO . printBytesLn
processCommand prefix (CmdList remote recursive maxDepth timeoutSecs) =
  runJsonJob prefix "get-directory" remote (jsonWorkload $ object ["recursive" .= recursive, "maxDepth" .= maxDepth]) timeoutSecs >>= liftClientIO . printBytesLn
processCommand prefix (CmdStat remote timeoutSecs) =
  runJsonJob prefix "stat-path" remote emptyWorkload timeoutSecs >>= liftClientIO . printBytesLn
processCommand prefix (CmdSha256 remote recursive timeoutSecs) =
  runJsonJob prefix "sha256sum" remote (jsonWorkload $ object ["recursive" .= recursive]) timeoutSecs >>= liftClientIO . printBytesLn
processCommand prefix (CmdMkdir remote timeoutSecs) =
  runJsonJob prefix "make-directory" remote emptyWorkload timeoutSecs >>= liftClientIO . printBytesLn
processCommand prefix (CmdMove from to overwrite timeoutSecs) =
  runJsonJob prefix "move-path" from (jsonWorkload $ object ["to" .= to, "overwrite" .= overwrite]) timeoutSecs >>= liftClientIO . printBytesLn
processCommand prefix (CmdCopy from to overwrite recursive timeoutSecs) =
  runJsonJob prefix "copy-path" from (jsonWorkload $ object ["to" .= to, "overwrite" .= overwrite, "recursive" .= recursive]) timeoutSecs >>= liftClientIO . printBytesLn
processCommand prefix (CmdRemove remote recursive timeoutSecs) =
  runJsonJob prefix "delete-path" remote (jsonWorkload $ object ["recursive" .= recursive]) timeoutSecs >>= liftClientIO . printBytesLn
processCommand prefix (CmdUpload local remote chunkSize timeoutSecs) =
  uploadFile prefix local remote chunkSize timeoutSecs
processCommand prefix (CmdDownload remote local chunkSize timeoutSecs) =
  downloadFile prefix remote local chunkSize timeoutSecs
processCommand prefix (CmdUploadDir local remote excludeHidden chunkSize timeoutSecs) =
  uploadDirectory prefix local remote excludeHidden chunkSize timeoutSecs
processCommand prefix (CmdDownloadDir remote local excludeHidden chunkSize timeoutSecs) =
  downloadDirectory prefix remote local excludeHidden chunkSize timeoutSecs

uploadFile :: Transport tp => String -> FilePath -> FilePath -> Int -> Int -> ClientT tp IO ()
uploadFile prefix local remote chunkSize timeoutSecs =
  uploadOneFile True prefix local remote chunkSize timeoutSecs

uploadOneFile :: Transport tp => Bool -> String -> FilePath -> FilePath -> Int -> Int -> ClientT tp IO ()
uploadOneFile printResult prefix local remote chunkSize timeoutSecs = do
  validateChunkSize chunkSize
  withUploadLock remote do
    uploadOneFileLocked printResult prefix local remote chunkSize timeoutSecs

uploadOneFileLocked :: Transport tp => Bool -> String -> FilePath -> FilePath -> Int -> Int -> ClientT tp IO ()
uploadOneFileLocked printResult prefix local remote chunkSize timeoutSecs = do
  fileSize <- liftClientIO $ getFileSize local
  digest <- liftClientIO $ sha256File local
  beginBytes <- runJsonJob prefix "upload-begin" remote (jsonWorkload $ object ["size" .= fileSize, "sha256" .= digest, "chunkSize" .= chunkSize]) timeoutSecs
  beginRsp <- liftClientIO $ decodeOkResponse beginBytes
  uploadId <- liftClientIO $ requireField "uploadId" beginRsp
  startOffset <- liftClientIO $ requireField "nextOffset" beginRsp
  liftClientIO $ logTransferFile "upload" remote local fileSize
  liftClientIO $ logProgress "upload" remote startOffset fileSize
  loopUpload uploadId startOffset fileSize
  finishBytes <- runJsonJob prefix "upload-finish" uploadId emptyWorkload timeoutSecs
  liftClientIO $ logProgress "upload" remote fileSize fileSize
  when printResult $ liftClientIO $ printBytesLn finishBytes
  where
    loopUpload uploadId offset fileSize
      | offset >= fileSize = pure ()
      | otherwise = do
          let size = nextChunkSize chunkSize offset fileSize
          chunk <- liftClientIO $ readFileChunk local offset size
          let chunkDigest = sha256Bytes chunk
              chunkName = uploadId <> "/" <> show offset <> "/" <> chunkDigest
          chunkRspBytes <- runJsonJob prefix "upload-chunk" chunkName (Workload chunk) timeoutSecs
          chunkRsp <- liftClientIO $ decodeOkResponse chunkRspBytes
          nextOffset <- liftClientIO $ requireField "nextOffset" chunkRsp
          when (nextOffset <= offset) $ liftClientIO $ die "upload did not advance"
          when (nextOffset < fileSize) $
            liftClientIO $ logProgress "upload" remote nextOffset fileSize
          loopUpload uploadId nextOffset fileSize

downloadFile :: Transport tp => String -> FilePath -> FilePath -> Int -> Int -> ClientT tp IO ()
downloadFile prefix remote local chunkSize timeoutSecs =
  downloadOneFile True prefix remote local chunkSize timeoutSecs

downloadOneFile :: Transport tp => Bool -> String -> FilePath -> FilePath -> Int -> Int -> ClientT tp IO ()
downloadOneFile printResult prefix remote local chunkSize timeoutSecs = do
  validateChunkSize chunkSize
  withDownloadLock local do
    infoBytes <- runJsonJob prefix "download-info" remote emptyWorkload timeoutSecs
    response <- liftClientIO $ decodeOkResponse infoBytes
    remoteSize <- liftClientIO $ requireField "size" response
    remoteSha <- liftClientIO $ requireField "sha256" response
    partOffset <- liftClientIO $ prepareDownloadPart local remoteSize remoteSha
    liftClientIO $ logTransferFile "download" remote local remoteSize
    liftClientIO $ logProgress "download" remote partOffset remoteSize
    loopDownload partOffset remoteSize remoteSha
    liftClientIO $ finishDownload local remoteSize remoteSha
    liftClientIO $ logProgress "download" remote remoteSize remoteSize
    when printResult $ liftClientIO $ LBC.putStrLn $ encode $ object ["ok" .= True, "path" .= remote, "local" .= local, "size" .= remoteSize, "sha256" .= remoteSha]
  where
    loopDownload offset remoteSize remoteSha
      | offset >= remoteSize = pure ()
      | otherwise = do
          let size = nextChunkSize chunkSize offset remoteSize
          chunk <- runRawJob prefix "download-chunk" remote (jsonWorkload $ object ["offset" .= offset, "size" .= size]) timeoutSecs
          when (BS.null chunk) $ liftClientIO $ die "download returned an empty chunk before EOF"
          let nextOffset = offset + fromIntegral (BS.length chunk)
          liftClientIO $ do
            writeDownloadChunk local offset chunk
            recordDownloadProgress local remoteSize remoteSha nextOffset
            when (nextOffset < remoteSize) $
              logProgress "download" remote nextOffset remoteSize
          loopDownload nextOffset remoteSize remoteSha

uploadDirectory :: Transport tp => String -> FilePath -> FilePath -> Bool -> Int -> Int -> ClientT tp IO ()
uploadDirectory prefix localRoot remoteRoot excludeHidden chunkSize timeoutSecs = do
  validateChunkSize chunkSize
  exists <- liftClientIO $ doesDirectoryExist localRoot
  unless exists $ liftClientIO $ die $ "local directory does not exist: " ++ localRoot
  (dirs, files) <- liftClientIO $ collectLocalDirectory excludeHidden localRoot
  liftClientIO $ logTransfer $ "upload-dir start local=" ++ localRoot ++ " remote=" ++ remoteRoot ++ " directories=" ++ show (length dirs) ++ " files=" ++ show (length files) ++ " excludeHidden=" ++ show excludeHidden
  forM_ dirs \rel -> do
    liftClientIO $ logTransfer $ "mkdir remote=" ++ joinRemotePath remoteRoot rel
    runJsonJob prefix "make-directory" (joinRemotePath remoteRoot rel) emptyWorkload timeoutSecs
  results <- forM files \(local, rel) -> do
    let remote = joinRemotePath remoteRoot rel
    fileSize <- liftClientIO $ getFileSize local
    if fileSize > fromIntegral defaultChunkSize
      then do
        uploadOneFile False prefix local remote chunkSize timeoutSecs
        liftClientIO $ logTransfer $ "uploaded remote=" ++ remote ++ " local=" ++ local ++ " size=" ++ humanBytes fileSize ++ " mode=resumable"
        pure True
      else do
        bs <- liftClientIO $ BS.readFile local
        _ <- runJsonJob prefix "put-file" remote (Workload bs) timeoutSecs
        liftClientIO $ logTransfer $ "uploaded remote=" ++ remote ++ " local=" ++ local ++ " size=" ++ humanBytes fileSize ++ " mode=single"
        pure False
  liftClientIO $ logTransfer $ "upload-dir done files=" ++ show (length files) ++ " largeFiles=" ++ show (length (filter id results))
  liftClientIO $ LBC.putStrLn $ encode $ object
    [ "ok" .= True
    , "local" .= localRoot
    , "remote" .= remoteRoot
    , "directories" .= length dirs
    , "files" .= length files
    , "largeFiles" .= length (filter id results)
    , "excludeHidden" .= excludeHidden
    ]

downloadDirectory :: Transport tp => String -> FilePath -> FilePath -> Bool -> Int -> Int -> ClientT tp IO ()
downloadDirectory prefix remoteRoot localRoot excludeHidden chunkSize timeoutSecs = do
  validateChunkSize chunkSize
  rspBytes <- runJsonJob prefix "get-directory" remoteRoot (jsonWorkload $ object ["recursive" .= True, "maxDepth" .= (Nothing :: Maybe Int)]) timeoutSecs
  rsp <- liftClientIO $ decodeOkResponse rspBytes
  entries <- liftClientIO $ requireField "entries" rsp
  let filteredEntries = filterRemoteEntries excludeHidden entries
      dirs = remoteEntryDirectories filteredEntries
      files = remoteEntryFiles filteredEntries
  liftClientIO $ createDirectoryIfMissing True localRoot
  liftClientIO $ logTransfer $ "download-dir start remote=" ++ remoteRoot ++ " local=" ++ localRoot ++ " directories=" ++ show (length dirs) ++ " files=" ++ show (length files) ++ " excludeHidden=" ++ show excludeHidden
  liftClientIO $ forM_ dirs \entry -> do
    let localDir = localRoot </> relativeRemotePath remoteRoot (remoteEntryPath entry)
    logTransfer $ "mkdir local=" ++ localDir
    createDirectoryIfMissing True localDir
  results <- forM files \entry -> do
    let remote = remoteEntryPath entry
        local = localRoot </> relativeRemotePath remoteRoot remote
        size = fromMaybe 0 $ remoteEntrySize entry
    liftClientIO $ createDirectoryIfMissing True $ takeDirectory local
    if size > fromIntegral defaultChunkSize
      then do
        downloadOneFile False prefix remote local chunkSize timeoutSecs
        liftClientIO $ logTransfer $ "downloaded remote=" ++ remote ++ " local=" ++ local ++ " size=" ++ humanBytes size ++ " mode=resumable"
        pure True
      else do
        bs <- runRawJob prefix "get-file" remote emptyWorkload timeoutSecs
        liftClientIO $ BS.writeFile local bs
        liftClientIO $ verifyDownloadedFile local entry
        liftClientIO $ logTransfer $ "downloaded remote=" ++ remote ++ " local=" ++ local ++ " size=" ++ humanBytes size ++ " mode=single"
        pure False
  liftClientIO $ logTransfer $ "download-dir done files=" ++ show (length files) ++ " largeFiles=" ++ show (length (filter id results))
  liftClientIO $ LBC.putStrLn $ encode $ object
    [ "ok" .= True
    , "remote" .= remoteRoot
    , "local" .= localRoot
    , "directories" .= length dirs
    , "files" .= length files
    , "largeFiles" .= length (filter id results)
    , "excludeHidden" .= excludeHidden
    ]

collectLocalDirectory :: Bool -> FilePath -> IO ([FilePath], [(FilePath, FilePath)])
collectLocalDirectory excludeHidden root = go ""
  where
    go rel = do
      let dir = if null rel then root else root </> rel
      names <- filter (`notElem` [".", ".."]) <$> getDirectoryContents dir
      let visibleNames = if excludeHidden then filter (not . isHiddenName) names else names
      children <- forM visibleNames \name -> do
        let childRel = if null rel then name else rel </> name
            childPath = root </> childRel
        isFile <- doesFileExist childPath
        isDir <- doesDirectoryExist childPath
        if isFile then pure ([], [(childPath, childRel)])
        else if isDir then do
          (dirs, files) <- go childRel
          pure (childRel : dirs, files)
        else pure ([], [])
      pure (concatMap fst children, concatMap snd children)

filterRemoteEntries :: Bool -> [RemoteEntry] -> [RemoteEntry]
filterRemoteEntries False = id
filterRemoteEntries True = foldr collect []
  where
    collect entry acc
      | isHiddenPath $ remoteEntryPath entry = acc
      | otherwise = entry {remoteEntryChildren = filterRemoteEntries True <$> remoteEntryChildren entry} : acc

remoteEntryDirectories :: [RemoteEntry] -> [RemoteEntry]
remoteEntryDirectories = concatMap go
  where
    go entry
      | remoteEntryType entry == "directory" =
          entry : maybe [] remoteEntryDirectories (remoteEntryChildren entry)
      | otherwise = []

remoteEntryFiles :: [RemoteEntry] -> [RemoteEntry]
remoteEntryFiles = concatMap go
  where
    go entry
      | remoteEntryType entry == "file" = [entry]
      | remoteEntryType entry == "directory" = maybe [] remoteEntryFiles (remoteEntryChildren entry)
      | otherwise = []

verifyDownloadedFile :: FilePath -> RemoteEntry -> IO ()
verifyDownloadedFile local entry =
  forM_ (remoteEntrySha256 entry) \expected -> do
    actual <- sha256File local
    when (actual /= expected) $
      die $ "download checksum mismatch: " ++ remoteEntryPath entry

joinRemotePath :: FilePath -> FilePath -> FilePath
joinRemotePath root rel
  | null root || root == "." = rel
  | null rel = root
  | otherwise = root </> rel

relativeRemotePath :: FilePath -> FilePath -> FilePath
relativeRemotePath root path
  | null root || root == "." = path
  | otherwise = makeRelative root path

isHiddenPath :: FilePath -> Bool
isHiddenPath = any isHiddenName . splitDirectories

isHiddenName :: FilePath -> Bool
isHiddenName name =
  case takeFileName name of
    '.' : _ -> True
    _       -> False

logTransfer :: String -> IO ()
logTransfer message =
  IO.hPutStrLn IO.stderr $ "[file-proxy-client] " ++ message

logTransferFile :: String -> FilePath -> FilePath -> Integer -> IO ()
logTransferFile label remote local size =
  logTransfer $ label ++ " remote=" ++ remote ++ " local=" ++ local ++ " size=" ++ humanBytes size

logProgress :: String -> FilePath -> Integer -> Integer -> IO ()
logProgress label remote done total = do
  let line =
        "\ESC[2K\r[file-proxy-client] "
          ++ label ++ " "
          ++ progressBar done total ++ " "
          ++ padLeft 3 (show $ progressPercent done total) ++ "% "
          ++ humanBytes done ++ "/" ++ humanBytes total
          ++ " file=" ++ takeFileName remote
  IO.hPutStr IO.stderr line
  when (done >= total) $ IO.hPutChar IO.stderr '\n'
  IO.hFlush IO.stderr

progressBar :: Integer -> Integer -> String
progressBar done total =
  "[" ++ body ++ "]"
  where
    width = 30
    filled
      | total <= 0 = width
      | otherwise = fromIntegral $ min (fromIntegral width) $ max 0 $ done * fromIntegral width `div` total
    body
      | done >= total = replicate width '='
      | filled <= 0 = ">" ++ replicate (width - 1) '.'
      | otherwise = replicate filled '=' ++ ">" ++ replicate (width - filled - 1) '.'

padLeft :: Int -> String -> String
padLeft width raw =
  replicate (max 0 $ width - length raw) ' ' ++ raw

progressPercent :: Integer -> Integer -> Integer
progressPercent _ total | total <= 0 = 100
progressPercent done total = min 100 $ max 0 $ done * 100 `div` total

humanBytes :: Integer -> String
humanBytes bytes
  | bytes < 1024 = show bytes ++ " B"
  | bytes < 1024 * 1024 = humanUnit bytes 1024 "KiB"
  | bytes < 1024 * 1024 * 1024 = humanUnit bytes (1024 * 1024) "MiB"
  | otherwise = humanUnit bytes (1024 * 1024 * 1024) "GiB"

humanUnit :: Integer -> Integer -> String -> String
humanUnit bytes unit suffix =
  let tenths = bytes * 10 `div` unit
      whole = tenths `div` 10
      frac = tenths `mod` 10
  in show whole ++ "." ++ show frac ++ " " ++ suffix

runJsonJob :: Transport tp => String -> String -> FilePath -> Workload -> Int -> ClientT tp IO BS.ByteString
runJsonJob prefix func job wl timeoutSecs = do
  bs <- runRawJob prefix func job wl timeoutSecs
  _ <- liftClientIO $ decodeOkResponse bs
  pure bs

runRawJob :: Transport tp => String -> String -> FilePath -> Workload -> Int -> ClientT tp IO BS.ByteString
runRawJob prefix func job wl timeoutSecs = do
  let fullFunc = prefixFunctionName prefix func
  result <- runJob (fromString fullFunc) (fromString job) wl timeoutSecs
  case result of
    Just bs -> pure bs
    Nothing -> liftClientIO $ die $ "file-proxy worker function failed: " ++ fullFunc

emptyWorkload :: Workload
emptyWorkload = Workload BS.empty

jsonWorkload :: Value -> Workload
jsonWorkload = Workload . LB.toStrict . encode

decodeOkResponse :: BS.ByteString -> IO Value
decodeOkResponse bs =
  case eitherDecodeStrict' bs of
    Left e -> die $ "invalid JSON response: " ++ e
    Right v -> do
      okValue <- requireField "ok" v
      if okValue
        then pure v
        else die $ formatApiError v

requireField :: FromJSON a => String -> Value -> IO a
requireField fieldName responseValue =
  case fieldValue fieldName responseValue of
    Just v  -> pure v
    Nothing -> die $ "missing or invalid response field: " ++ fieldName

fieldValue :: FromJSON a => String -> Value -> Maybe a
fieldValue fieldName =
  parseMaybe $ withObject "Response" \obj -> obj .: fromString fieldName

formatApiError :: Value -> String
formatApiError responseValue =
  fromMaybe "request failed" do
    errorValue <- fieldValue "error" responseValue
    code <- fieldValue "code" errorValue
    message <- fieldValue "message" errorValue
    pure $ code ++ ": " ++ message

validateChunkSize :: Int -> ClientT tp IO ()
validateChunkSize size =
  when (size <= 0) $ liftClientIO $ die "chunk size must be positive"

nextChunkSize :: Int -> Integer -> Integer -> Integer
nextChunkSize chunkSize offset total =
  max 0 $ min (fromIntegral chunkSize) (total - offset)

readFileChunk :: FilePath -> Integer -> Integer -> IO BS.ByteString
readFileChunk path offset size =
  IO.withBinaryFile path IO.ReadMode \h -> do
    IO.hSeek h IO.AbsoluteSeek offset
    BS.hGet h $ fromIntegral size

uploadLockKey :: FilePath -> String
uploadLockKey remote = "upload-" ++ sha256Bytes (B.pack remote)

acquireNamedLock :: String -> String -> IO ()
acquireNamedLock label lockPath = do
  createDirectoryIfMissing True $ takeDirectory lockPath
  exists <- doesPathExist lockPath
  if exists
    then
      die $ label ++ " is already in progress (lock: " ++ lockPath ++ ")"
    else do
      acquired <- E.try (createNamedPipe lockPath 0o600) :: IO (Either E.IOException ())
      case acquired of
        Right () -> pure ()
        Left _ ->
          die $ label ++ " is already in progress (lock: " ++ lockPath ++ ")"

releaseNamedLock :: String -> IO ()
releaseNamedLock lockPath = do
  removed <- E.try (removeFile lockPath) :: IO (Either E.IOException ())
  case removed of
    Right () -> pure ()
    Left _ -> pure ()

withUploadLock :: Transport tp => FilePath -> ClientT tp IO a -> ClientT tp IO a
withUploadLock remote clientAction = do
  liftClientIO $ acquireUploadLock remote
  clientAction `finally` liftClientIO (releaseUploadLock remote)

withDownloadLock :: Transport tp => FilePath -> ClientT tp IO a -> ClientT tp IO a
withDownloadLock local clientAction = do
  liftClientIO $ acquireDownloadLock local
  clientAction `finally` liftClientIO (releaseDownloadLock local)

acquireUploadLock :: FilePath -> IO ()
acquireUploadLock remote = do
  acquireNamedLock ("upload for remote path " ++ remote) ("/tmp" </> "file-proxy-client-locks" </> uploadLockKey remote)

releaseUploadLock :: FilePath -> IO ()
releaseUploadLock remote = do
  releaseNamedLock $ "/tmp" </> "file-proxy-client-locks" </> uploadLockKey remote

downloadLockPath :: FilePath -> FilePath
downloadLockPath local = downloadPartPath local ++ ".lock"

acquireDownloadLock :: FilePath -> IO ()
acquireDownloadLock local = do
  createDirectoryIfMissing True $ takeDirectory local
  acquireNamedLock ("download for local path " ++ local) (downloadLockPath local)

releaseDownloadLock :: FilePath -> IO ()
releaseDownloadLock local =
  releaseNamedLock $ downloadLockPath local

downloadPartPath :: FilePath -> FilePath
downloadPartPath path = path ++ ".part"

downloadMetaPath :: FilePath -> FilePath
downloadMetaPath path = downloadPartPath path ++ ".json"

prepareDownloadPart :: FilePath -> Integer -> String -> IO Integer
prepareDownloadPart local remoteSize remoteSha = do
  createDirectoryIfMissing True $ takeDirectory local
  let partPath = downloadPartPath local
      metaPath = downloadMetaPath local
  meta <- readDownloadMeta metaPath
  case meta of
    Just DownloadMeta {..}
      | downloadMetaSize == remoteSize
      , downloadMetaSha256 == remoteSha
      , 0 <= downloadMetaNextOffset
      , downloadMetaNextOffset <= remoteSize -> do
          completePart <- downloadPartHasSize partPath remoteSize
          if completePart
            then pure downloadMetaNextOffset
            else resetDownloadPart partPath remoteSize >> pure 0
    _ -> prepareLegacyDownloadPart partPath remoteSize remoteSha >>= \offset -> do
      recordDownloadProgress local remoteSize remoteSha offset
      pure offset

prepareLegacyDownloadPart :: FilePath -> Integer -> String -> IO Integer
prepareLegacyDownloadPart partPath remoteSize remoteSha = do
  exists <- doesFileExist partPath
  offset <-
    if exists
      then do
        currentSize <- getFileSize partPath
        when (currentSize > remoteSize) $ die "existing .part file is larger than the remote file"
        if currentSize == remoteSize
          then do
            actualSha <- sha256File partPath
            pure $ if actualSha == remoteSha then remoteSize else 0
          else pure currentSize
      else pure 0
  resetDownloadPart partPath remoteSize
  pure offset

resetDownloadPart :: FilePath -> Integer -> IO ()
resetDownloadPart partPath remoteSize = do
  exists <- doesFileExist partPath
  when (not exists) $ BS.writeFile partPath BS.empty
  IO.withBinaryFile partPath IO.ReadWriteMode \h ->
    IO.hSetFileSize h remoteSize

downloadPartHasSize :: FilePath -> Integer -> IO Bool
downloadPartHasSize partPath remoteSize = do
  exists <- doesFileExist partPath
  if not exists
    then pure False
    else do
      currentSize <- getFileSize partPath
      pure $ currentSize == remoteSize

writeDownloadChunk :: FilePath -> Integer -> BS.ByteString -> IO ()
writeDownloadChunk local offset chunk =
  IO.withBinaryFile (downloadPartPath local) IO.ReadWriteMode \h -> do
    IO.hSeek h IO.AbsoluteSeek offset
    BS.hPut h chunk

recordDownloadProgress :: FilePath -> Integer -> String -> Integer -> IO ()
recordDownloadProgress local remoteSize remoteSha nextOffset =
  BS.writeFile (downloadMetaPath local) $ LB.toStrict $ encode $
    DownloadMeta remoteSize remoteSha nextOffset

readDownloadMeta :: FilePath -> IO (Maybe DownloadMeta)
readDownloadMeta path = do
  exists <- doesFileExist path
  if exists
    then either (const Nothing) Just . eitherDecodeStrict' <$> BS.readFile path
    else pure Nothing

finishDownload :: FilePath -> Integer -> String -> IO ()
finishDownload local remoteSize expectedSha = do
  let partPath = downloadPartPath local
      metaPath = downloadMetaPath local
  actualSha <- sha256File partPath
  when (actualSha /= expectedSha) do
    recordDownloadProgress local remoteSize expectedSha 0
    die "download checksum mismatch; leaving .part file in place"
  targetExists <- doesFileExist local
  when targetExists $ removeFile local
  renameFile partPath local
  metaExists <- doesFileExist metaPath
  when metaExists $ removeFile metaPath

printBytesLn :: BS.ByteString -> IO ()
printBytesLn bs = do
  BS.hPut IO.stdout bs
  IO.hPutChar IO.stdout '\n'

liftClientIO :: IO a -> ClientT tp IO a
liftClientIO = liftIO

lookupNonEmptyEnv :: String -> IO (Maybe String)
lookupNonEmptyEnv name = do
  envValue <- lookupEnv name
  pure $ case envValue of
    Just "" -> Nothing
    other   -> other

lookupReadEnv :: Read a => String -> IO (Either String (Maybe a))
lookupReadEnv name = do
  envValue <- lookupNonEmptyEnv name
  pure $ case envValue of
    Nothing -> Right Nothing
    Just raw ->
      case readMaybe raw of
        Just parsed -> Right $ Just parsed
        Nothing     -> Left $ "Invalid value for $" ++ name ++ ": " ++ show raw

requireAuthPair :: Maybe String -> Maybe String -> IO (Maybe ClientIdentity)
requireAuthPair Nothing Nothing = pure Nothing
requireAuthPair (Just "") (Just "") = pure Nothing
requireAuthPair (Just name) (Just token)
  | not (null name) && not (null token) = pure $ Just $ ClientIdentity (B.pack name) (B.pack token)
  | otherwise = die "--client-name and --client-token must be provided together"
requireAuthPair _ _ = die "--client-name and --client-token must be provided together"

validateHost :: String -> IO ()
validateHost host =
  when (not ("tcp" `prefixOf` host) && not ("unix" `prefixOf` host)) $
    die $ "invalid host: " ++ host

prefixOf :: String -> String -> Bool
prefixOf prefix input = take (length prefix) input == prefix
