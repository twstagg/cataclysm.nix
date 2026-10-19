# Cataclysm: Bright Nights packaging for the cbn/ chunk of cataclysm.nix.
# CMake stays the build system; Nix hands it dependencies and the install
# prefix.
#
# Notes for maintainers:
#   * gfx/ ships pre-composed in every track, so there is no tileset
#     pipeline here. The game package already bundles every tileset,
#     like a release.
#   * Registry content (external mods + the Otopack soundpack) comes from
#     the `registryMods` argument (./registry-mods.nix, mirroring the
#     bundle build-scripts/bundle-registry-mods.ts produces for
#     releases) and links into the data dir below. Mods ship in every
#     game package; the soundpack only where `sound` is on.
#   * src/version.cmake regenerates src/version.h from git at build time,
#     and writes NULL when no git binary is configured. The root
#     CMakeLists only produces a version (and only writes VERSION.txt)
#     when git_describe finds a .git directory, which Nix sources never
#     have, so -DGIT_BINARY points at a stand-in answering `describe`
#     with the `version` argument. VERSION.txt is never generated here,
#     so postConfigure writes it from `rev`. The banner date comes from
#     __DATE__, so SOURCE_DATE_EPOCH becomes the commit time instead of
#     Nix's 1980 default.
#   * The docs build requires clang >= 22, so callers pass
#     llvmPackages_22.stdenv. Shadercross comes from nixpkgs
#     (BUILD_SHADERCROSS=OFF) instead of building from source, which
#     would need network at build time.
{
  lib,
  stdenv,
  cmake,
  ninja,
  pkg-config,
  gettext,
  sqlite,
  ncurses,
  zlib,
  bzip2,
  libbacktrace,
  libvorbis,
  freetype,
  sdl3,
  sdl3-image,
  sdl3-ttf,
  sdl3-mixer,
  sdl3-shadercross,
  # Builds the git stand-in below (answers describe/rev-parse from the
  # flake's version and rev).
  writeShellScriptBin,
  # SDL3 graphical build; ncurses text build when false
  tiles ? true,
  # sound via SDL3_mixer; requires tiles
  sound ? true,
  # user files in $XDG_DATA_HOME instead of ~/.cataclysm-bn
  useXdgDir ? false,
  # build the Catch2 test binary as a second output of this derivation
  # (TESTS=ON), so tiles and the test binary share one compile instead of
  # rebuilding the whole game
  buildTests ? false,
  version,
  # Full git revision of `src`, used for the version banner and the
  # commit link in VERSION.txt.
  rev ? "unknown",
  # Commit timestamp (flake self.lastModified), for the banner date via
  # SOURCE_DATE_EPOCH. Null keeps Nix's reproducibility default.
  commitTime ? null,
  src,
  # Registry mods + soundpack bundle (./registry-mods.nix); linked
  # into game packages below, never into the test output.
  registryMods,
}:

assert lib.assertMsg (tiles || !sound) "cataclysm-bn: sound requires tiles";
assert lib.assertMsg (
  !buildTests || (tiles && sound)
) "cataclysm-bn: tests need the tiles+sound variant (game-state init)";

let
  inherit (lib) optionals;
  gameDeps = [
    sqlite
    zlib
    bzip2
    freetype
    # Crash traces with line info, same as CI. Without the system
    # copy CMake fetches libbacktrace from GitHub, which cannot work
    # in the sandbox.
    libbacktrace
  ]
  ++ optionals tiles [
    sdl3
    sdl3-image
    sdl3-ttf
  ]
  ++ optionals sound [
    sdl3-mixer
    libvorbis
  ]
  # CATA_SDL forces on for every variant, even curses, for GPU platform
  # services; CMake fetches SDL3 from GitHub when the system copy is
  # missing, which cannot work in the sandbox. The tiles list already
  # carries it, so curses needs it here.
  ++ optionals (!tiles) [
    ncurses
    sdl3
  ];

  targetName =
    if buildTests then
      "cata_test-tiles"
    else if tiles then
      "cataclysm-bn-tiles"
    else
      "cataclysm-bn";
  # Credits match what the build ships: a soundless build gets the
  # mods-only list, the way release CI excludes soundpacks there.
  # Evaluated at the Nix level, so it cannot go stale relative to the
  # postInstall logic that consumes it.
  creditsFile = if sound then "external-mods-CREDITS.txt" else "external-mods-CREDITS-mods-only.txt";

  # Only src/version.cmake ever reaches the stand-in: it asks
  # `describe` for the build version, once, at build time. Configure
  # never does, because its git_describe needs a .git directory that Nix
  # sources do not carry.
  gitDescribe = writeShellScriptBin "cbn-git-describe" ''
    echo "${version}"
  '';
