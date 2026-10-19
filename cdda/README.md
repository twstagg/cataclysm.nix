# Nix build

This flake packages Cataclysm: DDA from this checkout by driving the project's own `Makefile` (see `doc/c++/COMPILING.md`). Nix supplies the toolchain and dependencies; the Makefile remains the build system.

## Build & run

```sh
nix build .#cdda-tiles        # SDL tiles + sound (SDL2 for the
                         # stable 0.I pin, SDL3 for master / 0.J dev)
nix run .#cdda-tiles          # ...and run it
nix build .#cdda-curses       # ncurses text build
nix run .#cdda-curses
./result/bin/cataclysm-tiles --help
```

User files (config, saves) live in `~/.cataclysm-dda` by default; the derivation exposes `useXdgDir = true` for XDG placement.

```sh
nix develop .#cdda          # Makefile build deps + the compose toolchain
```

## Tests

```sh
nix build .#cdda-cata-test    # Catch2 test binary: the second output of
                              # cdda-tiles, not a separate build (make
                              # tests compiles cataclysm.a, the game
                              # links the same archive)
nix flake check          # builds everything + runs the [calendar] smoke suite
```

The smoke check runs `cata_test "[calendar]"` headless: the game data is symlinked as `./data` next to the binary (the layout upstream CI uses) and the run happens in a temp dir, since tests write logs/saves relative to the cwd. To run the full suite after building:

```sh
cd "$(mktemp -d)" && ln -s ../result/share/cataclysm-dda data   # adjust path
# or from the source tree (data/ is already there):
../result/bin/cata_test ~[slow]
```

## How it works

The game source is filtered per track (`gameSource` in `./default.nix`), so a
docs-only upstream commit leaves the store path unchanged and nothing rebuilds.

- `./package.nix`: one `stdenv.mkDerivation` covering all variants (`tiles`, `sound`, `buildTests` flags, plus `useSdl3` for the SDL major version). It mirrors nixpkgs' `pkgs/games/cataclysm-dda` shape, with no source patches. SDL follows the pinned game era: SDL2 for stable 0.I and older, SDL3 for master / 0.J dev (upstream dropped SDL2 on 2026-08-11; flip `useSdl3` in `./default.nix` when moving the input across that boundary):
  - `PREFIX=$out` is baked into the binary (`-DPREFIX -DDATA_DIR_PREFIX`), so data resolves to `$out/share/cataclysm-dda` and locales to `$out/share/locale`.
  - `LANGUAGES=all LOCALIZE=1` compiles every translation via `msgfmt`.
  - `BACKTRACE=1 LIBBACKTRACE=1 PCH=0 LINTJSON=0` mirror the release CI line (`make TILES=.. SOUND=.. RELEASE=1 LOCALIZE=1 LANGUAGES=all BACKTRACE=1 LIBBACKTRACE=.. PCH=0 bindist`): crash backtraces via libbacktrace, precompiled headers off. `LINTJSON=0` matches CI's effect of building `bindist` (which skips the JSON style gate; in a Nix build that gate could only fail, since the read-only source cannot be auto-fixed).
  - Tiles builds compile GLSL shaders to SPIR-V with `glslangValidator` (`tools/build_shaders.py`); macOS/Windows formats are not produced.
- `./default.nix`: the chunk's flake-parts module. A `mkEra` factory instantiates both tracks (`stable` and `master`, each with its own input, SDL generation, version prefix, and tileset-bundling policy), then contributes `packages.cdda-*` and `packages.cdda-master-*`, the shared tileset attrset, a `devShells.default`, and the checks.

## Tuning

```sh
nix build .#packages.x86_64-linux.curses.overrideAttrs (_: { dontStrip = false; })
```

or import `./package.nix` directly via `pkgs.callPackage` with the flags you want (`debug`, `useXdgDir`, `tiles`, `sound`, `buildTests`, `extraTilesets`).

## Tilesets

All community tilesets are composed from source with `tools/gfx_tools/compose.py`, same as `.github/workflows/compose-tilesets.yml`: same per-set flags, `--format-json --feedback CONCISE --loglevel INFO`, same strictness (compose errors fail the build). Sources are lean sparse checkouts, not a whole-repo mirror.

```sh
nix build .#cdda-tileset-retrodays     # one of 17: see ./default.nix tilesetMatrix
nix build .#cdda-tiles-full            # game with every set baked into
                                   # share/cataclysm-dda/gfx (release equivalent),
                                   # plus CC-Sounds (see Soundpacks below)
nix build .#checks.x86_64-linux.cdda-tilesets-validate   # structural check of all sets
```

Use a set standalone by linking it into the user gfx dir. The game
looks in user gfx first, same as installing by hand:

```sh
ln -s ./result ~/.cataclysm-dda/gfx/Retrodays
```

### How it works

