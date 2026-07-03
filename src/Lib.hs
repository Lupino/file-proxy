{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE BlockArguments    #-}

module Lib
  ( someFunc
  ) where


import           Control.Monad         (forM, unless, void)
import           Data.Aeson            (ToJSON (..), encode, object, (.=))
import qualified Data.ByteString.Char8 as B (ByteString, pack, readFile,
                                             writeFile)
import qualified Data.ByteString.Lazy  as LB (toStrict)
import           Data.Maybe            (catMaybes, fromMaybe)
import           Data.String           (fromString)
import           Data.Time.Clock       (UTCTime)
import           Metro.Class           (Transport)
import qualified Metro.TP.RSA          as RSA (RSAMode (AES), configClient)
import           Metro.TP.Socket       (socket)
import           Options.Applicative
import           Periodic.Trans.Job    (JobT, name, workDone, workDone_,
                                        workload)
import           Periodic.Trans.Worker (WorkerT, addFunc,
                                        startWorkerTWithSignalWithAuth, work)
import           Periodic.Types        (ClientIdentity (ClientIdentity))
import           System.Directory      (createDirectoryIfMissing,
                                        doesDirectoryExist, doesFileExist,
                                        getDirectoryContents,
                                        getModificationTime)
import           System.Environment    (lookupEnv)
import           System.Exit           (exitFailure)
import           System.FilePath       (dropDrive, dropFileName,
                                        dropTrailingPathSeparator, joinPath,
                                        splitPath, (</>))
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
  }

flags :: Maybe String -> Maybe String -> Maybe String -> Maybe String -> Maybe String -> Maybe RSA.RSAMode -> Parser Flags
flags mHost mClientName mClientToken mRsaPrivate mRsaPublic mRsaMode =
  mkFlags
    <$> strOption (long "host" <> short 'H' <> metavar "HOST" <> showDefault <> value (fromMaybe "unix:///tmp/periodic.sock" mHost) <> help "Periodic server address [$PERIODIC_PORT].")
    <*> strOption (long "root" <> short 'r' <> metavar "ROOT" <> showDefault <> value "." <> help "FileSystem root path.")
    <*> option auto (long "thread" <> short 't' <> metavar "INT" <> showDefault <> value 10 <> help "Work thread.")
    <*> strOption (long "rsa-private-path" <> metavar "PATH" <> showDefault <> value (fromMaybe "" mRsaPrivate) <> help "RSA private key file path [$PERIODIC_RSA_PRIVATE_PATH].")
    <*> strOption (long "rsa-public-path" <> metavar "PATH" <> showDefault <> value (fromMaybe "public_key.pem" mRsaPublic) <> help "RSA public key file or directory [$PERIODIC_RSA_PUBLIC_PATH].")
    <*> option auto (long "rsa-mode" <> metavar "MODE" <> showDefault <> value (fromMaybe RSA.AES mRsaMode) <> help "RSA mode: Plain, RSA, or AES [$PERIODIC_RSA_MODE].")
    <*> optional (strOption (long "client-name" <> metavar "NAME" <> value (fromMaybe "" mClientName) <> help "Auth client name [$PERIODIC_CLIENT_NAME]."))
    <*> optional (strOption (long "client-token" <> metavar "TOKEN" <> value (fromMaybe "" mClientToken) <> help "Auth client token [$PERIODIC_CLIENT_TOKEN]."))
  where
    mkFlags hostPort rootPath workThread rsaPrivatePath rsaPublicPath rsaMode clientName clientToken =
      Flags
        { hostPort = hostPort
        , rootPath = rootPath
        , workThread = workThread
        , rsaPrivatePath = rsaPrivatePath
        , rsaPublicPath = rsaPublicPath
        , rsaMode = rsaMode
        , clientName = clientName
        , clientToken = clientToken
        }

