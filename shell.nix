{
  system ? builtins.currentSystem
, config ? { allowUnfreePredicate = (import ./plutus/nix/unfree.nix).unfreePredicate; }
, packages ? import ./plutus { inherit system config ; }
}:

let

  inherit (packages) pkgs;

  ghc = packages.plutus.haskell.project.ghcWithPackages (ps: with ps; [
    marlowe-playground-server
    plutus-playground-server
  ]);

in

  pkgs.stdenv.mkDerivation {
    name = "plutus-env";
    buildInputs = [
      pkgs.cabal-install
      ghc
    ];
  }
