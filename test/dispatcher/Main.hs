{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE DeriveGeneric #-}
module Main where

import           Control.Concurrent
import           Control.Concurrent.STM.TChan
import           Control.Monad.STM
import           Data.Aeson
import qualified Data.HashMap.Strict                   as H
import           Data.Typeable
import qualified Data.Text as T
import           Data.Default
import           GHC                            ( TypecheckedModule )
import           GHC.Generics
import           Haskell.Ide.Engine.MonadTypes
import           Haskell.Ide.Engine.PluginUtils
import           Haskell.Ide.Engine.Scheduler
import           Haskell.Ide.Engine.Types
import           Language.Haskell.LSP.Types
import           TestUtils
import           System.Directory
import           System.FilePath

import           Test.Hspec

-- ---------------------------------------------------------------------
-- plugins

import           Haskell.Ide.Engine.Plugin.ApplyRefact
import           Haskell.Ide.Engine.Plugin.Base
import           Haskell.Ide.Engine.Plugin.Example2
import           Haskell.Ide.Engine.Plugin.GhcMod
import           Haskell.Ide.Engine.Plugin.HaRe
import           Haskell.Ide.Engine.Plugin.HieExtras

{-# ANN module ("HLint: ignore Redundant do"       :: String) #-}
-- ---------------------------------------------------------------------

main :: IO ()
main = do
  setupStackFiles
  withFileLogging "main-dispatcher.log" $ do
    hspec funcSpec

-- main :: IO ()
-- main = do
--   summary <- withFile "results.xml" WriteMode $ \h -> do
--     let c = defaultConfig
--           { configFormatter = xmlFormatter
--           , configHandle = h
--           }
--     hspecWith c Spec.spec
--   unless (summaryFailures summary == 0) $
--     exitFailure

-- ---------------------------------------------------------------------

plugins :: IdePlugins
plugins = pluginDescToIdePlugins
  [applyRefactDescriptor "applyrefact"
  ,example2Descriptor "eg2"
  ,ghcmodDescriptor "ghcmod"
  ,hareDescriptor "hare"
  ,baseDescriptor "base"
  ]

startServer :: IO (Scheduler IO, TChan LogVal, ThreadId)
startServer = do
  scheduler <- newScheduler plugins testOptions
  logChan  <- newTChanIO
  dispatcher <- forkIO $
    runScheduler
    scheduler
    (\lid errCode e -> logToChan logChan ("received an error", Left (lid, errCode, e)))
    (\g x -> g x)
    def

  return (scheduler, logChan, dispatcher)

-- ---------------------------------------------------------------------

type LogVal = (String, Either (LspId, ErrorCode, T.Text) DynamicJSON)

logToChan :: TChan LogVal -> LogVal -> IO ()
logToChan c t = atomically $ writeTChan c t

-- ---------------------------------------------------------------------

dispatchGhcRequest :: ToJSON a
                   => TrackingNumber -> String -> Int
                   -> Scheduler IO -> TChan LogVal
                   -> PluginId -> CommandName -> a -> IO ()
dispatchGhcRequest tn ctx n scheduler lc plugin com arg = do
  let
    logger :: RequestCallback IO DynamicJSON
    logger x = logToChan lc (ctx, Right x)

  let req = GReq tn Nothing Nothing (Just (IdInt n)) logger $
        runPluginCommand plugin com (toJSON arg)
  sendRequest scheduler Nothing req


dispatchIdeRequest :: (Typeable a, ToJSON a)
                   => TrackingNumber -> String -> Scheduler IO
                   -> TChan LogVal -> LspId -> IdeDeferM (IdeResult a) -> IO ()
dispatchIdeRequest tn ctx scheduler lc lid f = do
  let
    logger :: (Typeable a, ToJSON a) => RequestCallback IO a
    logger x = logToChan lc (ctx, Right (toDynJSON x))

  let req = IReq tn lid logger f
  sendRequest scheduler Nothing req

-- ---------------------------------------------------------------------

data Cached = Cached | NotCached deriving (Show,Eq,Generic)

-- Don't care instances via GHC.Generic
instance FromJSON Cached where
instance ToJSON   Cached where

-- ---------------------------------------------------------------------

funcSpec :: Spec
funcSpec = describe "functional dispatch" $ do
    runIO $ setCurrentDirectory "test/testdata"
    (scheduler, logChan, dispatcher) <- runIO startServer

    cwd <- runIO getCurrentDirectory

    let testUri = filePathToUri $ cwd </> "FuncTest.hs"
        testFailUri = filePathToUri $ cwd </> "FuncTestFail.hs"

    let
      hoverReqHandler :: TypecheckedModule -> CachedInfo -> IdeDeferM (IdeResult Cached)
      hoverReqHandler _ _ = return (IdeResultOk Cached)
      -- Model a hover request
      hoverReq tn idVal doc = dispatchIdeRequest tn ("IReq " ++ show idVal) scheduler logChan idVal $ do
        pluginGetFile "hoverReq" doc $ \fp ->
          ifCachedModule fp (IdeResultOk NotCached) hoverReqHandler

      unpackRes (r,Right md) = (r, fromDynJSON md)
      unpackRes r            = error $ "unpackRes:" ++ show r


    it "defers responses until module is loaded" $ do

      -- Returns immediately, no cached value
      hoverReq 0 (IdInt 0) testUri

      hr0 <- atomically $ readTChan logChan
      unpackRes hr0 `shouldBe` ("IReq IdInt 0",Just NotCached)

      -- This request should be deferred, only return when the module is loaded
      dispatchIdeRequest 1 "req1" scheduler logChan (IdInt 1) $ symbolProvider testUri

      rrr <- atomically $ tryReadTChan logChan
      show rrr `shouldBe` "Nothing"

      -- need to typecheck the module to trigger deferred response
      dispatchGhcRequest 2 "req2" 2 scheduler logChan "ghcmod" "check" (toJSON testUri)

      -- And now we get the deferred response (once the module is loaded)
      ("req1",Right res) <- atomically $ readTChan logChan
      let Just ds = fromDynJSON res :: Maybe [DocumentSymbol]
          DocumentSymbol mainName _ mainKind _ mainRange _ _ = head ds 
      mainName `shouldBe` "main"
      mainKind `shouldBe` SkFunction
      mainRange `shouldBe` Range (Position 2 0) (Position 2 23)

      -- followed by the diagnostics ...
      ("req2",Right res2) <- atomically $ readTChan logChan
      show res2 `shouldBe` "((Map Uri (Set Diagnostic)),[Text])"

      -- No more pending results
      rr3 <- atomically $ tryReadTChan logChan
      show rr3 `shouldBe` "Nothing"

      -- Returns immediately, there is a cached value
      hoverReq 3 (IdInt 3) testUri
      hr3 <- atomically $ readTChan logChan
      unpackRes hr3 `shouldBe` ("IReq IdInt 3",Just Cached)

    it "instantly responds to deferred requests if cache is available" $ do
      -- deferred responses should return something now immediately
      -- as long as the above test ran before
      dispatchIdeRequest 0 "references" scheduler logChan (IdInt 4)
        $ getReferencesInDoc testUri (Position 7 0)

      hr4 <- atomically $ readTChan logChan
      -- show hr4 `shouldBe` "hr4"
      unpackRes hr4 `shouldBe` ("references",Just
                    [ DocumentHighlight
                      { _range = Range
                        { _start = Position {_line = 7, _character = 0}
                        , _end   = Position {_line = 7, _character = 2}
                        }
                      , _kind  = Just HkWrite
                      }
                    , DocumentHighlight
                      { _range = Range
                        { _start = Position {_line = 7, _character = 0}
                        , _end   = Position {_line = 7, _character = 2}
                        }
                      , _kind  = Just HkWrite
                      }
                    , DocumentHighlight
                      { _range = Range
                        { _start = Position {_line = 5, _character = 6}
                        , _end   = Position {_line = 5, _character = 8}
                        }
                      , _kind  = Just HkRead
                      }
                    , DocumentHighlight
                      { _range = Range
                        { _start = Position {_line = 7, _character = 0}
                        , _end   = Position {_line = 7, _character = 2}
                        }
                      , _kind  = Just HkWrite
                      }
                    , DocumentHighlight
                      { _range = Range
                        { _start = Position {_line = 7, _character = 0}
                        , _end   = Position {_line = 7, _character = 2}
                        }
                      , _kind  = Just HkWrite
                      }
                    , DocumentHighlight
                      { _range = Range
                        { _start = Position {_line = 5, _character = 6}
                        , _end   = Position {_line = 5, _character = 8}
                        }
                      , _kind  = Just HkRead
                      }
                    ])

    it "returns hints as diagnostics" $ do

      dispatchGhcRequest 5 "r5" 5 scheduler logChan "applyrefact" "lint" testUri

      hr5 <- atomically $ readTChan logChan
      unpackRes hr5 `shouldBe` ("r5",
              Just $ PublishDiagnosticsParams
                      { _uri         = testUri
                      , _diagnostics = List
                        [ Diagnostic
                            (Range (Position 9 6) (Position 10 18))
                            (Just DsInfo)
                            (Just "Redundant do")
                            (Just "hlint")
                            "Redundant do\nFound:\n  do putStrLn \"hello\"\nWhy not:\n  putStrLn \"hello\"\n"
                            Nothing
                        ]
                      }
                    )

      let req6 = HP testUri (toPos (8, 1))
      dispatchGhcRequest 6 "r6" 6 scheduler logChan "hare" "demote" req6

      hr6 <- atomically $ readTChan logChan
      -- show hr6 `shouldBe` "hr6"
      let textEdits = List [TextEdit (Range (Position 6 0) (Position 7 6)) "  where\n    bb = 5"]
          r6uri = testUri
      unpackRes hr6 `shouldBe` ("r6",Just
        (WorkspaceEdit
          (Just $ H.singleton r6uri textEdits)
          Nothing
        ))

    it "instantly responds to failed modules with no cache with the default" $ do

      dispatchIdeRequest 7 "req7" scheduler logChan (IdInt 7) $ findDef testFailUri (Position 1 2)

      dispatchGhcRequest 8 "req8" 8 scheduler logChan "ghcmod" "check" (toJSON testFailUri)

      hr7 <- atomically $ readTChan logChan
      unpackRes hr7 `shouldBe` ("req7", Just ([] :: [Location]))

      ("req8", Right diags) <- atomically $ readTChan logChan
      show diags `shouldBe` "((Map Uri (Set Diagnostic)),[Text])"

      killThread dispatcher

-- ---------------------------------------------------------------------
