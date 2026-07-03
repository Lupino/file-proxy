{-# LANGUAGE BlockArguments    #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Data.Aeson           (Value (..))
import qualified Data.Aeson.Key       as Key
import qualified Data.Aeson.KeyMap    as KeyMap
import qualified Data.ByteString      as BS
import qualified Data.Text            as Text
import           Lib
import           System.Directory     (doesFileExist)
import           System.FilePath      ((</>))
import           System.IO.Temp       (withSystemTempDirectory)
import           Test.Hspec

main :: IO ()
main = hspec do
  describe "path resolution" do
    it "rejects absolute paths, traversal, and reserved internals" do
      let root = "/tmp/root"
      resolveUserPath root "/etc/passwd" `shouldSatisfy` isLeft
      resolveUserPath root "../secret" `shouldSatisfy` isLeft
      resolveUserPath root ".file-proxy/uploads/x" `shouldSatisfy` isLeft
      resolveUserPath root "a/b.txt" `shouldBe` Right (root </> "a/b.txt")

  describe "single-shot file APIs" do
    it "writes a file and returns its sha256" do
      withTestConfig False \cfg -> do
        rsp <- apiPutFile cfg "nested/hello.txt" "hello"
        assertOk rsp
        lookupField "sha256" rsp `shouldBe` Just (String "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        BS.readFile (cfgRoot cfg </> "nested/hello.txt") `shouldReturn` "hello"

    it "returns recursive sha256 manifests for directories" do
      withTestConfig False \cfg -> do
        _ <- apiPutFile cfg "a.txt" "a"
        _ <- apiPutFile cfg "dir/b.txt" "b"
        rsp <- apiSha256Sum cfg "." (ListOptions True Nothing)
        assertOk rsp
        case lookupField "files" rsp of
          Just (Array files) -> length files `shouldBe` 2
          other -> expectationFailure $ "expected files array, got " ++ show other

    it "does not delete unless explicitly enabled" do
      withTestConfig False \cfg -> do
        _ <- apiPutFile cfg "keep.txt" "x"
        rsp <- apiDeletePath cfg "keep.txt" (DeleteOptions False)
        assertError "delete_disabled" rsp
        doesFileExist (cfgRoot cfg </> "keep.txt") `shouldReturn` True

      withTestConfig True \cfg -> do
        _ <- apiPutFile cfg "remove.txt" "x"
        rsp <- apiDeletePath cfg "remove.txt" (DeleteOptions False)
        assertOk rsp
        doesFileExist (cfgRoot cfg </> "remove.txt") `shouldReturn` False

  describe "resumable upload" do
    it "rejects invalid upload metadata" do
      withTestConfig False \cfg -> do
        rsp <- apiUploadBegin cfg "bad.bin" (UploadBegin 10 "not-a-sha" (Just 3))
        assertError "invalid_sha256" rsp

    it "resumes chunks and publishes only after final sha256 verification" do
      withTestConfig False \cfg -> do
        let target = "big/file.bin"
            body = "abcdef"
            first = "abc"
            second = "def"
            begin = UploadBegin 6 (sha256Bytes body) (Just 3)
            uploadId = uploadIdFor target begin

        beginRsp <- apiUploadBegin cfg target begin
        assertOk beginRsp
        lookupField "uploadId" beginRsp `shouldBe` Just (String $ Text.pack uploadId)

        secondRsp <- apiUploadChunk cfg (uploadId </> "3" </> sha256Bytes second) second
        assertOk secondRsp
        lookupField "nextOffset" secondRsp `shouldBe` Just (Number 0)

        duplicateRsp <- apiUploadChunk cfg (uploadId </> "3" </> sha256Bytes second) second
        assertOk duplicateRsp

        firstRsp <- apiUploadChunk cfg (uploadId </> "0" </> sha256Bytes first) first
        assertOk firstRsp
        lookupField "nextOffset" firstRsp `shouldBe` Just (Number 6)

        finishRsp <- apiUploadFinish cfg uploadId
        assertOk finishRsp
        lookupField "sha256" finishRsp `shouldBe` Just (String $ Text.pack $ sha256Bytes body)
        BS.readFile (cfgRoot cfg </> target) `shouldReturn` body

    it "rejects upload ids with path traversal" do
      withTestConfig False \cfg -> do
        statusRsp <- apiUploadStatus cfg "../../target"
        assertError "invalid_upload_id" statusRsp

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _        = False

withTestConfig :: Bool -> (ApiConfig -> IO a) -> IO a
withTestConfig allow action =
  withSystemTempDirectory "file-proxy-test" \dir ->
    action $ ApiConfig dir allow

lookupField :: String -> Value -> Maybe Value
lookupField field (Object obj) = KeyMap.lookup (Key.fromString field) obj
lookupField _ _                = Nothing

assertOk :: Value -> Expectation
assertOk rsp = lookupField "ok" rsp `shouldBe` Just (Bool True)

assertError :: String -> Value -> Expectation
assertError code rsp =
  case lookupField "error" rsp of
    Just errObj -> lookupField "code" errObj `shouldBe` Just (String $ Text.pack code)
    other -> expectationFailure $ "expected error object, got " ++ show other
