module FileProxy.Version
  ( fileProxyClientVersionText
  , fileProxyVersionText
  , packageVersion
  , versionedProgramName
  ) where

import           Data.Version     (showVersion)
import           Paths_file_proxy (version)

packageVersion :: String
packageVersion = showVersion version

versionedProgramName :: String -> String
versionedProgramName name = name ++ " " ++ packageVersion

fileProxyVersionText :: String
fileProxyVersionText = versionedProgramName "file-proxy"

fileProxyClientVersionText :: String
fileProxyClientVersionText = versionedProgramName "file-proxy-client"
