{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Data.Aeson           (Value (..), decode, encode, object, (.=))
import qualified Data.Aeson.Key       as Key
import qualified Data.Aeson.KeyMap    as KeyMap
import qualified Data.ByteString      as BS
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as LB
import           Data.List            (sort)
import qualified Data.Text            as Text
import           FileProxy.Web.Standalone (standaloneApp)
import           FileProxy.WebAssets  (embeddedFiles)
import           FileProxy.Worker     (ApiConfig (..), sha256Bytes)
import           Network.HTTP.Types   (RequestHeaders, hContentType, methodPost,
                                        methodPut, status200)
import           Network.Wai          (Application, defaultRequest, requestHeaders,
                                        requestMethod)
import           Network.Wai.Test     (SRequest (..), SResponse (..), Session,
                                        request, runSession, setPath, simpleBody,
                                        simpleStatus, srequest)
import           System.Directory     (doesDirectoryExist, listDirectory)
import           System.FilePath      ((</>), makeRelative)
import           System.IO.Temp       (withSystemTempDirectory)
import           Test.Hspec

main :: IO ()
main = hspec do
  describe "embedded web assets" do
    it "matches the generated frontend distribution" do
      assetPaths <- recursiveFiles "dist"
      let expected = map (makeRelative "dist") assetPaths
      map fst embeddedFiles `shouldBe` expected
      mapM BS.readFile assetPaths `shouldReturn` map snd embeddedFiles

  describe "standalone web routes" do
    it "serves health and lists the configured root directly" do
      withStandaloneApp False \root app -> do
        BS.writeFile (root </> "hello.txt") "hello"
        health <- runRequest app $ getRequest "/api/health"
        simpleStatus health `shouldBe` status200
        decodeResponse health `shouldBe` Just (object ["ok" .= True])

        listed <- runRequest app $ getRequest "/api/list?path=."
        simpleStatus listed `shouldBe` status200
        (lookupJsonField "ok" =<< decodeResponse listed) `shouldBe` Just (Bool True)

    it "rejects traversal and keeps delete disabled by default" do
      withStandaloneApp False \root app -> do
        BS.writeFile (root </> "keep.txt") "keep"
        traversal <- runRequest app $ getRequest "/api/stat?path=../secret"
        lookupErrorCode traversal `shouldBe` Just "invalid_path"

        deleted <- runRequest app $ jsonRequest methodPost "/api/delete" (object ["path" .= ("keep.txt" :: String)])
        lookupErrorCode deleted `shouldBe` Just "delete_disabled"
        BS.readFile (root </> "keep.txt") `shouldReturn` "keep"

        malformed <- runRequest app $ rawRequest methodPost "/api/delete" "{"
        lookupErrorCode malformed `shouldBe` Just "invalid_workload"

    it "uploads, finalizes, and downloads file chunks without Periodic" do
      withStandaloneApp False \root app -> do
        let contents = "hello"
            digest = sha256Bytes contents
            beginPayload = object
              [ "path" .= ("nested/hello.txt" :: String)
              , "size" .= (BS.length contents)
              , "sha256" .= digest
              , "chunkSize" .= BS.length contents
              ]
        begun <- runRequest app $ jsonRequest methodPost "/api/upload/begin" beginPayload
        uploadId <- responseString "uploadId" begun

        uploaded <- runRequest app $ rawRequest methodPut
          ("/api/upload/chunk/" ++ uploadId ++ "/0/" ++ sha256Bytes contents) contents
        (lookupJsonField "ok" =<< decodeResponse uploaded) `shouldBe` Just (Bool True)

        finished <- runRequest app $ rawRequest methodPost ("/api/upload/finish/" ++ uploadId) ""
        (lookupJsonField "ok" =<< decodeResponse finished) `shouldBe` Just (Bool True)
        BS.readFile (root </> "nested/hello.txt") `shouldReturn` contents

        chunk <- runRequest app $ getRequest "/api/download/chunk?path=nested%2Fhello.txt&offset=1&size=3"
        simpleStatus chunk `shouldBe` status200
        simpleBody chunk `shouldBe` "ell"

recursiveFiles :: FilePath -> IO [FilePath]
recursiveFiles directory = do
  entries <- sort <$> listDirectory directory
  paths <- mapM visit entries
  pure $ concat paths
  where
    visit entry = do
      let path = directory </> entry
      isDirectory <- doesDirectoryExist path
      if isDirectory
        then recursiveFiles path
        else pure [path]

withStandaloneApp :: Bool -> (FilePath -> Application -> IO a) -> IO a
withStandaloneApp allowDelete action =
  withSystemTempDirectory "file-proxy-web-standalone" \root -> do
    app <- standaloneApp $ ApiConfig root allowDelete
    action root app

runRequest :: Application -> Session SResponse -> IO SResponse
runRequest app session = runSession session app

getRequest :: String -> Session SResponse
getRequest path = request $ setPath defaultRequest (B8.pack path)

jsonRequest :: BS.ByteString -> String -> Value -> Session SResponse
jsonRequest method path payload = rawRequestWith method path (LB.toStrict $ encode payload)
  [(hContentType, "application/json")]

rawRequest :: BS.ByteString -> String -> BS.ByteString -> Session SResponse
rawRequest method path payload = rawRequestWith method path payload []

rawRequestWith :: BS.ByteString -> String -> BS.ByteString -> RequestHeaders -> Session SResponse
rawRequestWith method path payload headers =
  let req = (setPath defaultRequest (B8.pack path))
        { requestMethod = method
        , requestHeaders = headers
        }
  in srequest $ SRequest req (LB.fromStrict payload)

decodeResponse :: SResponse -> Maybe Value
decodeResponse = decode . simpleBody

lookupJsonField :: String -> Value -> Maybe Value
lookupJsonField name (Object fields) = KeyMap.lookup (Key.fromString name) fields
lookupJsonField _ _ = Nothing

lookupErrorCode :: SResponse -> Maybe String
lookupErrorCode response = do
  Object errorObject <- lookupJsonField "error" =<< decodeResponse response
  String code <- lookupJsonField "code" (Object errorObject)
  pure $ Text.unpack code

responseString :: String -> SResponse -> IO String
responseString field response =
  case lookupJsonField field =<< decodeResponse response of
    Just (String value) -> pure $ Text.unpack value
    other -> expectationFailure ("expected string field " ++ field ++ ", got " ++ show other) >> pure ""
