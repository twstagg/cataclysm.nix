# Build Cataclysm: Dark Days Ahead from the game source with the project's
# own Makefile (see doc/c++/COMPILING.md). The Makefile stays the build
# system; Nix just hands it dependencies and install targets.
#
# Shaped after nixpkgs' pkgs/games/cataclysm-dda/common.nix. Upstream
# switched the tiles backend from SDL2 to SDL3-only on 2026-08-11, so the
# SDL stack follows the pinned game era: stable 0.I and older need SDL2,
# master / 0.J dev needs SDL3. useSdl3 selects between them; flip it in
# flake.nix when moving the game input across that boundary.
#
# No patches are required:
#   * PREFIX is baked in at compile time (-DPREFIX -DDATA_DIR_PREFIX ->
#     src/main.cpp init_base_path), so the binary reads data from
#     $out/share/cataclysm-dda and locales from $out/share/locale.
#   * translations.cpp already resolves locale_dir() via base_path() on
#     Linux (the locale-path patch nixpkgs carries is for a 2024 revision).
#   * Without .git in the flake source, the Makefile falls back to the
#     VERSION= value we pass, and skips -DGIT_VERSION.
{
  lib,
  stdenv,
  pkg-config,
  gettext,
  python3,
  glslang,
  ncurses,
  zlib,
  bzip2,
  libbacktrace,
  SDL2,
  SDL2_image,
  SDL2_ttf,
  SDL2_mixer,
  libx11,
  sdl3,
  sdl3-image,
  sdl3-ttf,
  sdl3-mixer,
  freetype,
  # SDL major version: true for SDL3 (master / 0.J dev), false for
  # SDL2-era sources (stable 0.I and older)
  useSdl3 ? true,
  # SDL graphical build; ncurses text build when false
  tiles ? true,
  # sound via SDL mixer (matches useSdl3); requires tiles (COMPILING.md: SOUND needs TILES)
  sound ? true,
  # debug build: no RELEASE=1, keep symbols
  debug ? false,
  # user files in $XDG_DATA_HOME instead of ~/.cataclysm-dda
  useXdgDir ? false,
  # build the cata_test Catch2 binary instead of the game
  buildTests ? false,
  # composed tileset derivations (./tileset.nix) baked into
  # share/cataclysm-dda/gfx/<tilesetDir>; release-bundle equivalent
  extraTilesets ? [ ],
  # soundpack derivations (./soundpack.nix) baked into
  # share/cataclysm-dda/sound/<soundpackDir>, alongside the in-tree
  # Basic pack. Mirrors release.yml, which drops CC-Sounds into
  # data/sound for every sound-enabled build.
  extraSoundpacks ? [ ],
  version,
  src,
}:

assert lib.assertMsg (tiles || !sound) "cataclysm-dda: sound requires tiles";

let
  inherit (lib)
    optionals
    optionalString
    concatStrings
    ;

  gameDeps =
    if tiles then
      (
        if useSdl3 then
          [
            sdl3
            sdl3-image
            sdl3-ttf
            freetype
          ]
          ++ optionals sound [ sdl3-mixer ]
        else
          [
            SDL2
            SDL2_image
            SDL2_ttf
            freetype
            # imgui_impl_sdl2 + sdltiles include SDL_syswm.h, which pulls
            # X11/Xlib.h; real SDL2 propagated x11 headers transitively,
            # sdl2-compat (what nixpkgs' SDL2 resolves to) does not.
            # nixpkgs' own SDL2-era derivation adds libx11 for the same
            # reason.
            libx11
          ]
          ++ optionals sound [ SDL2_mixer ]
      )
    else
      [ ncurses ];

  targetName = if tiles then "cataclysm-tiles" else "cataclysm";

  variantSuffix = concatStrings (optionals tiles [ "-tiles" ] ++ optionals sound [ "-sound" ]);
