#!/usr/bin/env bash
# Detect newer release tags for the tagged flake inputs (CDDA stable,
# CTLG dated tag) and bump the ref in flake.nix when one is found.
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

# --- CTLG dated tag (e.g. cataclysm-tlg-1.0-2026-10-16-0752) ---
current_ctlg=$(grep -o 'github:Cataclysm-TLG/Cataclysm-TLG/[^"]*' flake.nix | head -1 | sed 's#.*/##')
echo "CTLG current tag: $current_ctlg"
latest_ctlg=$(git ls-remote --tags https://github.com/Cataclysm-TLG/Cataclysm-TLG 2>/dev/null \
  | awk '{print $2}' | sed 's#refs/tags/##' | grep -E '^cataclysm-tlg-' | sort | tail -1)
echo "CTLG latest tag:  $latest_ctlg"
if [ -n "$latest_ctlg" ] && [ "$latest_ctlg" != "$current_ctlg" ]; then
  if [ "$latest_ctlg" \> "$current_ctlg" ]; then
    echo "Bumping CTLG tag: $current_ctlg -> $latest_ctlg"
    sed -i "s#github:Cataclysm-TLG/Cataclysm-TLG/$current_ctlg#github:Cataclysm-TLG/Cataclysm-TLG/$latest_ctlg#" flake.nix
  fi
fi
