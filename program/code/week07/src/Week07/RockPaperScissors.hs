{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}

module Week07.RockPaperScissors
    ( Game (..)
    , GameChoice (..)
    , FirstParams (..)
    , SecondParams (..)
    , GameSchema
    , endpoints
    ) where

import           Control.Monad                hiding (fmap)
import           Data.Aeson                   (FromJSON, ToJSON)
import           Data.Text                    (Text, pack)
import           GHC.Generics                 (Generic)
import           Plutus.Contract              as Contract hiding (when)
import           Plutus.Contract.StateMachine
import qualified PlutusTx
import           PlutusTx.Prelude             hiding (Semigroup(..), check, unless)
import           Ledger                       hiding (singleton)
import           Ledger.Ada                   as Ada
import           Ledger.Constraints           as Constraints
import           Ledger.Typed.Tx
import qualified Ledger.Typed.Scripts         as Scripts
import           Ledger.Value
import           Playground.Contract          (ToSchema)
import           Prelude                      (Semigroup (..))
import qualified Prelude

data Game = Game
    { gFirst          :: !PubKeyHash
    , gSecond         :: !PubKeyHash
    , gStake          :: !Integer
    , gPlayDeadline   :: !Slot
    , gRevealDeadline :: !Slot
    , gToken          :: !AssetClass
    } deriving (Show, Generic, FromJSON, ToJSON, Prelude.Eq, Prelude.Ord)

PlutusTx.makeLift ''Game

data GameChoice = Rock | Paper | Scissors
    deriving (Show, Generic, FromJSON, ToJSON, ToSchema, Prelude.Eq, Prelude.Ord)

