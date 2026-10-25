#!/usr/bin/env bash
# Build the Nix Cache publish matrix from the flake's package set.
#
# Buckets:
#   - one job per game-compile package (the GAME_ATTRS list below: a
#     full C++ build gets its own runner, and adding a track variant
#     is a deliberate one-line edit — an attr that is neither listed
#     nor pattern-matched FAILS the planner, so a new package can
#     never silently ride along in the wrong bucket or skip CI),
#   - one job for every *-tileset-* pack (compose-only, shared deps),
#   - one job for the remaining content builds (json formatters,
#     soundpacks, BN registry archives, chkjson).
#
# Usage:
#   scripts/ci-matrix.sh [flake-url]        # eval the flake (default .)
#   scripts/ci-matrix.sh --attrs-json FILE  # attr list from a JSON array
#                                           # (test seam; keeps the
#                                           # classification logic
#                                           # exercisable without eval)
#
# Output: compact JSON on stdout, one entry per publish job:
#   [{"group":"cdda-tiles","packages":".#cdda-tiles"},...]
# Feed to GHA as a matrix include list (see nix-cache.yml).
set -euo pipefail

# Full game compiles: one runner each. Keep in sync with the flake's
# game packages; the planner exits 1 on any flake attr it cannot
# classify, and on any listed attr the flake no longer provides.
GAME_ATTRS=(
  cdda-tiles
  cdda-curses
  cdda-cata-test
  cdda-tiles-full
  cdda-master-tiles
  cdda-master-curses
  cdda-master-cata-test
  cdda-master-tiles-full
  cbn-tiles
  cbn-curses
  cbn-cata-test
  cbn-master-tiles
  cbn-master-curses
  cbn-master-cata-test
  ctlg-tiles
  ctlg-curses
)

# Naming-convention patterns for the grouped buckets. New tilesets and
# new content packs slot in automatically; new *game builds* must be
# listed above on purpose.
TILESET_RE='-tileset-'
CONTENT_RE='-(json-formatter|chkjson|registry-mods)$|-soundpack-'

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

case "${1:-}" in
  -h | --help) usage 0 ;;
esac

if [[ "${1:-}" == "--attrs-json" ]]; then
  [[ -r "${2:?--attrs-json needs a file}" ]] || usage 1
  attrs_json=$(jq -S 'sort' <"$2")
else
  flake="${1:-.}"
  attrs_json=$(nix eval "$flake#packages.x86_64-linux" \
    --apply 'p: builtins.attrNames p' --json | jq -S 'sort')
fi

declare -A seen=()
game_groups=()
tilesets=()
content=()
unknown=()

while IFS= read -r attr; do
  [[ -n "$attr" ]] || continue
  seen["$attr"]=1
  for g in "${GAME_ATTRS[@]}"; do
    if [[ "$attr" == "$g" ]]; then
      game_groups+=("$attr")
      continue 2
    fi
  done
  if [[ "$attr" =~ $TILESET_RE ]]; then
    tilesets+=("$attr")
  elif [[ "$attr" =~ $CONTENT_RE ]]; then
    content+=("$attr")
  else
    unknown+=("$attr")
  fi
done < <(jq -r '.[]' <<<"$attrs_json")

# Every listed game attr must still exist: dropping a package from the
# flake without dropping it here should fail at plan time, not as a
# missing-attr error in eighteen publish jobs.
for g in "${GAME_ATTRS[@]}"; do
  if [[ -z "${seen[$g]:-}" ]]; then
    echo "ci-matrix: GAME_ATTRS lists '$g' but the flake does not provide it" >&2
    exit 1
  fi
done

if ((${#unknown[@]})); then
  echo "ci-matrix: unclassified package attrs (add to GAME_ATTRS or a bucket pattern):" >&2
  printf '  %s\n' "${unknown[@]}" >&2
  exit 1
fi

# Build the matrix: one entry per game attr, plus the two grouped
# entries. packages is a prebuilt ".#attr" argument string so the
# workflow can splice it straight into nix build.
entries=()
for g in "${game_groups[@]}"; do
  entries+=("$(jq -nc --arg g "$g" --arg p ".#$g" '{group: $g, packages: $p}')")
done
join_args() {
  printf '%s\n' "$@" | jq -Rsr 'split("\n") | map(select(. != "")) | map(".#" + .) | join(" ")'
}
if ((${#tilesets[@]})); then
  entries+=("$(jq -nc --arg p "$(join_args "${tilesets[@]}")" \
    '{group: "tilesets", packages: $p}')")
fi
if ((${#content[@]})); then
  entries+=("$(jq -nc --arg p "$(join_args "${content[@]}")" \
    '{group: "content", packages: $p}')")
fi

printf '%s\n' "${entries[@]}" | jq -sc 'sort_by(.group)'
