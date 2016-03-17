{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}

module Juno.Util.Util
  ( seqIndex
  , lastLogInfo
  , getQuorumSize
  , debug
  , randomRIO
  , runRWS_
  , enqueueEvent, enqueueEventLater
  , dequeueEvent
  , messageReceiver
  , updateTerm
  , getCmdSigOrInvariantError
  , getRevSigOrInvariantError
  ) where

import Juno.Runtime.Types
import Juno.Util.Combinator

import Control.Lens
import Data.Sequence (Seq)
import Control.Monad.RWS
import qualified Control.Concurrent.Lifted as CL
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import qualified Data.Sequence as Seq
import qualified System.Random as R
import Data.Serialize

seqIndex :: Seq a -> Int -> Maybe a
seqIndex s i =
  if i >= 0 && i < Seq.length s
    then Just (Seq.index s i)
    else Nothing

getQuorumSize :: Int -> Int
getQuorumSize n = minimum [n - f | f <- [0..n], n >= 3*f + 1]

-- get the last term and index of a log
lastLogInfo :: Seq LogEntry -> (Term, LogIndex, ByteString)
lastLogInfo es =
  case Seq.viewr es of                 -- \/ TODO: This smells weird, should we really use length for this?
    _ Seq.:> LogEntry{..} -> (_leTerm, LogIndex $ Seq.length es - 1, _leHash)
    Seq.EmptyR            -> (startTerm, startIndex, B.empty)

debug :: Monad m => String -> Raft m ()
debug s = do
  dbg <- view (rs.debugPrint)
  nid <- view (cfg.nodeId)
  role' <- use role
  let prettyRole = case role' of
        Leader -> "\ESC[0;34m[LEADER]\ESC[0m"
        Follower -> "\ESC[0;32m[FOLLOWER]\ESC[0m"
        Candidate -> "\ESC[1;33m[CANDIDATE]\ESC[0m"
  dbg nid $ prettyRole ++ ": " ++ s

randomRIO :: (Monad m, R.Random a) => (a,a) -> Raft m a
randomRIO rng = view (rs.random) >>= \f -> f rng -- R.randomRIO

runRWS_ :: Monad m => RWST r w s m a -> r -> s -> m ()
runRWS_ ma r s = runRWST ma r s >> return ()

-- no state update
enqueueEvent :: Monad m => Event -> Raft m ()
enqueueEvent event = view (rs.enqueue) >>= \f -> f event
  -- lift $ writeChan ein event

enqueueEventLater :: Monad m => Int -> Event -> Raft m CL.ThreadId
enqueueEventLater t event = view (rs.enqueueLater) >>= \f -> f t event

-- no state update
dequeueEvent :: Monad m => Raft m Event
dequeueEvent = join $ view (rs.dequeue)

-- | Thread to take incoming messages and write them to the event queue.
-- THREAD: MESSAGE RECEIVER (client and server), no state updates
messageReceiver :: Monad m => Raft m ()
messageReceiver = do
  gm <- view (rs.getMessage)
  ks <- KeySet <$> view (cfg.publicKeys) <*> view (cfg.clientPublicKeys)
  forever $ do
    msg <- gm
    case decode msg of
      Left err -> debug $ "Failed to deserialize to SignedRPC: " ++ err
      Right v -> case signedRPCtoRPC ks v of
        Left err -> debug err
        Right rpc -> enqueueEvent $ ERPC rpc

updateTerm :: Monad m => Term -> Raft m ()
updateTerm t = do
  void $ rs.writeTermNumber ^$ t
  term .= t

getCmdSigOrInvariantError :: String -> Command -> LB.ByteString
getCmdSigOrInvariantError where' s@Command{..} = case _cmdProvenance of
  NewMsg -> error $ where'
    ++ ": This should be unreachable, somehow an AE got through with a LogEntry that contained an unsigned Command" ++ show s
  ReceivedMsg{..} -> _digSig _pDig

getRevSigOrInvariantError :: String -> Revolution -> LB.ByteString
getRevSigOrInvariantError where' s@Revolution{..} = case _revProvenance of
  NewMsg -> error $ where'
    ++ ": This should be unreachable, got an unsigned Revolution" ++ show s
  ReceivedMsg{..} -> _digSig _pDig
