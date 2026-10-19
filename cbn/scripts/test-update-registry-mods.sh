#!/usr/bin/env bash
# Tests for update-registry-mods.sh with mocked curl/nix. No network.
#
# Usage: test-update-registry-mods.sh <updater-under-test>
#
# Each case builds a temp dir with mock curl/nix on PATH plus a fixture
# lockfile (data/mods/external.json), registry JSON, vendored snapshot,
# and pin table, runs the updater, and asserts exit codes, file contents,
# and which urls were fetched. Cases: unchanged-skip, hash-update,
# check-mode, fetch-failure, missing-id, malformed-output,
# snapshot-update, url-resolution, unknown-arg.
set -u

UPDATER="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
PASS=0
FAIL=0
TMPDIRS=""

ok() {
  PASS=$((PASS + 1))
  echo "ok: $1"
}

bad() {
  FAIL=$((FAIL + 1))
  echo "NOT OK: $1"
  [ -n "${2-}" ] && printf '%s\n' "$2" | head -20
}

cleanup() {
  for d in $TMPDIRS; do rm -rf "$d"; done
}
trap cleanup EXIT

# Valid SRI hashes built programmatically (43 base64 chars + "=").
HASH_A="sha256-$(printf 'A%.0s' $(seq 42))B="
HASH_B="sha256-$(printf 'C%.0s' $(seq 42))D="
HASH_C="sha256-$(printf 'E%.0s' $(seq 42))F="
HASH_D="sha256-$(printf 'G%.0s' $(seq 42))H="
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
URL_B_COMMIT="https://example.com/b/archive/1111111111111111111111111111111111111111.zip"

REGISTRY_URL="https://mods.cataclysmbn.org/generated/mods.json"
# mod-a is tracked by tag, mod-b by commit on a branch: exercises both
# arms of url resolution.
URL_A="https://example.com/a/archive/refs/tags/v1.zip"
URL_B_BRANCH="https://example.com/b/archive/refs/heads/main.zip"
URL_B_SHA="https://example.com/b/archive/$SHA_B.zip"
URL_C="https://example.com/c/archive/refs/tags/v1.zip"

# setup: fresh fixture dir in $FIX with mocks on PATH. Always writes a
# two-entry lockfile (mod-a tag, mod-b branch), matching registry JSON,
# a vendored snapshot identical to it, and pins matching $HASH_A/$HASH_B.
setup() {
  FIX="$(mktemp -d)"
  TMPDIRS="$TMPDIRS $FIX"
  mkdir -p "$FIX/bin" "$FIX/data/mods" "$FIX/cbn"
  cat > "$FIX/bin/git" <<EOF
#!/bin/sh
if [ "\$1 \$2" = "rev-parse --show-toplevel" ]; then
  echo "$FIX"
else
  exit 1
fi
EOF
  # POSIX sh: the sandbox has no /usr/bin/env, so /bin/sh and no
  # bashisms in the mocks.
  cat > "$FIX/bin/curl" <<'EOF'
#!/bin/sh
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
[ "$url" = "$REGISTRY_URL" ] || exit 1
cat "$FIX/registry.json" > "$out"
EOF
  cat > "$FIX/bin/nix" <<'EOF'
#!/bin/sh
eval "url=\${$#}"
echo "$url" >> "$MOCK_CALL_LOG"
resp="$(awk -v u="$url" '$1 == u { print $2; exit }' "$MOCK_MAP")"
case "$resp" in
  "" | FAIL) exit 1 ;;
  GARBAGE) echo "this is not json" ;;
  BADHASH) echo '{"hash": "definitely-not-a-hash"}' ;;
  *) printf '{"hash": "%s"}\n' "$resp" ;;
esac
EOF
  chmod +x "$FIX/bin/git" "$FIX/bin/curl" "$FIX/bin/nix"
  export PATH="$FIX/bin:$PATH"
  export FIX
  export MOCK_MAP="$FIX/map.txt"
  export MOCK_CALL_LOG="$FIX/calls.txt"
  export REGISTRY_URL
  : > "$MOCK_CALL_LOG"
  cat > "$FIX/data/mods/external.json" <<EOF
