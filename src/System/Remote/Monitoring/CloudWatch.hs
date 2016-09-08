{-# LANGUAGE BangPatterns           #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE LambdaCase             #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE RecordWildCards        #-}
{-# LANGUAGE TemplateHaskell        #-}

-- | This module allows you to periodically push your 'ekg' metrics to the
-- Amazon CloudWatch backend. Inspired by the 'ekg-statsd' module.
--
-- To use, run 'forkCloudWatch' with the 'CloudWatchEnv' and metrics 'Store'.
module System.Remote.Monitoring.CloudWatch
  ( CloudWatchId
  , cloudWatchThreadId
  , forkCloudWatch
  , CloudWatchEnv(..)
  , defaultCloudWatchEnv
  ) where

import           Control.Concurrent                   (ThreadId, forkFinally,
                                                       myThreadId, threadDelay)
import           Control.Exception
import           Control.Lens
import           Control.Monad                        (void)
import qualified Data.HashMap.Strict                  as Map
import           Data.Int                             (Int64)
import           Data.Monoid
import           Data.Text                            (Text)
import qualified Data.Text                            as Text
import           Data.Time                            (NominalDiffTime)
import           Data.Time.Clock.POSIX                (getPOSIXTime)
import           Network.AWS                          as AWS
import           Network.AWS.CloudWatch               as AWS
import qualified System.Metrics.Distribution.Internal as Distribution

import qualified System.Metrics                       as Metrics

-- | The 'ThreadID' for the 'CloudWatch' process.
newtype CloudWatchId = CloudWatchId
  { cloudWatchThreadId :: ThreadId
  }

-- | The environment for the CloudWatch EKG metric pusher.
data CloudWatchEnv = CloudWatchEnv
  { cweFlushInterval :: !Int
  -- ^ The interval of time to flush, in milliseconds.
  , cweAwsEnv        :: !AWS.Env
  -- ^ The AWS Environment that connects to the CloudWatch services.
  , cweDimensions    :: ![AWS.Dimension]
  -- ^ The extra dimensions to pass for each metric.
  , cweNamespace     :: !Text
  -- ^ The namespace that the service runs in.
  }

makeFields ''CloudWatchEnv

-- | The default 'CloudWatchEnv'. Equal to:
-- @
-- 'CloudWatchEnv'
--   { 'cweFlushInterval' = 1000
--   , 'cweAwsEnv' = x
--   , 'cweNamespace' = ""
--   , 'cweDimensions' = []
--   }
-- @
defaultCloudWatchEnv :: AWS.Env -> CloudWatchEnv
defaultCloudWatchEnv x =
  CloudWatchEnv
  { cweFlushInterval = 1000
  , cweAwsEnv = x
  , cweNamespace = ""
  , cweDimensions = []
  }

-- | Forks a thread to periodically publish metrics to Amazon's CloudWatch
-- service for the given 'Store'.
forkCloudWatch :: CloudWatchEnv -> Metrics.Store -> IO CloudWatchId
forkCloudWatch env store = do
  me <- myThreadId
  fmap CloudWatchId . forkFinally (loop env store mempty) $ \case
      Left e -> throwTo me e
      Right _ -> pure ()

loop :: CloudWatchEnv -> Metrics.Store -> Metrics.Sample -> IO ()
loop env store lastSample = do
  start <- time
  sample <- Metrics.sampleAll store
  flushSample env (diffSamples lastSample sample)
  end <- time
  threadDelay (cweFlushInterval env * 100 - fromIntegral (end - start))
  loop env store sample

-- | Microseconds since epoch. Vendored from `ekg-statsd`
time :: IO Int64
time = round . (* 1000000.0) . toDouble <$> getPOSIXTime
  where
    toDouble = realToFrac :: NominalDiffTime -> Double

-- | Vendored from `ekg-statsd`
diffSamples :: Metrics.Sample -> Metrics.Sample -> Metrics.Sample
diffSamples prev !curr = Map.foldlWithKey' combine Map.empty curr
  where
    combine m name new =
      case Map.lookup name prev of
        Just old ->
          case diffMetric old new of
            Just val -> Map.insert name val m
            Nothing -> m
        _ -> Map.insert name new m

    diffMetric :: Metrics.Value -> Metrics.Value -> Maybe Metrics.Value
    diffMetric (Metrics.Counter n1) (Metrics.Counter n2)
      | n1 == n2 = Nothing
      | otherwise = Just $! Metrics.Counter $ n2 - n1
    diffMetric (Metrics.Gauge n1) (Metrics.Gauge n2)
      | n1 == n2 = Nothing
      | otherwise = Just $ Metrics.Gauge n2
    diffMetric (Metrics.Label n1) (Metrics.Label n2)
      | n1 == n2 = Nothing
      | otherwise = Just $ Metrics.Label n2
    diffMetric (Metrics.Distribution d1) (Metrics.Distribution d2)
      | Distribution.count d1 == Distribution.count d2 = Nothing
      | otherwise =
        Just . Metrics.Distribution $
        d2 {Distribution.count = Distribution.count d2 - Distribution.count d1}
    diffMetric _ _ = Nothing

flushSample :: CloudWatchEnv -> Metrics.Sample -> IO ()
flushSample CloudWatchEnv{..} = void . Map.traverseWithKey flushMetric
  where
    flushMetric :: Text -> Metrics.Value -> IO ()
    flushMetric name =
      \case
        Metrics.Counter n ->
          sendMetric name (mdValue ?~ fromIntegral n)
        Metrics.Gauge n ->
          sendMetric name (mdValue ?~ fromIntegral n)
        Metrics.Distribution d ->
          sendMetric name (mdStatisticValues ?~ conv d)
        Metrics.Label l ->
          pure ()

    sendMetric :: Text -> (MetricDatum -> MetricDatum) -> IO ()
    sendMetric name k = do
      e <- trying _Error . void . runResourceT . runAWS cweAwsEnv . send $
        putMetricData cweNamespace
          & pmdMetricData .~
            [ metricDatum name
              & mdDimensions .~ cweDimensions
              & k
            ]
      case e of
        Left err -> pure () -- TODO: log?
        Right _ -> pure ()

    conv :: Distribution.Stats -> StatisticSet
    conv Distribution.Stats{..} = statisticSet (fromIntegral count) sum min max
