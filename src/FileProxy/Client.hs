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
  , nextChunkSize
  , prepareDownloadPart
  , recordDownloadProgress
  , writeDownloadChunk
  ) where

import           Control.Monad          (when)
import           Control.Monad.IO.Class (liftIO)
import           Data.Aeson             (FromJSON (..), ToJSON (..), Value,
                                         eitherDecodeStrict', encode, object,
                                         withObject, (.:), (.=))
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
import           System.Directory       (createDirectoryIfMissing, doesFileExist,
                                         getFileSize, removeFile, renameFile)
import           System.Environment     (lookupEnv)
import           System.Exit            (die)
import           System.FilePath        (takeDirectory)
import qualified System.IO              as IO
import           Text.Read              (readMaybe)

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
  envFuncPrefix <- lookupNonEmptyEnv "FILE_PROXY_FUNC_PREFIX"
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
    <*> strOption (long "prefix" <> metavar "PREFIX" <> showDefault <> value (fromMaybe "" envFuncPrefix) <> help "Prefix for worker function names [$FILE_PROXY_FUNC_PREFIX].")
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
  )

getParser, putParser, listParser, statParser, sha256Parser, mkdirParser, moveParser, copyParser, removeParser, uploadParser, downloadParser :: Parser Command
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

remoteArg :: Parser FilePath
remoteArg = strArgument (metavar "REMOTE")

remoteArgTo :: Parser FilePath
remoteArgTo = strArgument (metavar "TO")

localArg :: Parser FilePath
localArg = strArgument (metavar "LOCAL")

recursiveOpt :: Parser Bool
recursiveOpt = switch (long "recursive" <> short 'r' <> help "Enable recursive operation")

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

uploadFile :: Transport tp => String -> FilePath -> FilePath -> Int -> Int -> ClientT tp IO ()
uploadFile prefix local remote chunkSize timeoutSecs = do
  validateChunkSize chunkSize
  fileSize <- liftClientIO $ getFileSize local
  digest <- liftClientIO $ sha256File local
  beginBytes <- runJsonJob prefix "upload-begin" remote (jsonWorkload $ object ["size" .= fileSize, "sha256" .= digest, "chunkSize" .= chunkSize]) timeoutSecs
  beginRsp <- liftClientIO $ decodeOkResponse beginBytes
  uploadId <- liftClientIO $ requireField "uploadId" beginRsp
  startOffset <- liftClientIO $ requireField "nextOffset" beginRsp
  loopUpload uploadId startOffset fileSize
  runJsonJob prefix "upload-finish" uploadId emptyWorkload timeoutSecs >>= liftClientIO . printBytesLn
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
          loopUpload uploadId nextOffset fileSize

downloadFile :: Transport tp => String -> FilePath -> FilePath -> Int -> Int -> ClientT tp IO ()
downloadFile prefix remote local chunkSize timeoutSecs = do
  validateChunkSize chunkSize
  infoBytes <- runJsonJob prefix "download-info" remote emptyWorkload timeoutSecs
  response <- liftClientIO $ decodeOkResponse infoBytes
  remoteSize <- liftClientIO $ requireField "size" response
  remoteSha <- liftClientIO $ requireField "sha256" response
  partOffset <- liftClientIO $ prepareDownloadPart local remoteSize remoteSha
  loopDownload partOffset remoteSize remoteSha
  liftClientIO $ finishDownload local remoteSize remoteSha
  liftClientIO $ LBC.putStrLn $ encode $ object ["ok" .= True, "path" .= remote, "local" .= local, "size" .= remoteSize, "sha256" .= remoteSha]
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
          loopDownload nextOffset remoteSize remoteSha

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