[
  { "id": "mod-a", "version": "1.0", "url": "$URL_A" },
  { "id": "mod-b", "version": "2.0", "url": "$URL_B_BRANCH" }
]
EOF
  write_registry
  cat > "$FIX/cbn/registry-mods.nix" <<EOF
{
  hashes = {
    "mod-a" = "$HASH_A";
    "mod-b" = "$HASH_B";
  };
}
EOF
  printf '%s %s\n' "$URL_A" "$HASH_A" > "$MOCK_MAP"
  printf '%s %s\n' "$URL_B_SHA" "$HASH_B" >> "$MOCK_MAP"
  # Normalize through one updater run so the fixture holds the canonical
  # snapshot/pin shapes rather than hand-written approximations, then
  # reset the call log so each case only observes its own fetches.
  if ! ( cd "$FIX" && bash "$UPDATER" >"$FIX/baseline.txt" 2>&1 ); then
    bad "setup baseline run failed" "$(cat "$FIX/baseline.txt")"
    return 1
  fi
  cp "$FIX/cbn/registry-mods.nix" "$FIX/pins.before"
  cp "$FIX/cbn/registry-mods.json" "$FIX/snapshot.before"
  : > "$MOCK_CALL_LOG"
}

# Registry JSON matching the two-entry fixture, in the vendored shape.
write_registry() {
  cat > "$FIX/registry.json" <<EOF
[
  {
    "id": "mod-a", "display_name": "Mod A", "homepage": "https://a.example",
    "license": "CC-BY-SA-4.0", "version": "1.0",
    "source": { "type": "github_archive", "url": "$URL_A", "extract_path": null }
  },
  {
    "id": "mod-b", "display_name": "Mod B", "homepage": "https://b.example",
    "license": "ALL-RIGHTS-RESERVED", "version": "2.0",
    "autoupdate": { "type": "commit", "branch": "main" },
    "source": {
      "type": "github_archive", "url": "$URL_B_BRANCH",
      "commit_sha": "$SHA_B", "extract_path": null
    }
  }
]
EOF
}

run_updater() {
  ( cd "$FIX" && bash "$UPDATER" ${1-} >"$FIX/out.txt" 2>&1 )
}

pin_of() {
  grep -o "\"$1\" = \"[^\"]*\"" "$FIX/cbn/registry-mods.nix" | head -n 1
}

# 1: everything current -> untouched, exit 0.
setup
if run_updater; then
  if cmp -s "$FIX/pins.before" "$FIX/cbn/registry-mods.nix" \
    && cmp -s "$FIX/snapshot.before" "$FIX/cbn/registry-mods.json" \
    && grep -q "untouched" "$FIX/out.txt"; then
    ok "unchanged-skip leaves pins and snapshot untouched"
  else
    bad "unchanged-skip changed files or missed message" "$(cat "$FIX/out.txt")"
  fi
else
  bad "unchanged-skip exited nonzero" "$(cat "$FIX/out.txt")"
fi

# 2: stale hash for one entry -> only that pin rewritten.
setup
printf '%s %s\n' "$URL_A" "$HASH_C" > "$MOCK_MAP"
printf '%s %s\n' "$URL_B_SHA" "$HASH_B" >> "$MOCK_MAP"
if run_updater; then
  pin_a="$(pin_of mod-a)"
  pin_b="$(pin_of mod-b)"
  if [ "$pin_a" = "\"mod-a\" = \"$HASH_C\"" ] && [ "$pin_b" = "\"mod-b\" = \"$HASH_B\"" ]; then
    ok "hash-update rewrites only the stale pin"
  else
    bad "hash-update wrong pins (a=$pin_a b=$pin_b)" "$(cat "$FIX/cbn/registry-mods.nix")"
  fi
else
  bad "hash-update exited nonzero" "$(cat "$FIX/out.txt")"
fi

# 3: --check with a stale pin -> reports, writes nothing.
setup
printf '%s %s\n' "$URL_A" "$HASH_C" > "$MOCK_MAP"
printf '%s %s\n' "$URL_B_SHA" "$HASH_B" >> "$MOCK_MAP"
if run_updater "--check"; then
  if cmp -s "$FIX/pins.before" "$FIX/cbn/registry-mods.nix" \
    && cmp -s "$FIX/snapshot.before" "$FIX/cbn/registry-mods.json" \
    && grep -q "plan:    update" "$FIX/out.txt"; then
    ok "check-mode reports without writing"
  else
    bad "check-mode wrote or stayed silent" "$(cat "$FIX/out.txt")"
  fi
else
  bad "check-mode exited nonzero" "$(cat "$FIX/out.txt")"
fi

