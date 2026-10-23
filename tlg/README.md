# TLG chunk: Cataclysm: The Last Generation

TLG is a story-focused content fork of CDDA sharing its Makefile build system. It lives in this self-contained chunk (`./default.nix` module + `./package.nix`), sibling of the CDDA chunk under `../cdda`. Upstream keeps Nix packaging out of tree for the same reason CDDA does: a no-LLM contribution policy.

```sh
nix run .#tlg-tiles       # SDL2 tiles + sound (CC-Sounds bundled)
nix run .#tlg-curses      # ncurses text build
nix develop .#tlg         # Makefile build deps (SDL2 era)
```

Differences from the CDDA chunk, all verified against the fork:

- **Game pin**: the `cataclysm-tlg` input (declared in the root flake) points at a dated release tag (`cataclysm-tlg-1.0-<date>`). Tags are immutable, so `nix flake update` keeps it steady; bump by editing the ref there.
- **SDL2 only**: no era switch. TLG predates CDDA's SDL3 switch and has no vendored imgui (the `libx11` fix for `SDL_syswm.h` headers still applies).
- **Tilesets ship pre-composed in-tree** (12 sets in `gfx/`, synced from `CTLG-Tilesets` releases by upstream CI). Nothing to compose, nothing to merge.
- **Version comes from the CWD, not the compiler**: TLG reads its version at runtime from a CWD-relative `VERSION.txt` (`src/version.cpp`, which returns the literal `unknown` when the file is missing). The `VERSION=` makeFlag that CDDA and BN rely on is inert for TLG: the fork commented out that code path and its Makefile never passes `-DVERSION`. `make install` writes no `VERSION.txt`, and upstream's own CWD contract is satisfied only by `cataclysm-launcher` (`cd "$(dirname $0)"` before exec), which `make install` does not install. So `package.nix` writes `share/cataclysm-tlg/VERSION.txt` from the flake pin and runs the game from that directory with `wrapProgram --chdir` — upstream's launcher trick, no patch, and the binary keeps its name and path. Skip it and the banner, window title, `--version`, memorial headers and crash logs all read `unknown`.
- **No test binary**: the Catch2 suite was stripped at fork time, so there is no `tlg-test` and no calendar smoke. The TLG checks are `tlg-json-check` (builds the game's `chkjson` and runs the real loader over `data/json`), `tlg-soundpacks-validate` (manifest gate) and `tlg-version-banner` (the game reports the flake revision, not `unknown`).
- **Own soundpack repo**: `Cataclysm-TLG/CTLG-Soundpacks` (same `sound/CC-Sounds` layout, music via the `CTLG-Music-Packs` submodule), bundled into `tlg-tiles` the way release CI does.
- **Filtered source**: `gameSource` drops `docs/`, `.git` and `.github/`, so a
  docs-only upstream commit does not invalidate the build.
- **User files**: `~/.cataclysm-tlg/` (XDG via the `useXdgDir` flag). Binaries are `cataclysm-tlg`/`cataclysm-tlg-tiles`, so both games coexist without collisions.

## Soundpacks

```sh
nix build .#tlg-soundpack-cc-sounds
nix run .#tlg-update-soundpacks -- --check   # compare current vs HEAD, no changes
nix run .#tlg-update-soundpacks              # bump the pin, verifying the hash
nix build .#checks.x86_64-linux.tlg-soundpacks-validate
```

`./scripts/update-soundpacks.sh` is the same probe-hash updater the CDDA chunk uses, scoped to the TLG pin in `./default.nix`; `./scripts/test-update-soundpacks.sh` is its mocked suite (7 cases, no network or builds), wired as `checks.tlg-updater-soundpacks-tests`. A stale pack is benign: unknown sound ids never trigger, so new content just stays silent until the pin catches up.

## How it works

- `./package.nix`: `stdenv.mkDerivation` for `tiles`/`sound` (SDL2 stack with `libx11` for the `SDL_syswm.h` chain, ncurses otherwise), `PREFIX` baked in, `LANGUAGES=all LOCALIZE=1`, no patches. `BACKTRACE=1 LIBBACKTRACE=1 PCH=0 LINTJSON=0` mirror TLG's release CI line (libbacktrace crash backtraces, PCH off, no JSON style gate: TLG release tags ship non-canonical JSON and the gate could not auto-fix a read-only source anyway). `extraSoundpacks` merges packs into `share/cataclysm-tlg/sound/` with the same mkdir+cp idiom CDDA uses. `postInstall` writes the `VERSION.txt` the banner reads and `postFixup` runs the game from the data dir (`wrapProgram --chdir`) so that file is in the CWD.
- `./default.nix`: game input handling (`version = "1.0+" + shortRev`), the CTLG-Soundpacks pin, `tlg-json-formatter` and `tlg-chkjson` (the `chkjson` target does not link as shipped: its `CHKJSON_SOURCES` omits `src/string_id.cpp`, so the derivation adds the TU with a make override), packages `tlg-tiles`/`tlg-curses`/`tlg-json-formatter`/`tlg-chkjson`/`tlg-soundpack-cc-sounds`, checks, and the `tlg-update-soundpacks` app.
- `./soundpack.nix`: isolates the pack subtree into `$out` (no compose step, packs ship as-is).