someFunc :: IO ()
someFunc = do
  envHost <- lookupEnv "PERIODIC_PORT"
  envClientName <- lookupEnv "PERIODIC_CLIENT_NAME"
  envClientToken <- lookupEnv "PERIODIC_CLIENT_TOKEN"
  envRsaPrivate <- lookupEnv "PERIODIC_RSA_PRIVATE_PATH"
  envRsaPublic <- lookupEnv "PERIODIC_RSA_PUBLIC_PATH"
  envRsaMode <- traverse readRsaMode =<< lookupEnv "PERIODIC_RSA_MODE"

  parsedFlags@Flags {..} <- execParser $ opts envHost envClientName envClientToken envRsaPrivate envRsaPublic envRsaMode
  auth <- requireAuthPair parsedFlags

  case rsaPrivatePath of
    "" -> startWorkerTWithSignalWithAuth auth Nothing (pure ()) (socket hostPort) $ registerWorkers rootPath workThread
    _ -> do
      genTP <- RSA.configClient rsaMode rsaPrivatePath rsaPublicPath
      startWorkerTWithSignalWithAuth auth Nothing (pure ()) (genTP $ socket hostPort) $ registerWorkers rootPath workThread
  where opts h n t priv pub mode = info (flags h n t priv pub mode <**> helper) (fullDesc <> header "file-proxy - a file proxy worker" )

registerWorkers :: (Transport tp, MonadUnliftIO m) => FilePath -> Int -> WorkerT tp m ()
registerWorkers root thread = do
  void $ addFunc (fromString "get-file") $ getFile root
  void $ addFunc (fromString "get-directory") $ getDirectory root
  void $ addFunc (fromString "put-file") $ putFile root
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

data FileTree = Directory String UTCTime Int [FileTree] | FileName String Int UTCTime
  deriving (Show)

instance ToJSON FileTree where
  toJSON (Directory dir modifiedAt fileCount trees) =
    object [ "name" .= dir
           , "type" .= ("directory" :: String)
           , "modifiedAt" .= modifiedAt
           , "fileCount" .= fileCount
           , "children" .= trees
           ]
  toJSON (FileName file size modifiedAt) =
    object [ "name" .= file
           , "type" .= ("file" :: String)
           , "size" .= size
           , "modifiedAt" .= modifiedAt
           ]
encodeTreeList :: [FileTree] -> B.ByteString
encodeTreeList = LB.toStrict . encode

getFileTreeList :: FilePath -> IO [FileTree]
getFileTreeList topdir = do
  isDirectory <- doesDirectoryExist topdir
  unless isDirectory $ createDirectoryIfMissing True topdir
  names <- getDirectoryContents topdir
  let properNames = filter (`notElem` [".", ".."]) names
  catMaybes <$> forM properNames (\file -> do
    let path = topdir </> file
    isSubDirectory <- doesDirectoryExist path
    if isSubDirectory then do
      modifiedAt <- getModificationTime path
      fileCount <- getDirectoryFileCount path
      return $ Just $ Directory file modifiedAt fileCount []
    else do
      isFile <- doesFileExist path
      if isFile then do
        size <- fromInteger <$> getFileSize path
        modifiedAt <- getModificationTime path
        return $ Just $ FileName file size modifiedAt
      else return Nothing)

getFileSize :: FilePath -> IO Integer
getFileSize path = IO.withFile path IO.ReadMode IO.hFileSize

getDirectoryFileCount :: FilePath -> IO Int
getDirectoryFileCount dir = do
  names <- getDirectoryContents dir
  let properNames = filter (`notElem` [".", ".."]) names
  length . filter id <$> forM properNames (doesFileExist . (dir </>))

getFile :: (Transport tp, MonadUnliftIO m) => FilePath -> JobT tp m ()
getFile root = do
  n <- normal root <$> name
  bs <- liftIO $ do
    exists <- doesFileExist n
    if exists then B.readFile n
              else return $ fromString $ "Error: file " ++ n ++ " not exists"
  void $ workDone_ bs

getDirectory :: (Transport tp, MonadUnliftIO m) => FilePath -> JobT tp m ()
getDirectory root = do
  n <- normal root <$> name
  trees <- liftIO $ getFileTreeList n
  void $ workDone_ $ encodeTreeList trees

putFile :: (Transport tp, MonadUnliftIO m) => FilePath -> JobT tp m ()
putFile root = do
  n <- normal root <$> name
  bs <- workload
  liftIO $ createDirectoryIfMissing True $ dropFileName n
  liftIO $ B.writeFile n bs
  void workDone

normal :: FilePath -> FilePath -> FilePath
normal root =
  (root </>)
  . dropDrive
  . joinPath
  . filter (/= ".")
  . filter (/= "..")
  . map dropTrailingPathSeparator
  . splitPath
