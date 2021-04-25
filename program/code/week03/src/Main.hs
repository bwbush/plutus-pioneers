
{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE TypeApplications #-}


module Main (
  main
) where


import Data.Text (Text)
import Control.Monad (void)
import           Ledger                  (pubKeyHash)
import qualified Ledger.Ada              as Ada
import qualified Ledger.Typed.Scripts    as Scripts
import           Plutus.Contract
import           Plutus.Contract.Test

import qualified Plutus.Trace.Emulator   as Trace

import Week03.Vesting


main :: IO ()
main = Trace.runEmulatorTraceIO test


w1 :: Wallet
w1 = Wallet 1


test :: Trace.EmulatorTrace ()
test =
  do
    let
      gp = GiveParams
        {
          gpBeneficiary = pubKeyHash $ walletPubKey w1
        , gpDeadline    = 10
        , gpAmount      = 1000
        }
      con = give gp :: Contract () VestingSchema Text ()
    hdl1 <- Trace.activateContractWallet w1 con
    Trace.callEndpoint @"give" hdl1 gp
    void $ Trace.waitNSlots 1
