{
  system ? builtins.currentSystem
, config ? { allowUnfreePredicate = (import ./plutus/nix/unfree.nix).unfreePredicate; }
, packages ? import ./plutus { inherit system config ; }
}:

let

  inherit (packages) pkgs;

  ghc = packages.plutus.haskell.project.ghcWithHoogle (ps: with ps; [

    marlowe-playground-server
    plutus-playground-server

    plutus-benchmark
    plutus-contract
    plutus-core
    plutus-errors
    plutus-ledger
    plutus-ledger-api
    plutus-metatheory
    plutus-pab
    plutus-tx
    plutus-tx-plugin
    plutus-use-cases

  ]);

in

  pkgs.stdenv.mkDerivation {
    name = "plutus-env";
    buildInputs = [
      pkgs.cabal-install
      ghc
    ];
  }
