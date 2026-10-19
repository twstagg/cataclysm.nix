#!/usr/bin/env bash
# Refresh the registry-mod snapshot and pins.
#
# Usage: update-registry-mods.sh [--check]
#   (no args)  fetch the live registry, write nix/registry-mods.json,
#              resolve urls through it, re-prefetch every archive, and
#              rewrite the pins in ./registry-mods.nix
#   --check    report what would change without writing anything
#
# What is pinned and why: data/mods/external.json (the lockfile) lives in
# the repo and is read live, so new entries are detected, not skipped.
# Registry metadata is vendored to nix/registry-mods.json rather than
# pinned by hash, because the live mods.json is regenerated often and a
# hash pin on it breaks evaluation of the whole flake. Archives are
# fetched from the registry's immutable urls (tag, or the recorded
# commit) where available, so a pin stops breaking on unrelated upstream
# pushes; see resolve_url below.
#
# Cost model: fetching only downloads the registry JSON into a temp file
# and pulls archives into the store. Nothing here compiles project code;
# the game rebuild happens on the next `nix build` as usual.
#
# Safety: phase 1 resolves everything and computes the whole plan before
# writing. Phase 2 backs both files up, writes them, and re-reads both to
# confirm; any failure restores the backup via trap.
set -euo pipefail

REGISTRY_URL="https://mods.cataclysmbn.org/generated/mods.json"
NIX_FILE="cbn/registry-mods.nix"
SNAPSHOT_FILE="cbn/registry-mods.json"
# The lockfile ships with the game, not with this repo. The flake bakes
# the pinned path in; the default keeps the script runnable from a game
# checkout for debugging.
LOCK_FILE="${LOCK_FILE:-data/mods/external.json}"
# Second track's lockfile, when the caller passes one. Both tracks lock
# the same entries today; if they ever diverge, bundling one silently
# would ship content the other track's game does not expect, so stop.
MASTER_LOCK_FILE="${MASTER_LOCK_FILE:-}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cd "$(git rev-parse --show-toplevel)"
CHECK_ONLY=0
case "${1-}" in
  "") ;;
  --check) CHECK_ONLY=1 ;;
  *) die "unknown argument '$1' (expected no arguments or --check)" ;;
esac
[ "$#" -le 1 ] || die "too many arguments (expected no arguments or --check)"

is_sri_hash() {
  [[ "$1" =~ ^sha256-[A-Za-z0-9+/]{43}=$ ]]
}

current_hash() {
  local line
  line="$(grep -o "\"$1\" = \"sha256-[A-Za-z0-9+/=]*\"" "$NIX_FILE" | head -n 1)" || true
  [ -n "$line" ] || return 0
  printf '%s\n' "$line" | grep -o 'sha256-[A-Za-z0-9+/=]*'
}

# Print the verified hash for a URL, or die. Never guesses: fetch and
# parse failures and malformed hashes are hard errors with the URL.
prefetch() {
  local url="$1" out hash
  out="$(nix store prefetch-file --json "$url")" || die "prefetch failed for $url"
  hash="$(printf '%s\n' "$out" | jq -r '.hash // empty')" \
    || die "cannot parse prefetch output for $url"
  if ! is_sri_hash "$hash"; then
    die "malformed hash for $url: $hash"
  fi
  printf '%s\n' "$hash"
}

