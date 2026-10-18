# Turn a soundpack source tree into a game-ready soundpack.
#
# Unlike tilesets there is no compose step: packs ship as-is (a
# directory with soundpack.txt + JSON + audio, per TLG's doc/SOUNDPACKS.md
# inherited from CDDA). This builder just isolates <src>/<sourceDir>
# into $out, so the game merge only sees the pack itself and not the
# repo's docs/tools/template siblings. Single-level function (like
# ./package.nix) so callers use pkgs.callPackage with all non-nixpkgs
# arguments passed explicitly.
{
  lib,
  stdenv,
  # Pack name, e.g. "CC-Sounds" (used for $out layout docs)
  name,
  # Directory name the pack installs as under sound/, e.g. "CC-Sounds".
  installName ? name,
  # Source tree containing the pack; the pack lives at
  # <src>/<sourceDir> with soundpack.txt + soundset.json + audio dirs.
  src,
  sourceDir,
  version,
}:

stdenv.mkDerivation {
  pname = "tlg-soundpack-${lib.toLower (builtins.replaceStrings [ "+" "_" ] [ "-plus" "-" ] name)}";
  inherit version src;

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r "$src/${sourceDir}/." $out/
    runHook postInstall
  '';

  passthru = {
    # Directory name for installation under sound/.
    soundpackDir = installName;
  };

  meta = {
    description = "Cataclysm: The Last Generation soundpack ${name}";
    homepage = "https://github.com/Cataclysm-TLG/CTLG-Soundpacks";
    license = lib.licenses.cc-by-sa-40;
    platforms = lib.platforms.all;
  };
}
