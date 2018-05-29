{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE UnboxedTuples #-}
{-# OPTIONS_GHC -Wno-overflowed-literals #-}

module Asterius.CodeGen
  ( marshalToModuleSymbol
  , moduleSymbolPath
  , CodeGen
  , runCodeGen
  , marshalHaskellIR
  , marshalCmmIR
  ) where

import Asterius.Builtins
import Asterius.Internals
import Asterius.Resolve
import Asterius.Types
import qualified CLabel as GHC
import qualified Cmm as GHC
import qualified CmmSwitch as GHC
import Control.Monad.Except
import Control.Monad.Reader
import qualified Data.ByteString.Char8 as CBS
import qualified Data.ByteString.Short as SBS
import qualified Data.HashMap.Strict as HM
import Data.List
import Data.Maybe
import Data.String
import Data.Traversable
import qualified Data.Vector as V
import Foreign
import GHC.Exts
import qualified GhcPlugins as GHC
import qualified Hoopl.Block as GHC
import qualified Hoopl.Graph as GHC
import qualified Hoopl.Label as GHC
import Language.Haskell.GHC.Toolkit.Compiler
import Language.Haskell.GHC.Toolkit.Orphans.Show ()
import Prelude hiding (IO)
import System.Directory
import System.FilePath
import qualified Unique as GHC

asmPpr :: GHC.Outputable a => GHC.DynFlags -> a -> String
asmPpr dflags = GHC.showSDoc dflags . GHC.pprCode GHC.AsmStyle . GHC.ppr

showSBS :: Show a => a -> SBS.ShortByteString
showSBS = fromString . show

{-# INLINEABLE marshalToModuleSymbol #-}
marshalToModuleSymbol :: GHC.Module -> AsteriusModuleSymbol
marshalToModuleSymbol (GHC.Module u m) =
  AsteriusModuleSymbol
    { unitId = SBS.toShort $ GHC.fs_bs $ GHC.unitIdFS u
    , moduleName =
        V.fromList $
        map SBS.toShort $
        CBS.splitWith (== '.') $ GHC.fs_bs $ GHC.moduleNameFS m
    }

{-# INLINEABLE moduleSymbolPath #-}
moduleSymbolPath :: FilePath -> AsteriusModuleSymbol -> FilePath -> IO FilePath
moduleSymbolPath topdir AsteriusModuleSymbol {..} ext = do
  createDirectoryIfMissing True $ takeDirectory p
  pure p
  where
    f = CBS.unpack . SBS.fromShort
    p =
      topdir </> f unitId </>
      V.foldr'
        (\c tot -> f c </> tot)
        (f (V.last moduleName) <.> ext)
        (V.init moduleName)

type CodeGenContext = (GHC.DynFlags, String)

newtype CodeGen a =
  CodeGen (ReaderT CodeGenContext (Except AsteriusCodeGenError) a)
  deriving ( Functor
           , Applicative
           , Monad
           , MonadReader CodeGenContext
           , MonadError AsteriusCodeGenError
           )

unCodeGen :: CodeGen a -> CodeGen (Either AsteriusCodeGenError a)
unCodeGen (CodeGen m) = asks $ runExcept . runReaderT m

{-# INLINEABLE runCodeGen #-}
runCodeGen ::
     CodeGen a -> GHC.DynFlags -> GHC.Module -> Either AsteriusCodeGenError a
runCodeGen (CodeGen m) dflags def_mod =
  runExcept $ runReaderT m (dflags, asmPpr dflags def_mod <> "_")

marshalCLabel :: GHC.CLabel -> CodeGen AsteriusEntitySymbol
marshalCLabel clbl = do
  (dflags, def_mod_prefix) <- ask
  pure
    AsteriusEntitySymbol
      { entityName =
          fromString $
          if GHC.externallyVisibleCLabel clbl
            then asmPpr dflags clbl
            else def_mod_prefix <> asmPpr dflags clbl
      }

{-# INLINEABLE isDisposedStaticsSymbol #-}
isDisposedStaticsSymbol :: AsteriusEntitySymbol -> Bool
isDisposedStaticsSymbol AsteriusEntitySymbol {..} =
  V.any (`CBS.isSuffixOf` SBS.fromShort entityName) ["_srt", "_srtd", "_btm"]

marshalLabel :: GHC.Label -> CodeGen SBS.ShortByteString
marshalLabel lbl = do
  (dflags, _) <- ask
  pure $ fromString $ asmPpr dflags $ GHC.mkLocalBlockLabel $ GHC.getUnique lbl

marshalCmmType :: GHC.CmmType -> CodeGen ValueType
marshalCmmType t
  | GHC.b8 `GHC.cmmEqType_ignoring_ptrhood` t ||
      GHC.b16 `GHC.cmmEqType_ignoring_ptrhood` t ||
      GHC.b32 `GHC.cmmEqType_ignoring_ptrhood` t = pure I32
  | GHC.b64 `GHC.cmmEqType_ignoring_ptrhood` t = pure I64
  | GHC.f32 `GHC.cmmEqType_ignoring_ptrhood` t = pure F32
  | GHC.f64 `GHC.cmmEqType_ignoring_ptrhood` t = pure F64
  | otherwise = throwError $ UnsupportedCmmType $ showSBS t

dispatchCmmWidth :: GHC.Width -> a -> a -> CodeGen a
dispatchCmmWidth w r32 = dispatchAllCmmWidth w r32 r32 r32

dispatchAllCmmWidth :: GHC.Width -> a -> a -> a -> a -> CodeGen a
dispatchAllCmmWidth w r8 r16 r32 r64 =
  case w of
    GHC.W8 -> pure r8
    GHC.W16 -> pure r16
    GHC.W32 -> pure r32
    GHC.W64 -> pure r64
    _ -> throwError $ UnsupportedCmmWidth $ showSBS w

marshalCmmStatic :: GHC.CmmStatic -> CodeGen AsteriusStatic
marshalCmmStatic st =
  case st of
    GHC.CmmStaticLit lit ->
      case lit of
        GHC.CmmInt x w ->
          Serialized <$>
          dispatchAllCmmWidth
            w
            (if x < 0
               then encodePrim (fromIntegral x :: Int8)
               else encodePrim (fromIntegral x :: Word8))
            (if x < 0
               then encodePrim (fromIntegral x :: Int16)
               else encodePrim (fromIntegral x :: Word16))
            (if x < 0
               then encodePrim (fromIntegral x :: Int32)
               else encodePrim (fromIntegral x :: Word32))
            (if x < 0
               then encodePrim (fromIntegral x :: Int64)
               else encodePrim (fromIntegral x :: Word64))
        GHC.CmmFloat x w ->
          Serialized <$>
          dispatchCmmWidth
            w
            (encodePrim (fromRational x :: Float))
            (encodePrim (fromRational x :: Double))
        GHC.CmmLabel clbl -> do
          sym <- marshalCLabel clbl
          pure $
            if isDisposedStaticsSymbol sym
              then Serialized $ encodePrim (0 :: Word64)
              else UnresolvedStatic sym
        GHC.CmmLabelOff clbl o -> do
          sym <- marshalCLabel clbl
          pure $
            if isDisposedStaticsSymbol sym
              then Serialized $ encodePrim (0 :: Word64)
              else UnresolvedOffStatic sym o
        _ -> throwError $ UnsupportedCmmLit $ showSBS lit
    GHC.CmmUninitialised s -> pure $ Uninitialized s
    GHC.CmmString s -> pure $ Serialized $ SBS.pack s <> "\0"

marshalCmmData :: GHC.CmmStatics -> CodeGen AsteriusStatics
marshalCmmData (GHC.Statics _ ss) = do
  ass <- for ss marshalCmmStatic
  pure AsteriusStatics {asteriusStatics = V.fromList ass}

marshalCmmLocalReg :: GHC.LocalReg -> CodeGen (UnresolvedLocalReg, ValueType)
marshalCmmLocalReg (GHC.LocalReg u t) = do
  vt <- marshalCmmType t
  pure (UniqueLocalReg (GHC.getKey u) vt, vt)

marshalTypedCmmLocalReg ::
     GHC.LocalReg -> ValueType -> CodeGen UnresolvedLocalReg
marshalTypedCmmLocalReg r vt = do
  (lr, vt') <- marshalCmmLocalReg r
  if vt == vt'
    then pure lr
    else throwError $ UnsupportedCmmExpr $ showSBS r

marshalCmmGlobalReg :: GHC.GlobalReg -> CodeGen UnresolvedGlobalReg
marshalCmmGlobalReg r =
  case r of
    GHC.VanillaReg i _ -> pure $ VanillaReg i
    GHC.FloatReg i -> pure $ FloatReg i
    GHC.DoubleReg i -> pure $ DoubleReg i
    GHC.LongReg i -> pure $ LongReg i
    GHC.Sp -> pure Sp
    GHC.SpLim -> pure SpLim
    GHC.Hp -> pure Hp
    GHC.HpLim -> pure HpLim
    GHC.CurrentTSO -> pure CurrentTSO
    GHC.CurrentNursery -> pure CurrentNursery
    GHC.HpAlloc -> pure HpAlloc
    GHC.GCEnter1 -> pure GCEnter1
    GHC.GCFun -> pure GCFun
    GHC.BaseReg -> pure BaseReg
    _ -> throwError $ UnsupportedCmmGlobalReg $ showSBS r

marshalCmmLit :: GHC.CmmLit -> CodeGen (Expression, ValueType)
marshalCmmLit lit =
  case lit of
    GHC.CmmInt x w ->
      dispatchCmmWidth
        w
        (ConstI32 $ fromIntegral x, I32)
        (ConstI64 $ fromIntegral x, I64)
    GHC.CmmFloat x w ->
      dispatchCmmWidth
        w
        (ConstF32 $ fromRational x, F32)
        (ConstF64 $ fromRational x, F64)
    GHC.CmmLabel clbl -> do
      sym <- marshalCLabel clbl
      pure
        ( if isDisposedStaticsSymbol sym
            then ConstI64 0
            else Unresolved {unresolvedSymbol = sym}
        , I64)
    GHC.CmmLabelOff clbl o -> do
      sym <- marshalCLabel clbl
      pure
        ( if isDisposedStaticsSymbol sym
            then ConstI64 0
            else UnresolvedOff {unresolvedSymbol = sym, offset' = o}
        , I64)
    _ -> throwError $ UnsupportedCmmLit $ showSBS lit

marshalCmmLoad :: GHC.CmmExpr -> GHC.CmmType -> CodeGen (Expression, ValueType)
marshalCmmLoad p t = do
  pv <- marshalAndCastCmmExpr p I32
  join $
    dispatchAllCmmWidth
      (GHC.typeWidth t)
      (pure
         ( Load
             { signed = False
             , bytes = 1
             , offset = 0
             , align = 0
             , valueType = I32
             , ptr = pv
             }
         , I32))
      (pure
         ( Load
             { signed = False
             , bytes = 2
             , offset = 0
             , align = 0
             , valueType = I32
             , ptr = pv
             }
         , I32))
      (do vt <- marshalCmmType t
          pure
            ( Load
                { signed = False
                , bytes = 4
                , offset = 0
                , align = 0
                , valueType = vt
                , ptr = pv
                }
            , vt))
      (do vt <- marshalCmmType t
          pure
            ( Load
                { signed = False
                , bytes = 8
                , offset = 0
                , align = 0
                , valueType = vt
                , ptr = pv
                }
            , vt))

marshalCmmReg :: GHC.CmmReg -> CodeGen (Expression, ValueType)
marshalCmmReg r =
  case r of
    GHC.CmmLocal lr -> do
      (lr_k, lr_vt) <- marshalCmmLocalReg lr
      pure (UnresolvedGetLocal {unresolvedLocalReg = lr_k}, lr_vt)
    GHC.CmmGlobal gr -> do
      gr_k <- marshalCmmGlobalReg gr
      pure
        ( case gr_k of
            GCEnter1 -> marshalErrorCode errGCEnter1 I64
            GCFun -> marshalErrorCode errGCFun I64
            _ -> UnresolvedGetGlobal {unresolvedGlobalReg = gr_k}
        , unresolvedGlobalRegType gr_k)

marshalCmmRegOff :: GHC.CmmReg -> Int -> CodeGen (Expression, ValueType)
marshalCmmRegOff r o = do
  (re, vt) <- marshalCmmReg r
  case vt of
    I32 ->
      pure
        ( Binary
            { binaryOp = AddInt32
            , operand0 = re
            , operand1 = ConstI32 $ fromIntegral o
            }
        , vt)
    I64 ->
      pure
        ( Binary
            { binaryOp = AddInt64
            , operand0 = re
            , operand1 = ConstI64 $ fromIntegral o
            }
        , vt)
    _ -> throwError $ UnsupportedCmmExpr $ showSBS $ GHC.CmmRegOff r o

marshalCmmBinMachOp ::
     BinaryOp
  -> ValueType
  -> ValueType
  -> ValueType
  -> BinaryOp
  -> ValueType
  -> ValueType
  -> ValueType
  -> GHC.Width
  -> GHC.CmmExpr
  -> GHC.CmmExpr
  -> CodeGen (Expression, ValueType)
marshalCmmBinMachOp o32 tx32 ty32 tr32 o64 tx64 ty64 tr64 w x y =
  join $
  dispatchCmmWidth
    w
    (do xe <- marshalAndCastCmmExpr x tx32
        ye <- marshalAndCastCmmExpr y ty32
        pure (Binary {binaryOp = o32, operand0 = xe, operand1 = ye}, tr32))
    (do xe <- marshalAndCastCmmExpr x tx64
        ye <- marshalAndCastCmmExpr y ty64
        pure (Binary {binaryOp = o64, operand0 = xe, operand1 = ye}, tr64))

marshalCmmHomoConvMachOp ::
     UnaryOp
  -> UnaryOp
  -> ValueType
  -> ValueType
  -> GHC.Width
  -> GHC.Width
  -> GHC.CmmExpr
  -> CodeGen (Expression, ValueType)
marshalCmmHomoConvMachOp o36 o63 t32 t64 _ w1 x = do
  (o, t, tr) <- dispatchCmmWidth w1 (o63, t64, t32) (o36, t32, t64)
  xe <- marshalAndCastCmmExpr x t
  pure (Unary {unaryOp = o, operand0 = xe}, tr)

marshalCmmHeteroConvMachOp ::
     UnaryOp
  -> UnaryOp
  -> UnaryOp
  -> UnaryOp
  -> ValueType
  -> ValueType
  -> ValueType
  -> ValueType
  -> GHC.Width
  -> GHC.Width
  -> GHC.CmmExpr
  -> CodeGen (Expression, ValueType)
marshalCmmHeteroConvMachOp o33 o36 o63 o66 tx32 ty32 tx64 ty64 w0 w1 x = do
  (g0, g1) <-
    dispatchCmmWidth
      w0
      ((o33, tx32, ty32), (o36, tx32, ty64))
      ((o63, tx64, ty32), (o66, tx64, ty64))
  (o, t, tr) <- dispatchCmmWidth w1 g0 g1
  xe <- marshalAndCastCmmExpr x t
  pure (Unary {unaryOp = o, operand0 = xe}, tr)

marshalCmmMachOp ::
     GHC.MachOp -> [GHC.CmmExpr] -> CodeGen (Expression, ValueType)
marshalCmmMachOp (GHC.MO_Add w) [x, y] =
  marshalCmmBinMachOp AddInt32 I32 I32 I32 AddInt64 I64 I64 I64 w x y
marshalCmmMachOp (GHC.MO_Sub w) [x, y] =
  marshalCmmBinMachOp SubInt32 I32 I32 I32 SubInt64 I64 I64 I64 w x y
marshalCmmMachOp (GHC.MO_Eq w) [x, y] =
  marshalCmmBinMachOp EqInt32 I32 I32 I32 EqInt64 I64 I64 I32 w x y
marshalCmmMachOp (GHC.MO_Ne w) [x, y] =
  marshalCmmBinMachOp NeInt32 I32 I32 I32 NeInt64 I64 I64 I32 w x y
marshalCmmMachOp (GHC.MO_Mul w) [x, y] =
  marshalCmmBinMachOp MulInt32 I32 I32 I32 MulInt64 I64 I64 I64 w x y
marshalCmmMachOp (GHC.MO_S_Quot w) [x, y] =
  marshalCmmBinMachOp DivSInt32 I32 I32 I32 DivSInt64 I64 I64 I64 w x y
marshalCmmMachOp (GHC.MO_S_Rem w) [x, y] =
  marshalCmmBinMachOp RemSInt32 I32 I32 I32 RemSInt64 I64 I64 I64 w x y
marshalCmmMachOp (GHC.MO_S_Neg w) [x] =
  join $
  dispatchCmmWidth
    w
    (do xe <- marshalAndCastCmmExpr x I32
        pure
          ( Binary {binaryOp = SubInt32, operand0 = ConstI32 0, operand1 = xe}
          , I32))
    (do xe <- marshalAndCastCmmExpr x I64
        pure
          ( Binary {binaryOp = SubInt64, operand0 = ConstI64 0, operand1 = xe}
          , I64))
marshalCmmMachOp (GHC.MO_U_Quot w) [x, y] =
  marshalCmmBinMachOp DivUInt32 I32 I32 I32 DivUInt64 I64 I64 I64 w x y
marshalCmmMachOp (GHC.MO_U_Rem w) [x, y] =
  marshalCmmBinMachOp RemUInt32 I32 I32 I32 RemUInt64 I64 I64 I64 w x y
marshalCmmMachOp (GHC.MO_S_Ge w) [x, y] =
  marshalCmmBinMachOp GeSInt32 I32 I32 I32 GeSInt64 I64 I64 I32 w x y
marshalCmmMachOp (GHC.MO_S_Le w) [x, y] =
  marshalCmmBinMachOp LeSInt32 I32 I32 I32 LeSInt64 I64 I64 I32 w x y
marshalCmmMachOp (GHC.MO_S_Gt w) [x, y] =
  marshalCmmBinMachOp GtSInt32 I32 I32 I32 GtSInt64 I64 I64 I32 w x y
marshalCmmMachOp (GHC.MO_S_Lt w) [x, y] =
  marshalCmmBinMachOp LtSInt32 I32 I32 I32 LtSInt64 I64 I64 I32 w x y
marshalCmmMachOp (GHC.MO_U_Ge w) [x, y] =
  marshalCmmBinMachOp GeUInt32 I32 I32 I32 GeUInt64 I64 I64 I32 w x y
marshalCmmMachOp (GHC.MO_U_Le w) [x, y] =
  marshalCmmBinMachOp LeUInt32 I32 I32 I32 LeUInt64 I64 I64 I32 w x y
marshalCmmMachOp (GHC.MO_U_Gt w) [x, y] =
  marshalCmmBinMachOp GtUInt32 I32 I32 I32 GtUInt64 I64 I64 I32 w x y
marshalCmmMachOp (GHC.MO_U_Lt w) [x, y] =
  marshalCmmBinMachOp LtUInt32 I32 I32 I32 LtUInt64 I64 I64 I32 w x y
marshalCmmMachOp (GHC.MO_F_Add w) [x, y] =
  marshalCmmBinMachOp AddFloat32 F32 F32 F32 AddFloat64 F64 F64 F64 w x y
marshalCmmMachOp (GHC.MO_F_Sub w) [x, y] =
  marshalCmmBinMachOp SubFloat32 F32 F32 F32 SubFloat64 F64 F64 F64 w x y
marshalCmmMachOp (GHC.MO_F_Neg w) [x] =
  join $
  dispatchCmmWidth
    w
    (do xe <- marshalAndCastCmmExpr x F32
        pure
          ( Binary {binaryOp = SubFloat32, operand0 = ConstF32 0, operand1 = xe}
          , F32))
    (do xe <- marshalAndCastCmmExpr x F64
        pure
          ( Binary {binaryOp = SubFloat64, operand0 = ConstF64 0, operand1 = xe}
          , F64))
marshalCmmMachOp (GHC.MO_F_Mul w) [x, y] =
  marshalCmmBinMachOp MulFloat32 F32 F32 F32 MulFloat64 F64 F64 F64 w x y
marshalCmmMachOp (GHC.MO_F_Quot w) [x, y] =
  marshalCmmBinMachOp DivFloat32 F32 F32 F32 DivFloat64 F64 F64 F64 w x y
marshalCmmMachOp (GHC.MO_F_Eq w) [x, y] =
  marshalCmmBinMachOp EqFloat32 F32 F32 I32 EqFloat64 F64 F64 I32 w x y
marshalCmmMachOp (GHC.MO_F_Ne w) [x, y] =
  marshalCmmBinMachOp NeFloat32 F32 F32 I32 NeFloat64 F64 F64 I32 w x y
marshalCmmMachOp (GHC.MO_F_Ge w) [x, y] =
  marshalCmmBinMachOp GeFloat32 F32 F32 I32 GeFloat64 F64 F64 I32 w x y
marshalCmmMachOp (GHC.MO_F_Le w) [x, y] =
  marshalCmmBinMachOp LeFloat32 F32 F32 I32 LeFloat64 F64 F64 I32 w x y
marshalCmmMachOp (GHC.MO_F_Gt w) [x, y] =
  marshalCmmBinMachOp GtFloat32 F32 F32 I32 GtFloat64 F64 F64 I32 w x y
marshalCmmMachOp (GHC.MO_F_Lt w) [x, y] =
  marshalCmmBinMachOp LtFloat32 F32 F32 I32 LtFloat64 F64 F64 I32 w x y
marshalCmmMachOp (GHC.MO_And w) [x, y] =
  marshalCmmBinMachOp AndInt32 I32 I32 I32 AndInt64 I64 I64 I64 w x y
marshalCmmMachOp (GHC.MO_Or w) [x, y] =
  marshalCmmBinMachOp OrInt32 I32 I32 I32 OrInt64 I64 I64 I64 w x y
marshalCmmMachOp (GHC.MO_Xor w) [x, y] =
  marshalCmmBinMachOp XorInt32 I32 I32 I32 XorInt64 I64 I64 I64 w x y
marshalCmmMachOp (GHC.MO_Not w) [x] =
  join $
  dispatchCmmWidth
    w
    (do xe <- marshalAndCastCmmExpr x I32
        pure
          ( Binary
              { binaryOp = XorInt32
              , operand0 = xe
              , operand1 = ConstI32 0xFFFFFFFF
              }
          , I32))
    (do xe <- marshalAndCastCmmExpr x I64
        pure
          ( Binary
              { binaryOp = XorInt64
              , operand0 = xe
              , operand1 = ConstI64 0xFFFFFFFFFFFFFFFF
              }
          , I64))
marshalCmmMachOp (GHC.MO_Shl w) [x, y] =
  marshalCmmBinMachOp ShlInt32 I32 I32 I32 ShlInt64 I64 I64 I64 w x y
marshalCmmMachOp (GHC.MO_U_Shr w) [x, y] =
  marshalCmmBinMachOp ShrUInt32 I32 I32 I32 ShrUInt64 I64 I64 I64 w x y
marshalCmmMachOp (GHC.MO_S_Shr w) [x, y] =
  marshalCmmBinMachOp ShrSInt32 I32 I32 I32 ShrSInt64 I64 I64 I64 w x y
marshalCmmMachOp (GHC.MO_SF_Conv w0 w1) [x] =
  marshalCmmHeteroConvMachOp
    ConvertSInt32ToFloat32
    ConvertSInt32ToFloat64
    ConvertSInt64ToFloat32
    ConvertSInt64ToFloat64
    I32
    F32
    I64
    F64
    w0
    w1
    x
marshalCmmMachOp (GHC.MO_FS_Conv w0 w1) [x] =
  marshalCmmHeteroConvMachOp
    TruncSFloat32ToInt32
    TruncSFloat32ToInt64
    TruncSFloat64ToInt32
    TruncSFloat64ToInt64
    F32
    I32
    F64
    I64
    w0
    w1
    x
marshalCmmMachOp (GHC.MO_SS_Conv w0 w1) [x] =
  marshalCmmHomoConvMachOp ExtendSInt32 WrapInt64 I32 I64 w0 w1 x
marshalCmmMachOp (GHC.MO_UU_Conv w0 w1) [x] =
  marshalCmmHomoConvMachOp ExtendUInt32 WrapInt64 I32 I64 w0 w1 x
marshalCmmMachOp (GHC.MO_FF_Conv w0 w1) [x] =
  marshalCmmHomoConvMachOp PromoteFloat32 DemoteFloat64 F32 F64 w0 w1 x
marshalCmmMachOp op xs =
  throwError $ UnsupportedCmmExpr $ showSBS $ GHC.CmmMachOp op xs

marshalCmmExpr :: GHC.CmmExpr -> CodeGen (Expression, ValueType)
marshalCmmExpr cmm_expr =
  case cmm_expr of
    GHC.CmmLit lit -> marshalCmmLit lit
    GHC.CmmLoad p t -> marshalCmmLoad p t
    GHC.CmmReg r -> marshalCmmReg r
    GHC.CmmMachOp op xs -> marshalCmmMachOp op xs
    GHC.CmmRegOff r o -> marshalCmmRegOff r o
    _ -> throwError $ UnsupportedCmmExpr $ showSBS cmm_expr

marshalAndCastCmmExpr :: GHC.CmmExpr -> ValueType -> CodeGen Expression
marshalAndCastCmmExpr cmm_expr dest_vt = do
  (src_expr, src_vt) <- marshalCmmExpr cmm_expr
  case (# src_vt, dest_vt #) of
    (# I32, I64 #) -> pure Unary {unaryOp = ExtendSInt32, operand0 = src_expr}
    (# I64, I32 #) -> pure Unary {unaryOp = WrapInt64, operand0 = src_expr}
    _
      | src_vt == dest_vt -> pure src_expr
      | otherwise ->
        throwError $ UnsupportedImplicitCasting src_expr src_vt dest_vt

marshalCmmUnPrimCall ::
     UnaryOp -> ValueType -> GHC.LocalReg -> GHC.CmmExpr -> CodeGen [Expression]
marshalCmmUnPrimCall op vt r x = do
  lr <- marshalTypedCmmLocalReg r vt
  xe <- marshalAndCastCmmExpr x vt
  pure
    [ UnresolvedSetLocal
        {unresolvedLocalReg = lr, value = Unary {unaryOp = op, operand0 = xe}}
    ]

marshalCmmQuotRemPrimCall ::
     UnresolvedLocalReg
  -> UnresolvedLocalReg
  -> BinaryOp
  -> BinaryOp
  -> ValueType
  -> GHC.LocalReg
  -> GHC.LocalReg
  -> GHC.CmmExpr
  -> GHC.CmmExpr
  -> CodeGen [Expression]
marshalCmmQuotRemPrimCall tmp0 tmp1 qop rop vt qr rr x y = do
  qlr <- marshalTypedCmmLocalReg qr vt
  rlr <- marshalTypedCmmLocalReg rr vt
  xe <- marshalAndCastCmmExpr x vt
  ye <- marshalAndCastCmmExpr y vt
  pure
    [ UnresolvedSetLocal {unresolvedLocalReg = tmp0, value = xe}
    , UnresolvedSetLocal {unresolvedLocalReg = tmp1, value = ye}
    , UnresolvedSetLocal
        { unresolvedLocalReg = qlr
        , value =
            Binary
              { binaryOp = qop
              , operand0 = UnresolvedGetLocal {unresolvedLocalReg = tmp0}
              , operand1 = UnresolvedGetLocal {unresolvedLocalReg = tmp1}
              }
        }
    , UnresolvedSetLocal
        { unresolvedLocalReg = rlr
        , value =
            Binary
              { binaryOp = rop
              , operand0 = UnresolvedGetLocal {unresolvedLocalReg = tmp0}
              , operand1 = UnresolvedGetLocal {unresolvedLocalReg = tmp1}
              }
        }
    ]

marshalCmmPrimCall ::
     GHC.CallishMachOp
  -> [GHC.LocalReg]
  -> [GHC.CmmExpr]
  -> CodeGen [Expression]
marshalCmmPrimCall GHC.MO_F64_Fabs [r] [x] =
  marshalCmmUnPrimCall AbsFloat64 F64 r x
marshalCmmPrimCall GHC.MO_F64_Sqrt [r] [x] =
  marshalCmmUnPrimCall SqrtFloat64 F64 r x
marshalCmmPrimCall GHC.MO_F32_Fabs [r] [x] =
  marshalCmmUnPrimCall AbsFloat32 F32 r x
marshalCmmPrimCall GHC.MO_F32_Sqrt [r] [x] =
  marshalCmmUnPrimCall SqrtFloat32 F32 r x
marshalCmmPrimCall (GHC.MO_S_QuotRem w) [qr, rr] [x, y] =
  join $
  dispatchCmmWidth
    w
    (marshalCmmQuotRemPrimCall
       QuotRemI32X
       QuotRemI32Y
       DivSInt32
       RemSInt32
       I32
       qr
       rr
       x
       y)
    (marshalCmmQuotRemPrimCall
       QuotRemI64X
       QuotRemI64Y
       DivSInt64
       RemSInt64
       I64
       qr
       rr
       x
       y)
marshalCmmPrimCall (GHC.MO_U_QuotRem w) [qr, rr] [x, y] =
  join $
  dispatchCmmWidth
    w
    (marshalCmmQuotRemPrimCall
       QuotRemI32X
       QuotRemI32Y
       DivUInt32
       RemUInt32
       I32
       qr
       rr
       x
       y)
    (marshalCmmQuotRemPrimCall
       QuotRemI64X
       QuotRemI64Y
       DivUInt64
       RemUInt64
       I64
       qr
       rr
       x
       y)
marshalCmmPrimCall GHC.MO_WriteBarrier _ _ = pure []
marshalCmmPrimCall GHC.MO_Touch _ _ = pure []
marshalCmmPrimCall (GHC.MO_Prefetch_Data _) _ _ = pure []
marshalCmmPrimCall (GHC.MO_PopCnt GHC.W64) [r] [x] =
  marshalCmmUnPrimCall PopcntInt64 I64 r x
marshalCmmPrimCall (GHC.MO_Clz GHC.W64) [r] [x] =
  marshalCmmUnPrimCall ClzInt64 I64 r x
marshalCmmPrimCall (GHC.MO_Ctz GHC.W64) [r] [x] =
  marshalCmmUnPrimCall CtzInt64 I64 r x
marshalCmmPrimCall op rs xs =
  throwError $
  UnsupportedCmmInstr $
  showSBS $ GHC.CmmUnsafeForeignCall (GHC.PrimTarget op) rs xs

marshalCmmUnsafeCall ::
     GHC.CmmExpr
  -> GHC.ForeignConvention
  -> [GHC.LocalReg]
  -> [GHC.CmmExpr]
  -> CodeGen [Expression]
marshalCmmUnsafeCall p@(GHC.CmmLit (GHC.CmmLabel clbl)) f rs xs = do
  sym <- marshalCLabel clbl
  if entityName sym == "barf"
    then pure [marshalErrorCode errBarf None]
    else do
      xes <-
        for xs $ \x -> do
          (xe, _) <- marshalCmmExpr x
          pure xe
      case rs of
        [] ->
          pure
            [Call {target = sym, operands = V.fromList xes, valueType = None}]
        [r] -> do
          (lr, vt) <- marshalCmmLocalReg r
          pure
            [ UnresolvedSetLocal
                { unresolvedLocalReg = lr
                , value =
                    Call
                      {target = sym, operands = V.fromList xes, valueType = vt}
                }
            ]
        _ ->
          throwError $
          UnsupportedCmmInstr $
          showSBS $ GHC.CmmUnsafeForeignCall (GHC.ForeignTarget p f) rs xs
marshalCmmUnsafeCall p f rs xs =
  throwError $
  UnsupportedCmmInstr $
  showSBS $ GHC.CmmUnsafeForeignCall (GHC.ForeignTarget p f) rs xs

marshalCmmInstr :: GHC.CmmNode GHC.O GHC.O -> CodeGen [Expression]
marshalCmmInstr instr =
  case instr of
    GHC.CmmComment {} -> pure []
    GHC.CmmTick {} -> pure []
    GHC.CmmUnsafeForeignCall (GHC.PrimTarget op) rs xs ->
      marshalCmmPrimCall op rs xs
    GHC.CmmUnsafeForeignCall (GHC.ForeignTarget t c) rs xs ->
      marshalCmmUnsafeCall t c rs xs
    GHC.CmmAssign (GHC.CmmLocal r) e -> do
      (lr, vt) <- marshalCmmLocalReg r
      v <- marshalAndCastCmmExpr e vt
      pure [UnresolvedSetLocal {unresolvedLocalReg = lr, value = v}]
    GHC.CmmAssign (GHC.CmmGlobal r) e -> do
      gr <- marshalCmmGlobalReg r
      v <- marshalAndCastCmmExpr e $ unresolvedGlobalRegType gr
      if gr `V.elem` [CurrentTSO, EagerBlackholeInfo, GCEnter1, GCFun]
        then throwError $ AssignToImmutableGlobalReg gr
        else pure [UnresolvedSetGlobal {unresolvedGlobalReg = gr, value = v}]
    GHC.CmmStore p e -> do
      pv <- marshalAndCastCmmExpr p I32
      (dflags, _) <- ask
      store_instr <-
        join $
        dispatchAllCmmWidth
          (GHC.cmmExprWidth dflags e)
          (do xe <- marshalAndCastCmmExpr e I32
              pure
                Store
                  { bytes = 1
                  , offset = 0
                  , align = 0
                  , ptr = pv
                  , value = xe
                  , valueType = I32
                  })
          (do xe <- marshalAndCastCmmExpr e I32
              pure
                Store
                  { bytes = 2
                  , offset = 0
                  , align = 0
                  , ptr = pv
                  , value = xe
                  , valueType = I32
                  })
          (do (xe, vt) <- marshalCmmExpr e
              pure
                Store
                  { bytes = 4
                  , offset = 0
                  , align = 0
                  , ptr = pv
                  , value = xe
                  , valueType = vt
                  })
          (do (xe, vt) <- marshalCmmExpr e
              pure
                Store
                  { bytes = 8
                  , offset = 0
                  , align = 0
                  , ptr = pv
                  , value = xe
                  , valueType = vt
                  })
      pure [store_instr]
    _ -> throwError $ UnsupportedCmmInstr $ showSBS instr

marshalCmmBlockBody :: [GHC.CmmNode GHC.O GHC.O] -> CodeGen [Expression]
marshalCmmBlockBody instrs = concat <$> for instrs marshalCmmInstr

marshalCmmBlockBranch ::
     GHC.CmmNode GHC.O GHC.C
  -> CodeGen ([Expression], V.Vector RelooperAddBranch, Bool)
marshalCmmBlockBranch instr =
  case instr of
    GHC.CmmBranch lbl -> do
      k <- marshalLabel lbl
      pure ([], [AddBranch {to = k, condition = Null, code = Null}], False)
    GHC.CmmCondBranch {..} -> do
      c <- marshalAndCastCmmExpr cml_pred I32
      kf <- marshalLabel cml_false
      kt <- marshalLabel cml_true
      pure
        ( []
        , V.fromList $
          [AddBranch {to = kt, condition = c, code = Null} | kt /= kf] <>
          [AddBranch {to = kf, condition = Null, code = Null}]
        , False)
    GHC.CmmSwitch cml_arg st -> do
      a <- marshalAndCastCmmExpr cml_arg I64
      brs <-
        fmap (HM.toList . HM.fromListWith (<>)) $
        for (GHC.switchTargetsCases st) $ \(idx, lbl) -> do
          dest <- marshalLabel lbl
          pure (dest, [fromIntegral idx])
      dest_def_m <-
        case GHC.switchTargetsDefault st of
          Just lbl -> Just <$> marshalLabel lbl
          _ -> pure Nothing
      pure
        ( [UnresolvedSetLocal {unresolvedLocalReg = SwitchCondReg, value = a}]
        , V.fromList $
          case dest_def_m of
            Just dest_def ->
              [ AddBranch
                { to = dest
                , condition =
                    foldl1'
                      (Binary OrInt32)
                      [ Binary
                        { binaryOp = EqInt64
                        , operand0 =
                            UnresolvedGetLocal
                              {unresolvedLocalReg = SwitchCondReg}
                        , operand1 = ConstI64 tag
                        }
                      | tag <- tags
                      ]
                , code = Null
                }
              | (dest, tags) <- brs
              , dest /= dest_def
              ] <>
              [AddBranch {to = dest_def, condition = Null, code = Null}]
            _ ->
              [ AddBranch
                { to = dest
                , condition =
                    foldl1'
                      (Binary OrInt32)
                      [ Binary
                        { binaryOp = EqInt64
                        , operand0 =
                            UnresolvedGetLocal
                              {unresolvedLocalReg = SwitchCondReg}
                        , operand1 = ConstI64 tag
                        }
                      | tag <- tags
                      ]
                , code = Null
                }
              | (dest, tags) <- brs
              ] <>
              [AddBranch {to = "~unreachable", condition = Null, code = Null}]
        , isNothing dest_def_m)
    GHC.CmmCall {..} -> do
      t <- marshalAndCastCmmExpr cml_target I64
      pure
        ( [ SetLocal
              { index = 1
              , value =
                  case t of
                    Unresolved {..}
                      | "stg_gc" `CBS.isPrefixOf`
                          SBS.fromShort (entityName unresolvedSymbol) ->
                        marshalErrorCode errStgGC I64
                    _ -> t
              }
          ]
        , []
        , False)
    _ -> throwError $ UnsupportedCmmBranch $ showSBS instr

marshalCmmBlock ::
     [GHC.CmmNode GHC.O GHC.O]
  -> GHC.CmmNode GHC.O GHC.C
  -> CodeGen (RelooperBlock, Bool)
marshalCmmBlock inner_nodes exit_node = do
  inner_exprs <- marshalCmmBlockBody inner_nodes
  (br_helper_exprs, br_branches, need_unreachable_block) <-
    marshalCmmBlockBranch exit_node
  pure
    ( RelooperBlock
        { addBlock =
            AddBlock {code = concatExpressions $ inner_exprs <> br_helper_exprs}
        , addBranches = br_branches
        }
    , need_unreachable_block)
  where
    concatExpressions es =
      case es of
        [] -> Nop
        [e] -> e
        _ -> Block {name = "", bodys = V.fromList es, valueType = None}

marshalCmmProc :: GHC.CmmGraph -> CodeGen Function
marshalCmmProc GHC.CmmGraph {g_graph = GHC.GMany _ body _, ..} = do
  entry_k <- marshalLabel g_entry
  (rbs', us) <-
    fmap unzip $
    for (GHC.bodyList body) $ \(lbl, GHC.BlockCC _ inner_nodes exit_node) -> do
      k <- marshalLabel lbl
      (b, u) <- marshalCmmBlock (GHC.blockToList inner_nodes) exit_node
      pure ((k, b), u)
  let (rbs, lrs) = resolveLocalRegs $ resolveGlobalRegs rbs'
  pure
    Function
      { functionTypeName = "I64()"
      , varTypes = lrs
      , body =
          Block
            { name = ""
            , bodys =
                [ CFG
                    RelooperRun
                      { entry = entry_k
                      , blockMap =
                          fromList $
                          [ ( "~unreachable"
                            , RelooperBlock
                                { addBlock =
                                    AddBlock
                                      { code =
                                          marshalErrorCode
                                            errUnreachableBlock
                                            None
                                      }
                                , addBranches = []
                                })
                          | or us
                          ] <>
                          rbs
                      , labelHelper = 0
                      }
                , GetLocal {index = 1, valueType = I64}
                ]
            , valueType = I64
            }
      }

marshalCmmDecl ::
     GHC.GenCmmDecl GHC.CmmStatics h GHC.CmmGraph -> CodeGen AsteriusModule
marshalCmmDecl decl =
  case decl of
    GHC.CmmData _ d@(GHC.Statics clbl _) -> do
      sym <- marshalCLabel clbl
      if isDisposedStaticsSymbol sym
        then pure mempty
        else do
          r <- unCodeGen $ marshalCmmData d
          pure $
            case r of
              Left err -> mempty {staticsErrorMap = [(sym, err)]}
              Right ass -> mempty {staticsMap = [(sym, ass)]}
    GHC.CmmProc _ clbl _ g -> do
      sym <- marshalCLabel clbl
      r <- unCodeGen $ marshalCmmProc g
      pure $
        case r of
          Left err -> mempty {functionErrorMap = [(sym, err)]}
          Right f -> mempty {functionMap = [(sym, f)]}

marshalHaskellIR :: HaskellIR -> CodeGen AsteriusModule
marshalHaskellIR HaskellIR {..} = mconcat <$> for cmmRaw marshalCmmDecl

marshalCmmIR :: CmmIR -> CodeGen AsteriusModule
marshalCmmIR CmmIR {..} = mconcat <$> for cmmRaw marshalCmmDecl
