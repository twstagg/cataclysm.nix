# TLG chunk of the flake: Cataclysm: The Last Generation packaging as a
# self-contained directory. Sibling of ../cdda; the root flake.nix only
# declares inputs and systems. See ./README.md for the tour.
#
# TLG is a story-focused content fork of CDDA sharing its Makefile build
# system, but: SDL2 backend, tilesets shipped pre-composed in-tree
# (nothing to compose), the Catch2 suite stripped at fork time (no test
# binary), and its own soundpack repo (CTLG-Soundpacks) bundled by
# release CI the way CDDA bundles CC-Sounds.
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
      # Keep only what the Makefile reads; docs/, .git and .github/ are
      # dead weight, and a docs-only upstream commit then leaves this
      # path unchanged so nothing rebuilds. The json-check runs the
      # loader over data/json from here, which the filter keeps.
      gameSource =
        input:
        pkgs.lib.cleanSourceWith {
          src = input;
          name = "cataclysm-tlg-${input.shortRev or "source"}";
          filter =
            path: type:
            let
              base = baseNameOf (toString path);
            in
            !(base == "docs" || base == ".git" || base == ".github");
        };

      # The game itself. Pinned to a dated release tag in the root flake
      # inputs (tags are immutable, so nix flake update keeps it steady);
      # bump by editing the ref there.
      tlgSrc = gameSource inputs.cataclysm-tlg;
      # VERSION for the binary banner; the Makefile default is a bare
      # 1.0 and fetched sources have no .git. The prefix is parsed out
      # of the tag ref in flake.lock (cataclysm-tlg-<prefix>-<date>),
      # not hardcoded, so a tag bump moves it automatically.
      tlgTag = lockHelpers.refOf "cataclysm-tlg";
      tlgPrefix =
        let
          m = builtins.match "cataclysm-tlg-(.+)-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}" (if tlgTag == null then "" else tlgTag);
        in
        if m == null then "1.0" else builtins.head m;
      version = "${tlgPrefix}+" + (inputs.cataclysm-tlg.shortRev or "git");

      mkTlg =
        attrs:
        pkgs.callPackage ./package.nix (
          attrs
          // {
            inherit version;
            src = tlgSrc;
            # Full sha for VERSION.txt's commit fields (the banner itself
            # only reads `version`); tags are immutable so this is stable.
            gitRev = inputs.cataclysm-tlg.rev or "";
          }
        );

      # CTLG-Soundpacks: TLG's fork of the community soundpack repo.
      # Same layout as Fris0uman's (sound/CC-Sounds), music via the
      # CTLG-Music-Packs submodule, fetched with submodules enabled.
      # Now a flake input (see flake.nix) so `nix flake update` bumps it.
      tlgSoundpacksSrc = inputs.tlg-soundpacks;
      tlgSoundpacksVersion = inputs.tlg-soundpacks.shortRev or "0000000";

      tlgSoundpackPacks = {
        tlg-soundpack-cc-sounds = pkgs.callPackage ./soundpack.nix {
          name = "CC-Sounds";
          src = tlgSoundpacksSrc;
          sourceDir = "sound/CC-Sounds";
          installName = "CC-Sounds";
          version = tlgSoundpacksVersion;
        };
      };

      # Sound build carries CTLG's CC-Sounds (release parity). The twelve
      # tilesets need no bundling: make install already ships them
      # in-tree, pre-composed. Bound here (not inline in packages) so the
      # version-banner check can reference it.
      tlgTiles = mkTlg {
        tiles = true;
        sound = true;
        extraSoundpacks = [ tlgSoundpackPacks.tlg-soundpack-cc-sounds ];
      };

      # json_formatter.cgi: TLG's canonical JSON formatter, built with
      # the same Makefile target the JSON workflow uses.
      tlgJsonFormatter = pkgs.stdenv.mkDerivation {
        pname = "ctlg-json-formatter";
        inherit version;
        src = tlgSrc;
        # The Makefile's global LDFLAGS drag -lncursesw -lz into this
        # link (non-TILES default), same as CDDA's json_formatter.
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
          description = "Cataclysm: TLG canonical JSON formatter";
          license = lib.licenses.cc-by-sa-30;
          platforms = lib.platforms.unix;
        };
      };

      # chkjson: TLG's structural JSON validator. It runs the game's
      # real loader (load_all_from_json) over CWD-relative data/json,
      # so it catches parse errors *and* semantic breakage (unknown
      # ids, bad types) that would black-screen the game at boot.
      #
      # The stock target does not link: CHKJSON_SOURCES omits
      # src/string_id.cpp while string_id.h arrives via json.cpp, so
      # string_id symbols are undefined (same omission in CleverRaven
      # 0.I). Add the missing TU with a command-line override.
      tlgChkjson = pkgs.stdenv.mkDerivation {
        pname = "ctlg-chkjson";
        inherit version;
        src = tlgSrc;
        # Same global-LDFLAGS reason as the formatter above.
        buildInputs = with pkgs; [
          ncurses
          zlib
        ];
        buildPhase = ''
          runHook preBuild
          # Sources listed explicitly rather than via $(wildcard ...):
          # a command-line override of the Makefile's immediate (:=)
          # CHKJSON_SOURCES does not re-expand a wildcard reliably, and
          # there is exactly one .cpp under src/chkjson anyway.
          make chkjson -j$NIX_BUILD_CORES \
            CHKJSON_SOURCES="src/chkjson/chkjson.cpp src/wcwidth.cpp src/json.cpp src/string_id.cpp"
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          install -Dm755 chkjson $out/bin/chkjson
          runHook postInstall
        '';
        enableParallelBuilding = true;
        meta = {
          description = "Cataclysm: TLG structural JSON validator";
          license = lib.licenses.cc-by-sa-30;
          platforms = lib.platforms.unix;
        };
      };
    in
    {
      packages = {
        # Sound build carries CTLG's CC-Sounds (release parity). The
        # twelve tilesets need no bundling: make install already
        # ships them in-tree, pre-composed.
        tlg-tiles = tlgTiles;
        tlg-curses = mkTlg {
          tiles = false;
          sound = false;
        };
        tlg-json-formatter = tlgJsonFormatter;
        tlg-chkjson = tlgChkjson;
      }
      // tlgSoundpackPacks;

      checks = {
        # Every TLG soundpack must carry its soundpack.txt manifest
        # (same gate as the CDDA soundpacks-validate check).
        tlg-soundpacks-validate =
          let
            allPacks = builtins.attrValues tlgSoundpackPacks;
          in
          pkgs.runCommand "ctlg-soundpacks-validate" { } ''
            ${lib.concatMapStrings (s: ''
              test -f '${s}/soundpack.txt' \
                || (echo "missing soundpack.txt in ${s.soundpackDir}" >&2; exit 1)
            '') allPacks}
            touch $out
          '';

        # Semantic JSON check over the pinned game data, via the game's
        # own loader. TLG has no game test binary (suite stripped at
        # fork time), so this is its smoke check. chkjson reads
        # CWD-relative data/json, hence the cd; it only reads.
        #
        # Not a canonical-formatting gate on purpose: upstream's own
        # json.yml runs the formatter over data/, but "json-fixes" PRs
        # land non-canonical JSON in release tags, and formatting is
        # cosmetic anyway. chkjson is the load-bearing check.
        tlg-json-check = pkgs.runCommand "ctlg-json-check" { } ''
          cd ${tlgSrc}
          ${tlgChkjson}/bin/chkjson
          touch $out
        '';

        # The banner, window title, `--version`, memorial headers and
        # crash logs all come from getVersionString(), which reads the
        # CWD-relative VERSION.txt and falls back to the literal
        # "unknown" when it finds none (see ./package.nix). The --chdir
        # wrapper is what makes the shipped data dir the CWD, so assert
        # the game reports the flake revision: a missing file, a wrong
        # directory or an unwrapped binary all land on "unknown". Safe
        # to run headless, because main() handles --version and exits
        # ahead of the data/user dir existence checks; HOME still has to
        # be set, since PATH_INFO::init_user_dir() aborts without it and
        # the build sandbox has none.
        tlg-version-banner =
          pkgs.runCommand "ctlg-version-banner"
            {
              nativeBuildInputs = [ pkgs.gnugrep ];
            }
            ''
              export HOME="$NIX_BUILD_TOP"
              ver="$(${tlgTiles}/bin/${tlgTiles.targetName} --version 2>&1)"
              printf '%s\n' "$ver"
              # Whole-line match: an unresolved version prints this same
              # line with "unknown" where the revision should be, and
              # other lines of --version output can legitimately contain
              # that word.
              printf '%s' "$ver" | grep -Fx 'Cataclysm: The Last Generation: ${version}'
              touch $out
            '';

      };

      # One shell per game, no default. TLG is SDL2-only and ships its
      # tilesets pre-composed, so no compose toolchain here.
      devShells.tlg = pkgs.mkShell {
        packages = with pkgs; [
          SDL2
          SDL2_image
          SDL2_mixer
          SDL2_ttf
          bzip2
          gettext
          git
          libbacktrace
          libx11
          ncurses
          nixfmt
          pkg-config
          zlib
        ];

        shellHook = ''
          echo 'cataclysm.nix TLG shell. Try: nix build .#tlg-tiles' 1>&2
        '';
      };

    };
}
