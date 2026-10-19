# cataclysm.nix

Nix packaging for the Cataclysm family of roguelikes, living outside the game repos. Each
game is built through its own build system — the Makefile for CDDA and its forks, CMake
for BN, which dropped the Makefile — rather than reimplementing any of it.

```sh
nix run .#cdda-tiles          # CDDA, SDL + sound
nix run .#cdda-tiles-full     # ... with every composed tileset baked in
nix build .#cdda-tileset-retrodays
nix run .#tlg-tiles           # TLG, SDL2 + sound, art in-tree
nix run .#cbn-tiles           # BN, SDL3 + sound, registry mods included
```

Every game is a flake input, so `nix flake update` moves it forward like any other
input. There is no default package: outputs are prefixed per game (`cdda-*`, `tlg-*`,
`cbn-*`) so the forks coexist in one namespace.

## The chunks

| directory | game | why it lives here |
| --- | --- | --- |
| `cdda/` | Cataclysm: Dark Days Ahead | upstream doesn't take Nix packaging in-tree, and won't accept contributions from people who use LLMs at all (see CleverRaven/Cataclysm-DDA#87320 and #89051) |
| `tlg/` | Cataclysm: The Last Generation | a CDDA content fork with the same no-LLM policy |
| `cbn/` | Cataclysm: Bright Nights | a CDDA-family fork that does take AI-assisted contributions, but upstreaming a Nix flake means keeping it alive against a fast-moving CMake and release process; here it just tracks upstream and models builds on what upstream's own pipeline produces |

Each directory is a self-contained flake-parts chunk owning its derivations, pin tooling,
checks, dev shell and docs: `flake.nix` stays a thin root (inputs, systems, imports).

## Tracks

CDDA and BN each ship two tracks side by side, so a stable install and a bleeding-edge
install coexist in one store:

- `cdda-*` on the stable `0.I-1` tag (SDL2, in-tree art), `cdda-master-*` on upstream
  master (SDL3, art composed here from `CDDA-Tilesets`). The era only decides the SDL
  generation and whether composed tilesets merge into the bundle.
- `cbn-*` on the `v0.13.0` tag, `cbn-master-*` on BN's `master`. No era split needed:
  both are SDL3 and `gfx/` ships pre-composed in-tree.

TLG tracks dated release tags only; they update on their own cadence.

## Content pins

Game content that does not live in the game repo is pinned per chunk and refreshed by a
dedicated updater app, each with a mocked test suite running as a flake check:

- `nix run .#cdda-update-tilesets` — the 17-set tileset matrix, composed from source with
  `compose.py`, exactly as the game's own compose workflow does it.
- `nix run .#cdda-update-soundpacks` / `nix run .#tlg-update-soundpacks` — CC-Sounds.
- `nix run .#cbn-update-registry-mods` — the mod registry content and the Otopack
  soundpack, resolving archives to immutable urls.

All three are plan-first, backup, verify-after-write updaters; pass `--check` to preview
without touching anything.

See `cdda/README.md`, `tlg/README.md` and `cbn/README.md` for the full tours: packages,
checks, dev shells, pins.