{
  description = ''
    cataclysm.nix: Nix packaging for the Cataclysm family of game
    forks. Each fork gets its own self-contained directory under this
    flake, contributing its own packages, checks, and pin tooling to a
    shared nixpkgs/flake-parts base.
  '';

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    # Fork sources, one input per game (or game track). Each fork
    # directory consumes its own input and owns how it gets bumped:
    #
    #   cdda/  CleverRaven/Cataclysm-DDA, the upstream they all fork
    #          from. Two tracks:
    #
    #            cataclysm-dda         stable, pinned to the 0.I-1
    #                                   release tag (immutable, so nix
    #                                   flake update leaves it alone;
    #                                   bump by editing the ref)
    #            cataclysm-dda-master  0.J development, follows the
    #                                   master branch, so nix flake
    #                                   update moves it like any other
    #                                   input
    #
    #   tlg/   Cataclysm-TLG/Cataclysm-TLG, an independent fork with
    #          its own release cadence, pinned to a dated tag for the
    #          same reason.
    #
    #   cbn/   cataclysmbn/Cataclysm-BN, a third fork with the same
    #          no-AI policy. Two tracks for the same reason as CDDA's:
    #
    #            cataclysm-bn         stable, pinned to the v0.13.0
    #                                 release tag
    #            cataclysm-bn-master  development, follows the master
    #                                 branch, so nix flake update moves
    #                                 it
    cataclysm-dda = {
      url = "github:CleverRaven/Cataclysm-DDA/0.I-1";
      flake = false;
    };
    cataclysm-dda-master = {
      url = "github:CleverRaven/Cataclysm-DDA";
      flake = false;
    };
    cataclysm-tlg = {
      url = "github:Cataclysm-TLG/Cataclysm-TLG/cataclysm-tlg-1.0-2026-10-16-0752";
      flake = false;
    };
    cataclysm-bn = {
      url = "github:cataclysmbn/Cataclysm-BN/v0.13.0";
      flake = false;
    };
    cataclysm-bn-master = {
      url = "github:cataclysmbn/Cataclysm-BN";
      flake = false;
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # One directory per game fork. Each default.nix contributes its
      # packages (no name collisions by convention), checks, dev
      # shells, and updater apps.
      imports = [
        ./cdda
        ./tlg
        ./cbn
      ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    };
}
