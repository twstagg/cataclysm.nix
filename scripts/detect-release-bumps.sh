#!/usr/bin/env bash
# Detect newer release tags for the tagged flake inputs (CDDA stable,
# TLG dated tag) and bump the ref in flake.nix when one is found.
# Prints what changed; exits 0 either way.
set -uo pipefail

cd "$(dirname "$0")/.."

# --- CDDA stable tag (e.g. 0.I-1) ---
current_cdda=$(grep -o 'github:CleverRaven/Cataclysm-DDA/[^"]*' flake.nix | head -1 | sed 's#.*/##')
echo "CDDA current tag: $current_cdda"
latest_cdda=$(git ls-remote --tags https://github.com/CleverRaven/Cataclysm-DDA 2>/dev/null \
  | awk '{print $2}' | sed 's#refs/tags/##' | grep -E '^0\.[A-Z]-[0-9]+$' | sort -V | tail -1)
echo "CDDA latest tag:  $latest_cdda"
if [ -n "$latest_cdda" ] && [ "$latest_cdda" != "$current_cdda" ]; then
  if [ "$(printf '%s\n%s\n' "$current_cdda" "$latest_cdda" | sort -V | tail -1)" = "$latest_cdda" ]; then
    echo "Bumping CDDA stable tag: $current_cdda -> $latest_cdda"
    sed -i "s#github:CleverRaven/Cataclysm-DDA/$current_cdda#github:CleverRaven/Cataclysm-DDA/$latest_cdda#" flake.nix
  fi
fi

# --- TLG dated tag (e.g. cataclysm-tlg-1.0-2026-10-16-0752) ---
current_tlg=$(grep -o 'github:Cataclysm-TLG/Cataclysm-TLG/[^"]*' flake.nix | head -1 | sed 's#.*/##')
echo "TLG current tag: $current_tlg"
latest_tlg=$(git ls-remote --tags https://github.com/Cataclysm-TLG/Cataclysm-TLG 2>/dev/null \
  | awk '{print $2}' | sed 's#refs/tags/##' | grep -E '^cataclysm-tlg-' | sort | tail -1)
echo "TLG latest tag:  $latest_tlg"
if [ -n "$latest_tlg" ] && [ "$latest_tlg" != "$current_tlg" ]; then
  if [ "$latest_tlg" \> "$current_tlg" ]; then
    echo "Bumping TLG tag: $current_tlg -> $latest_tlg"
    sed -i "s#github:Cataclysm-TLG/Cataclysm-TLG/$current_tlg#github:Cataclysm-TLG/Cataclysm-TLG/$latest_tlg#" flake.nix
  fi
fi
