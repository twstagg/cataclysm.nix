# cataclysm.nix

Nix packaging for Cataclysm: Dark Days Ahead that lives outside the game repo. It builds the game and composes all community tilesets from source, driving the project's own Makefile and compose.py instead of reimplementing either. Upstream doesn't seem to want to take Nix packaging in-tree, and they also seem to have an aversion to LLMs, as they do not accept contributions from people who use LLMs at all, even when used in minor cases, so it lives here (see CleverRaven/Cataclysm-DDA#87320 and CleverRaven/Cataclysm-DDA#89051).

```sh
nix run github:twstagg/cataclysm.nix#cdda-tiles-full   # SDL + sound, every tileset baked in
nix build github:twstagg/cataclysm.nix#cdda-tileset-retrodays
nix run github:twstagg/cataclysm.nix#cdda-master-tiles   # CDDA bleeding edge (SDL3)
```

The game itself comes from a flake input (`github:CleverRaven/Cataclysm-DDA`), so `nix flake update` moves it forward like any other input. Tileset sources stay pinned in `cdda/default.nix`, with `nix run .#cdda-update-tilesets` to bump them. See `cdda/README.md` for the full tour: packages, checks, dev shell, pins.

Layout: `flake.nix` is a thin root (inputs, systems, imports). One directory per game, each a self-contained flake-parts chunk owning its derivations, pin tooling, checks, and docs: `cdda/` holds `default.nix`, `package.nix`, `tileset.nix`, `soundpack.nix`, and `scripts/` with the two pin updaters and their test suites. CDDA ships two tracks side by side: `cdda-*` on the stable 0.I tag (SDL2, in-tree art) and `cdda-master-*` on upstream master (SDL3, composed art); sound (CC-Sounds) ships on both, from the game's own soundpack repo.