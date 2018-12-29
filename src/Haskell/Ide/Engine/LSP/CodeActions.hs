{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE FlexibleContexts      #-}
module Haskell.Ide.Engine.LSP.CodeActions where

import Control.Lens
import Control.Monad.Reader
import qualified Data.Aeson as J
import Data.Maybe
import Data.Foldable
import qualified GHC.Generics as G
import Haskell.Ide.Engine.LSP.Reactor
import Haskell.Ide.Engine.Types
import qualified Language.Haskell.LSP.Core as Core
import qualified Language.Haskell.LSP.Types as J
import qualified Language.Haskell.LSP.Types.Lens as J
import qualified Language.Haskell.LSP.Types.Capabilities as C
import Language.Haskell.LSP.VFS
import Language.Haskell.LSP.Messages
import Haskell.Ide.Engine.PluginsIdeMonads

data FallbackCodeActionParams =
  FallbackCodeActionParams
    { fallbackWorkspaceEdit :: Maybe J.WorkspaceEdit
    , fallbackCommand       :: Maybe J.Command
    }
  deriving (G.Generic, J.ToJSON, J.FromJSON)

handleCodeActionReq :: TrackingNumber -> J.CodeActionRequest -> R ()
handleCodeActionReq tn req = do

  vfsFunc <- asksLspFuncs Core.getVirtualFileFunc
  docVersion <- fmap _version <$> liftIO (vfsFunc docUri)
  let docId = J.VersionedTextDocumentIdentifier docUri docVersion

  let getProvider p = pluginCodeActionProvider p <*> return (pluginId p)
      getProviders = do
        IdePlugins m <- getPlugins
        return $ IdeResultOk $ mapMaybe getProvider $ toList m

      providersCb providers =
        let reqs = map (\f -> lift (f docId range context)) providers
        in makeRequests reqs tn (req ^. J.id) (send . concat)

  makeRequest (IReq tn (req ^. J.id) providersCb getProviders)

  where
    params = req ^. J.params
    docUri = params ^. J.textDocument . J.uri
    range = params ^. J.range
    context = params ^. J.context

    wrapCodeAction :: J.CodeAction -> R (Maybe J.CAResult)
    wrapCodeAction action = do

      (C.ClientCapabilities _ textDocCaps _) <- asksLspFuncs Core.clientCapabilities
      let literalSupport = textDocCaps >>= C._codeAction >>= C._codeActionLiteralSupport

      case literalSupport of
        Nothing -> do
            let cmdParams = [J.toJSON (FallbackCodeActionParams (action ^. J.edit) (action ^. J.command))]
            cmd <- mkLspCommand "hie" "fallbackCodeAction" (action ^. J.title) (Just cmdParams)
            return $ Just (J.CACommand cmd)
        Just _ -> return $ Just (J.CACodeAction action)

    send :: [J.CodeAction] -> R ()
    send codeActions = do
      body <- J.List . catMaybes <$> mapM wrapCodeAction codeActions
      reactorSend $ RspCodeAction $ Core.makeResponseMessage req body

  -- TODO: make context specific commands for all sorts of things, such as refactorings          
