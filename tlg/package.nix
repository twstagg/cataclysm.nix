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
# $out/share/locale. No patches required: the one place where an install
# layout diverges from upstream's expectations (the CWD-relative
# VERSION.txt the version banner is read from) is reconciled at wrap
# time rather than with a patch. See postInstall/postFixup.
{
  lib,
  stdenv,
  pkg-config,
  gettext,
  # --chdir wrapper for the CWD-relative VERSION.txt (see postFixup)
  makeWrapper,
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
  # Full commit sha for VERSION.txt's commit fields. Nothing in the game
  # parses them (only "build number:" is read); they are what a player
  # pastes into a bug report, so carry the full sha rather than the
  # short rev in `version`. Empty for inputs with no rev (a local path).
  gitRev ? "",
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
stdenv.mkDerivation (finalAttrs: {
  pname = "cataclysm-tlg" + variantSuffix;
  inherit version src;

  # gettext: msgfmt for lang/*.po -> lang/*.mo. No python: TLG has no
  # shader script or codegen step in the default goal. makeWrapper: the
  # --chdir wrapper in postFixup.
  nativeBuildInputs = [
    pkg-config
    gettext
    makeWrapper
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
    optionalString true ''
      # TLG reports its version at runtime, not compile time:
      # src/version.cpp opens the CWD-relative "VERSION.txt", returns the
      # value of its "build number:" line, and falls back to the literal
      # "unknown" when the file is not there. The VERSION= makeFlag is
      # inert for TLG (it commented out the VERSION/GIT_VERSION code path
      # that CDDA 0.I and BN still use, and its Makefile never adds
      # -DVERSION), so this file is the only way to name the build.
      #
      # Upstream CI writes it in the release workflow and `make bindist`
      # ships it beside the binary, where cataclysm-launcher's
      # `cd "$(dirname $0)"` makes that directory the CWD. `make install`
      # writes no such file and installs none, hence: write it here, and
      # see postFixup for how the data dir becomes the CWD. Only
      # "build number:" is parsed; the commit lines are human-facing and
      # deliberately upstream's format.
      printf 'build type: Release\nbuild number: ${version}\ncommit sha: ${gitRev}\ncommit url: https://github.com/Cataclysm-TLG/Cataclysm-TLG/commit/${gitRev}\n' > "$out/share/cataclysm-tlg/VERSION.txt"
    ''
    + optionalString true ''
      # The Makefile installs the zzip CLI as bin/zzip, but the game
      # links zzip as a library and never executes the CLI itself (no
      # popen/system references to it in src/). The CLI is a shell
      # convenience tool, and two games installed side by side would
      # collide on bin/zzip in a home-manager buildEnv, so rename it
      # per game.
      if [ -f "$out/bin/zzip" ]; then
        mv "$out/bin/zzip" "$out/bin/zzip-tlg"
      fi
    ''
    + optionalString tiles ''
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

  # The version file above is found by CWD, and a `make install` layout
  # splits bin/ from the data dir, so a desktop entry (Exec= with no
  # Path=, so CWD is $HOME) or a bare `nix run` starts the game with no
  # VERSION.txt in reach and the banner/title/`--version` all say
  # "unknown". Upstream's answer for its own bundle is
  # cataclysm-launcher, which cds into the bundle directory before exec;
  # do the same thing here for the data dir, which is where VERSION.txt
  # lives. Nothing else depends on the CWD: data and locales are
  # compile-time absolute (PREFIX + DATA_DIR_PREFIX) and player files go
  # under the user dir (USE_HOME_DIR/USE_XDG_DIR). wrapProgram keeps the
  # name and path of the binary, so meta.mainProgram and the .desktop
  # Exec= above keep pointing at the same thing. The generated wrapper is
  # `bash -e` ending in `exec -a "$0"`, so exit status and signals pass
  # through untouched, and a missing data dir aborts the launch rather
  # than starting a game that could not find its own data.
  postFixup = ''
    wrapProgram "$out/bin/${targetName}" --chdir "$out/share/cataclysm-tlg"
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
})