in
stdenv.mkDerivation (
  {
    pname = "cataclysm-bn";
    inherit version src;

    nativeBuildInputs = [
      cmake
      ninja
      pkg-config
      gettext
      # Provides `shadercross` on PATH so BUILD_SHADERCROSS can stay OFF.
      sdl3-shadercross
    ];

    buildInputs = gameDeps;

    strictDeps = true;

    # Banner date falls back to __DATE__ (version.h.in carries no
    # BUILD_TIMESTAMP), and clang renders __DATE__ from
    # SOURCE_DATE_EPOCH. Nix pins that to 1980; the commit time keeps
    # the build reproducible while showing something true.
    env = lib.optionalAttrs (commitTime != null) {
      SOURCE_DATE_EPOCH = toString commitTime;
    };

    # RelWithDebInfo takes the release path in CMakeLists.txt (PREFIX data
    # layout under share/cataclysm-bn); Debug would drop into dev mode
    # with binaries in the source dir and no install rules.
    cmakeBuildType = "RelWithDebInfo";

    # The test binary is a second output here, not a build-time suite
    # run: doCheck flips the cmake hook's -DBUILD_TESTING to ON (it
    # forces OFF otherwise, which silently drops the test target), while
    # the no-op checkPhase keeps the suite from running in the sandbox.
    # The calendar suite runs later as a flake check instead.
    doCheck = buildTests;
    checkPhase = ":";

    cmakeFlags = [
      "-DGIT_BINARY=${gitDescribe}/bin/cbn-git-describe"
      "-DTILES=${if tiles then "ON" else "OFF"}"
      "-DCURSES=${if tiles then "OFF" else "ON"}"
      "-DSOUND=${if sound then "ON" else "OFF"}"
      "-DTESTS=${if buildTests then "ON" else "OFF"}"
      "-DUSE_PREFIX_DATA_DIR=ON"
      "-DBUILD_SHADERCROSS=OFF"
      "-DCATA_CCACHE=OFF"
      "-DLIBBACKTRACE=ON"
      "-DJSON_FORMAT=OFF"
    ]
    ++ optionals useXdgDir [ "-DUSE_XDG_DIR=ON" ];

    # Configure never writes VERSION.txt (its git_describe finds no .git),
    # and the install rule ships the file, so write it here from the
    # flake revision. postConfigure runs in the build dir, so name the
    # source root explicitly. The dirty marker is dropped so the commit
    # link resolves.
    postConfigure = ''
      rev='${rev}'
      clean_rev="''${rev%-dirty}"
      printf 'build type: RelWithDebInfo\nbuild number: nix\ncommit sha: %s\ncommit url: https://github.com/cataclysmbn/Cataclysm-BN/commit/%s\n' "$clean_rev" "$clean_rev" > "$NIX_BUILD_TOP/$sourceRoot/VERSION.txt"
    '';

    # Registry mods and credits ship with every game output, the soundpack
    # only where sound is on. The game installs no desktop entry itself
    # (those CMake messages are leftovers nothing sets), so ship the
    # repo's files with Exec pointed at the store binary, tiles only: the
    # shipped entry launches the graphical build.
    postInstall = ''
      for d in ${registryMods}/mods/*/; do
        [ -e "$d" ] || continue
        ln -s "$d" $out/share/cataclysm-bn/mods/"$(basename "$d")"
      done
      # Credits match what the build ships: a soundless build gets the
      # mods-only list, the way release CI excludes soundpacks there.
      ln -s ${registryMods}/mods/${creditsFile} $out/share/cataclysm-bn/mods/${creditsFile}
    ''
    + lib.optionalString sound ''
      for d in ${registryMods}/sound/*/; do
        [ -e "$d" ] || continue
        ln -s "$d" $out/share/cataclysm-bn/sound/"$(basename "$d")"
      done
    ''
    + lib.optionalString tiles ''
      install -Dm644 ${src}/data/XDG/org.cataclysmbn.CataclysmBN.svg $out/share/icons/hicolor/scalable/apps/org.cataclysmbn.CataclysmBN.svg
      install -Dm644 ${src}/data/XDG/org.cataclysmbn.CataclysmBN.metainfo.xml $out/share/metainfo/org.cataclysmbn.CataclysmBN.metainfo.xml
      install -Dm644 ${src}/data/XDG/org.cataclysmbn.CataclysmBN.desktop $out/share/applications/org.cataclysmbn.CataclysmBN.desktop
      substituteInPlace $out/share/applications/org.cataclysmbn.CataclysmBN.desktop \
        --replace-fail "Exec=cataclysm-bn-tiles" "Exec=$out/bin/cataclysm-bn-tiles"
    ''
    + lib.optionalString buildTests ''
      # tests/CMakeLists.txt has no install rule, so fish the binary out
      # of the build tree. The test output ships only the binary; the
      # calendar check reads data from the game output.
      testBin=$(find "$NIX_BUILD_TOP" -name cata_test-tiles -type f | head -n 1)
      test -n "$testBin" || { echo "cata_test-tiles not found in build tree" >&2; exit 1; }
      install -Dm755 "$testBin" $test/bin/cata_test-tiles
    '';

    meta = {
      description = "Cataclysm: Bright Nights ${targetName} (${version})";
      homepage = "https://github.com/cataclysmbn/Cataclysm-BN";
      license = lib.licenses.cc-by-sa-30;
      platforms = lib.platforms.linux;
      mainProgram = targetName;
    };
  }
  // lib.optionalAttrs buildTests {
    # Second output of the same derivation: the game and the Catch2
    # binary come out of one cmake run, sharing the object files.
    outputs = [
      "out"
      "test"
    ];
  }
)