# Filter the live registry down to what the bundle consumes, keyed by id
# and sorted. Mirrors the shape ./registry-mods.nix reads.
snapshot_from_registry() {
  jq -S --slurpfile lock "$LOCK_FILE" '
    ($lock[0] | map(.id)) as $ids
    | [ .[] | select(.id as $i | $ids | index($i)) ]
    | sort_by(.id)
    | map({key: .id, value: {
        version: .version,
        package_type: (.package_type // "mod"),
        display_name: .display_name,
        homepage: (.homepage // "unknown"),
        license: (.license // "unknown"),
        source: {
          url: .source.url,
          commit_sha: (.source.commit_sha // null),
          extract_path: (.source.extract_path // null)
        }
      }})
    | from_entries
  ' "$1"
}

# Mirror of resolveUrl in ./registry-mods.nix, in order: the lockfile's
# own url when it is already immutable (a release tag pins archives by
# commit), then the registry's recorded commit, then the registry's tag
# url. Empty output means nothing immutable is available and the caller
# falls back to the lockfile url.
resolve_url() {
  local id="$1" snap="$2"
  local lock_url
  lock_url="$(url_of "$id")"
  jq -r --arg id "$id" --arg lock "$lock_url" '
    def moving: contains("/refs/heads/");
    (.[$id].source // {}) as $s
    | if ($lock | moving) | not then $lock
      elif (($s.url // "") | length) == 0 then $lock
      elif (($s.url | split("/archive/") | length) == 2) and (($s.commit_sha // "") | length) > 0
        then (($s.url | split("/archive/"))[0]) + "/archive/" + $s.commit_sha + ".zip"
      elif ($s.url | moving) | not then $s.url
      else $lock
      end
  ' "$snap"
}

# Phase 1: resolve everything and compute the plan. No writes.
[ -f "$LOCK_FILE" ] || die "no $LOCK_FILE"
[ -f "$NIX_FILE" ] || die "no $NIX_FILE"

if [ -n "$MASTER_LOCK_FILE" ]; then
  [ -f "$MASTER_LOCK_FILE" ] || die "no $MASTER_LOCK_FILE"
  # Compare what the bundle actually consumes, not the raw files: the
  # tracks legitimately differ in url form (v0.13.0 pins archives by
  # commit, master tracks branches) while resolving to the same bytes.
  # A difference in the mod set or an extract path is a real divergence.
  lock_shape() {
    jq -S '[.[] | {id, extract_path}]' "$1"
  }
  if ! diff -q <(lock_shape "$LOCK_FILE") <(lock_shape "$MASTER_LOCK_FILE") >/dev/null; then
    die "the stable and master lockfiles lock different content; the registry \
bundle is shared, so split it per track before updating"
  fi
  echo "tracks agree on mod set and extract paths"
fi

echo "fetch: $REGISTRY_URL"
registry_tmp="$(mktemp)"
trap 'rm -f "$registry_tmp"' EXIT
if ! curl -fsSL -A "Cataclysm-BN-release-bundler" "$REGISTRY_URL" -o "$registry_tmp"; then
  die "cannot fetch registry from $REGISTRY_URL"
fi
snapshot_tmp="$(mktemp)"
trap 'rm -f "$registry_tmp" "$snapshot_tmp"' EXIT
snapshot_from_registry "$registry_tmp" > "$snapshot_tmp"

mapfile -t ids < <(jq -r '.[].id' "$LOCK_FILE") || die "cannot read mod ids from $LOCK_FILE"
[ "${#ids[@]}" -gt 0 ] || die "no entries in $LOCK_FILE"

url_of() {
  jq -r --arg id "$1" '.[] | select(.id == $id) | .url' "$LOCK_FILE"
}

declare -A newhash_of
declare -A action_of
for id in "${ids[@]}"; do
  lock_url="$(url_of "$id")"
  [ -n "$lock_url" ] || die "no url for locked mod $id"

  if ! jq -e --arg id "$id" 'has($id)' "$snapshot_tmp" >/dev/null; then
    die "locked mod '$id' is not in the registry snapshot; it may have been removed upstream"
  fi

  url="$(resolve_url "$id" "$snapshot_tmp")"
  if [ -z "$url" ]; then
    echo "note: $id has no immutable url in the registry; pinning the branch archive" >&2
    url="$lock_url"
  fi

  if [ -z "${newhash_of[$url]+x}" ]; then
    echo "fetch: $url"
    newhash_of[$url]="$(prefetch "$url")"
  fi
  cur="$(current_hash "$id")"
  new="${newhash_of[$url]}"
  if [ -z "$cur" ]; then
    action="missing"
  elif [ "$cur" = "$new" ]; then
    action="skip"
  else
    action="update"
  fi
  action_of[$id]="$action"
  echo "== $id"
  echo "url:     $url"
  echo "current: ${cur:-<no pin>}"
  echo "fetched: $new"
  echo "plan:    $action"
done

snapshot_action="skip"
if [ ! -f "$SNAPSHOT_FILE" ]; then
  snapshot_action="missing"
elif ! diff -q "$SNAPSHOT_FILE" "$snapshot_tmp" >/dev/null; then
  snapshot_action="update"
fi
echo "== registry snapshot ($SNAPSHOT_FILE)"
echo "plan:    $snapshot_action"

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "check only; $NIX_FILE and $SNAPSHOT_FILE untouched."
  exit 0
fi

all_skip=1
for id in "${ids[@]}"; do
  if [ "${action_of[$id]}" != "skip" ]; then
    all_skip=0
    break
  fi
done
[ "$snapshot_action" = "skip" ] || all_skip=0
if [ "$all_skip" -eq 1 ]; then
  echo "all sources current; $NIX_FILE and $SNAPSHOT_FILE untouched."
  exit 0
fi

# Phase 2: apply. Regenerate the hashes block whole (sorted, quoted ids
# so any id is a valid Nix attribute name) and swap the snapshot file.
# The trap restores both files on any failure from here on.
[ "$(grep -c '^  hashes = {$' "$NIX_FILE")" -eq 1 ] \
  || die "expected exactly one hashes block in $NIX_FILE"

nix_backup="$(mktemp)"
snap_backup="$(mktemp)"
cp "$NIX_FILE" "$nix_backup"
cp "$SNAPSHOT_FILE" "$snap_backup" 2>/dev/null || :
restore() {
  cp "$nix_backup" "$NIX_FILE"
  if [ -f "$snap_backup" ]; then
    cp "$snap_backup" "$SNAPSHOT_FILE"
  else
    rm -f "$SNAPSHOT_FILE"
  fi
}
trap 'restore; exit 1' ERR
trap 'rm -f "$registry_tmp" "$snapshot_tmp" "$nix_backup" "$snap_backup" "$NIX_FILE.new"' EXIT

block_tmp="$(mktemp)"
{
  echo "  hashes = {"
  for id in $(printf '%s\n' "${ids[@]}" | sort -u); do
    url="$(resolve_url "$id" "$snapshot_tmp")"
    [ -n "$url" ] || url="$(url_of "$id")"
    printf '    "%s" = "%s";\n' "$id" "${newhash_of[$url]}"
  done
  echo "  };"
} > "$block_tmp"

block_file="$block_tmp" awk '
  NR == FNR { block = block $0 "\n"; next }
  /^  hashes = \{$/ {
    if (replaced) { print "ERROR: duplicate hashes block" > "/dev/stderr"; exit 1 }
    replaced = 1
    printf "%s", block
    inblock = 1
    next
  }
  /^  \};$/ && inblock { inblock = 0; next }
  !inblock { print }
' "$block_tmp" "$NIX_FILE" > "$NIX_FILE.new"
mv "$NIX_FILE.new" "$NIX_FILE"
rm -f "$block_tmp"

install -Dm644 "$snapshot_tmp" "$SNAPSHOT_FILE"

# Fault injection for the test suite, which cannot otherwise reach the
# restore paths: phase 2 only fails on a real write error. "fail-after-
# writes" dies with the pins already changed; "corrupt-pins" writes a
# bogus hash so the post-write verification catches it.
case "${UPDATE_REGISTRY_TEST_FAULT-}" in
  fail-after-writes)
    echo "injected failure after writes" >&2
    false
    ;;
  corrupt-pins)
    sed -i 's/sha256-[A-Za-z0-9+/=]*/sha256-0000000000000000000000000000000000000000000=/' "$NIX_FILE"
    ;;
  "") ;;
  *) die "unknown UPDATE_REGISTRY_TEST_FAULT '$UPDATE_REGISTRY_TEST_FAULT'" ;;
esac

# Post-write verification: every planned pin and the snapshot read back
# as decided. Any mismatch restores both files.
for id in "${ids[@]}"; do
  url="$(resolve_url "$id" "$snapshot_tmp")"
  [ -n "$url" ] || url="$(url_of "$id")"
  now="$(current_hash "$id")" || {
    restore
    die "post-write readback failed for $id; restored from backup"
  }
  if [ "$now" != "${newhash_of[$url]}" ]; then
    restore
    die "post-write verification failed for $id; restored from backup"
  fi
done
if ! diff -q "$SNAPSHOT_FILE" "$snapshot_tmp" >/dev/null; then
  restore
  die "post-write verification failed for $SNAPSHOT_FILE; restored from backup"
fi

echo "done; run nix flake show, review the diff, and commit."