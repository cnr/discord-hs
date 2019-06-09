
module Discord.Rest
    ( HasRateLimits(..)
    , RateLimits(..)
    , Request(..)
    , newRateLimits
    , runRequest
    )
    where

import           Control.Applicative
import           Control.Lens
import           Control.Monad.Reader
import           Data.Aeson
import qualified Data.ByteString.Char8 as BS8
import           Data.CaseInsensitive
import           Data.Foldable
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.Time.Clock.POSIX (getPOSIXTime)
import qualified Network.HTTP.Client as HC
import qualified Network.HTTP.Types.Status as HS
import           Network.HTTP.Req
import           UnliftIO hiding (Handler)
import           UnliftIO.Concurrent

import Discord.Types.Common
import Discord.Types.Rest


runRequest :: (FromJSON a, HasToken e, HasRateLimits e, MonadReader e m, MonadUnliftIO m) => Request a -> m a
runRequest request = do
    limits <- view rateLimitsL

    (box :: MVar (Either SomeException a)) <- newEmptyMVar

    lock <- getRouteLock limits (requestUrl request) (requestMajor request)

    let go :: (HasRateLimits e, HasToken e, MonadReader e m, MonadUnliftIO m) => m ()
        go = do
            token  <- view tokenL
            readMVar (globalLock limits)
            result <- runReq defaultHttpConfig (requestAction request token)

            putMVar box (Right (responseBody result))

            traverse_ waitRateLimit (parseLimit (toVanillaResponse result))
                `catch` (\(e :: HttpException) -> case e of
                    VanillaHttpException (HC.HttpExceptionRequest _ (HC.StatusCodeException resp _)) ->
                        case HS.statusCode (HC.responseStatus resp) of
                            429 -> traverse_ waitRateLimit (parseLimit resp) *> go
                            _   -> tryPutMVar box (Left (SomeException e)) *> throwIO e
                    _ -> tryPutMVar box (Left (SomeException e)) *> throwIO e)
                `catch` (\(e :: SomeException) -> tryPutMVar box (Left e) *> pure ())

    -- TODO: this shouldn't deadlock(?) but double-check
    _ <- forkIO $ withMVar lock $ \_ -> go

    result <- takeMVar box
    case result of
        Left  e -> throwIO e
        Right a -> pure a

getRouteLock :: MonadUnliftIO m => RateLimits -> Url 'Https -> Maybe Snowflake -> m Lock
getRouteLock limits route major = do
    modifyMVar (routeLocks limits) $ \routeLocks ->
        case M.lookup (route, major) routeLocks of
            Just semaphore -> pure (routeLocks, semaphore)
            Nothing -> do
                semaphore <- newMVar ()
                pure (M.insert (route, major) semaphore routeLocks, semaphore)

parseLimit :: HC.Response a -> Maybe RateLimit
parseLimit response = do
    guard noneRemaining
    reset <- RLResetAfter <$> retryAfter <|> RLResetAt <$> ratelimitReset
    pure (RateLimit scope reset)

    where
    getHeader bs = lookup (mk bs) (HC.responseHeaders response)

    scope = if isGlobal then RLGlobal else RLRoute
    isGlobal = maybe False (== "true") (getHeader "X-RateLimit-Global")
    noneRemaining = maybe True (== "0") (getHeader "X-RateLimit-Remaining")

    retryAfter     = read . BS8.unpack <$> getHeader "Retry-After"       :: Maybe Int
    ratelimitReset = read . BS8.unpack <$> getHeader "X-Ratelimit-Reset" :: Maybe Int

waitRateLimit :: (HasRateLimits e, MonadReader e m, MonadUnliftIO m) => RateLimit -> m ()
waitRateLimit (RateLimit scope reset) =
    case scope of
        RLGlobal -> do
            lock <- view (rateLimitsL . to globalLock)
            withMVar lock $ \_ -> delayRateLimit reset
        RLRoute -> delayRateLimit reset

delayRateLimit :: MonadIO m => RateLimitReset -> m ()
delayRateLimit (RLResetAfter millis) = liftIO $ threadDelay (millis * 1_000)
delayRateLimit (RLResetAt resetTime) = liftIO $ do
    currentTime <- getCurrentTimeEpochSeconds
    threadDelay ((resetTime - currentTime) * 1_000_000)

newRateLimits :: MonadUnliftIO m => m RateLimits
newRateLimits = RateLimits <$> newMVar () <*> newMVar M.empty

type Lock = MVar ()

data RateLimits = RateLimits
    { globalLock :: Lock
    , routeLocks :: MVar (Map (Url 'Https, Maybe Snowflake) Lock)
    }

class HasRateLimits e where
    rateLimitsL :: Lens' e RateLimits

instance HasRateLimits RateLimits where
    rateLimitsL = id

data RateLimit = RateLimit RateLimitScope RateLimitReset deriving Show

data RateLimitScope = RLGlobal | RLRoute deriving Show

data RateLimitReset = RLResetAfter Int -- millis
                    | RLResetAt EpochSeconds
                    deriving Show


type EpochSeconds = Int

getCurrentTimeEpochSeconds :: IO EpochSeconds
getCurrentTimeEpochSeconds = round <$> getPOSIXTime
