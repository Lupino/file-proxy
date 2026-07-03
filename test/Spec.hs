{-# LANGUAGE BlockArguments    #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Data.Aeson           (Value (..))
import qualified Data.Aeson.Key       as Key
import qualified Data.Aeson.KeyMap    as KeyMap
import qualified Data.ByteString      as BS
import qualified Data.Text            as Text
import           FileProxy.Client
import           FileProxy.Worker
import           System.Directory     (doesFileExist, getFileSize, removeFile)
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

  describe "resumable download" do
    it "returns download metadata for a file" do
      withTestConfig False \cfg -> do
        _ <- apiPutFile cfg "big/file.bin" "abcdef"
        rsp <- apiDownloadInfo cfg "big/file.bin"
        assertOk rsp
        lookupField "size" rsp `shouldBe` Just (Number 6)
        lookupField "sha256" rsp `shouldBe` Just (String $ Text.pack $ sha256Bytes "abcdef")

    it "reads middle and final partial chunks" do
      withTestConfig False \cfg -> do
        _ <- apiPutFile cfg "big/file.bin" "abcdef"
        middle <- apiDownloadChunk cfg "big/file.bin" (DownloadRange 2 3)
        middle `shouldBe` Right "cde"

        final <- apiDownloadChunk cfg "big/file.bin" (DownloadRange 4 8)
        final `shouldBe` Right "ef"

    it "rejects invalid download paths and ranges" do
      withTestConfig False \cfg -> do
        missing <- apiDownloadChunk cfg "missing.bin" (DownloadRange 0 3)
        assertLeftError "not_found" missing

        invalidPath <- apiDownloadChunk cfg "../secret.bin" (DownloadRange 0 3)
        assertLeftError "invalid_path" invalidPath

        _ <- apiPutFile cfg "file.bin" "abc"
        negative <- apiDownloadChunk cfg "file.bin" (DownloadRange (-1) 1)
        assertLeftError "invalid_range" negative

        zero <- apiDownloadChunk cfg "file.bin" (DownloadRange 0 0)
        assertLeftError "invalid_range" zero

        pastEnd <- apiDownloadChunk cfg "file.bin" (DownloadRange 3 1)
        assertLeftError "range_out_of_bounds" pastEnd

    it "reconstructs a file from multiple chunks and verifies sha256" do
      withTestConfig False \cfg -> do
        let body = "abcdefghij"
        _ <- apiPutFile cfg "remote.bin" body
        first <- apiDownloadChunk cfg "remote.bin" (DownloadRange 0 4)
        second <- apiDownloadChunk cfg "remote.bin" (DownloadRange 4 4)
        third <- apiDownloadChunk cfg "remote.bin" (DownloadRange 8 4)

        let reconstructed = mconcat [unwrapRight first, unwrapRight second, unwrapRight third]
        reconstructed `shouldBe` body
        sha256Bytes reconstructed `shouldBe` sha256Bytes body

    it "creates a sized download placeholder with progress metadata" do
      withTestConfig False \cfg -> do
        let local = cfgRoot cfg </> "download.bin"
            expectedSha = sha256Bytes "abcdef"

        offset <- prepareDownloadPart local 6 expectedSha
        offset `shouldBe` 0
        getFileSize (downloadPartPath local) `shouldReturn` 6
        doesFileExist (downloadMetaPath local) `shouldReturn` True

    it "resumes downloads from metadata instead of placeholder size" do
      withTestConfig False \cfg -> do
        let local = cfgRoot cfg </> "download.bin"
            expectedSha = sha256Bytes "abcdef"

        _ <- prepareDownloadPart local 6 expectedSha
        writeDownloadChunk local 0 "abc"
        recordDownloadProgress local 6 expectedSha 3

        offset <- prepareDownloadPart local 6 expectedSha
        offset `shouldBe` 3
        getFileSize (downloadPartPath local) `shouldReturn` 6

    it "resets download progress when metadata outlives the partial file" do
      withTestConfig False \cfg -> do
        let local = cfgRoot cfg </> "download.bin"
            expectedSha = sha256Bytes "abcdef"

        _ <- prepareDownloadPart local 6 expectedSha
        writeDownloadChunk local 0 "abc"
        recordDownloadProgress local 6 expectedSha 3
        removeFile $ downloadPartPath local

        offset <- prepareDownloadPart local 6 expectedSha
        offset `shouldBe` 0
        getFileSize (downloadPartPath local) `shouldReturn` 6

    it "keeps compatibility with legacy partial download files" do
      withTestConfig False \cfg -> do
        let local = cfgRoot cfg </> "download.bin"
            partPath = downloadPartPath local
            expectedSha = sha256Bytes "abcdef"

        BS.writeFile partPath "abc"
        offset <- prepareDownloadPart local 6 expectedSha
        offset `shouldBe` 3
        getFileSize partPath `shouldReturn` 6

    it "cleans download metadata after sha256 verification" do
      withTestConfig False \cfg -> do
        let local = cfgRoot cfg </> "download.bin"
            expectedSha = sha256Bytes "abcdef"

        _ <- prepareDownloadPart local 6 expectedSha
        writeDownloadChunk local 0 "abc"
        recordDownloadProgress local 6 expectedSha 3
        writeDownloadChunk local 3 "def"
        recordDownloadProgress local 6 expectedSha 6
        finishDownload local 6 expectedSha

        BS.readFile local `shouldReturn` "abcdef"
        doesFileExist (downloadPartPath local) `shouldReturn` False
        doesFileExist (downloadMetaPath local) `shouldReturn` False

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
            dataFile = uploadDataPath cfg uploadId

        beginRsp <- apiUploadBegin cfg target begin
        assertOk beginRsp
        lookupField "uploadId" beginRsp `shouldBe` Just (String $ Text.pack uploadId)
        getFileSize dataFile `shouldReturn` 6

        secondRsp <- apiUploadChunk cfg (uploadId </> "3" </> sha256Bytes second) second
        assertOk secondRsp
        lookupField "nextOffset" secondRsp `shouldBe` Just (Number 0)

        duplicateRsp <- apiUploadChunk cfg (uploadId </> "3" </> sha256Bytes second) second
        assertOk duplicateRsp
        assertRangeCount 1 duplicateRsp

        firstRsp <- apiUploadChunk cfg (uploadId </> "0" </> sha256Bytes first) first
        assertOk firstRsp
        lookupField "nextOffset" firstRsp `shouldBe` Just (Number 6)

        finishRsp <- apiUploadFinish cfg uploadId
        assertOk finishRsp
        lookupField "sha256" finishRsp `shouldBe` Just (String $ Text.pack $ sha256Bytes body)
        BS.readFile (cfgRoot cfg </> target) `shouldReturn` body

    it "repairs upload placeholders when begin resumes an existing session" do
      withTestConfig False \cfg -> do
        let target = "repair.bin"
            body = "abcdef"
            first = "abc"
            begin = UploadBegin 6 (sha256Bytes body) (Just 3)
            uploadId = uploadIdFor target begin
            dataFile = uploadDataPath cfg uploadId

        beginRsp <- apiUploadBegin cfg target begin
        assertOk beginRsp
        firstRsp <- apiUploadChunk cfg (uploadId </> "0" </> sha256Bytes first) first
        assertOk firstRsp
        lookupField "nextOffset" firstRsp `shouldBe` Just (Number 3)
        removeFile dataFile

        resumeRsp <- apiUploadBegin cfg target begin
        assertOk resumeRsp
        lookupField "nextOffset" resumeRsp `shouldBe` Just (Number 0)
        getFileSize dataFile `shouldReturn` 6

    it "rejects empty upload chunks" do
      withTestConfig False \cfg -> do
        let target = "empty.bin"
            body = "abc"
            begin = UploadBegin 3 (sha256Bytes body) (Just 3)
            uploadId = uploadIdFor target begin

        beginRsp <- apiUploadBegin cfg target begin
        assertOk beginRsp
        chunkRsp <- apiUploadChunk cfg (uploadId </> "0" </> sha256Bytes "") ""
        assertError "invalid_chunk_size" chunkRsp

    it "rejects upload ids with path traversal" do
      withTestConfig False \cfg -> do
        statusRsp <- apiUploadStatus cfg "../../target"
        assertError "invalid_upload_id" statusRsp

  describe "client transfer helpers" do
    it "calculates bounded chunk sizes" do
      nextChunkSize defaultChunkSize 0 3 `shouldBe` 3
      nextChunkSize 4 0 10 `shouldBe` 4
      nextChunkSize 4 8 10 `shouldBe` 2
      nextChunkSize 4 10 10 `shouldBe` 0

    it "uses a stable partial download path" do
      downloadPartPath "remote.bin" `shouldBe` "remote.bin.part"

    it "prefixes worker function names with raw concatenation" do
      prefixFunctionName "" "get-file" `shouldBe` "get-file"
      prefixFunctionName "files-" "get-file" `shouldBe` "files-get-file"

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _        = False

withTestConfig :: Bool -> (ApiConfig -> IO a) -> IO a
withTestConfig allow action =
  withSystemTempDirectory "file-proxy-test" \dir ->
    action $ ApiConfig dir allow

uploadDataPath :: ApiConfig -> String -> FilePath
uploadDataPath cfg uploadId =
  cfgRoot cfg </> ".file-proxy" </> "uploads" </> uploadId </> "data.bin"

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

assertRangeCount :: Int -> Value -> Expectation
assertRangeCount expected rsp =
  case lookupField "receivedRanges" rsp of
    Just (Array ranges) -> length ranges `shouldBe` expected
    other -> expectationFailure $ "expected receivedRanges array, got " ++ show other

assertLeftError :: String -> Either ApiError BS.ByteString -> Expectation
assertLeftError code rsp =
  case rsp of
    Left e -> errorCode e `shouldBe` code
    Right bs -> expectationFailure $ "expected error " ++ code ++ ", got bytes " ++ show bs

unwrapRight :: Either ApiError BS.ByteString -> BS.ByteString
unwrapRight (Right bs) = bs
unwrapRight (Left e)   = error $ "unexpected error: " ++ show e
