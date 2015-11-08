{-# LANGUAGE OverloadedStrings #-}
module Haskell.Ide.HaRePlugin where

import           Control.Exception
import           Control.Monad.IO.Class
import           Data.Aeson
import qualified Data.Text as T
import           Haskell.Ide.Engine.PluginDescriptor
import           Haskell.Ide.Engine.PluginUtils
import qualified Language.Haskell.GhcMod as GM (defaultOptions)
import           Language.Haskell.Refact.HaRe
import           System.Directory

-- ---------------------------------------------------------------------

hareDescriptor :: PluginDescriptor
hareDescriptor = PluginDescriptor
  {
    pdCommands =
      [
        Command
          { cmdDesc = CommandDesc
                     { cmdName = "rename"
                     , cmdUiDescription = "rename a variable or type"
                     , cmdFileExtensions = [".hs"]
                     , cmdContexts = [CtxPoint]
                     , cmdAdditionalParams = [RP "name"]
                     }
          , cmdFunc = renameCmd
          }
      ]
  , pdExposedServices = []
  , pdUsedServices    = []
  }

-- ---------------------------------------------------------------------

renameCmd :: Dispatcher
renameCmd req = do
  case getParams ["file","start_pos","name"] req of
    Left err -> return err
    Right [ParamFile fileName,ParamPos pos,ParamText name] -> do
      res <- liftIO $ catchException $ rename defaultSettings GM.defaultOptions (T.unpack fileName) (T.unpack name) pos
      case res of
        Left err -> return (IdeResponseFail (toJSON err))
        Right fs -> do
          fs' <- liftIO $ mapM makeRelativeToCurrentDirectory fs
          return (IdeResponseOk (toJSON fs'))
    Right _ -> error "HarePlugin.renameCmd: should never get here"

-- rename :: RefactSettings -> Options -> FilePath -> String -> SimpPos -> IO [FilePath] 

-- ---------------------------------------------------------------------

catchException :: (IO t) -> IO (Either String t)
catchException f = do
  res <- handle handler (f >>= \r -> return $ Right r)
  return res
  where
    handler:: SomeException -> IO (Either String t)
    handler e = return (Left (show e))