# 4: prefetch failure -> nonzero, pins untouched.
setup
printf '%s %s\n' "$URL_A" "$HASH_C" > "$MOCK_MAP"
printf '%s %s\n' "$URL_B_SHA" "FAIL" >> "$MOCK_MAP"
if run_updater; then
  bad "fetch-failure exited zero" "$(cat "$FIX/out.txt")"
else
  if cmp -s "$FIX/pins.before" "$FIX/cbn/registry-mods.nix"; then
    ok "fetch-failure leaves pins untouched"
  else
    bad "fetch-failure left partial writes" "$(diff "$FIX/pins.before" "$FIX/cbn/registry-mods.nix")"
  fi
fi

# 5: lockfile entry with no pin -> inserted sorted with prefetched hash.
setup
cat > "$FIX/data/mods/external.json" <<EOF
[
  { "id": "mod-0", "version": "0.1", "url": "$URL_C" },
  { "id": "mod-a", "version": "1.0", "url": "$URL_A" },
  { "id": "mod-b", "version": "2.0", "url": "$URL_B_BRANCH" }
]
EOF
write_registry
python_add_mod0() {
  jq '. + [{
    "id": "mod-0", "display_name": "Mod Zero", "homepage": "https://c.example",
    "license": "CC0-1.0", "version": "0.1",
    "source": { "type": "github_archive", "url": "'"$URL_C"'", "extract_path": null }
  }]' "$FIX/registry.json" > "$FIX/registry.tmp" && mv "$FIX/registry.tmp" "$FIX/registry.json"
}
python_add_mod0
cp "$FIX/registry.json" "$FIX/cbn/registry-mods.json"
printf '%s %s\n' "$URL_A" "$HASH_A" > "$MOCK_MAP"
printf '%s %s\n' "$URL_B_SHA" "$HASH_B" >> "$MOCK_MAP"
printf '%s %s\n' "$URL_C" "$HASH_D" >> "$MOCK_MAP"
if run_updater; then
  order="$(grep -o '^    "mod-[a-z0-9-]*"' "$FIX/cbn/registry-mods.nix" | tr '\n' ' ')"
  pin_new="$(pin_of mod-0)"
  if [ "$order" = '    "mod-0"     "mod-a"     "mod-b" ' ] && [ "$pin_new" = "\"mod-0\" = \"$HASH_D\"" ]; then
    ok "missing-id inserted sorted with prefetched hash"
  else
    bad "missing-id wrong order/content ($order $pin_new)" "$(cat "$FIX/cbn/registry-mods.nix")"
  fi
else
  bad "missing-id exited nonzero" "$(cat "$FIX/out.txt")"
fi

# 6: malformed prefetch output -> hard error, pins untouched.
for mode in GARBAGE BADHASH; do
  setup
  printf '%s %s\n' "$URL_A" "$mode" > "$MOCK_MAP"
  printf '%s %s\n' "$URL_B_SHA" "$HASH_B" >> "$MOCK_MAP"
  if run_updater; then
    bad "malformed-output($mode) exited zero" "$(cat "$FIX/out.txt")"
  else
    if cmp -s "$FIX/pins.before" "$FIX/cbn/registry-mods.nix"; then
      ok "malformed-output($mode) errors without writing"
    else
      bad "malformed-output($mode) left partial writes" "$(cat "$FIX/out.txt")"
    fi
  fi
done

# 7: live registry changed -> vendored snapshot rewritten.
setup
jq '.[0].display_name = "Mod A (renamed)"' "$FIX/registry.json" > "$FIX/r.tmp" \
  && mv "$FIX/r.tmp" "$FIX/registry.json"
if run_updater; then
  if jq -e '.["mod-a"].display_name == "Mod A (renamed)"' "$FIX/cbn/registry-mods.json" >/dev/null; then
    ok "snapshot-update rewrites the vendored snapshot"
  else
    bad "snapshot-update left stale metadata" "$(cat "$FIX/cbn/registry-mods.json")"
  fi
else
  bad "snapshot-update exited nonzero" "$(cat "$FIX/out.txt")"
fi

# 8: branch-tracked entry fetches the registry commit, not the branch.
setup
run_updater >/dev/null 2>&1
fetched="$(grep -c -F -x "$URL_B_SHA" "$MOCK_CALL_LOG")"
branch="$(grep -c -F -x "$URL_B_BRANCH" "$MOCK_CALL_LOG")"
if [ "$fetched" -eq 1 ] && [ "$branch" -eq 0 ]; then
  ok "url-resolution pins branch entries to the registry commit"
