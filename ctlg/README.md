# TLG chunk: Cataclysm: The Last Generation

TLG is a story-focused content fork of CDDA sharing its Makefile build system. It lives in this self-contained chunk (`./default.nix` module + `./package.nix`), sibling of the CDDA chunk under `../cdda`. Upstream keeps Nix packaging out of tree for the same reason CDDA does: a no-LLM contribution policy.

```sh
nix run .#ctlg-tiles       # SDL3 tiles + sound (CC-Sounds bundled)
nix develop .#ctlg         # Makefile build deps (SDL3)
```

Differences from the CDDA chunk, all verified against the fork:

- **Game pin**: the `cataclysm-tlg` input (declared in the root flake) points at a dated release tag (`cataclysm-tlg-1.0-<date>`). Tags are immutable, so `nix flake update` keeps it steady; bump by editing the ref there.
- **SDL3 tiles backend, no curses**: TLG gained an SDL2/SDL3 dual build in its 2026-10-31 backport, but the same backport broke both legacy paths: the SDL2 path references the SDL3-only `SDL_FlipMode` type (`sdl_wrappers.h`/`cata_tiles.cpp`), and `sdlsound.cpp` lost its `#if defined(SDL_SOUND)` guard (commit `6c132f58b3`), so a no-SDL build cannot compile. Upstream does not notice: `matrix.yml` (the curses jobs) and `release.yml` are `workflow_dispatch`-only, and the only push-triggered workflow (`sdl3-matrix.yml`) builds `TILES=1 SDL3=1 SOUND=1` alone. This chunk follows that: `SDL3=1` tiles+sound, and `ctlg-curses` is dropped until upstream restores the guard.
- **Tilesets ship pre-composed in-tree** (12 sets in `gfx/`, synced from `CTLG-Tilesets` releases by upstream CI). Nothing to compose, nothing to merge.
- **Version comes from the CWD, not the compiler**: TLG reads its version at runtime from a CWD-relative `VERSION.txt` (`src/version.cpp`, which returns the literal `unknown` when the file is missing). The `VERSION=` makeFlag that CDDA and BN rely on is inert for TLG: the fork commented out that code path and its Makefile never passes `-DVERSION`. `make install` writes no `VERSION.txt`, and upstream's own CWD contract is satisfied only by `cataclysm-launcher` (`cd "$(dirname $0)"` before exec), which `make install` does not install. So `package.nix` writes `share/cataclysm-tlg/VERSION.txt` from the flake pin and runs the game from that directory with `wrapProgram --chdir` — upstream's launcher trick, no patch, and the binary keeps its name and path. Skip it and the banner, window title, `--version`, memorial headers and crash logs all read `unknown`.
- **No test binary**: the Catch2 suite was stripped at fork time, so there is no `ctlg-test` and no calendar smoke. The TLG checks are `ctlg-json-check` (builds the game's `chkjson` and runs the real loader over `data/json`) and `ctlg-soundpacks-validate` (manifest gate).
- **Own soundpack repo**: `Cataclysm-TLG/CTLG-Soundpacks` (same `sound/CC-Sounds` layout, music via the `CTLG-Music-Packs` submodule), bundled into `ctlg-tiles` the way release CI does.
- **Filtered source**: `gameSource` drops `docs/`, `.git` and `.github/`, so a
  docs-only upstream commit does not invalidate the build.
- **User files**: `~/.cataclysm-tlg/` (XDG via the `useXdgDir` flag). The binary is `cataclysm-tlg-tiles`, so the games coexist without collisions.

## Soundpacks

```sh
nix build .#ctlg-soundpack-cc-sounds
nix flake update ctlg-soundpacks   # moves the CTLG-Soundpacks pin (now a flake input)
nix build .#checks.x86_64-linux.ctlg-soundpacks-validate
```

CTLG-Soundpacks is now a flake input (see root `flake.nix`), so `nix flake update` bumps it and no probe-hash updater remains. A stale pack is benign: unknown sound ids never trigger, so new content just stays silent until the pin catches up.

## How it works

- `./package.nix`: `stdenv.mkDerivation` for `tiles`/`sound` (SDL3 stack: `sdl3`/`sdl3-image`/`sdl3-ttf`/`sdl3-mixer` + `freetype`, ncurses branch kept for a future curses revival), `PREFIX` baked in, `LANGUAGES=all LOCALIZE=1`, no patches. `BACKTRACE=1 LIBBACKTRACE=1 PCH=0 LINTJSON=0` mirror TLG's release CI line (libbacktrace crash backtraces, PCH off, no JSON style gate: TLG release tags ship non-canonical JSON and the gate could not auto-fix a read-only source anyway). `extraSoundpacks` merges packs into `share/cataclysm-tlg/sound/` with the same mkdir+cp idiom CDDA uses. `postInstall` writes the `VERSION.txt` the banner reads and `postFixup` runs the game from the data dir (`wrapProgram --chdir`) so that file is in the CWD.
- `./default.nix`: game input handling (`version = "1.0+" + shortRev`), the CTLG-Soundpacks pin, `ctlg-json-formatter` and `ctlg-chkjson` (the `chkjson` target does not link as shipped: its `CHKJSON_SOURCES` omits `src/string_id.cpp`, so the derivation adds the TU with a make override), packages `ctlg-tiles`/`ctlg-json-formatter`/`ctlg-chkjson`/`ctlg-soundpack-cc-sounds`, and checks. Soundpacks are now a flake input (see root `flake.nix`).
- `./soundpack.nix`: isolates the pack subtree into `$out` (no compose step, packs ship as-is).
