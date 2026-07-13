{-# LANGUAGE TemplateHaskell #-}

module FileProxy.WebAssets (embeddedFiles) where

import qualified Data.ByteString as BS
import           Data.FileEmbed (embedDir)

embeddedFiles :: [(FilePath, BS.ByteString)]
embeddedFiles = $(embedDir "web/dist")
