{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE MultiWayIf                #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE TypeFamilies              #-}

module Aws.DynamoDb.Tools.TimeSeries.Sparse
    ( saveCell
    , getCell
    , getCells
    , getLastCell
    , deleteCells
    ) where


-------------------------------------------------------------------------------
import           Aws.Aws
import           Aws.DynamoDb
import           Control.Applicative
import           Control.Error
import           Control.Lens
import           Control.Monad
import           Control.Monad.Reader
import           Control.Monad.Trans.Resource
import           Data.Conduit                        (($$), (=$=))
import qualified Data.Conduit                        as C
import qualified Data.Conduit.List                   as C
import           Data.Default
import qualified Data.Map                            as M
import           Data.Time
import           System.Random
-------------------------------------------------------------------------------
import           Aws.DynamoDb.Tools.Connection
import           Aws.DynamoDb.Tools.TimeSeries.Types
import           Aws.DynamoDb.Tools.Types
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
-- | Save item into series.
--
-- If an old item is present:
--
-- 1. diff the changes and only send those, minimizing write
-- throughput.
--
-- 2. Raise an error if item on database has already been updated (via
-- 'UpdateCursor').
saveCell
    :: ( TimeSeries v
       , DdbQuery n )
    => Maybe v
    -- ^ An old item, if there is one
    -> v
    -- ^ The new item to be written to db
    -> ResourceT n ()
saveCell old new = do
    tbl <- lift $ dynTableFullname dynTimeseriesTable

    -- generate new cursor
    u <- liftIO randomIO
    let new' = new & updateCursor .~ u

    case update new' of
      Left v -> void $ (cDynN 5) $ putItem tbl v
      Right (pk, us) -> void $ (cDynN 5) $
        (updateItem tbl pk us) { uiExpect = mkCond old }
    where
      update n =
        let new' = mkItem n
        in maybe (Left new')
                 (diffItem ["_k", "_t"] new' . mkItem)
                 old

      mkItem i = M.union (adds i) (toItem i)

      adds i = item
        [ attr "_k" (seriesKey i) -- primary/hash key
        , attr "_t" (timeCursor i) -- secondary/range key
        , attr "_l" (updatedAt i)
        , attr "_s" (i ^. updateCursor)
        ]

      -- prevent concurrent race conditions by requiring identity on
      -- cursor
      mkCond Nothing = def
      mkCond (Just e) = Conditions CondAnd $
        [ Condition "_l" (DEq (toValue (updatedAt e))) ] ++
        if e ^. updateCursor == nilUuid
          then []
          else [Condition "_s" (DEq (toValue (e ^. updateCursor)))]


-------------------------------------------------------------------------------
-- | Get cell with an exactly known timestamp
getCell
    :: (DdbQuery n , TimeSeries a )
    => TimeSeriesKey a
    -> UTCTime
    -> ResourceT n (Either String a)
getCell k at = do
    tbl <- lift $ dynTableFullname dynTimeseriesTable
    let a = PrimaryKey (seriesKeyAttr k) (Just (attr "_t" at))
        q = GetItem tbl a Nothing True def
    resp <- girItem <$> (cDynN 5) q
    return $ note missing resp >>= fromItem
  where
    missing = "TimeSeries cell not found: " ++ show (serializeSeriesKey k, at)


-------------------------------------------------------------------------------
getCells
    :: ( TimeSeries a
       , DdbQuery n )
    => TimeSeriesKey a
    -> Maybe UTCTime
    -> Maybe UTCTime
    -> Int
    -- ^ Per-page pull from DynamoDb
    -> C.Producer (ResourceT n) (Either String a)
getCells k fr to lim = do
    tbl <- lift . lift $ dynTableFullname dynTimeseriesTable
    let q = (query tbl (Slice (seriesKeyAttr k) (Condition "_t" <$> cond)))
              { qLimit = Just lim, qForwardScan = False, qConsistent = True}
    awsIteratedList' (cDynN 5) q =$= C.isolate lim =$= C.map fromItem
  where

    cond = between <|> gt <|> lt

    between = do
        fr' <- fr
        to' <- to
        return $ Between (toValue fr') (toValue to')

    gt = DGE . toValue <$> fr
    lt = DLE . toValue <$> to


-------------------------------------------------------------------------------
-- | Obtain the last cell in series.
getLastCell
    :: (DdbQuery n, TimeSeries a)
    => TimeSeriesKey a
    -> ResourceT n (Maybe (Either String a))
getLastCell k = headMay <$> (getCells k Nothing Nothing 1 $$ C.take 1)


-------------------------------------------------------------------------------
-- | Delete all values for given timeseries key between the given two
-- dates. Input 'Nothing' for limits if you want to remove the entire
-- series.
deleteCells
    :: ( DdbQuery n
       , SeriesKey k)
    => k
    -- ^ Series key to delete
    -> Maybe UTCTime
    -- ^ From time
    -> Maybe UTCTime
    -- ^ To time
    -> Maybe Int
    -- ^ Per-page limit during query scan
    -> ResourceT n ()
deleteCells k fr to lim = do
    tbl <- lift $ dynTableFullname dynTimeseriesTable
    let q = (query tbl (Slice pkAttr (Condition "_t" <$> cond)))
              { qLimit = lim, qConsistent = True, qSelect = SelectSpecific ["_k", "_t"] }
    awsIteratedList' (cDynN 5) q =$= C.mapM_ (void . cDynN 5 . del tbl) C.$$ C.sinkNull
  where

    pkAttr = seriesKeyAttr k

    del tbl i = deleteItem tbl pk
        where
          pk = PrimaryKey pkAttr (attr "_t" <$> M.lookup "_t" i)

    cond = between <|> gt <|> lt

    between = do
        fr' <- fr
        to' <- to
        return $ Between (toValue fr') (toValue to')

    gt = DGE . toValue <$> fr
    lt = DLE . toValue <$> to







