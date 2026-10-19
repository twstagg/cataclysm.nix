# CBN chunk: Cataclysm: Bright Nights

Nix packaging for [Cataclysm: Bright Nights](https://github.com/cataclysmbn/Cataclysm-BN),
kept here rather than upstream. BN is a CDDA-family fork (it dropped the Makefile for
CMake) and it is happy to take AI-assisted contributions — an in-tree flake was submitted
and reviewed there — but upstreaming it means keeping it alive against a fast-moving CMake
setup and release process. Here it tracks upstream as an ordinary flake input and the
packaging evolves on its own schedule. Nothing is lost either way: builds are modelled on
what upstream's own release pipeline produces.

```sh
nix run .#cbn-tiles           # SDL3 + sound, the stable v0.13.0 tag
nix run .#cbn-curses          # ncurses text build
nix build .#cbn-master-tiles  # development branch
nix build .#cbn-cata-test
```

## Tracks

Two tracks, packaged side by side so a stable install and a bleeding-edge install coexist
in one store:

| package prefix | input | notes |
| --- | --- | --- |
| `cbn-*` | `cataclysm-bn` | the `v0.13.0` release tag; bump the ref in `flake.nix` for a new release |
| `cbn-master-*` | `cataclysm-bn-master` | the `master` branch; `nix flake update cataclysm-bn-master` moves it |

Unlike CDDA there is no era split to encode. Both tracks are SDL3, and `gfx/` ships
pre-composed in-tree, so a track differs only by its pin. The banner version is read out
of `flake.lock` rather than hardcoded: a tag pin yields its tag, a branch pin falls back
to `master+<rev>`.

The source is filtered per track, so a docs-only upstream commit leaves the store path
unchanged and nothing rebuilds.

## Packages

- `cbn-tiles` / `cbn-master-tiles` — SDL3 + sound game, the default.
- `cbn-curses` / `cbn-master-curses` — ncurses text build, no sound.
- `cbn-cata-test` / `cbn-master-cata-test` — the Catch2 binary, which is the *second
  output of the tiles derivation*, not a separate build: one cmake run produces both.
- `cbn-registry-mods` — the registry bundle on its own (see below).

## Registry mods and the Otopack soundpack

Release builds bundle the mod-registry content listed in the game's
`data/mods/external.json`: external mods into `data/mods`, soundpacks into `data/sound`.
`./registry-mods.nix` reproduces that bundle as a pure derivation, mirroring the
extract, marker-file and credits semantics of the game's own
`build-scripts/bundle-registry-mods.ts`.

Two deliberate differences from a release build:

- **Registry metadata is vendored**, not fetched. `mods.json` is regenerated constantly,
  so hashing a live URL breaks evaluation of the whole flake rather than just this
  derivation. `./registry-mods.json` is a small generated snapshot (only the fields the
  bundle reads, keyed by id) that a deliberate commit refreshes.
- **Archives resolve to immutable urls.** The lockfile points at branch archives on
  master, which move on every upstream push. `resolveUrl` prefers an already-immutable url
  in order: the lockfile's own (the `v0.13.0` tag pins archives by commit — exactly what
  that release shipped), then the registry's recorded commit, then its tag url. Only a
  branch url with nothing better recorded falls through to the moving one.

Both tracks lock the same nine entries, so the bundle is built once and shared. The two
lockfiles legitimately differ in url *form* (tag pins by commit, master tracks branches),
which is exactly why resolution happens in one place; the updater compares the parts that
matter (mod set and extract paths) and refuses to continue if those ever diverge.

`--check-mods` therefore validates the bundled registry content too, and
`cbn-soundpacks-validate` asserts every bundled pack carries a manifest.

## Updating the registry pins

```sh
nix run .#cbn-update-registry-mods -- --check   # preview, writes nothing
nix run .#cbn-update-registry-mods              # rewrite pins + snapshot
```

Plan first, then apply: the updater resolves every hash, prints the plan, keeps a backup,
and re-reads both files afterwards; any failure restores the backup via a trap. Run
`nix flake check` and review the diff before committing. Its mocked suite
(`scripts/test-update-registry-mods.sh`, 14 cases) runs as the `cbn-updater-tests` check,
including two that exercise the restore and post-write-verification paths through
documented fault injection.

Run it alongside `nix flake update cataclysm-bn` when moving the game pin: the lockfile
the bundle reads lives in the pinned game source, so the two move together.

## Checks

- `cbn-calendar-test` — the calendar suite headless. The test output starts with an empty
  base path, so the check links `./data`, `./gfx` and `./lang/mo` out of the game package;
  it runs in a temp dir because non-`[nogame]` tests boot a game state and write under
  cwd. `CATA_TEST_COMPUTE_ACCELERATION=cpu` because the sandbox has no GPU, not even
  software Vulkan.
- `cbn-check-mods` — `--check-mods` over the game data and the bundled registry mods.
- `cbn-soundpacks-validate` — every bundled pack has its manifest.
- `cbn-updater-tests` — the updater suite, mocked, no network.

## Requirement differences from an upstream build

- System SDL3 and shadercross from nixpkgs. The vendored `BUILD_SDL3` / `BUILD_SHADERCROSS`
  fetches need network and cannot work in the sandbox. The curses build still needs system
  SDL3 for GPU platform services (`CATA_SDL`).
- clang 22 from `llvmPackages_22`, which the docs build requires.
- `libbacktrace` from nixpkgs (`LIBBACKTRACE=ON`), same as CI, so crash traces keep line
  info. No ccache: nothing persists between sandbox builds.
- The banner needs a stand-in git: the version comes from CMake's own git calls, which
  cannot work without a `.git` directory. See `./package.nix`.