{-# LANGUAGE RecordWildCards #-}

module Asterius.FrontendPlugin
  ( frontendPlugin
  ) where

import Asterius.CodeGen
import Asterius.Internals
import Asterius.Store
import Control.Exception
import Control.Monad
import Data.IORef
import Data.Maybe
import GhcPlugins
import Language.Haskell.GHC.Toolkit.Compiler
import Language.Haskell.GHC.Toolkit.FrontendPlugin
import System.Environment
import System.FilePath
import Text.Show.Pretty

frontendPlugin :: FrontendPlugin
frontendPlugin =
  makeFrontendPlugin $
  liftIO $ do
    obj_topdir <- getEnv "ASTERIUS_LIB_DIR"
    is_debug <- isJust <$> lookupEnv "ASTERIUS_DEBUG"
    store_ref <- decodeFile (obj_topdir </> "asterius_store") >>= newIORef
    pure $
      defaultCompiler
        { withHaskellIR =
            \ModSummary {..} ir@HaskellIR {..} -> do
              let mod_sym = marshalToModuleSymbol ms_mod
              dflags <- getDynFlags
              liftIO $
                case runCodeGen (marshalHaskellIR ir) dflags ms_mod of
                  Left err -> throwIO err
                  Right m -> do
                    atomicModifyIORef' store_ref $ \store ->
                      (addModule mod_sym m store, ())
                    when is_debug $ do
                      p_c <-
                        moduleSymbolPath obj_topdir mod_sym "dump-cmm-raw-ast"
                      writeFile p_c $ ppShow cmmRaw
                      p_s <- moduleSymbolPath obj_topdir mod_sym "txt"
                      writeFile p_s $ ppShow m
        , finalize =
            liftIO $ do
              store <- readIORef store_ref
              encodeFile (obj_topdir </> "asterius_store") store
        }
