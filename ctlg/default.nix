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
      ctlgSrc = gameSource inputs.cataclysm-tlg;
      # VERSION for the binary banner; the Makefile default is a bare
      # 1.0 and fetched sources have no .git. The prefix is parsed out
      # of the tag ref in flake.lock (cataclysm-tlg-<prefix>-<date>),
      # not hardcoded, so a tag bump moves it automatically.
      ctlgTag = lockHelpers.refOf "cataclysm-tlg";
      ctlgPrefix =
        let
          m = builtins.match "cataclysm-tlg-(.+)-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}" (if ctlgTag == null then "" else ctlgTag);
        in
        if m == null then "1.0" else builtins.head m;
      version = "${ctlgPrefix}+" + (inputs.cataclysm-tlg.shortRev or "git");

      mkTlg =
        attrs:
        pkgs.callPackage ./package.nix (
          attrs
          // {
            inherit version;
            src = ctlgSrc;
            # Full sha for VERSION.txt's commit fields (the banner itself
            # only reads `version`); tags are immutable so this is stable.
            gitRev = inputs.cataclysm-tlg.rev or "";
          }
        );

      # CTLG-Soundpacks: TLG's fork of the community soundpack repo.
      # Same layout as Fris0uman's (sound/CC-Sounds), music via the
      # CTLG-Music-Packs submodule, fetched with submodules enabled.
      # Now a flake input (see flake.nix) so `nix flake update` bumps it.
      ctlgSoundpacksSrc = inputs.ctlg-soundpacks;
      ctlgSoundpacksVersion = inputs.ctlg-soundpacks.shortRev or "0000000";

      ctlgSoundpackPacks = {
        ctlg-soundpack-cc-sounds = pkgs.callPackage ./soundpack.nix {
          name = "CC-Sounds";
          src = ctlgSoundpacksSrc;
          sourceDir = "sound/CC-Sounds";
          installName = "CC-Sounds";
          version = ctlgSoundpacksVersion;
        };
      };

      # Sound build carries CTLG's CC-Sounds (release parity). The twelve
      # tilesets need no bundling: make install already ships them
      # in-tree, pre-composed. Bound here (not inline in packages) so the
      # version-banner check can reference it.
      ctlgTiles = mkTlg {
        tiles = true;
        sound = true;
        extraSoundpacks = [ ctlgSoundpackPacks.ctlg-soundpack-cc-sounds ];
      };

      # json_formatter.cgi: TLG's canonical JSON formatter, built with
      # the same Makefile target the JSON workflow uses.
      ctlgJsonFormatter = pkgs.stdenv.mkDerivation {
        pname = "ctlg-json-formatter";
        inherit version;
        src = ctlgSrc;
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
      ctlgChkjson = pkgs.stdenv.mkDerivation {
        pname = "ctlg-chkjson";
        inherit version;
        src = ctlgSrc;
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
        ctlg-tiles = ctlgTiles;
        ctlg-curses = mkTlg {
          tiles = false;
          sound = false;
        };
        ctlg-json-formatter = ctlgJsonFormatter;
        ctlg-chkjson = ctlgChkjson;
      }
      // ctlgSoundpackPacks;

      checks = {
        # Every TLG soundpack must carry its soundpack.txt manifest
        # (same gate as the CDDA soundpacks-validate check).
        ctlg-soundpacks-validate =
          let
            allPacks = builtins.attrValues ctlgSoundpackPacks;
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
        ctlg-json-check = pkgs.runCommand "ctlg-json-check" { } ''
          cd ${ctlgSrc}
          ${ctlgChkjson}/bin/chkjson
          touch $out
        '';

      };

      # One shell per game, no default. TLG is SDL2-only and ships its
      # tilesets pre-composed, so no compose toolchain here.
      devShells.ctlg = pkgs.mkShell {
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
          echo 'cataclysm.nix TLG shell. Try: nix build .#ctlg-tiles' 1>&2
        '';
      };

    };
}