in
stdenv.mkDerivation (
  finalAttrs:
  {
    pname = "cataclysm-dda" + optionalString buildTests "-test" + variantSuffix;
    inherit version src;

    # python3: tools/build_shaders.py (SDL3 tiles only; SDL2-era sources
    # have no shader step); glslang: glslangValidator for GLSL -> SPIR-V;
    # gettext: msgfmt for lang/*.po -> lang/*.mo.
    nativeBuildInputs = [
      pkg-config
      gettext
      python3
    ]
    ++ optionals (tiles && useSdl3) [ glslang ];

    buildInputs = [
      zlib
      bzip2
      gettext
      # LIBBACKTRACE=1 links -lbacktrace and includes <backtrace.h>
      # (see the makeFlags note on release parity).
      libbacktrace
    ]
    ++ gameDeps;

    strictDeps = true;

    postPatch = ''
      patchShebangs lang/
    '';

    # gcc 16 grew -Werror=sfinae-incomplete, and the stable 0.I sources
    # predate upstream's own -Wno-error= for it (master and TLG carry it
    # in their Makefiles), so on gcc 16 they hard-fail on
    # src/vehicle.h. NIX_CFLAGS_COMPILE is appended after the Makefile's
    # flags, so this wins over -Werror.
    #
    # Probed rather than unconditional: an older compiler does not know
    # the flag and rejects it as an unknown-warning error, and this
    # package is built from other nixpkgs pins too (a home-manager
    # config consuming this flake builds it with its own gcc). Harmless
    # once the stable tag moves; drop it then.
    preConfigure = ''
      # Probe with a real file, not stdin: gcc 16 rejects stdin without
      # -x c++, which would look like "flag unsupported" and silently
      # drop the relaxation this build needs.
      probe="$(mktemp -d)/probe.cpp"
      echo 'int main() {}' > "$probe"
      if $CXX -Werror=sfinae-incomplete -fsyntax-only "$probe" >/dev/null 2>&1; then
        echo "adding -Wno-error=sfinae-incomplete"
        export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE:-} -Wno-error=sfinae-incomplete"
      else
        echo "compiler lacks -Wsfinae-incomplete; nothing to relax"
      fi
    '';

    env = lib.optionalAttrs (tiles && useSdl3) {
      # The Makefile invokes this by bare name; be explicit anyway.
      # (SDL2-era sources never call the shader script, so no GLSLANG then.)
      GLSLANG = lib.getExe' glslang "glslangValidator";
    };

    makeFlags = [
      "PREFIX=${placeholder "out"}"
      "VERSION=${finalAttrs.version}"
      "TESTS=${if buildTests then "1" else "0"}"
      "RUNTESTS=0"
      "LOCALIZE=1"
      "LANGUAGES=all"
      # Release parity with .github/workflows/release.yml, which builds
      # ... BACKTRACE=1 LIBBACKTRACE=1 PCH=0 bindist. BACKTRACE=1 is the
      # Makefile default on Linux (adds -DBACKTRACE, -rdynamic); this
      # adds the libbacktrace variant (-DLIBBACKTRACE, -lbacktrace).
      # PCH=0 matches CI (precompiled headers off; pure build-time
      # difference, same output).
      "BACKTRACE=1"
      "LIBBACKTRACE=1"
      "PCH=0"
      # The default goal includes the json style gate (LINTJSON=1 on
      # RELEASE builds), which fails when json_formatter would rewrite
      # a non-canonical data/*.json. Today's tag passes, but the rewrite
      # path is meaningless in a Nix build: the source is read-only and
      # we do not want silently-reformatted data in the store output.
      # Upstream CI sidesteps the gate by building `bindist`.
      "LINTJSON=0"
      (if useXdgDir then "USE_XDG_DIR=1" else "USE_HOME_DIR=1")
    ]
    ++ optionals (!debug) [ "RELEASE=1" ]
    ++ optionals tiles [ "TILES=1" ]
    ++ optionals sound [ "SOUND=1" ];

    # One make invocation covers game and tests: `tests` builds
    # cataclysm.a (every game object) and the game target links that
    # same archive, so the test output costs no extra compile. `prefix`
    # generates src/prefix.h from PREFIX, which `tests` does not pull in.
    buildFlags = optionals buildTests [
      "prefix"
      "tests"
    ];

    postInstall =
      optionalString true ''
        # The Makefile installs the zzip CLI as bin/zzip, but the game
        # links zzip as a library and never runs it; the CLI is a shell
        # convenience tool. Rename it per game: two games installed side
        # by side (home-manager's buildEnv refuses conflicting
        # subpaths) would otherwise collide on bin/zzip.
        if [ -f "$out/bin/zzip" ]; then
          mv "$out/bin/zzip" "$out/bin/zzip-cdda"
        fi
      ''
      + optionalString buildTests ''
        # tests/ has no install rule for the binary and `make install`
        # takes only the game, so ship the Catch2 binary to the test
        # output here.
        install -Dm755 tests/cata_test "$test/bin/cata_test"
      ''
      + optionalString (tiles && !buildTests) ''
        substituteInPlace $out/share/applications/org.cataclysmdda.CataclysmDDA.desktop \
          --replace-fail "Exec=cataclysm-tiles" "Exec=$out/bin/cataclysm-tiles"
      ''
      + optionalString (extraTilesets != [ ]) ''
        # Merge contents into the target dir (mkdir -p + cp src/.), never
        # nest: make install already ships in-tree gfx/ (e.g.
        # gfx/Larwick_Overmap), and cp -R src dst/ into an existing dir
        # would create dst/<store-path>/ with a duplicate tileset.txt.
        # Merging with overwrite mirrors release.yml ("Fetch tileset
        # artifact into build": download-artifact with merge-multiple
        # into gfx/ on top of the game checkout).
        ${lib.concatMapStrings (t: ''
          mkdir -p $out/share/cataclysm-dda/gfx/${t.tilesetDir}
          cp -R --no-preserve=ownership ${t}/. $out/share/cataclysm-dda/gfx/${t.tilesetDir}/
        '') extraTilesets}
      ''
      + optionalString (extraSoundpacks != [ ]) ''
        # Same merge idiom as extraTilesets above, but simpler: packs
        # need no compose step, so each derivation already IS the pack
        # directory (soundpack.txt + JSON + audio). Installed under
        # sound/, where the game scans them alongside the in-tree pack
        # (Basic on stable, Menu_Sound_Test on master).
        ${lib.concatMapStrings (s: ''
          mkdir -p $out/share/cataclysm-dda/sound/${s.soundpackDir}
          cp -R --no-preserve=ownership ${s}/. $out/share/cataclysm-dda/sound/${s.soundpackDir}/
        '') extraSoundpacks}
      '';

    dontStrip = debug;
    enableParallelBuilding = true;

    passthru = {
      isTiles = tiles;
      isSound = sound;
      inherit targetName;
    };

    meta = {
      description = "Free, post-apocalyptic, zombie-infested roguelike";
      longDescription = ''
        Cataclysm: Dark Days Ahead is a roguelike set in a post-apocalyptic
        world: scavenge, craft, fight zombies, mutants and rogue machines in a
        persistent procedurally generated world with per-body-part combat,
        vehicles, mutations, bionics, NPCs and mods.
      '';
      homepage = "https://cataclysmdda.org/";
      license = lib.licenses.cc-by-sa-30;
      mainProgram = targetName;
      platforms = lib.platforms.linux;
    };
  }
  // lib.optionalAttrs buildTests {
    # Second output of the same derivation: game and Catch2 binary come
    # out of one make run, sharing cataclysm.a.
    outputs = [
      "out"
      "test"
    ];
  }
)
