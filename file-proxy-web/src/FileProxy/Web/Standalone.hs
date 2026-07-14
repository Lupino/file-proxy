{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module FileProxy.Web.Standalone
  ( standaloneApp
  , standaloneMain
  ) where

import           Data.Aeson (FromJSON, Value, eitherDecodeStrict', object, (.=))
import qualified Data.ByteString.Lazy as LB
import           Data.Maybe (fromMaybe)
import           Data.String (fromString)
import           FileProxy.WebAssets (embeddedFiles)
import           FileProxy.Worker
import           Network.HTTP.Types.Status (status404)
import           Network.Wai (Application)
import           Network.Wai.Handler.Warp (setHost, setPort)
import           Options.Applicative
import           System.Environment (lookupEnv)
import           System.FilePath ((</>))
import           Text.Read (readMaybe)
import           Web.Scotty

data StandaloneOptions = StandaloneOptions
  { standaloneHost        :: String
  , standalonePort        :: Int
  , standaloneRoot        :: FilePath
  , standaloneAllowDelete :: Bool
  }

data StandaloneDefaults = StandaloneDefaults
  { defaultHost        :: String
  , defaultPort        :: Int
  , defaultRoot        :: FilePath
  , defaultAllowDelete :: Bool
  }

standaloneMain :: IO ()
standaloneMain = do
  defaults <- envDefaults
  opts <- execParser $ info (helper <*> parser defaults)
    (fullDesc <> Options.Applicative.header "file-proxy-web-standalone - standalone file proxy web server")
  let settings' = setPort (standalonePort opts) $
        setHost (fromString $ standaloneHost opts) (settings defaultOptions)
      cfg = ApiConfig (standaloneRoot opts) (standaloneAllowDelete opts)
  scottyOpts (defaultOptions {settings = settings'}) $ standaloneRoutes cfg

standaloneApp :: ApiConfig -> IO Application
standaloneApp cfg = scottyApp $ standaloneRoutes cfg

envDefaults :: IO StandaloneDefaults
envDefaults = StandaloneDefaults
  <$> envString "FILE_PROXY_WEB_HOST" "127.0.0.1"
  <*> envInt "FILE_PROXY_WEB_PORT" 8080
  <*> envString "FILE_PROXY_ROOT" "."
  <*> envBool "FILE_PROXY_ALLOW_DELETE" False

envString :: String -> String -> IO String
envString name fallback = fromMaybe fallback <$> lookupEnv name

envInt :: String -> Int -> IO Int
envInt name fallback = do
  envValue <- lookupEnv name
  pure $ fromMaybe fallback (envValue >>= readMaybe)

envBool :: String -> Bool -> IO Bool
envBool name fallback = do
  envValue <- lookupEnv name
  pure $ fromMaybe fallback (envValue >>= parseBool)

parseBool :: String -> Maybe Bool
parseBool rawValue
  | rawValue `elem` ["1", "true", "TRUE", "yes", "YES", "on", "ON"] = Just True
  | rawValue `elem` ["0", "false", "FALSE", "no", "NO", "off", "OFF"] = Just False
  | otherwise = Nothing

parser :: StandaloneDefaults -> Parser StandaloneOptions
parser StandaloneDefaults {..} = StandaloneOptions
  <$> strOption (long "host" <> value defaultHost <> showDefault <> help "HTTP bind address [$FILE_PROXY_WEB_HOST]")
  <*> option auto (long "port" <> value defaultPort <> showDefault <> help "HTTP port [$FILE_PROXY_WEB_PORT]")
  <*> strOption (long "root" <> short 'r' <> value defaultRoot <> showDefault <> help "Filesystem root [$FILE_PROXY_ROOT]")
  <*> (flag' True (long "allow-delete" <> help "Allow delete requests [$FILE_PROXY_ALLOW_DELETE]") <|> pure defaultAllowDelete)

standaloneRoutes :: ApiConfig -> ScottyM ()
standaloneRoutes cfg = do
  get "/api/health" $ json $ object ["ok" .= True]
  get "/api/list" $ do
    path <- queryParamMaybe "path" >>= pure . fromMaybe "."
    recursive <- queryParamMaybe "recursive" >>= pure . fromMaybe False
    maxDepth <- queryParamMaybe "maxDepth" :: ActionM (Maybe Int)
    respondValue =<< liftIO (apiListDirectory cfg path (ListOptions recursive maxDepth (Just path)))
  get "/api/stat" $ do
    path <- queryParam "path"
    respondValue =<< liftIO (apiStatPath cfg path)
  get "/api/sha256" $ do
    path <- queryParam "path"
    recursive <- queryParamMaybe "recursive" >>= pure . fromMaybe False
    respondValue =<< liftIO (apiSha256Sum cfg path (ListOptions recursive Nothing (Just path)))
  get "/api/download/info" $ do
    path <- queryParam "path"
    respondValue =<< liftIO (apiDownloadInfo cfg path)
  get "/api/download/chunk" $ do
    path <- queryParam "path"
    offset <- queryParam "offset"
    size <- queryParam "size"
    result <- liftIO $ apiDownloadChunk cfg path (DownloadRange offset size (Just path))
    case result of
      Left ApiError {..} -> respondValue $ apiError errorCode errorMessage
      Right bytes -> raw $ LB.fromStrict bytes
  post "/api/mkdir" $ do
    path <- queryParam "path"
    respondValue =<< liftIO (apiMakeDirectory cfg path)
  post "/api/move" $ bodyRequest doMove
  post "/api/copy" $ bodyRequest doCopy
  post "/api/delete" $ bodyRequest doDelete
  post "/api/upload/begin" $ bodyRequest doUploadBegin
  put "/api/upload/chunk/:uploadId/:offset/:sha256" $ do
    uploadId <- captureParam "uploadId"
    offset <- captureParam "offset"
    digest <- captureParam "sha256"
    payload <- body
    respondValue =<< liftIO (apiUploadChunk cfg (uploadId </> offset </> digest) (LB.toStrict payload))
  get "/api/upload/status/:uploadId" $ do
    uploadId <- captureParam "uploadId"
    respondValue =<< liftIO (apiUploadStatus cfg uploadId)
  post "/api/upload/finish/:uploadId" $ do
    uploadId <- captureParam "uploadId"
    respondValue =<< liftIO (apiUploadFinish cfg uploadId)
  post "/api/upload/abort/:uploadId" $ do
    uploadId <- captureParam "uploadId"
    respondValue =<< liftIO (apiUploadAbort cfg uploadId)
  get "/" $ staticFile "index.html"
  get "/favicon.svg" $ staticFile "favicon.svg"
  get "/assets/:name" $ do
    name <- captureParam "name"
    staticFile ("assets" </> name)
  where
    doMove moveOpts =
      case moveFrom moveOpts of
        Nothing -> pure $ apiError "invalid_workload" "missing from"
        Just source -> apiMovePath cfg source moveOpts
    doCopy copyOpts =
      case copyFrom copyOpts of
        Nothing -> pure $ apiError "invalid_workload" "missing from"
        Just source -> apiCopyPath cfg source copyOpts
    doDelete deleteOpts =
      case deleteOptionPath deleteOpts of
        Nothing -> pure $ apiError "invalid_workload" "missing path"
        Just path -> apiDeletePath cfg path deleteOpts
    doUploadBegin begin = apiUploadBegin cfg "" begin

bodyRequest :: FromJSON a => (a -> IO Value) -> ActionM ()
bodyRequest handle = do
  payload <- body
  case eitherDecodeStrict' (LB.toStrict payload) of
    Left message -> respondValue $ apiError "invalid_workload" message
    Right decoded -> respondValue =<< liftIO (handle decoded)

respondValue :: Value -> ActionM ()
respondValue = json

apiError :: String -> String -> Value
apiError code message = object
  [ "ok" .= False
  , "error" .= object ["code" .= code, "message" .= message]
  ]

staticFile :: FilePath -> ActionM ()
staticFile path =
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
