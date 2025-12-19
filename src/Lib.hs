{-# LANGUAGE RecordWildCards #-}

module Lib
  ( someFunc
  ) where


import           Control.Monad         (void)
import qualified Data.ByteString.Char8 as B (readFile, writeFile)
import           Data.String           (fromString)
import           Metro.Class           (Transport)
import           Metro.TP.Socket       (socket)
import           Options.Applicative
import           Periodic.Trans.Job    (JobT, name, workDone, workDone_,
                                        workload)
import           Periodic.Trans.Worker (addFunc, startWorkerT, work)
import           System.Directory      (createDirectoryIfMissing, doesFileExist)
import           System.FilePath       (dropDrive, dropFileName,
                                        dropTrailingPathSeparator, joinPath,
                                        splitPath, (</>))
import           UnliftIO

data Flags = Flags
  { hostPort   :: String
  , rootPath   :: FilePath
  , workThread :: Int
  }

flags :: Parser Flags
flags = Flags
  <$> strOption (long "host" <> short 'H' <> metavar "HOST" <> help "Periodic server address.")
  <*> strOption (long "root" <> short 'r' <> metavar "ROOT" <> showDefault <> value "." <> help "FileSystem root path.")
  <*> option auto (long "thread" <> short 't' <> metavar "INT" <> showDefault <> value 10 <> help "Work thread.")

someFunc :: IO ()
someFunc = do
  Flags {..} <- execParser opts
  startWorkerT (socket hostPort) $ do
    void $ addFunc (fromString "get-file") $ getFile rootPath
    void $ addFunc (fromString "put-file") $ putFile rootPath
    work workThread
  where opts = info (flags <**> helper) (fullDesc <> header "file-proxy - a file proxy worker" )


getFile :: (Transport tp, MonadUnliftIO m) => FilePath -> JobT tp m ()
getFile root = do
  n <- normal root <$> name
  bs <- liftIO $ do
    exists <- doesFileExist n
    if exists then B.readFile n
              else return $ fromString $ "Error: file " ++ n ++ " not exists"
  void $ workDone_ bs

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
