module Main where

import           Control.Monad.IO.Class
import           Language.Haskell.LSP.Test
import qualified FunctionalSpec
import           Test.Hspec
import           TestUtils

main :: IO ()
main = do
  setupStackFiles
  -- run a test session to warm up the cache to prevent timeouts in other tests
  putStrLn "Warming up HIE cache..."
  runSessionWithConfig (defaultConfig { messageTimeout = 120 }) hieCommand fullCaps "test/testdata" $
    liftIO $ putStrLn "HIE cache is warmed up"
  -- withFileLogging "functional.log" $ hspec FunctionalSpec.spec
  withFileLogging logFilePath $ hspec FunctionalSpec.spec
