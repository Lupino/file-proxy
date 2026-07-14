{-# LANGUAGE BlockArguments #-}

module Main where

import qualified Data.ByteString      as BS
import           Data.List            (sort)
import           FileProxy.WebAssets  (embeddedFiles)
import           System.Directory     (doesDirectoryExist, listDirectory)
import           System.FilePath      ((</>), makeRelative)
import           Test.Hspec

main :: IO ()
main = hspec do
  describe "embedded web assets" do
    it "matches the generated frontend distribution" do
      assetPaths <- recursiveFiles "dist"
      let expected = map (makeRelative "dist") assetPaths
      map fst embeddedFiles `shouldBe` expected
      mapM BS.readFile assetPaths `shouldReturn` map snd embeddedFiles

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
