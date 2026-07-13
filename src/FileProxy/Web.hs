{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}

module FileProxy.Web (webMain) where

import           Data.Aeson (Value, eitherDecodeStrict', encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LB
import           Data.Maybe (fromMaybe)
import           Data.String (fromString)
import           FileProxy.Worker (prefixFunctionName)
import           FileProxy.WebAssets (embeddedFiles)
import qualified Metro.TP.RSA as RSA (RSAMode (AES), configClient)
import           Metro.Class (Transport)
import           Metro.TP.Socket (socket)
import           Options.Applicative
import           Periodic.Trans.Client (ClientT, open, openWithAuth, runClientT,
                                         runJob)
import           Periodic.Types (ClientIdentity (ClientIdentity), Workload (Workload))
import           System.Environment (lookupEnv)
import           Text.Read (readMaybe)
import           Web.Scotty
import           Network.Wai.Handler.Warp (setHost, setPort)
import           Network.HTTP.Types.Status (status404)
import           System.FilePath ((</>))

data WebOptions = WebOptions
  { webHost       :: String
  , webPort       :: Int
  , workerHost    :: String
  , workerPrefix  :: String
  , rsaPrivate    :: FilePath
  , rsaPublic     :: FilePath
  , rsaMode       :: RSA.RSAMode
  , clientName    :: Maybe String
  , clientToken   :: Maybe String
  }

webMain :: IO ()
webMain = do
  defaults <- envDefaults
  opts <- execParser $ info (helper <*> parser defaults) (fullDesc <> Options.Applicative.header "file-proxy-web - HTTP gateway and web client server")
  let warpSettings = setPort (webPort opts) $ setHost (fromString $ webHost opts) (settings defaultOptions)
  scottyOpts (defaultOptions {settings = warpSettings}) $ routes opts

data WebDefaults = WebDefaults
  { defaultHost :: String
  , defaultPort :: Int
  , defaultWorkerHost :: String
  , defaultPrefix :: String
  , defaultRsaPrivate :: FilePath
  , defaultRsaPublic :: FilePath
  , defaultRsaMode :: RSA.RSAMode
  , defaultClientName :: Maybe String
  , defaultClientToken :: Maybe String
  }

envDefaults :: IO WebDefaults
envDefaults = WebDefaults
  <$> envString "FILE_PROXY_WEB_HOST" "127.0.0.1"
  <*> envInt "FILE_PROXY_WEB_PORT" 8080
  <*> envString "PERIODIC_PORT" "unix:///tmp/periodic.sock"
  <*> envString "PERIODIC_FUNC_PREFIX" ""
  <*> envString "PERIODIC_RSA_PRIVATE_PATH" ""
  <*> envString "PERIODIC_RSA_PUBLIC_PATH" "public_key.pem"
  <*> envMode "PERIODIC_RSA_MODE" RSA.AES
  <*> optionalEnv "PERIODIC_CLIENT_NAME"
  <*> optionalEnv "PERIODIC_CLIENT_TOKEN"

envString :: String -> String -> IO String
envString name fallback = fromMaybe fallback <$> lookupEnv name

envInt :: String -> Int -> IO Int
envInt name fallback = do
  envRaw <- lookupEnv name
  pure $ fromMaybe fallback (envRaw >>= readMaybe)

envMode :: String -> RSA.RSAMode -> IO RSA.RSAMode
envMode name fallback = do
  envRaw <- lookupEnv name
  pure $ fromMaybe fallback (envRaw >>= readMaybe)

optionalEnv :: String -> IO (Maybe String)
optionalEnv name = do
  envRaw <- lookupEnv name
  pure $ case envRaw of
    Just "" -> Nothing
    other -> other

parser :: WebDefaults -> Parser WebOptions
parser WebDefaults {..} = WebOptions
  <$> strOption (long "host" <> value defaultHost <> showDefault <> help "HTTP bind address [$FILE_PROXY_WEB_HOST]")
  <*> option auto (long "port" <> value defaultPort <> showDefault <> help "HTTP port [$FILE_PROXY_WEB_PORT]")
  <*> strOption (long "worker-host" <> value defaultWorkerHost <> showDefault <> help "Periodic worker address [$PERIODIC_PORT]")
  <*> strOption (long "prefix" <> value defaultPrefix <> showDefault <> help "Periodic function prefix [$PERIODIC_FUNC_PREFIX]")
  <*> strOption (long "rsa-private-path" <> value defaultRsaPrivate <> showDefault <> help "[$PERIODIC_RSA_PRIVATE_PATH]")
  <*> strOption (long "rsa-public-path" <> value defaultRsaPublic <> showDefault <> help "[$PERIODIC_RSA_PUBLIC_PATH]")
  <*> option auto (long "rsa-mode" <> value defaultRsaMode <> showDefault <> help "[$PERIODIC_RSA_MODE]")
  <*> optional (strOption (long "client-name" <> value (fromMaybe "" defaultClientName) <> help "[$PERIODIC_CLIENT_NAME]"))
  <*> optional (strOption (long "client-token" <> value (fromMaybe "" defaultClientToken) <> help "[$PERIODIC_CLIENT_TOKEN]"))

routes :: WebOptions -> ScottyM ()
routes opts = do
  get "/api/health" $ json $ object ["ok" .= True]
  get "/api/list" $ do
    path <- queryParamMaybe "path" >>= pure . fromMaybe "."
    recursive <- queryParamMaybe "recursive" >>= pure . fromMaybe False
    maxDepth <- (queryParamMaybe "maxDepth" :: ActionM (Maybe Int))
    jsonRpc opts "get-directory" (uniqueJob "get-directory" path)
      (object ["path" .= (path :: String), "recursive" .= (recursive :: Bool), "maxDepth" .= maxDepth])
  get "/api/stat" $ queryJson opts "stat-path" "path"
  get "/api/sha256" $ do
    path <- queryParam "path"
    recursive <- queryParamMaybe "recursive" >>= pure . fromMaybe False
    jsonRpc opts "sha256sum" (uniqueJob "sha256sum" (path :: String))
      (object ["path" .= (path :: String), "recursive" .= (recursive :: Bool)])
  get "/api/download/info" $ queryJson opts "download-info" "path"
  get "/api/download/chunk" $ do
    path <- queryParam "path"
    offset <- queryParam "offset"
    size <- queryParam "size"
    result <- liftIO $ runRaw opts "download-chunk" (uniqueJob "download-chunk" (path :: String))
      (LB.fromStrict $ LB.toStrict $ encode (object ["path" .= (path :: String), "offset" .= (offset :: Integer), "size" .= (size :: Integer)]))
    raw (LB.fromStrict result)
  post "/api/mkdir" $ queryJsonBody opts "make-directory" "path"
  post "/api/move" $ jsonBodyRpc opts "move-path"
  post "/api/copy" $ jsonBodyRpc opts "copy-path"
  post "/api/delete" $ jsonBodyRpc opts "delete-path"
  post "/api/upload/begin" $ jsonBodyRpc opts "upload-begin"
  put "/api/upload/chunk/:uploadId/:offset/:sha256" $ do
    uploadId <- captureParam "uploadId"
    offset <- captureParam "offset"
    digest <- captureParam "sha256"
    payload <- body
    jsonRpcRaw opts "upload-chunk" (uploadId ++ "/" ++ offset ++ "/" ++ digest) payload
  get "/api/upload/status/:uploadId" $ do
    uploadId <- captureParam "uploadId"
    jsonRpcRaw opts "upload-status" uploadId LB.empty
  post "/api/upload/finish/:uploadId" $ do
    uploadId <- captureParam "uploadId"
    jsonRpcRaw opts "upload-finish" uploadId LB.empty
  post "/api/upload/abort/:uploadId" $ do
    uploadId <- captureParam "uploadId"
    jsonRpcRaw opts "upload-abort" uploadId LB.empty
  get "/" $ staticFile opts "index.html"
  get "/assets/:name" $ do
    name <- captureParam "name"
    staticFile opts ("assets" </> name)

queryJson :: WebOptions -> String -> String -> ActionM ()
queryJson opts func field = do
  path <- queryParam (fromString field)
  jsonRpc opts func (uniqueJob func (path :: String)) (object [fromString field .= (path :: String)])

queryJsonBody :: WebOptions -> String -> String -> ActionM ()
queryJsonBody opts func field = do
  path <- queryParam (fromString field)
  jsonRpc opts func (uniqueJob func (path :: String)) (object [fromString field .= (path :: String)])

jsonBodyRpc :: WebOptions -> String -> ActionM ()
jsonBodyRpc opts func = do
  payload <- body
  jsonRpcRaw opts func (uniqueJob func "request") payload

jsonRpc :: WebOptions -> String -> String -> Value -> ActionM ()
jsonRpc opts func job payload = jsonRpcRaw opts func job (encode payload)

jsonRpcRaw :: WebOptions -> String -> String -> LB.ByteString -> ActionM ()
jsonRpcRaw opts func job payload = do
  response <- liftIO $ runRaw opts func job payload
  case eitherDecodeStrict' response of
    Left _ -> raw (LB.fromStrict response)
    Right decoded -> json (decoded :: Value)

runRaw :: WebOptions -> String -> String -> LB.ByteString -> IO BS.ByteString
runRaw WebOptions {..} func job payload = do
  auth <- requireAuth clientName clientToken
  let rpcAction :: forall tp. Transport tp => ClientT tp IO BS.ByteString
      rpcAction = do
        result <- runJob (fromString $ prefixFunctionName workerPrefix func)
          (fromString job) (Workload $ LB.toStrict payload) 300
        case result of
          Just response -> pure response
          Nothing -> liftIO $ ioError $ userError $ "file-proxy worker function failed: " ++ func
  if null rsaPrivate
    then do
      env <- maybe (open $ socket workerHost) (openWithAuth $ socket workerHost) auth
      runClientT env rpcAction
    else do
      transport <- RSA.configClient rsaMode rsaPrivate rsaPublic
      env <- maybe (open $ transport $ socket workerHost) (openWithAuth $ transport $ socket workerHost) auth
      runClientT env rpcAction

requireAuth :: Maybe String -> Maybe String -> IO (Maybe ClientIdentity)
requireAuth Nothing Nothing = pure Nothing
requireAuth (Just "") (Just "") = pure Nothing
requireAuth (Just name) (Just token)
  | not (null name) && not (null token) = pure $ Just $ ClientIdentity (fromString name) (fromString token)
requireAuth _ _ = ioError $ userError "--client-name and --client-token must be provided together"

uniqueJob :: String -> String -> String
uniqueJob func path = func ++ "-web-" ++ path

staticFile :: WebOptions -> FilePath -> ActionM ()
staticFile _ path =
  case lookup path embeddedFiles of
    Just contents -> do
      setHeader "Content-Type" (fromString $ contentType path)
      raw $ LB.fromStrict contents
    Nothing -> status status404 >> text (fromString $ "embedded asset not found: " ++ path)

contentType :: FilePath -> String
contentType path
  | hasSuffix ".html" = "text/html; charset=utf-8"
  | hasSuffix ".css" = "text/css; charset=utf-8"
  | hasSuffix ".js" = "text/javascript; charset=utf-8"
  | hasSuffix ".json" = "application/json"
  | hasSuffix ".svg" = "image/svg+xml"
  | hasSuffix ".png" = "image/png"
  | hasSuffix ".jpg" || hasSuffix ".jpeg" = "image/jpeg"
  | hasSuffix ".gif" = "image/gif"
  | hasSuffix ".webp" = "image/webp"
  | otherwise = "application/octet-stream"
  where
    hasSuffix suffix = reverse suffix `isPrefixOf` reverse path

isPrefixOf :: Eq a => [a] -> [a] -> Bool
isPrefixOf [] _ = True
isPrefixOf _ [] = False
isPrefixOf (x:xs) (y:ys) = x == y && isPrefixOf xs ys
