# CDDA chunk of the flake: Cataclysm: Dark Days Ahead packaging as a
# self-contained directory. Sibling of ../tlg; the root flake.nix only
# declares inputs and systems. See ./README.md for the tour.
{
  inputs,
  self,
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

      # Two upstream tracks, packaged side by side rather than behind a
      # switch, so a stable install and a bleeding-edge install coexist
      # in one store:
      #
      #   stable  0.I release tag (SDL2 era, in-tree pre-composed
      #           tilesets, Basic soundpack). Pinned by tag in the root
      #           flake, so nix flake update leaves it alone.
      #   master  0.J development (SDL3-only since 2026-08-11, art
      #           decoupled upstream and composed here, test soundpack).
      #           Tracks the master branch; nix flake update moves it.
      #
      # Both tracks share the tileset matrix and the soundpack pin; the
      # era only decides SDL generation, the version banner, and whether
      # composed tilesets are merged into the bundle (on stable they
      # already ship in-tree, and merging would duplicate tileset NAMEs).
      mkEra =
        {
          src,
          shortRev,
          versionPrefix,
          useSdl3,
          bundleTilesets,
        }:
        let
          # VERSION banner; fetched sources have no .git, so the
          # Makefile would fall back to its bare per-era default.
          version = "${versionPrefix}+${if shortRev == null then "git" else shortRev}";
          mk = extra: pkgs.callPackage ./package.nix (extra // { inherit src version useSdl3; });
          # Sound builds carry CC-Sounds, mirroring release.yml (which
          # drops it into data/sound for every sound-enabled build).
          # Overridable per package; curses and cata-test stay lean.
          tiles = mk {
            tiles = true;
            sound = true;
            extraSoundpacks = [ soundpackPacks.cdda-soundpack-cc-sounds ];
          };
        in
        {
          inherit src version;
          tiles = tiles;
          curses = mk {
            tiles = false;
            sound = false;
          };
          # Test binary with tiles + sound, same flags upstream CI uses.
          # Keeps the tileset and soundpack lists non-empty so game-state
          # init works inside tests.
          cata-test = mk {
            tiles = true;
            sound = true;
            buildTests = true;
          };
          # Release-bundle equivalent: the game with every composed set
          # baked into share/cataclysm-dda/gfx. Empty list on stable by
          # design.
          tiles-full = tiles.override {
            extraTilesets = lib.optionals bundleTilesets (builtins.attrValues tilesets);
          };
        };

      stable = mkEra {
        src = inputs.cataclysm-dda.outPath;
        shortRev = inputs.cataclysm-dda.shortRev;
        versionPrefix = "0.I-1";
        useSdl3 = false;
        bundleTilesets = false;
      };

      master = mkEra {
        src = inputs.cataclysm-dda-master.outPath;
        shortRev = inputs.cataclysm-dda-master.shortRev;
        versionPrefix = "0.J";
        useSdl3 = true;
        bundleTilesets = true;
      };

      # json_formatter.cgi, built with the same make target the
      # tileset workflow uses. compose.py looks it up relative to CWD
      # (tools/format/json_formatter.cgi), so the tileset builder drops
      # it under its work root.
      #
      # Built from the stable track: the composed sets are a single
      # attrset shared by both eras (same pinned tileset sources, same
      # compose CLI), and the stable tree is the one whose cata_test
      # validates them. Only master bundles them.
      jsonFormatter = pkgs.stdenv.mkDerivation {
        pname = "cdda-json-formatter";
        version = stable.version;
        src = stable.src;
        # The Makefile's global LDFLAGS drag -lncursesw -lz into this
        # link, so those go on buildInputs and the make target runs as-is.
        buildInputs = with pkgs; [
          ncurses
          zlib
        ];
        buildPhase = ''
          runHook preBuild
          make tools/format/json_formatter.cgi -j$NIX_BUILD_CORES
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          install -Dm755 tools/format/json_formatter.cgi $out/bin/json_formatter.cgi
          runHook postInstall
        '';
        enableParallelBuilding = true;
        meta = {
          description = "CDDA canonical JSON formatter (tileset compose step)";
          license = lib.licenses.cc-by-sa-30;
          platforms = lib.platforms.unix;
        };
      };

      composePy = stable.src + "/tools/gfx_tools/compose.py";

      # Sparse checkouts of just the gfx/<set> dirs, same as the
      # workflow's sparse-checkout of "gfx".
      #
      # Pins live in attrsets so derivation versions derive from the rev:
      # a hand-written short rev goes stale the moment an updater moves
      # the pin, and the store path then misnames its own contents.
      tilesetsPin = {
        owner = "I-am-Erk";
        repo = "CDDA-Tilesets";
        rev = "dfd8d69f388e6b9c2719b250845e51d8d30eb2cb";
        sha256 = "sha256-lx0q3CZTpfPr+LiQeIBtZahQJifpCjxN7AnVQn2EeZU=";
        sparseCheckout = [
          "gfx/Altica"
          "gfx/ASCII_Overmap"
          "gfx/BrownLikeBears"
          "gfx/Chibi_Ultica"
          "gfx/GiantDays"
          "gfx/HitButton_iso"
          "gfx/HollowMoon"
          # TODO: re-enable once upstream draws the missing sprites
          # (see NOTE at the commented-out matrix entry below).
          # "gfx/IsoMSX+"
          "gfx/Larwick_Overmap"
          "gfx/MShockXotto+"
          "gfx/MShockXotto+_Portraits"
          # TODO: re-enable with the matrix entry below once upstream
          # ships the file (see NOTE there).
          # "gfx/Mushroom-Dream"
          "gfx/NeoDays"
          "gfx/PenAndPaper"
          "gfx/Retrodays"
          "gfx/SurveyorsMap"
          "gfx/Ultica_iso"
          "gfx/UltimateCataclysm"
        ];
      };
      tilesetsSrc = pkgs.fetchFromGitHub tilesetsPin;
      tilesetsVersion = builtins.substring 0 7 tilesetsPin.rev;

      cuteclysmPin = {
        owner = "pixel-32";
        repo = "CDDA-tileset";
        rev = "3f06254658f48f3c01e5a29994c971f2a6e5fc8a";
        sha256 = "sha256-ZAZ3uAuav2H7CTI6CLHnnQIFMxNHQJV9HpgUcFhp5bc=";
      };
      cuteclysmSrc = pkgs.fetchFromGitHub cuteclysmPin;
      cuteclysmVersion = builtins.substring 0 7 cuteclysmPin.rev;

      # CC-Sounds: the community soundpack release CI bundles into
      # data/sound for sound-enabled builds (release.yml "Get
      # soundpack"). Full clone with submodules: music/ arrives via
      # the CDDA-Music-Packs submodule, same as the workflow's
      # --recurse-submodules. Pin + hash bump with
      # nix run .#cdda-update-soundpacks (never by hand).
      soundpacksPin = {
        owner = "Fris0uman";
        repo = "CDDA-Soundpacks";
        rev = "02b65460a808624b500013d4b9aa71dccd968817";
        sha256 = "sha256-S5aZjQYG2LHnC2lJcVkcNn4p3CA/iAed99w250K/Wp4=";
        fetchSubmodules = true;
      };
      soundpacksSrc = pkgs.fetchFromGitHub soundpacksPin;
      soundpacksVersion = builtins.substring 0 7 soundpacksPin.rev;

      soundpackPacks = {
        cdda-soundpack-cc-sounds = pkgs.callPackage ./soundpack.nix {
          name = "CC-Sounds";
          src = soundpacksSrc;
          sourceDir = "sound/CC-Sounds";
          installName = "CC-Sounds";
          version = soundpacksVersion;
        };
      };

      # Per-set table copied from .github/workflows/compose-tilesets.yml:
      # --use-all everywhere; --obsolete-fillers on Altica,
      # BrownLikeBears, HollowMoon and UltimateCataclysm. The result
      # is exactly the 17-set release matrix: IsoMSX+ and
      # Mushroom-Dream stay commented out with NOTEs (broken and
      # unloadable at the pinned rev, respectively).
      tilesetMatrix = [
        {
          attr = "cdda-tileset-altica";
          name = "Altica";
          dir = "gfx/Altica";
          args = [
            "--use-all"
            "--obsolete-fillers"
          ];
        }
        {
          attr = "cdda-tileset-ascii-overmap";
          name = "ASCII_Overmap";
          dir = "gfx/ASCII_Overmap";
          args = [ "--use-all" ];
        }
        {
          attr = "cdda-tileset-brownlikebears";
          name = "BrownLikeBears";
          dir = "gfx/BrownLikeBears";
          args = [
            "--use-all"
            "--obsolete-fillers"
          ];
        }
        {
          attr = "cdda-tileset-chibi-ultica";
          name = "Chibi_Ultica";
          dir = "gfx/Chibi_Ultica";
          args = [ "--use-all" ];
        }
        {
          attr = "cdda-tileset-hollowmoon";
          name = "HollowMoon";
          dir = "gfx/HollowMoon";
          args = [
            "--use-all"
            "--obsolete-fillers"
          ];
        }
        {
          attr = "cdda-tileset-larwick-overmap";
          name = "Larwick_Overmap";
          dir = "gfx/Larwick_Overmap";
          args = [ "--use-all" ];
        }
        {
          attr = "cdda-tileset-mshockxotto-plus";
          name = "MShockXotto+";
          dir = "gfx/MShockXotto+";
          args = [ "--use-all" ];
        }
        {
          attr = "cdda-tileset-mshockxotto-plus-portraits";
          name = "MShockXotto+_Portraits";
          dir = "gfx/MShockXotto+_Portraits";
          args = [ "--use-all" ];
        }
        {
          attr = "cdda-tileset-neodays";
          name = "NeoDays";
          dir = "gfx/NeoDays";
          args = [ "--use-all" ];
        }
        {
          attr = "cdda-tileset-retrodays";
          name = "Retrodays";
          dir = "gfx/Retrodays";
          args = [ "--use-all" ];
        }
        {
          attr = "cdda-tileset-giantdays";
          name = "GiantDays";
          dir = "gfx/GiantDays";
          args = [ "--use-all" ];
        }
        {
          attr = "cdda-tileset-smashbutton-iso";
          name = "SmashButton_iso";
          dir = "gfx/HitButton_iso";
          args = [ "--use-all" ];
        }
        {
          attr = "cdda-tileset-surveyorsmap";
          name = "SurveyorsMap";
          dir = "gfx/SurveyorsMap";
          args = [ "--use-all" ];
        }
        {
          attr = "cdda-tileset-ultimatecataclysm";
          name = "UltimateCataclysm";
          dir = "gfx/UltimateCataclysm";
          args = [
            "--use-all"
            "--obsolete-fillers"
          ];
        }
        {
          attr = "cdda-tileset-ultica-iso";
          name = "Ultica_iso";
          dir = "gfx/Ultica_iso";
          args = [ "--use-all" ];
        }
        {
          attr = "cdda-tileset-penandpaper";
          name = "PenAndPaper";
          dir = "gfx/PenAndPaper";
          args = [ "--use-all" ];
        }
        # NOTE: IsoMSX+ commented out. At the pinned rev its JSON
        # references seasonal sprites that were never drawn
        # (t_grass_summer/autumn, ...), so compose.py exits 1 on
        # missing-sprite errors and upstream releases can't carry it
        # either. Filed upstream as
        # https://github.com/I-am-Erk/CDDA-Tilesets/issues/2938.
        # Re-enable the entry + sparse path above once fixed.
        # {
        #   attr = "cdda-tileset-isomsx-plus";
        #   name = "IsoMSX+";
        #   dir = "gfx/IsoMSX+";
        #   args = [ "--use-all" ];
        # }
        # NOTE: Mushroom-Dream stays commented out. It composes fine
        # but ships no fallback.png, and the loader opens every
        # tiles-new file under an assert, so picking it breaks loading.
        # Confirmed in-game (debug error "Could not load image ...
        # fallback.png" from main_menu opening_screen). The stock
        # fallback sheet does not fit (16px cells on a 32x32 set).
        # TODO: upstream issue filed as
        # https://github.com/I-am-Erk/CDDA-Tilesets/issues/2939.
        # Re-enable the entry + sparse path above once fixed.
        # {
        #   attr = "cdda-tileset-mushroom-dream";
        #   name = "Mushroom-Dream";
        #   dir = "gfx/Mushroom-Dream";
        #   args = [ "--use-all" ];
        # }
        {
          attr = "cdda-tileset-cuteclysm";
          name = "Cuteclysm";
          dir = ".";
          args = [ "--use-all" ];
          src = cuteclysmSrc;
          tilesVersion = cuteclysmVersion;
        }
      ];

      mkTileset =
        {
          attr,
          name,
          dir,
          args,
          src ? tilesetsSrc,
          tilesVersion ? tilesetsVersion,
        }:
        pkgs.callPackage ./tileset.nix {
          inherit
            name
            src
            composePy
            jsonFormatter
            ;
          sourceDir = dir;
          composeArgs = args;
          installName = name;
          version = tilesVersion;
        };

      tilesets = lib.listToAttrs (
        map (entry: lib.nameValuePair entry.attr (mkTileset entry)) tilesetMatrix
      );
    in
    {
      packages = {
        # Every attr is cdda-prefixed so both forks' outputs coexist in
        # one namespace (tlg/* mirrors this), and there is no default:
        # always name what you want, e.g. `nix build .#cdda-tiles`.
        #
        # Unprefixed = the stable 0.I tag track; -master- = the 0.J dev
        # track that follows upstream master.
        cdda-tiles = stable.tiles;
        cdda-curses = stable.curses;
        cdda-cata-test = stable.cata-test;
        cdda-tiles-full = stable.tiles-full;
        cdda-master-tiles = master.tiles;
        cdda-master-curses = master.curses;
        cdda-master-cata-test = master.cata-test;
        cdda-master-tiles-full = master.tiles-full;
        cdda-json-formatter = jsonFormatter;
      }
      // tilesets
      // soundpackPacks;

      devShells.default = pkgs.mkShell {
        packages = with pkgs; [
          git
          nixfmt
          python3Packages.pyvips
          vips
        ];

        shellHook = ''
          echo 'cataclysm.nix packaging shell. Try: nix build .#cdda-tileset-retrodays' 1>&2
        '';
      };

      checks = {
        # Smoke test: cata_test with the calendar suite. The test
        # binary always starts with an empty base path, so all resource
        # dirs are relative to cwd (see set_standard_filenames in
        # src/path_info.cpp): datadir is ./data, but gfxdir is ./gfx
        # (not ./data/gfx) and langdir is ./lang/mo. The symlinks below
        # rebuild the post-make repo layout upstream CI runs in. Data
        # comes from the tiles package: it holds everything the curses
        # package has plus gfx/, shaders/ and sound/. ./gfx has to be
        # there or build_tilesets_list() asserts and the check aborts.
        # (Soundpacks fall back to a built-in instead, so ./data/sound
        # is belt-and-suspenders.) Everything runs in a temp dir because
        # non-[nogame] tests boot a full game state (loads all JSON)
        # and write logs and saves under cwd.
        cdda-calendar-test = pkgs.runCommand "cdda-calendar-test" { } ''
          cd "$(mktemp -d)"
          ln -s ${stable.tiles}/share/cataclysm-dda data
          ln -s ${stable.tiles}/share/cataclysm-dda/gfx gfx
          mkdir -p lang
          ln -s ${stable.tiles}/share/locale lang/mo
          export HOME="$PWD"
          export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy
          ${stable.cata-test}/bin/cata_test "[calendar]"
          touch $out
        '';

        # Every composed set must be structurally sound: parseable
        # tile_config.json with a non-empty tiles-new, plus tileset.txt
        # and at least one composited sheet.
        cdda-tilesets-validate =
          let
            allSets = builtins.attrValues tilesets;
          in
          pkgs.runCommand "cdda-tilesets-validate"
            {
              nativeBuildInputs = [ pkgs.python3 ];
            }
            ''
              fail=0
              ${lib.concatMapStrings (t: ''
                echo "== ${t.tilesetDir}"
                python3 -c "
                import json, pathlib, sys
                t = pathlib.Path(sys.argv[1])
                d = json.loads((t / 'tile_config.json').read_text())
                sheets = d.get('tiles-new')
                assert sheets, 'empty tiles-new'
                missing = [s['file'] for s in sheets if not (t / s['file']).is_file()]
                assert not missing, 'missing sheets: %s' % (missing,)
                assert (t / 'tileset.txt').is_file(), 'missing tileset.txt'
                print(' ', len(sheets), 'sheets, all present')
                " '${t}' || fail=1
              '') allSets}
              test "$fail" -eq 0
              touch $out
            '';

        # Boot a game state with a real composed pack present, proving a
        # composed tileset gets discovered without tripping assertions.
        #
        # The pack goes into the *user* gfx dir (~/.cataclysm-dda/gfx,
        # the standalone-install path the README documents, and searched
        # before data/gfx). Putting it in the data dir instead would
        # collide with an in-tree NAME on stable: e.g. composed
        # Retrodays is NAME retrodays, in-tree RetroDaysTileset is too,
        # and build_resource_list (src/options.cpp) logs
        # 'Found "tileset" duplicate ...' at ERROR severity, which fails
        # this test (init treats any logged error as failure). The
        # per-directory scan means user-gfx and data-gfx never collide.
        cdda-tileset-discovery = pkgs.runCommand "cdda-tileset-discovery" { } ''
          cd "$(mktemp -d)"
          export HOME="$PWD"
          ln -s ${stable.tiles}/share/cataclysm-dda data
          mkdir gfx
          ln -s ${stable.tiles}/share/cataclysm-dda/gfx/* gfx/
          mkdir -p .cataclysm-dda/gfx
          ln -s ${tilesets."cdda-tileset-retrodays"} .cataclysm-dda/gfx/Retrodays
          mkdir -p lang
          ln -s ${stable.tiles}/share/locale lang/mo
          export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy
          ${stable.cata-test}/bin/cata_test "[calendar]"
          touch $out
        '';

        # Unit tests for the tileset updater with mocked git/nix. No
        # network, no builds. Mock programs get absolute bash shebangs
        # when created, so nothing needs patching; the scripts run
        # through bash directly.
        cdda-updater-tests =
          pkgs.runCommand "cdda-updater-tests"
            {
              nativeBuildInputs = with pkgs; [
                bash
                coreutils
                gawk
                gnugrep
                gnused
              ];
            }
            ''
              bash ${self + /cdda/scripts/test-update-tilesets.sh} ${self + /cdda/scripts/update-tilesets.sh}
              touch $out
            '';

        # Every soundpack must carry its soundpack.txt manifest (same
        # gate idea as tilesets-validate: catches empty-fetch and
        # wrong-subdir failures before they reach the game).
        cdda-soundpacks-validate =
          let
            allPacks = builtins.attrValues soundpackPacks;
          in
          pkgs.runCommand "cdda-soundpacks-validate" { } ''
            ${lib.concatMapStrings (s: ''
              test -f '${s}/soundpack.txt' \
                || (echo "missing soundpack.txt in ${s.soundpackDir}" >&2; exit 1)
            '') allPacks}
            touch $out
          '';

        # Unit tests for the soundpack updater with mocked git/nix.
        # No network, no builds; same harness as updater-tests.
        cdda-updater-soundpacks-tests =
          pkgs.runCommand "cdda-updater-soundpacks-tests"
            {
              nativeBuildInputs = with pkgs; [
                bash
                coreutils
                gawk
                gnugrep
                gnused
              ];
            }
            ''
              bash ${self + /cdda/scripts/test-update-soundpacks.sh} ${self + /cdda/scripts/update-soundpacks.sh}
              touch $out
            '';
      };

      apps.cdda-update-tilesets =
        let
          updater = pkgs.writeShellApplication {
            name = "cdda-update-tilesets";
            runtimeInputs = with pkgs; [
              coreutils
              gawk
              git
              gnugrep
              gnused
              nix
            ];
            text = builtins.readFile ./scripts/update-tilesets.sh;
          };
        in
        {
          type = "app";
          program = lib.getExe updater;
        };

      apps.cdda-update-soundpacks =
        let
          updater = pkgs.writeShellApplication {
            name = "cdda-update-soundpacks";
            runtimeInputs = with pkgs; [
              coreutils
              gawk
              git
              gnugrep
              gnused
              nix
            ];
            text = builtins.readFile ./scripts/update-soundpacks.sh;
          };
        in
        {
          type = "app";
          program = lib.getExe updater;
        };
    };
}