- `./tileset.nix`: generic builder. Runs compose under `python3 + pyvips`, then assembles `$out` (`tile_config.json` + composited sheets + `tileset.txt`/`fallback.png`/`layering.json` moved alongside, like the workflow). Per-set flags come from the `tilesetMatrix` table in `./default.nix`.
- `packages.json-formatter`: `json_formatter.cgi` built with the exact make target the workflow uses; staged where compose's CWD-relative lookup finds it, so output bytes match upstream releases.
- `checks.cdda-tilesets-validate`: every set must parse with non-empty `tiles-new`, and every referenced sheet file must exist. (This gate caught a real unloadable set, see below.)
- `checks.cdda-tileset-discovery`: game-state init with a composed pack in `gfx/`, proving discovery without tripping assertions.

### Sets that need work

- **IsoMSX+**: broken at the pinned rev. Its JSON names seasonal sprites nobody ever drew, so compose exits 1. Commented out with a NOTE; filing upstream is tracked work.
- **Mushroom-Dream**: composes fine but ships no `fallback.png`, and the loader opens every `tiles-new` file under an assert. Trialed in-game: fails to load as predicted. Commented out with a NOTE; upstream issue still TODO.

### Updating tileset pins

Revs + hashes live in `./default.nix` (`tilesetsSrc`, `cuteclysmSrc`). Bump
them with the updater app (pinned-by-default, fresh-on-demand):

```sh
nix run .#cdda-update-tilesets -- --check   # compare current vs HEAD, no changes
nix run .#cdda-update-tilesets              # bump stale pins, verifying hashes
```

The updater reads HEAD with `git ls-remote`, puts the new rev in with
a throwaway hash, and takes the verified `got:` hash back out of a
probe build. The probe dies fetching, so updating never compiles
anything. To put it plainly: evaluation reads expressions, fetching
downloads sources, compilation turns sources into outputs, and the
updater stops after fetching. Sources already at HEAD get skipped.
Then run `nix flake check --no-build`, look over the diff, and commit.

How it stays safe: it resolves every HEAD and works out the whole plan before writing anything. Writes go through a backup (put back on any failure) plus a re-read at the end to confirm. Probe output has to hold exactly one good hash or the run stops and shows you the output. A leftover placeholder hash from a killed run gets repaired, not skipped. `nurl` stays out on purpose: it hashes whole repos and these pins hash sparse subtrees, so its hashes would fail every build.

`./scripts/test-update-tilesets.sh` tests the updater with mocked git/nix (skip, update, sparse preservation, bad diagnostics, fetch failures, interrupted runs, ambiguous output, surprise success) and runs as `checks.cdda-updater-tests` with no network or builds.

Bump when tilesets go stale: new game content without matching sprites falls back to ASCII/unknown glyphs in-game.

## Soundpacks

What ships where depends on the game era (`gameEra` in `./default.nix`):

Two upstream tracks are packaged side by side, not behind a switch:

| Track | Outputs | Game pin | SDL | Tilesets | Sound in-tree | Sound bundled |
|-------|---------|----------|-----|----------|---------------|---------------|
| stable 0.I | `cdda-*` | tag `0.I-1` (bump by editing the ref) | SDL2 | 17 sets pre-composed in `gfx/`, used as-is and never merged over (merging would duplicate tileset NAMEs) | `Basic` (menu clicks) | CC-Sounds |
| master 0.J dev | `cdda-master-*` | `master` branch (`nix flake update`) | SDL3 (upstream went SDL3-only on 2026-08-11) | decoupled upstream; composed here via `tilesetMatrix` and merged into `gfx/` | `Menu_Sound_Test` (test clicks) | CC-Sounds |

```sh
nix build .#cdda-tiles           # stable release track
nix build .#cdda-master-tiles    # bleeding edge, follows master
nix flake update                 # moves the master track only
```

Checks (calendar smoke, tileset discovery, validation) run against the stable track; `cdda-master-cata-test` is exposed for anyone who wants the test binary on the dev track.

Both eras bundle CC-Sounds (`Fris0uman/CDDA-Soundpacks`, `sound/CC-Sounds`, music via submodule) into every sound-enabled package, mirroring `release.yml`'s "Get soundpack" step. Unlike tilesets there is no compose step: `./soundpack.nix` just isolates the pack subtree into `$out`, and `extraSoundpacks` in `./package.nix` merges it into `share/cataclysm-dda/sound/` next to the in-tree pack, using the same merge idiom as `extraTilesets`.

```sh
nix build .#cdda-soundpack-cc-sounds
nix run .#cdda-update-soundpacks -- --check   # compare current vs HEAD, no changes
nix run .#cdda-update-soundpacks              # bump the pin, verifying the hash
nix build .#checks.x86_64-linux.cdda-soundpacks-validate   # every pack has soundpack.txt
```

A stale soundpack is benign, unlike stale art: unknown sound ids never trigger, so new content just stays silent until the pin catches up. And players can always drop packs into the user sound dir (`~/.cataclysm-dda/sound/`), which the game scans before the shipped `data/sound/`. The flake bundling is release parity and convenience, not a requirement.

The TLG chunk under `../tlg` packages the CDDA fork "The Last Generation" with its own soundpack repo; see `../tlg/README.md`.
