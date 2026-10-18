# Build Cataclysm: The Last Generation from source with the project's
# own Makefile. TLG is a content fork of CDDA sharing its build system,
# so this mirrors the CDDA chunk's ./package.nix, trimmed to TLG's reality:
#
#   * SDL2 backend (TLG predates upstream CDDA's SDL3 switch; no
#     vendored imgui, SDL2-era headers throughout)
#   * no shader step (no tools/build_shaders.py, no glslang)
#   * no test binary (the Catch2 suite was stripped at fork time;
#     tests/ holds fixtures only)
#   * tilesets ship pre-composed in gfx/ (synced from CTLG-Tilesets
#     releases by upstream CI), so there is nothing to compose here
#
# PREFIX is baked in at compile time (-DPREFIX -DDATA_DIR_PREFIX), so
# the binary reads data from $out/share/cataclysm-tlg and locales from
# $out/share/locale. No patches required.
{
  lib,
  stdenv,
  pkg-config,
  gettext,
  ncurses,
  zlib,
  bzip2,
  libbacktrace,
  SDL2,
  SDL2_image,
  SDL2_ttf,
  SDL2_mixer,
  libx11,
  freetype,
  # SDL graphical build; ncurses text build when false
  tiles ? true,
  # sound via SDL2_mixer; requires tiles (Makefile: SOUND needs TILES)
  sound ? true,
  # debug build: no RELEASE=1, keep symbols
  debug ? false,
  # user files in $XDG_DATA_HOME instead of ~/.cataclysm-tlg
  useXdgDir ? false,
  # soundpack derivations (./soundpack.nix) baked into
  # share/cataclysm-tlg/sound/<soundpackDir>, alongside the in-tree
  # Basic pack. Mirrors TLG's release.yml, which drops CTLG-Soundpacks'
  # CC-Sounds into data/sound for every sound-enabled build.
  extraSoundpacks ? [ ],
  version,
  src,
}:

assert lib.assertMsg (tiles || !sound) "cataclysm-tlg: sound requires tiles";

let
  inherit (lib)
    optionals
    optionalString
    concatStrings
    ;

  gameDeps =
    if tiles then
      [
        SDL2
        SDL2_image
        SDL2_ttf
        freetype
        # sdltiles.cpp includes SDL_syswm.h, which pulls X11/Xlib.h;
        # nixpkgs' SDL2 is sdl2-compat, which does not propagate the
        # X11 headers transitively (same fix as CDDA stable builds).
        libx11
      ]
      ++ optionals sound [ SDL2_mixer ]
    else
      [ ncurses ];

  targetName = if tiles then "cataclysm-tlg-tiles" else "cataclysm-tlg";

  variantSuffix = concatStrings (optionals tiles [ "-tiles" ] ++ optionals sound [ "-sound" ]);
in
stdenv.mkDerivation (
  finalAttrs:
  {
    pname = "cataclysm-tlg" + variantSuffix;
    inherit version src;

    # gettext: msgfmt for lang/*.po -> lang/*.mo. No python: TLG has no
    # shader script or codegen step in the default goal.
    nativeBuildInputs = [
      pkg-config
      gettext
    ];

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

    makeFlags = [
      "PREFIX=${placeholder "out"}"
      "VERSION=${finalAttrs.version}"
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
      # TLG's default goal includes the json style gate (LINTJSON=1 by
      # default on RELEASE builds): json_formatter rewrites any
      # non-canonical data/*.json and exits nonzero, failing the build.
      # TLG release tags ship non-canonical JSON (their "json-fixes"
      # PRs land unformatted files), and in a Nix build the rewrite path
      # is useless anyway: the source is read-only, and we would not
      # want silently-reformatted data in the store output. Upstream CI
      # sidesteps the gate the same way, by building `bindist` rather
      # than `all`.
      "LINTJSON=0"
      (if useXdgDir then "USE_XDG_DIR=1" else "USE_HOME_DIR=1")
    ]
    ++ optionals (!debug) [ "RELEASE=1" ]
    ++ optionals tiles [ "TILES=1" ]
    ++ optionals sound [ "SOUND=1" ];

    postInstall =
      optionalString tiles ''
        substituteInPlace $out/share/applications/com.cataclysm-tlg.cataclysm-tlg.desktop \
          --replace-fail "Exec=cataclysm-tlg-tiles" "Exec=$out/bin/cataclysm-tlg-tiles"
      ''
      + optionalString (extraSoundpacks != [ ]) ''
        # Merge contents into the target dir (mkdir -p + cp src/.), never
        # nest: make install already ships in-tree sound/ (Basic), and
        # cp -R src dst/ into an existing dir would create
        # dst/<store-path>/ with a duplicate soundpack.txt. Merging with
        # overwrite mirrors release.yml (mv CC-Sounds into data/sound).
        ${lib.concatMapStrings (s: ''
          mkdir -p $out/share/cataclysm-tlg/sound/${s.soundpackDir}
          cp -R --no-preserve=ownership ${s}/. $out/share/cataclysm-tlg/sound/${s.soundpackDir}/
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
      description = "Post-apocalyptic survival roguelike; story-focused CDDA fork";
      longDescription = ''
        Cataclysm: The Last Generation is a single-player turn-based
        postapocalyptic survival game based on Cataclysm: Dark Days
        Ahead. It preserves Cataclysm's depth and plausibility while
        foregrounding character progression and immersive life-sim
        elements: uncover the truth about the Cataclysm, form a band of
        survivors, and adapt via bionics or mutations.
      '';
      homepage = "https://cataclysmtlg.com/";
      license = lib.licenses.cc-by-sa-30;
      mainProgram = targetName;
      platforms = lib.platforms.linux;
    };
  }
)