else
  bad "url-resolution fetched wrong url (commit=$fetched branch=$branch)" "$(cat "$MOCK_CALL_LOG")"
fi

# 9: unknown argument is rejected instead of silently applying.
setup
if run_updater "--dry-run"; then
  bad "unknown-arg exited zero" "$(cat "$FIX/out.txt")"
else
  if grep -q "unknown argument" "$FIX/out.txt" \
    && cmp -s "$FIX/pins.before" "$FIX/cbn/registry-mods.nix"; then
    ok "unknown-arg rejected without writing"
  else
    bad "unknown-arg misdiagnosed or wrote" "$(cat "$FIX/out.txt")"
  fi
fi

# 10: locked id missing from the registry -> loud failure, no writes.
setup
jq 'map(select(.id != "mod-b"))' "$FIX/registry.json" > "$FIX/r.tmp" \
  && mv "$FIX/r.tmp" "$FIX/registry.json"
if run_updater; then
  bad "missing-registry-entry exited zero" "$(cat "$FIX/out.txt")"
else
  if cmp -s "$FIX/pins.before" "$FIX/cbn/registry-mods.nix" \
    && grep -q "not in the registry snapshot" "$FIX/out.txt"; then
    ok "missing-registry-entry fails loudly without writing"
  else
    bad "missing-registry-entry misdiagnosed or wrote" "$(cat "$FIX/out.txt")"
  fi
fi

# 11: a lockfile url that is already immutable wins over the registry's,
# because that is the commit the release actually shipped.
setup
cat > "$FIX/data/mods/external.json" <<EOF
[
  { "id": "mod-a", "version": "1.0", "url": "$URL_A" },
  { "id": "mod-b", "version": "2.0", "url": "$URL_B_COMMIT" }
]
EOF
run_updater >/dev/null 2>&1
fetched="$(grep -c -F -x "$URL_B_COMMIT" "$MOCK_CALL_LOG")"
branch="$(grep -c -F -x "$URL_B_BRANCH" "$MOCK_CALL_LOG")"
sha="$(grep -c -F -x "$URL_B_SHA" "$MOCK_CALL_LOG")"
if [ "$fetched" -eq 1 ] && [ "$branch" -eq 0 ] && [ "$sha" -eq 0 ]; then
  ok "url-resolution prefers the lockfile's immutable url"
else
  bad "url-resolution ignored the lockfile commit (lock=$fetched branch=$branch sha=$sha)" "$(cat "$MOCK_CALL_LOG")"
fi

# 12: phase-2 failure after the pins were rewritten -> trap restores both.
setup
jq '.[0].display_name = "Mod A (renamed)"' "$FIX/registry.json" > "$FIX/r.tmp" \
  && mv "$FIX/r.tmp" "$FIX/registry.json"
printf '%s %s\n' "$URL_A" "$HASH_C" > "$MOCK_MAP"
printf '%s %s\n' "$URL_B_SHA" "$HASH_B" >> "$MOCK_MAP"
if UPDATE_REGISTRY_TEST_FAULT=fail-after-writes run_updater; then
  bad "phase2-failure exited zero" "$(cat "$FIX/out.txt")"
else
  if cmp -s "$FIX/pins.before" "$FIX/cbn/registry-mods.nix" \
    && cmp -s "$FIX/snapshot.before" "$FIX/cbn/registry-mods.json"; then
    ok "phase2-failure restores pins and snapshot from backup"
  else
    bad "phase2-failure left partial writes" "$(cat "$FIX/cbn/registry-mods.nix")"
  fi
fi

# 12: post-write verification catches a corrupted pin table -> restore.
setup
printf '%s %s\n' "$URL_A" "$HASH_C" > "$MOCK_MAP"
printf '%s %s\n' "$URL_B_SHA" "$HASH_B" >> "$MOCK_MAP"
if UPDATE_REGISTRY_TEST_FAULT=corrupt-pins run_updater; then
  bad "verification-failure exited zero" "$(cat "$FIX/out.txt")"
else
  if cmp -s "$FIX/pins.before" "$FIX/cbn/registry-mods.nix" \
    && grep -q "post-write verification failed" "$FIX/out.txt"; then
    ok "verification-failure is detected and restored"
  else
    bad "verification-failure not detected or not restored" "$(cat "$FIX/out.txt")"
  fi
fi

echo "---"
echo "pass: $PASS fail: $FAIL"
[ "$FAIL" -eq 0 ]