instance Eq GameChoice where
    {-# INLINABLE (==) #-}
    Rock     == Rock     = True
    Paper    == Paper    = True
    Scissors == Scissors = True
    _        == _        = False

PlutusTx.unstableMakeIsData ''GameChoice

data GameDatum = GameDatum ByteString (Maybe GameChoice) | Finished
    deriving Show

instance Eq GameDatum where
    {-# INLINABLE (==) #-}
    GameDatum bs mc == GameDatum bs' mc' = (bs == bs') && (mc == mc')
    Finished        == Finished          = True
    _               == _                 = False

PlutusTx.unstableMakeIsData ''GameDatum

data GameRedeemer = Play GameChoice | Reveal ByteString | ClaimFirst | ClaimSecond | ClaimDraw
    deriving Show

PlutusTx.unstableMakeIsData ''GameRedeemer

{-# INLINABLE lovelaces #-}
lovelaces :: Value -> Integer
lovelaces = Ada.getLovelace . Ada.fromValue

{-# INLINABLE gameDatum #-}
gameDatum :: TxOut -> (DatumHash -> Maybe Datum) -> Maybe GameDatum
gameDatum o f = do
    dh      <- txOutDatum o
    Datum d <- f dh
    PlutusTx.fromData d

{-# INLINABLE transition #-}
transition :: ByteString -> ByteString -> ByteString -> Game -> State GameDatum -> GameRedeemer -> Maybe (TxConstraints Void Void, State GameDatum)
transition bsRock' bsPaper' bsScissors' game s r = case (stateValue s, stateData s, r) of
    (v, GameDatum bs Nothing, Play c)
        | lovelaces v == gStake game                                                                    -> Just ( Constraints.mustBeSignedBy (gSecond game)                    <>
                                                                                                                  Constraints.mustValidateIn (to $ gPlayDeadline game)
                                                                                                                , State (GameDatum bs $ Just c) (lovelaceValueOf $ 2 * gStake game)
                                                                                                                )
    (v, GameDatum bs (Just c), Reveal nonce)
        | lovelaces v == (2 * gStake game) && outcome bsRock' bsPaper' bsScissors' nonce bs c == FirstWins -> Just ( Constraints.mustBeSignedBy (gFirst game)                     <>
                                                                                                             Constraints.mustValidateIn (to $ gRevealDeadline game)       <>
                                                                                                             Constraints.mustPayToPubKey (gFirst game) token
                                                                                                           , State Finished mempty
                                                                                                           )
        | lovelaces v == (2 * gStake game) && outcome bsRock' bsPaper' bsScissors' nonce bs c == Draw      -> Just ( Constraints.mustBeSignedBy (gFirst game)                     <>
                                                                                                             Constraints.mustValidateIn (to $ gRevealDeadline game)       <>
                                                                                                             Constraints.mustPayToPubKey (gFirst game) token <>
                                                                                                             Constraints.mustPayToPubKey (gSecond game) (lovelaceValueOf $ gStake game)
                                                                                                           , State Finished mempty
                                                                                                           )
    (v, GameDatum _ Nothing, ClaimFirst)
        | lovelaces v == gStake game                                                                    -> Just ( Constraints.mustBeSignedBy (gFirst game)                     <>
                                                                                                                  Constraints.mustValidateIn (from $ 1 + gPlayDeadline game)   <>
                                                                                                                  Constraints.mustPayToPubKey (gFirst game) token
                                                                                                                , State Finished mempty
                                                                                                                )
    (v, GameDatum _ (Just _), ClaimSecond)
        | lovelaces v == (2 * gStake game)                                                              -> Just ( Constraints.mustBeSignedBy (gSecond game)                    <>
                                                                                                                  Constraints.mustValidateIn (from $ 1 + gRevealDeadline game) <>
                                                                                                                  Constraints.mustPayToPubKey (gFirst game) token
                                                                                                                , State Finished mempty
                                                                                                                )
    _                                                                                                   -> Nothing
  where
    token :: Value
    token = assetClassValue (gToken game) 1

{-# INLINABLE final #-}
final :: GameDatum -> Bool
final Finished = True
final _        = False


data Outcome = FirstWins | SecondWins | Draw

instance Eq Outcome where
  {-# INLINABLE (==) #-}
  FirstWins  == FirstWins  = True
  SecondWins == SecondWins = True
  Draw       == Draw       = True
  _          == _          = False
  
{-# INLINABLE outcome #-}
outcome :: ByteString -> ByteString -> ByteString -> ByteString -> ByteString -> GameChoice -> Outcome
outcome _       _        bsScissors' nonce bs c | sha2_256 (nonce `concatenate` bsScissors') == bs = outcome' Scissors c
outcome bsRock' _        _           nonce bs c | sha2_256 (nonce `concatenate` bsRock'    ) == bs = outcome' Rock     c
outcome _       bsPaper' _           nonce bs c | sha2_256 (nonce `concatenate` bsPaper'   ) == bs = outcome' Paper    c
outcome _       _        _           _     _  _                                                    = Draw

{-# INLINABLE outcome' #-}
outcome' :: GameChoice -> GameChoice -> Outcome
outcome' Rock     Scissors = FirstWins
outcome' Paper    Rock     = FirstWins
outcome' Scissors Paper    = FirstWins
outcome' Rock     Paper    = SecondWins
outcome' Paper    Scissors = SecondWins
outcome' Scissors Rock     = SecondWins
outcome' _        _        = Draw

{-# INLINABLE check #-}
check :: ByteString -> ByteString -> ByteString -> GameDatum -> GameRedeemer -> ScriptContext -> Bool
check bsRock' bsPaper' bsScissors' (GameDatum bs (Just _)) (Reveal nonce) _ = bs `elem` map (sha2_256 . concatenate nonce) [bsRock', bsPaper', bsScissors']
check _       _        _           _                       _              _ = True


{-# INLINABLE gameStateMachine #-}
gameStateMachine :: Game -> ByteString -> ByteString -> ByteString -> StateMachine GameDatum GameRedeemer
gameStateMachine game bsRock' bsPaper' bsScissors' = StateMachine
    { smTransition  = transition bsRock' bsPaper' bsScissors' game
    , smFinal       = final
    , smCheck       = check bsRock' bsPaper' bsScissors'
    , smThreadToken = Just $ gToken game
    }

{-# INLINABLE mkGameValidator #-}
mkGameValidator :: Game -> ByteString -> ByteString -> ByteString -> GameDatum -> GameRedeemer -> ScriptContext -> Bool
mkGameValidator game bsRock' bsPaper' bsScissors' = mkValidator $ gameStateMachine game bsRock' bsPaper' bsScissors'

type Gaming = StateMachine GameDatum GameRedeemer

bsRock, bsPaper, bsScissors :: ByteString
bsRock     = "Rock"
bsPaper    = "Paper"
bsScissors = "Scissors"

{-# INLINABLE fromGameChoice #-}
fromGameChoice :: ByteString -> ByteString -> ByteString -> GameChoice -> ByteString
fromGameChoice bsRock' _        _           Rock     = bsRock'
fromGameChoice _       bsPaper' _           Paper    = bsPaper'
fromGameChoice _       _        bsScissors' Scissors = bsScissors'

gameStateMachine' :: Game -> StateMachine GameDatum GameRedeemer
gameStateMachine' game = gameStateMachine game bsRock bsPaper bsScissors

gameInst :: Game -> Scripts.ScriptInstance Gaming
gameInst game = Scripts.validator @Gaming
    ($$(PlutusTx.compile [|| mkGameValidator ||])
        `PlutusTx.applyCode` PlutusTx.liftCode game
        `PlutusTx.applyCode` PlutusTx.liftCode bsRock
        `PlutusTx.applyCode` PlutusTx.liftCode bsPaper
        `PlutusTx.applyCode` PlutusTx.liftCode bsScissors)
    $$(PlutusTx.compile [|| wrap ||])
  where
    wrap = Scripts.wrapValidator @GameDatum @GameRedeemer

gameValidator :: Game -> Validator
gameValidator = Scripts.validatorScript . gameInst

gameAddress :: Game -> Ledger.Address
gameAddress = scriptAddress . gameValidator

gameClient :: Game -> StateMachineClient GameDatum GameRedeemer
gameClient game = mkStateMachineClient $ StateMachineInstance (gameStateMachine' game) (gameInst game)

data FirstParams = FirstParams
    { fpSecond         :: !PubKeyHash
    , fpStake          :: !Integer
    , fpPlayDeadline   :: !Slot
    , fpRevealDeadline :: !Slot
    , fpNonce          :: !ByteString
    , fpCurrency       :: !CurrencySymbol
    , fpTokenName      :: !TokenName
    , fpChoice         :: !GameChoice
    } deriving (Show, Generic, FromJSON, ToJSON, ToSchema)

mapError' :: Contract w s SMContractError a -> Contract w s Text a
mapError' = mapError $ pack . show

firstGame :: forall w s. HasBlockchainActions s => FirstParams -> Contract w s Text ()
firstGame fp = do
    pkh <- pubKeyHash <$> Contract.ownPubKey
    let game   = Game
            { gFirst          = pkh
            , gSecond         = fpSecond fp
            , gStake          = fpStake fp
            , gPlayDeadline   = fpPlayDeadline fp
            , gRevealDeadline = fpRevealDeadline fp
            , gToken          = AssetClass (fpCurrency fp, fpTokenName fp)
            }
        client = gameClient game
        v      = lovelaceValueOf (fpStake fp)
        c      = fpChoice fp
        bs     = sha2_256 $ fpNonce fp `concatenate` fromGameChoice bsRock bsPaper bsScissors c
    void $ mapError' $ runInitialise client (GameDatum bs Nothing) v
    logInfo @String $ "made first move: " ++ show (fpChoice fp)

    void $ awaitSlot $ 1 + fpPlayDeadline fp

    m <- mapError' $ getOnChainState client
    case m of
        Nothing             -> throwError "game output not found"
        Just ((o, _), _) -> case tyTxOutData o of
            GameDatum _ Nothing -> do
                                     logInfo @String "second player did not play"
                                     void $ mapError' $ runStep client ClaimFirst
                                     logInfo @String "first player reclaimed stake"
            GameDatum _ (Just c') -> case outcome' c c' of
                                       FirstWins -> do
                                                      logInfo @String "second player played and lost"
                                                      void $ mapError' $ runStep client $ Reveal $ fpNonce fp
                                                      logInfo @String "first player revealed and won"
                                       Draw      -> do
                                                      logInfo @String "second player played and drew"
                                                      void $ mapError' $ runStep client $ Reveal $ fpNonce fp
                                                      logInfo @String "first player revealed and drew"
                                       SecondWins -> logInfo @String "second player played and won"
            Finished              -> logInfo @String "game finished prematurely"

data SecondParams = SecondParams
    { spFirst          :: !PubKeyHash
    , spStake          :: !Integer
    , spPlayDeadline   :: !Slot
    , spRevealDeadline :: !Slot
    , spCurrency       :: !CurrencySymbol
    , spTokenName      :: !TokenName
    , spChoice         :: !GameChoice
    } deriving (Show, Generic, FromJSON, ToJSON, ToSchema)

secondGame :: forall w s. HasBlockchainActions s => SecondParams -> Contract w s Text ()
secondGame sp = do
    pkh <- pubKeyHash <$> Contract.ownPubKey
    let game   = Game
            { gFirst          = spFirst sp
            , gSecond         = pkh
            , gStake          = spStake sp
            , gPlayDeadline   = spPlayDeadline sp
            , gRevealDeadline = spRevealDeadline sp
            , gToken          = AssetClass (spCurrency sp, spTokenName sp)
            }
        client = gameClient game
    m <- mapError' $ getOnChainState client
    case m of
        Nothing          -> logInfo @String "no running game found"
        Just ((o, _), _) -> case tyTxOutData o of
            GameDatum _ Nothing -> do
                logInfo @String "running game found"
                void $ mapError' $ runStep client $ Play $ spChoice sp
                logInfo @String $ "made second move: " ++ show (spChoice sp)

                void $ awaitSlot $ 1 + spRevealDeadline sp

                m' <- mapError' $ getOnChainState client
                case m' of
                    Nothing -> logInfo @String "second player didn't win"
                    Just _  -> do
                        logInfo @String "first player didn't reveal"
                        void $ mapError' $ runStep client ClaimSecond
                        logInfo @String "first player didn't win"

            _ -> throwError "unexpected datum"

type GameSchema = BlockchainActions .\/ Endpoint "first" FirstParams .\/ Endpoint "second" SecondParams

endpoints :: Contract () GameSchema Text ()
endpoints = (first `select` second) >> endpoints
  where
    first  = endpoint @"first"  >>= firstGame
    second = endpoint @"second" >>= secondGame
