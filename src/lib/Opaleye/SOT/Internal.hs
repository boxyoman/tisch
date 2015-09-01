{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | This is an internal module. You are not encouraged to use it directly.
module Opaleye.SOT.Internal where

import           Control.Lens
import qualified Control.Exception as Ex
import qualified Data.Aeson
import qualified Data.ByteString
import qualified Data.ByteString.Lazy
import qualified Data.CaseInsensitive
import qualified Data.Text
import qualified Data.Text.Lazy
import qualified Data.Time
import qualified Data.UUID
import           Data.Int
import           Data.Proxy (Proxy(..))
import           Data.HList (Tagged(Tagged, unTagged), HList(HCons, HNil))
import qualified Data.HList as HL
import qualified Data.Profunctor as P
import qualified Data.Profunctor.Product as PP
import qualified Data.Profunctor.Product.Default as PP
import           Data.Singletons
import qualified Data.Promotion.Prelude.List as List (Map)
import           GHC.Exts (Constraint)
import qualified GHC.TypeLits as GHC
import qualified Opaleye as O
import qualified Opaleye.Internal.Join as OI

-------------------------------------------------------------------------------

-- | Whether to read a plain value or a possibly null value.
data RN = R  -- ^ Read plain value.
        | RN -- ^ Read possibly null value.

-- | Whether to write a plain value or a possibly null value.
data WN = W  -- ^ Write plain value.
        | WN -- ^ Write possibly null value.

--------------------------------------------------------------------------------

-- | Column description.
--
-- This is only used as a promoted datatype expected to have kind
-- @'Col' 'GHC.Symbol' 'WN' 'RN' * *@.
--
-- * @name@: Column name.
--
-- * @wn@: Whether @NULL@ can be written to this column ('WN') or not ('W').
--
-- * @rn@: Whether @NULL@ might be read from this column ('RN') or not ('R').
--
-- * @pgType@: Type of the column value used in Opaleye queries
--   (e.g., 'O.PGText', 'O.PGInt2').
--
-- * @hsType@: Type of the column value used in Haskell outside Opaleye
--   queries. Hint: don't use something like @'Maybe' 'Bool'@ here if you
--   want to indicate that this is an optional 'Bool' column. Instead, use
--   'Int' here and 'WN' and 'RN' in the @wn@ and @rn@ fields.
data Col name wn rn pgType hsType
   = Col name wn rn pgType hsType

--

type Cols_Names (t :: *) = List.Map Col_NameSym0 (Cols t)
type family Col_Name (col :: Col GHC.Symbol WN RN * *) :: GHC.Symbol where
  Col_Name ('Col n w r p h) = n
data Col_NameSym0 (col :: TyFun (Col GHC.Symbol WN RN * *) GHC.Symbol)
type instance Apply Col_NameSym0 col = Col_Name col

type family Col_WN (col :: Col GHC.Symbol WN RN * *) :: WN where
  Col_WN ('Col n w r p h) = w

type family Col_RN (col :: Col GHC.Symbol WN RN * *) :: RN where
  Col_RN ('Col n w r p h) = r

type family Col_PgType (col :: Col GHC.Symbol WN RN * *) :: * where
  Col_PgType ('Col n w r p h) = p

type family Col_HsType (col :: Col GHC.Symbol WN RN * *) :: * where
  Col_HsType ('Col n w 'R  p h) = h
  Col_HsType ('Col n w 'RN p h) = Maybe h

type family Col_HsTypeMay (col :: Col GHC.Symbol WN RN * *) :: * where
  Col_HsTypeMay ('Col n w r p h) = Maybe (Col_HsType ('Col n w r p h))

---

-- | Lookup column info by name
type Col_ByName (t :: *) (name :: GHC.Symbol) = Col_ByName' name (Cols t)
type family Col_ByName' (name :: GHC.Symbol) (cols :: [Col GHC.Symbol WN RN * *])
       :: Col GHC.Symbol WN RN * * where
  Col_ByName' n ('Col n  w r p h ': xs) = 'Col n w r p h
  Col_ByName' n ('Col n' w r p h ': xs) = Col_ByName' n xs

---

-- | Type of the 'HL.Record' columns in Haskell.
type Cols_Hs (t :: *) = List.Map (Col_HsRecordFieldSym1 t) (Cols t)
type Col_HsRecordField (t :: *) (col :: Col GHC.Symbol WN RN * *)
  = Tagged (TC t (Col_Name col)) (Col_HsType col)
data Col_HsRecordFieldSym1 (t :: *) (col :: TyFun (Col GHC.Symbol WN RN * *) *)
type instance Apply (Col_HsRecordFieldSym1 t) col = Col_HsRecordField t col

-- | Type of the 'HL.Record' columns in Haskell when all the columns
-- are @NULL@ (e.g., a missing rhs on a left join).
type Cols_HsMay (t :: *) = List.Map (Col_HsMayRecordFieldSym1 t) (Cols t)
type Col_HsMayRecordField (t :: *) (col :: Col GHC.Symbol WN RN * *)
  = Tagged (TC t (Col_Name col)) (Col_HsTypeMay col)
data Col_HsMayRecordFieldSym1 (t :: *) (col :: TyFun (Col GHC.Symbol WN RN * *) *)
type instance Apply (Col_HsMayRecordFieldSym1 t) col = Col_HsMayRecordField t col

---

-- | Tag to be used alone or with 'Tagged' for uniquely identifying a specific
-- table in a specific schema.
data Tisch t => T (t :: *) = T

-- | Tag to be used alone or with 'Tagged' for uniquely identifying a specific
-- column in a specific table in a specific schema.
data Tisch t => TC (t :: *) (c :: GHC.Symbol) = TC

-- | Tag to be used alone or with 'Tagged' for uniquely identifying a specific
-- column in an unknown table.
data C (c :: GHC.Symbol) = C

---

-- | Type of the 'HL.Record' columns when inserting or updating a row.
type Cols_PgWrite (t :: *) = List.Map (Col_PgWriteSym1 t) (Cols t)
type family Col_PgWrite (t :: *) (col :: Col GHC.Symbol WN RN * *) :: * where
  Col_PgWrite t ('Col n 'W 'R p h) = Tagged (TC t n) (O.Column p)
  Col_PgWrite t ('Col n 'W 'RN p h) = Tagged (TC t n) (O.Column (O.Nullable p))
  Col_PgWrite t ('Col n 'WN 'R p h) = Tagged (TC t n) (Maybe (O.Column p))
  Col_PgWrite t ('Col n 'WN 'RN p h) = Tagged (TC t n) (Maybe (O.Column (O.Nullable p)))
data Col_PgWriteSym1 (t :: *) (col :: TyFun (Col GHC.Symbol WN RN * *) *)
type instance Apply (Col_PgWriteSym1 t) col = Col_PgWrite t col

---

-- | Type of the 'HL.Record' columns (e.g., result of 'O.query')
type Cols_PgRead (t :: *) = List.Map (Col_PgReadSym1 t) (Cols t)
type family Col_PgRead (t :: *) (col :: Col GHC.Symbol WN RN * *) :: * where
  Col_PgRead t ('Col n w 'R  p h) = Tagged (TC t n) (O.Column p)
  Col_PgRead t ('Col n w 'RN p h) = Tagged (TC t n) (O.Column (O.Nullable p))
data Col_PgReadSym1 (t :: *) (col :: TyFun (Col GHC.Symbol WN RN * *) *)
type instance Apply (Col_PgReadSym1 t) col = Col_PgRead t col

---

-- | Type of the 'HL.Record' columns when they can all be nullable
-- (e.g., rhs on a 'O.leftJoin').
type Cols_PgReadNull (t :: *) = List.Map (Col_PgReadNullSym1 t) (Cols t)
type family Col_PgReadNull (t :: *) (col :: Col GHC.Symbol WN RN * *) :: * where
  Col_PgReadNull t ('Col n w 'R  p h) = Tagged (TC t n) (O.Column (O.Nullable p))
  Col_PgReadNull t ('Col n w 'RN p h) = Tagged (TC t n) (O.Column (O.Nullable (O.Nullable p)))
data Col_PgReadNullSym1 (t :: *) (col :: TyFun (Col GHC.Symbol WN RN * *) *)
type instance Apply (Col_PgReadNullSym1 t) col = Col_PgReadNull t col

--------------------------------------------------------------------------------

type Rec (t :: *) xs = Tagged (T t) (HL.Record xs)

-- | Haskell representation for @a@ having a column-per-column mapping to
-- @'RecPgRead' a@. Use this type as the output type of 'O.runQuery'.
type RecHs (t :: *) = Rec t (Cols_Hs t)

-- | Haskell representation for @a@ having a column-per-column mapping to
-- @'RecPgReadNull' a@. Use this type as the output type of 'O.runQuery'.
--
-- Convert a 'RecHsMay' to a more useful @'Maybe' ('RecHs' a)@ using
-- 'mayRecHs'.
type RecHsMay (t :: *) = Rec t (Cols_HsMay t)

-- | You'll often end up with a @('RecHsMay' a)@, for example, when converting
-- the right side of a 'O.leftJoin' to Haskell types. Use this function to
-- get a much more useful @'Maybe' ('RecHs' a)@ to be used with 'fromRecHs'.
mayRecHs :: Tisch t => RecHsMay t -> Maybe (RecHs t)
mayRecHs = fmap Tagged . recordUndistributeMaybe . unTagged
{-# INLINE mayRecHs #-}

-- | Output type of @'O.queryTable' ('tisch'' ('T' :: 'T' t))@
type RecPgRead (t :: *) = Rec t (Cols_PgRead t)

-- | Output type of the right hand side of a 'O.leftJoin'
-- with @'tisch'' ('T' :: 'T' t)@.
type RecPgReadNull (t :: *) = Rec t (Cols_PgReadNull t)

-- | Type used when writting @t@'s PostgreSQL representation to the database.
type RecPgWrite (t :: *) = Rec t (Cols_PgWrite t)

--------------------------------------------------------------------------------

-- | All these constraints need to be satisfied by tools that work with 'Tisch'.
-- It's easier to just write all the constraints once here and make 'TischCtx' a
-- superclass of 'Tisch'. Moreover, they enforce some sanity constraints on our
-- 'Tisch' so that we can get early compile time errors.
type TischCtx t
  = ( DropMaybes (HL.RecordValuesR (Cols_HsMay t)) ~ HL.RecordValuesR (Cols_Hs t)
    , GHC.KnownSymbol (SchemaName t)
    , GHC.KnownSymbol (TableName t)
    , HDistributeProxy (Cols t)
    , HL.HMapAux HList (HCol_Props t) (List.Map ProxySym0 (Cols t)) (Cols_Props t)
    , HL.HMapAux HList HL.TaggedFn (HL.RecordValuesR (Cols_Hs t)) (Cols_Hs t)
    , HL.HMapAux HList HL.TaggedFn (HL.RecordValuesR (Cols_PgWrite t)) (Cols_PgWrite t)
    , HL.HMapAux HList HToPgColumn (HL.RecordValuesR (Cols_Hs t)) (HL.RecordValuesR (Cols_PgWrite t))
    , HL.HRLabelSet (Cols_Hs t)
    , HL.HRLabelSet (Cols_HsMay t)
    , HL.HRLabelSet (Cols_PgRead t)
    , HL.HRLabelSet (Cols_PgReadNull t)
    , HL.HRLabelSet (Cols_PgWrite t)
    , HL.RecordValues (Cols_Hs t)
    , HL.RecordValues (Cols_HsMay t)
    , HL.RecordValues (Cols_PgWrite t)
    , HL.SameLabels (Cols_HsMay t) (Cols_Hs t)
    , HL.SameLength (Cols_Hs t) (Cols_PgWrite t)
    , HL.SameLength (Cols_Props t) (List.Map ProxySym0 (Cols t))
    , HL.SameLength (HL.RecordValuesR (Cols_Hs t)) (HL.RecordValuesR (Cols_PgWrite t))
    , HL.SameLength (HL.RecordValuesR (Cols_PgWrite t)) (HL.RecordValuesR (Cols_Hs t))
    , HUndistributeMaybe (HL.RecordValuesR (Cols_Hs t)) (HL.RecordValuesR (Cols_HsMay t))
    , ProductProfunctorAdaptor O.TableProperties (HL.Record (Cols_Props t)) (HL.Record (Cols_PgWrite t)) (HL.Record (Cols_PgRead t))
    )

-- | Tisch means table in german.
--
-- An instance of this class can uniquely describe a PostgreSQL table and
-- how to convert back and forth between it and its Haskell representation.
--
-- The @t@ type is only used as a tag for the purposes of uniquely identifying
-- this 'Tisch'. It can be whatever you want.
class TischCtx t => Tisch (t :: *) where
  -- | The Haskell type that this 'Tisch' represents.
  type UnTisch t :: *

  type SchemaName t :: GHC.Symbol
  type TableName t :: GHC.Symbol

  -- | Columns in this table. See the documentation for 'Col'.
  type Cols t :: [Col GHC.Symbol WN RN * *]

  -- | Convert an Opaleye-compatible Haskell representation of @'UnTisch' t@ to
  -- @'UnTisch' t@.
  --
  -- For your convenience, you are encouraged to use 'cola', but you may also use
  -- other tools from "Data.HList.Record" as you see fit:
  --
  -- @
  -- 'fromRecHs'' r = Person (r '^.' 'cola' ('C' :: 'C' "name"))
  --                       (r '^.' 'cola' ('C' :: 'C' "age"))
  -- @
  --
  -- Hint: If the type checker is having trouble inferring @('UnTisch' t)@,
  -- consider using 'fromRecHs' instead.
  fromRecHs' :: RecHs t -> Either Ex.SomeException (UnTisch t)

  -- | Convert an @'UnTisch' t@ to an Opaleye-compatible Haskell representation.
  --
  -- For your convenience, you are encouraged to use 'mkRecHs' together with
  -- 'HL.hBuild':
  --
  -- @
  -- 'toRecHs' (Person name age) = 'mkRecHs' $ \\set_ -> 'HL.hBuild'
  --     (set_ ('C' :: 'C' "name") name)
  --     (set_ ('C' :: 'C' "age") age)
  -- @
  --
  -- You may also use other tools from "Data.HList.Record" as you see fit.
  -- A particular benefit of 'mkRecHs' is that you are able to define your
  -- fields in any order and it will work.
  toRecHs :: UnTisch t -> RecHs t

-- | Like 'fromRecHs'', except it takes @t@ explicitely for the times when
-- the it can't be inferred.
fromRecHs :: Tisch t => T t -> RecHs t -> Either Ex.SomeException (UnTisch t)
fromRecHs _ = fromRecHs'
{-# INLINE fromRecHs #-}

-- | Convenience intended to be used within 'toRecHs', together with 'HL.hBuild'.
mkRecHs
  :: forall t xs
  .  (Tisch t, HL.HRearrange (HL.LabelsOf (Cols_Hs t)) xs (Cols_Hs t))
  => ((forall c a. (C c -> a -> Tagged (TC t c) a)) -> HList xs)
  -> RecHs t -- ^
mkRecHs k = Tagged
          $ HL.Record
          $ HL.hRearrange2 (Proxy :: Proxy (HL.LabelsOf (Cols_Hs t)))
          $ k (const Tagged)
{-# INLINE mkRecHs #-}

--------------------------------------------------------------------------------

-- | You'll need to use this function to convert a 'RecHs' to a 'RecPgWrite'
-- when using 'O.runInsert'.
writeRecHs :: Tisch t => RecHs t -> RecPgWrite t
writeRecHs = Tagged . HL.hMapTaggedFn . HL.hMapL HToPgColumn
           . HL.recordValues . unTagged
{-# INLINE writeRecHs #-}

--------------------------------------------------------------------------------

-- | 'O.TableProperties' for all the columns in 'Tisch' @t@.
type Cols_Props (t :: *) = List.Map (Col_PropsSym1 t) (Cols t)

-- | 'O.TableProperties' for a single column in 'Tisch' @t@.
type Col_Props (t :: *) (col :: Col GHC.Symbol WN RN * *)
  = O.TableProperties (Col_PgWrite t col) (Col_PgRead t col)
data Col_PropsSym1 (t :: *) (col :: TyFun (Col GHC.Symbol WN RN * *) *)
type instance Apply (Col_PropsSym1 t) col = Col_Props t col
data Col_PropsSym0 (col :: TyFun t (TyFun (Col GHC.Symbol WN RN * *) * -> *))
type instance Apply Col_PropsSym0 t = Col_PropsSym1 t

class ICol_Props (col :: Col GHC.Symbol WN RN * *) where
  colProps :: Tisch t => Proxy t -> Proxy col -> Col_Props t col

-- | 'colProps' is equivalent 'O.required'.
instance forall n p h. GHC.KnownSymbol n => ICol_Props ('Col n 'W 'R p h) where
  colProps _ = \_ -> P.dimap unTagged Tagged (O.required (GHC.symbolVal (Proxy :: Proxy n)))
  {-# INLINE colProps #-}
-- | 'colProps' is equivalent 'O.required'.
instance forall n p h. GHC.KnownSymbol n => ICol_Props ('Col n 'W 'RN p h) where
  colProps _ = \_ -> P.dimap unTagged Tagged (O.required (GHC.symbolVal (Proxy :: Proxy n)))
  {-# INLINE colProps #-}
-- | 'colProps' is equivalent 'O.optional'.
instance forall n p h. GHC.KnownSymbol n => ICol_Props ('Col n 'WN 'R p h) where
  colProps _ = \_ -> P.dimap unTagged Tagged (O.optional (GHC.symbolVal (Proxy :: Proxy n)))
  {-# INLINE colProps #-}
-- | 'colProps' is equivalent 'O.optional'.
instance forall n p h. GHC.KnownSymbol n => ICol_Props ('Col n 'WN 'RN p h) where
  colProps _ = \_ -> P.dimap unTagged Tagged (O.optional (GHC.symbolVal (Proxy :: Proxy n)))
  {-# INLINE colProps #-}

-- | Use with 'HL.ApplyAB' to apply 'colProps' to each element of an 'HList'.
data HCol_Props (t :: *) = HCol_Props

instance forall t (col :: Col GHC.Symbol WN RN * *) pcol out n w r p h
  . ( Tisch t
    , GHC.KnownSymbol n
    , ICol_Props col
    , pcol ~ Proxy col
    , col ~ 'Col n w r p h
    , out ~ Col_Props t col
    ) => HL.ApplyAB (HCol_Props t) pcol out
    where
      applyAB _ = colProps (Proxy :: Proxy t)
      {-# INLINE applyAB #-}

--------------------------------------------------------------------------------

-- | Opaleye 'O.Table' for a 'Tisch'.
type TischTable (t :: *) = O.Table (RecPgWrite t) (RecPgRead t)

-- | Build the Opaleye 'O.Table' for a 'Tisch'.
tisch :: Tisch t => TischTable t
tisch = tisch' T
{-# INLINE tisch #-}

-- | Like 'tisch', but takes @t@ explicitly to help the compiler when it
-- can't infer @t@.
tisch' :: Tisch t => T t -> TischTable t
tisch' (_ :: T t) =
    O.TableWithSchema schemaName tableName (ppaUnTagged (ppa recProps))
  where
    schemaName = GHC.symbolVal (Proxy :: Proxy (SchemaName t))
    tableName = GHC.symbolVal (Proxy :: Proxy (TableName t))
    recProps = HL.Record (HL.hMapL (HCol_Props :: HCol_Props t)
                                   (hDistributeProxy (Proxy :: Proxy (Cols t))))

--------------------------------------------------------------------------------

-- | Provide 'Comparable' instances for every two columns that you want to be
-- able to compare (e.g., using 'eq').
class (Tisch t1, Tisch t2) => Comparable (t1 :: *) (c1 :: GHC.Symbol) (t2 :: *) (c2 :: GHC.Symbol) (a :: *) where
  _ComparableL :: Iso (Tagged (TC t1 c1) (O.Column a)) (Tagged (TC t2 c2) (O.Column a)) (O.Column a) (O.Column a)
  _ComparableL = _Wrapped
  _ComparableR :: Iso (Tagged (TC t2 c2) (O.Column a)) (Tagged (TC t1 c1) (O.Column a)) (O.Column a) (O.Column a)
  _ComparableR = _Wrapped

-- | Trivial. Same table, same column, same value.
instance Tisch t => Comparable t c t c a 

--------------------------------------------------------------------------------

-- | Convert a Haskell value to a PostgreSQL 'O.Column' value.
-- Think of 'O.pgString', 'O.pgInt4', 'O.pgStrictText', etc.
--
-- You probably won't ever need to call 'toPgColumn' explicity, yet you need to
-- provide an instance for every Haskell type you plan to convert to its
-- PostgreSQL representation.
--
-- A a default implementation of 'toPgColumn' is available for 'Wrapped' types
class ToPgColumn (pg :: *) (hs :: *) where
  toPgColumn :: hs -> O.Column pg
  default toPgColumn :: (Wrapped hs, ToPgColumn pg (Unwrapped hs)) => hs -> O.Column pg
  toPgColumn = toPgColumn . view _Wrapped'
  {-# INLINE toPgColumn #-}

-- | Trivial.
instance ToPgColumn pg (O.Column pg) where toPgColumn = id
-- | OVERLAPPABLE. Any @pg@ can be made 'O.Nullable'.
instance {-# OVERLAPPABLE #-} ToPgColumn pg hs => ToPgColumn (O.Nullable pg) hs where
  toPgColumn = O.toNullable . toPgColumn
  {-# INLINE toPgColumn #-}
-- | OVERLAPPS @'ToPgColumn' ('O.Nullable' pg) hs@. 'Nothing' is @NULL@.
instance ToPgColumn pg hs => ToPgColumn (O.Nullable pg) (Maybe hs) where
  toPgColumn = maybe O.null (O.toNullable . toPgColumn)
  {-# INLINE toPgColumn #-}

instance ToPgColumn O.PGText [Char] where toPgColumn = O.pgString
instance ToPgColumn O.PGBool Bool where toPgColumn = O.pgBool
-- | Note: Portability wise, it's a /terrible/ idea to have an 'Int' instance instead.
-- Use 'Int32', 'Int64', etc. explicitely.
instance ToPgColumn O.PGInt4 Int32 where toPgColumn = O.pgInt4 . fromIntegral
-- | Note: Portability wise, it's a /terrible/ idea to have an 'Int' instance instead.
-- Use 'Int32', 'Int64', etc. explicitely.
instance ToPgColumn O.PGInt8 Int64 where toPgColumn = O.pgInt8
instance ToPgColumn O.PGFloat8 Double where toPgColumn = O.pgDouble
instance ToPgColumn O.PGText Data.Text.Text where toPgColumn = O.pgStrictText
instance ToPgColumn O.PGText Data.Text.Lazy.Text where toPgColumn = O.pgLazyText
instance ToPgColumn O.PGBytea Data.ByteString.ByteString where toPgColumn = O.pgStrictByteString
instance ToPgColumn O.PGBytea Data.ByteString.Lazy.ByteString where toPgColumn = O.pgLazyByteString
instance ToPgColumn O.PGTimestamptz Data.Time.UTCTime where toPgColumn = O.pgUTCTime
instance ToPgColumn O.PGTimestamp Data.Time.LocalTime where toPgColumn = O.pgLocalTime
instance ToPgColumn O.PGTime Data.Time.TimeOfDay where toPgColumn = O.pgTimeOfDay
instance ToPgColumn O.PGDate Data.Time.Day where toPgColumn = O.pgDay
instance ToPgColumn O.PGUuid Data.UUID.UUID where toPgColumn = O.pgUUID
instance ToPgColumn O.PGCitext (Data.CaseInsensitive.CI Data.Text.Text) where toPgColumn = O.pgCiStrictText
instance ToPgColumn O.PGCitext (Data.CaseInsensitive.CI Data.Text.Lazy.Text) where toPgColumn = O.pgCiLazyText
instance Data.Aeson.ToJSON hs => ToPgColumn O.PGJson hs where toPgColumn = O.pgLazyJSON . Data.Aeson.encode
instance Data.Aeson.ToJSON hs => ToPgColumn O.PGJsonb hs where toPgColumn = O.pgLazyJSONB . Data.Aeson.encode

--------------------------------------------------------------------------------

-- | Use with 'HL.ApplyAB' to apply 'toPgColumn' to each element of an 'HList'.
data HToPgColumn = HToPgColumn

instance (ToPgColumn pg hs) => HL.ApplyAB HToPgColumn hs (O.Column pg) where
   applyAB _ = toPgColumn
   {-# INLINE applyAB #-}
instance (ToPgColumn pg hs) => HL.ApplyAB HToPgColumn hs (Maybe (O.Column pg)) where
   applyAB _ hs = Just (toPgColumn hs)
   {-# INLINE applyAB #-}

--------------------------------------------------------------------------------

-- | Lens to the value of a column.
col :: HL.HLensCxt (TC t c) HL.Record xs xs' a a'
    => C c
    -> Lens (Rec t xs) (Rec t xs') (Tagged (TC t c) a) (Tagged (TC t c) a')
col prx = cola prx . _Unwrapped
{-# INLINE col #-}

-- | Lens to the value of a column without the 'TC' tag.
--
-- Most of the time you'll want to use 'col' instead, but this might be more useful
-- when trying to change the type of @a@ during an update, or when implementing
-- 'fromRecHs'.
cola :: HL.HLensCxt (TC t c) HL.Record xs xs' a a'
     => C c
     -> Lens (Rec t xs) (Rec t xs') a a'
cola = go where -- just to hide the "forall" from the haddocks
  go
    :: forall t c xs xs' a a'. HL.HLensCxt (TC t c) HL.Record xs xs' a a'
    => C c -> Lens (Rec t xs) (Rec t xs') a a'
  go = \_ -> _Wrapped . HL.hLens (HL.Label :: HL.Label (TC t c))
  {-# INLINE go #-}
{-# INLINE cola #-}

-- | @'setc' ('C' :: 'C' "x") hs = 'set' ('cola' ('C' :: 'C' "x")) ('toPgColumn' hs)@
--
-- This function is particularly useful when writing functions of type
-- @(RecPgRead t -> RecPgWrite t)@, such as those required by 'O.runUpdate'.
setc :: ( ToPgColumn a' hs
        , HL.HLensCxt (TC t c) HL.Record xs xs' (O.Column a) (O.Column a') )
     => C c -> hs -> Rec t xs -> Rec t xs'
setc c hs = set (cola c) (toPgColumn hs)
{-# INLINE setc #-}

--------------------------------------------------------------------------------

type family IsNotNullable (x :: *) :: Constraint where
  IsNotNullable (O.Nullable x) = ('True ~ 'False)
  IsNotNullable x = ()

-- | Like 'O..==', but restricted to 'Comparable' columns and not 'O.Nullable'
-- columns.
eq :: (Comparable lt lc rt rc a, IsNotNullable a)
   => Tagged (TC lt lc) (O.Column a)
   -> Tagged (TC rt rc) (O.Column a)
   -> O.Column O.PGBool
eq l r = (O..==) (view _ComparableL l) (view _ComparableR r)
{-# INLINE eq #-}

-- | Like 'eq', but the first argument is a constant.
eqc :: (ToPgColumn a h, IsNotNullable a)
    => h
    -> Tagged (TC rt rc) (O.Column a)
    -> O.Column O.PGBool
eqc lh r = (O..==) (toPgColumn lh) (unTagged r)
{-# INLINE eqc #-}

-- | Like 'O..==', but restricted to 'Comparable' columns and 'O.Nullable'
-- columns. The first argument doesn't need to be 'O.Nullable' already.
eqn :: ( Comparable lt lc rt rc (O.Nullable a)
       , PP.Default OI.NullMaker (O.Column a') (O.Column (O.Nullable a)))
    => Tagged (TC lt lc) (O.Column a')
    -> Tagged (TC rt rc) (O.Column (O.Nullable a))
    -> O.Column (O.Nullable O.PGBool)
eqn l r = O.toNullable $ (O..==)
   (OI.toNullable PP.def (view _ComparableL l))
   (view _ComparableR r)
{-# INLINE eqn #-}

-- | Like 'eqn', but the first argument is a constant.
eqnc :: ToPgColumn (O.Nullable a) (Maybe h)
     => Maybe h
     -> Tagged (TC rt rc) (O.Column (O.Nullable a))
     -> O.Column (O.Nullable O.PGBool)
eqnc lmh r = O.toNullable $ (O..==) (toPgColumn lmh) (unTagged r)
{-# INLINE eqnc #-}


--------------------------------------------------------------------------------

-- | The functional dependencies make type inference easier, but also forbid some
-- otherwise acceptable instances. See the instance for 'Tagged' for example.
class P.Profunctor p => ProductProfunctorAdaptor p l ra rb | p l -> ra rb, p ra rb -> l where
  ppa :: l -> p ra rb

ppaUnTagged :: P.Profunctor p => p a b -> p (Tagged ta a) (Tagged tb b)
ppaUnTagged = P.dimap unTagged Tagged
{-# INLINE ppaUnTagged #-}

ppaTagged :: P.Profunctor p => Tagged tpab (p a b) -> p (Tagged ta a) (Tagged tb b)
ppaTagged = ppaUnTagged . unTagged
{-# INLINE ppaTagged #-}

-- | Due to the functional dependencies in 'ProductProfunctorAdaptor', this instance is not as
-- polymorphic as it could be in @t@. Use 'ppaTagged' instead for a fully polymorphic version.
instance P.Profunctor p => ProductProfunctorAdaptor p (Tagged t (p a b)) (Tagged t a) (Tagged t b) where
  ppa = ppaTagged
  {-# INLINE ppa #-}

-- | 'HList' of length 0.
instance PP.ProductProfunctor p => ProductProfunctorAdaptor p (HList '[]) (HList '[]) (HList '[]) where
  ppa = const (P.dimap (const ()) (const HNil) PP.empty)
  {-# INLINE ppa #-}

-- | 'HList' of length 1 or more.
instance
    ( PP.ProductProfunctor p
    , ProductProfunctorAdaptor p (HList pabs) (HList as) (HList bs)
    ) => ProductProfunctorAdaptor p (HList (p a1 b1 ': pabs)) (HList (a1 ': as)) (HList (b1 ': bs)) where
  ppa = \(HCons pab1 pabs) -> P.dimap (\(HCons x xs) -> (x,xs)) (uncurry HCons) (pab1 PP.***! ppa pabs)
  {-# INLINABLE ppa #-}

instance
    ( ProductProfunctorAdaptor p (HList pabs) (HList as) (HList bs)
    ) => ProductProfunctorAdaptor p (HL.Record pabs) (HL.Record as) (HL.Record bs) where
  ppa = P.dimap unRecord HL.Record . ppa . unRecord
  {-# INLINE ppa #-}

--------------------------------------------------------------------------------

-- | Orphan. 'Opaleye.SOT.Internal'.
instance (PP.ProductProfunctor p, PP.Default p a b) => PP.Default p (Tagged ta a) (Tagged tb b) where
  def = ppaUnTagged PP.def
  {-# INLINE def #-}

-- -- | Orphan. 'Opaleye.SOT.Internal'. Defaults to 'Just'.
-- instance PP.ProductProfunctor p => PP.Default p (HList '[]) (Maybe (HList '[])) where
--   def = P.rmap Just PP.def
--   {-# INLINE def #-}
-- 
-- instance 
--     ( PP.ProductProfunctor p, PP.Default p (O.Column (O.Nullable a)) (Maybe b)
--     ) => PP.Default p (Tagged ta (O.Column (O.Nullable a))) (Maybe (Tagged tb b)) where
--   def = P.dimap unTagged (fmap Tagged) PP.def
--   {-# INLINE def #-}

-- | Orphan. 'Opaleye.SOT.Internal'.
instance PP.ProductProfunctor p => PP.Default p (HList '[]) (HList '[]) where
  def = ppa HNil
  {-# INLINE def #-}

-- | Orphan. 'Opaleye.SOT.Internal'.
instance
    ( PP.ProductProfunctor p, PP.Default p a1 b1, PP.Default p (HList as) (HList bs)
    ) => PP.Default p (HList (a1 ': as)) (HList (b1 ': bs)) where
  def = P.dimap (\(HCons x xs) -> (x,xs)) (uncurry HCons) (PP.def PP.***! PP.def)
  {-# INLINABLE def #-}

-- | Orphan. 'Opaleye.SOT.Internal'.
instance
    ( PP.ProductProfunctor p, PP.Default p (HList as) (HList bs)
    ) => PP.Default p (HL.Record as) (HL.Record bs) where
  def = P.dimap unRecord HL.Record PP.def
  {-# INLINE def #-}

--------------------------------------------------------------------------------
-- Misc

-- | Apply a same constraint to all the types in the list.
type family All (c :: k -> Constraint) (xs :: [k]) :: Constraint where
  All c '[]       = ()
  All c (x ': xs) = (c x, All c xs)

---

-- | Defunctionalized 'Proxy'. To be used with 'Apply'.
data ProxySym0 (a :: TyFun k *)
type instance Apply ProxySym0 a = Proxy a

class HDistributeProxy (xs :: [k]) where
  hDistributeProxy :: Proxy xs -> HList (List.Map ProxySym0 xs)
instance HDistributeProxy ('[] :: [k]) where
  hDistributeProxy _ = HNil
  {-# INLINE hDistributeProxy #-}
instance forall (x :: k) (xs :: [k]). HDistributeProxy xs => HDistributeProxy (x ': xs) where
  hDistributeProxy _ = HCons (Proxy :: Proxy x) (hDistributeProxy (Proxy :: Proxy xs))
  {-# INLINE hDistributeProxy #-}

---

type family AllMaybes (xs :: [*]) :: Constraint where
  AllMaybes '[] = ()
  AllMaybes (Maybe x ': xs) = AllMaybes xs

type family DropMaybes (xs :: [*]) :: [*] where
  DropMaybes '[] = '[]
  DropMaybes (Maybe x ': xs) = (x ': DropMaybes xs)

class ( AllMaybes xms, DropMaybes xms ~ xs
      ) => HUndistributeMaybe (xs :: [*]) (xms :: [*]) where
  hUndistributeMaybe :: HList xms -> Maybe (HList xs)
instance HUndistributeMaybe '[] '[] where
  hUndistributeMaybe = \_ -> Just HNil
  {-# INLINE hUndistributeMaybe #-}
instance HUndistributeMaybe xs xms => HUndistributeMaybe (x ': xs) (Maybe x ': xms) where
  hUndistributeMaybe = \(HCons mx xms) -> HCons <$> mx <*> hUndistributeMaybe xms
  {-# INLINE hUndistributeMaybe #-}

-- | It's easier to have this function than to have 'HUndistributeMaybe' work
-- for both 'HList' and 'HL.Record'.
recordUndistributeMaybe
  :: ( HL.SameLabels tmxs txs
     , HL.HAllTaggedLV txs
     , HL.RecordValues txs
     , HL.HAllTaggedLV tmxs
     , HL.RecordValues tmxs
     , HL.RecordValuesR txs ~ DropMaybes (HL.RecordValuesR tmxs)
     , HL.HMapAux HList HL.TaggedFn (HL.RecordValuesR txs) txs
     , HUndistributeMaybe (HL.RecordValuesR txs) (HL.RecordValuesR tmxs) )
  => HL.Record tmxs
  -> Maybe (HL.Record txs)
recordUndistributeMaybe = fmap HL.hMapTaggedFn . hUndistributeMaybe . HL.recordValues
{-# INLINE recordUndistributeMaybe #-}

--------------------------------------------------------------------------------

unRecord :: HL.Record xs -> HList xs
unRecord = \(HL.Record x) -> x
{-# INLINE unRecord #-}
