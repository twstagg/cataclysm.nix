# Cataclysm: Bright Nights chunk of the flake: BN packaging as a
# self-contained directory. Sibling of ../cdda and ../ctlg; the root
# flake.nix only declares inputs and systems. See ./README.md for the
# tour.
#
# Two tracks, packaged side by side rather than behind a switch, so a
# stable install and a bleeding-edge install coexist in one store:
#
#   stable  the v0.13.0 release tag (banner prefix read from the tag in
#           flake.lock), pinned by tag so nix flake update leaves it
#           alone; bump by editing the ref.
#   master  the development branch, so nix flake update moves it.
#
# Unlike CDDA there is no era split to encode: both tracks are SDL3, and
# gfx/ ships pre-composed in-tree, so a track differs only by its pin.
# Registry content (data/mods/external.json) is identical on both tracks
# today and bundled once, shared by both; the updater fails loudly if the
# two lockfiles ever diverge.
{
  lib,
  inputs,
  self,
  lockHelpers,
  ...
}:
{
  perSystem =
    {
      pkgs,
      ...
    }:
    let
      inherit (pkgs) lib;

      # The docs build needs clang >= 22; the default gcc stdenv is not
      # it. Both tracks share it.
      clangStdenv = pkgs.llvmPackages_22.stdenv;

      # Keep only what the CMake build reads. docs/, .git and .github/
      # are dead weight, and dropping them means a docs-only upstream
      # commit leaves this path unchanged, so nothing rebuilds. A filter
      # (rather than an explicit allowlist) so a new upstream directory
      # is never silently missing from the build.
      gameSource =
        input:
        pkgs.lib.cleanSourceWith {
          src = input;
          name = "cataclysm-bn-${input.shortRev or "source"}";
          filter =
            path: type:
            let
              base = baseNameOf (toString path);
            in
            !(base == "docs" || base == ".git" || base == ".github");
        };

      # Banner prefix from the ref we asked for, read out of the root
      # flake.lock so nothing is hardcoded here: a tag pin yields its tag
      # (minus a leading v), a branch pin falls back to a label. Bumping
      # the tag in flake.nix is the only edit a new release needs. The
      # helper now lives in the root flake and is shared by all chunks.
      bannerPrefix = lockHelpers.bannerPrefix;

      # Registry bundle: external mods + the Otopack soundpack, from the
      # lockfile in the pinned game source and the vendored snapshot in
      # ./registry-mods.json. Built from the stable track and shared,
      # because both tracks lock the same nine entries (the updater
      # enforces that).
      #
      # The lockfile is read from the raw input, not from the filtered
      # source: registry-mods.nix parses it at eval time, and a
      # cleanSourceWith path does not exist until it is built.
      stableSrc = gameSource inputs.cataclysm-bn;
      masterSrc = gameSource inputs.cataclysm-bn-master;
      registryMods = pkgs.callPackage ./registry-mods.nix { src = inputs.cataclysm-bn; };

      mkTrack =
        {
          input,
          src,
          prefix,
        }:
        let
          version = "${prefix}+${input.shortRev or "git"}";
          mk =
            extra:
            pkgs.callPackage ./package.nix (
              extra
              // {
                inherit version src registryMods;
                stdenv = clangStdenv;
                rev = input.rev or "unknown";
                commitTime = input.lastModified;
              }
            );
          # One cmake run builds the game and the Catch2 binary, so the
          # test output costs no extra compile.
          tiles = mk {
            tiles = true;
            sound = true;
            buildTests = true;
          };
        in
        {
          inherit tiles;
          curses = mk {
            tiles = false;
            sound = false;
          };
          cata-test = tiles.test;
        };

      stable = mkTrack {
        input = inputs.cataclysm-bn;
        src = stableSrc;
        prefix = bannerPrefix "cataclysm-bn" "stable";
      };

      master = mkTrack {
        input = inputs.cataclysm-bn-master;
        src = masterSrc;
        prefix = bannerPrefix "cataclysm-bn-master" "master";
      };
    in
    {
      packages = {
        # bn-prefixed so all three chunks coexist in one namespace (see
        # cdda/* and ctlg/*), and no default: always name what you want.
        #
        # Unprefixed = the v0.13.0 tag track; -master- = development.
        cbn-tiles = stable.tiles;
        cbn-curses = stable.curses;
        cbn-cata-test = stable.cata-test;
        cbn-master-tiles = master.tiles;
        cbn-master-curses = master.curses;
        cbn-master-cata-test = master.cata-test;
        # The registry bundle on its own: external mods under mods/ and
        # the Otopack pack under sound/, with credits.
        cbn-registry-mods = registryMods;
      };

      checks = {
        # Smoke test: the calendar suite through the Catch2 binary. The
        # test output starts with an empty base path, so its resource
        # dirs resolve relative to cwd (./data, ./gfx, ./lang/mo). Logs
        # and saves go to cwd and non-[nogame] tests boot a full game
        # state, hence the temp dir. Data comes from the game output,
        # which is the data dir itself under USE_PREFIX_DATA_DIR.
        cbn-calendar-test = pkgs.runCommand "cbn-calendar-test" { } ''
          cd "$(mktemp -d)"
          root="${stable.tiles}/share/cataclysm-bn"
          ln -s "$root" data
          ln -s "$root/gfx" gfx
          mkdir -p lang
          if [ -d "${stable.tiles}/share/locale" ]; then
            ln -s "${stable.tiles}/share/locale" lang/mo
          fi
          export HOME="$PWD"
          export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy
          # No GPU in the sandbox, not even software Vulkan.
          export CATA_TEST_COMPUTE_ACCELERATION=cpu
          ${stable.cata-test}/bin/cata_test-tiles "[calendar]"
          touch $out
        '';

        # Content gate: --check-mods validates the game data plus the
        # bundled registry mods, the same pass release CI runs.
        cbn-check-mods = pkgs.runCommand "cbn-check-mods" { } ''
          cd "$(mktemp -d)"
          export HOME="$PWD"
          export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy
          ${stable.tiles}/bin/cataclysm-bn-tiles --check-mods
          touch $out
        '';

        # Every bundled soundpack must carry its manifest (same gate
        # idea as the CDDA soundpacks-validate check: catches an empty
        # or misrouted extraction before it reaches the game).
        cbn-soundpacks-validate = pkgs.runCommand "cbn-soundpacks-validate" { } ''
          for d in ${registryMods}/sound/*/; do
            [ -e "$d" ] || continue
            test -f "$d/soundpack.txt" || test -f "$d/soundpack.json" \
              || (echo "no soundpack manifest in $d" >&2; exit 1)
            echo "ok: $(basename "$d")"
          done
          touch $out
        '';

        # Unit tests for the registry updater with mocked curl/nix. No
        # network, no builds.
        cbn-updater-tests =
          pkgs.runCommand "cbn-updater-tests"
            {
              nativeBuildInputs = with pkgs; [
                bash
                coreutils
                curl
                gawk
                gnugrep
                jq
              ];
            }
            ''
              bash ${self + /cbn/scripts/test-update-registry-mods.sh} ${
                self + /cbn/scripts/update-registry-mods.sh
              }
              touch $out
            '';
      };

      # One dev shell per game, no default. This one carries the CMake
      # toolchain the chunk's builders use; the game shells carry their
      # runtime bits instead.
      devShells.cbn = pkgs.mkShell {
        packages = with pkgs; [
          bzip2
          cmake
          freetype
          gettext
          git
          libbacktrace
          libvorbis
          ncurses
          ninja
          nixfmt
          pkg-config
          # shadercross on PATH so a local build can use
          # -DBUILD_SHADERCROSS=OFF like the flake does.
          sdl3-shadercross
          sdl3
          sdl3-image
          sdl3-mixer
          sdl3-ttf
          sqlite
          zlib
        ];

        shellHook = ''
          echo 'cataclysm.nix CBN shell. Try: nix build .#cbn-tiles' 1>&2
        '';
      };

      apps.cbn-update-registry-mods =
        let
          updater = pkgs.writeShellApplication {
            name = "cbn-update-registry-mods";
            runtimeInputs = with pkgs; [
              coreutils
              curl
              gawk
              gnugrep
              jq
              nix
            ];
            # The lockfile lives in the pinned game source, not in this
            # repo, so the path is baked in at eval time. Raw inputs,
            # not the filtered sources: an input's store path always
            # exists after evaluation, while the filtered one is a
            # derivation nothing realizes on the app's behalf. Both
            # tracks are passed: the script fails loudly if their
            # lockfiles ever diverge, rather than silently bundling one
            # track's content under the other's.
            text = ''
              LOCK_FILE=${inputs.cataclysm-bn}/data/mods/external.json
              MASTER_LOCK_FILE=${inputs.cataclysm-bn-master}/data/mods/external.json
            ''
            + builtins.readFile ./scripts/update-registry-mods.sh;
          };
        in
        {
          type = "app";
          program = lib.getExe updater;
          meta.description = "Refresh the cbn registry pins and vendored snapshot";
        };
    };
}
