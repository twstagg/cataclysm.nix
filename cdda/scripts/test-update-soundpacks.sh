#!/usr/bin/env bash
# Tests for update-soundpacks.sh with mocked git/nix. No network, no builds.
#
# Usage: test-update-soundpacks.sh <updater-under-test>
#
# Each case builds a temp dir with mock git/nix on PATH and a fixture
# pin file (cdda/default.nix), runs the updater, and asserts exit
# codes, file contents and which external commands ran. Cases:
# unchanged-skip, revision-update, malformed-diagnostics, fetch-failure,
# interrupted-repair, multi-hash-ambiguity, unexpected-success,
# unknown-arg, phase2-failure-restores, verification-failure-restores.
#
# Sibling of test-update-tilesets.sh: same harness, one full-clone
# source instead of two sparse ones.
set -u

UPDATER="$1"
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

# 40-hex shas and valid SRI hashes for fixtures/mocks.
SHA_OLD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_NEW="cccccccccccccccccccccccccccccccccccccccc"
FAKE="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
HASH_OLD="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB="
HASH_NEW="sha256-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC="
HASH_NEW2="sha256-DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD="

# $1 snd_rev $2 snd_hash $3 outfile. The fetchSubmodules line must
# survive every run byte-identical (sed only touches rev/sha lines).
fixture_flake() {
  cat >"$3" <<EOF
{
  outputs = { ... }: {
    unrelated-top = 1;
    a = pkgs.fetchFromGitHub {
      owner = "Fris0uman";
      repo = "CDDA-Soundpacks";
      rev = "$1";
      sha256 = "$2";
      fetchSubmodules = true;
    };
    unrelated-bottom = [ 1 2 3 ];
  };
}
EOF
}

# Sets T, MOCKBIN; writes mock git/nix; caller exports MOCK_* first.
# Mock shebangs use an absolute bash path resolved here: valid both on a
# normal system and in the Nix sandbox (no /usr/bin/env there), with no
# patchShebangs dependency.
new_case() {
  T="$(mktemp -d)"
  TMPDIRS="$TMPDIRS $T"
  MOCKBIN="$T/bin"
  mkdir -p "$MOCKBIN" "$T/wt/cdda"
  BASH_BIN="$(command -v bash)"
  printf '#!%s\n' "$BASH_BIN" >"$MOCKBIN/git"
  cat >>"$MOCKBIN/git" <<'EOF'
if [ "$1" = "rev-parse" ]; then printf '%s\n' "$MOCK_ROOT"; exit 0; fi
if [ "$1" = "ls-remote" ]; then
  case "$2" in
    *CDDA-Soundpacks) h="$MOCK_HEAD_SND" ;;
    *) echo "mock git: unexpected url $2" >&2; exit 99 ;;
  esac
  printf '%s\tHEAD\n' "$h"; exit 0
fi
echo "mock git: unexpected args: $*" >&2; exit 99
EOF
  printf '#!%s\n' "$BASH_BIN" >"$MOCKBIN/nix"
  cat >>"$MOCKBIN/nix" <<'EOF'
echo "$*" >> "$MOCK_NIX_LOG"
probe="$2"
case "$probe" in
  *cc-sounds*) mode="$MOCK_NIX_SND"; got="$MOCK_GOT_SND" ;;
  *) echo "mock nix: unexpected probe $probe" >&2; exit 99 ;;
esac
case "$mode" in
  got) printf 'error: hash mismatch:\n specified: fake\n got:    %s\n' "$got" >&2; exit 1 ;;
  multi) printf 'got:    %s\ngot:    %s\n' "$MOCK_GOT_SND" "$MOCK_GOT2" >&2; exit 1 ;;
  garbage) echo "some unrelated noise" >&2; exit 1 ;;
  netfail) echo "error: unable to download: network unreachable" >&2; exit 1 ;;
  ok) exit 0 ;;
  *) echo "mock nix: bad mode $mode" >&2; exit 99 ;;
esac
EOF
  chmod +x "$MOCKBIN/git" "$MOCKBIN/nix"
  export MOCK_ROOT="$T/wt" MOCK_NIX_LOG="$T/nix.log" PATH="$MOCKBIN:$PATH"
  : >"$MOCK_NIX_LOG"
}

run_updater() {
  bash "$UPDATER" "$@" >"$T/out.txt" 2>&1
  echo "$?"
}

nix_calls() {
  grep -c . "$MOCK_NIX_LOG" || true
}

# 1. unchanged: pin current and valid -> no writes, no fetches.
t_unchanged() {
  new_case
  export MOCK_HEAD_SND="$SHA_OLD"
  fixture_flake "$SHA_OLD" "$HASH_OLD" "$T/wt/cdda/default.nix"
  cp "$T/wt/cdda/default.nix" "$T/before.nix"
  rc="$(run_updater)"
  [ "$rc" -eq 0 ] || {
    bad "unchanged: exit $rc"
    return
  }
  cmp -s "$T/before.nix" "$T/wt/cdda/default.nix" || {
    bad "unchanged: file modified"
    return
  }
  [ "$(nix_calls)" -eq 0 ] || {
    bad "unchanged: nix invoked"
    return
  }
  grep -q "plan: skip" "$T/out.txt" || {
    bad "unchanged: no skip message"
    return
  }
  ok "unchanged-skip"
}

# 2. update: snd stale -> rev+hash rewritten, fetchSubmodules kept.
t_update() {
  new_case
  export MOCK_HEAD_SND="$SHA_NEW"
  export MOCK_NIX_SND=got MOCK_GOT_SND="$HASH_NEW"
  fixture_flake "$SHA_OLD" "$HASH_OLD" "$T/wt/cdda/default.nix"
  fixture_flake "$SHA_NEW" "$HASH_NEW" "$T/expected.nix"
  rc="$(run_updater)"
  [ "$rc" -eq 0 ] || {
    bad "update: exit $rc"
    cat "$T/out.txt"
    return
  }
  cmp -s "$T/expected.nix" "$T/wt/cdda/default.nix" || {
    bad "update: content mismatch"
    diff "$T/expected.nix" "$T/wt/cdda/default.nix"
    return
  }
  ok "revision-update"
}

# 3. malformed diagnostics: garbage probe output -> clear failure, file untouched.
t_malformed() {
  new_case
  export MOCK_HEAD_SND="$SHA_NEW"
  export MOCK_NIX_SND=garbage
  fixture_flake "$SHA_OLD" "$HASH_OLD" "$T/wt/cdda/default.nix"
  cp "$T/wt/cdda/default.nix" "$T/before.nix"
  rc="$(run_updater)"
  [ "$rc" -ne 0 ] || {
    bad "malformed: exit 0"
    return
  }
  cmp -s "$T/before.nix" "$T/wt/cdda/default.nix" || {
    bad "malformed: file modified"
    return
  }
  grep -q "expected exactly 1 hash" "$T/out.txt" || {
    bad "malformed: no clear error"
    cat "$T/out.txt"
    return
  }
  ok "malformed-diagnostics"
}

# 4. fetch failure: network error, no hash -> clear failure, file untouched.
t_fetchfail() {
  new_case
  export MOCK_HEAD_SND="$SHA_NEW"
  export MOCK_NIX_SND=netfail
  fixture_flake "$SHA_OLD" "$HASH_OLD" "$T/wt/cdda/default.nix"
  cp "$T/wt/cdda/default.nix" "$T/before.nix"
  rc="$(run_updater)"
  [ "$rc" -ne 0 ] || {
    bad "fetchfail: exit 0"
    return
  }
  cmp -s "$T/before.nix" "$T/wt/cdda/default.nix" || {
    bad "fetchfail: file modified"
    return
  }
  grep -q "network unreachable" "$T/out.txt" || {
    bad "fetchfail: no probe context"
    return
  }
  ok "fetch-failure"
}

# 5. interrupted repair: rev==HEAD but placeholder hash -> hash repaired, rev kept.
t_repair() {
  new_case
  export MOCK_HEAD_SND="$SHA_OLD"
  export MOCK_NIX_SND=got MOCK_GOT_SND="$HASH_NEW"
  fixture_flake "$SHA_OLD" "$FAKE" "$T/wt/cdda/default.nix"
  fixture_flake "$SHA_OLD" "$HASH_NEW" "$T/expected.nix"
  rc="$(run_updater)"
  [ "$rc" -eq 0 ] || {
    bad "repair: exit $rc"
    cat "$T/out.txt"
    return
  }
  cmp -s "$T/expected.nix" "$T/wt/cdda/default.nix" || {
    bad "repair: content mismatch"
    diff "$T/expected.nix" "$T/wt/cdda/default.nix"
    return
  }
  grep -q "plan: repair" "$T/out.txt" || {
    bad "repair: not detected as repair"
    return
  }
  ok "interrupted-repair"
}

# 6. ambiguous multi-hash output -> failure, file untouched.
t_multihash() {
  new_case
  export MOCK_HEAD_SND="$SHA_NEW"
  export MOCK_NIX_SND=multi MOCK_GOT_SND="$HASH_NEW" MOCK_GOT2="$HASH_NEW2"
  fixture_flake "$SHA_OLD" "$HASH_OLD" "$T/wt/cdda/default.nix"
  cp "$T/wt/cdda/default.nix" "$T/before.nix"
  rc="$(run_updater)"
  [ "$rc" -ne 0 ] || {
    bad "multihash: exit 0"
    return
  }
  cmp -s "$T/before.nix" "$T/wt/cdda/default.nix" || {
    bad "multihash: file modified"
    return
  }
  grep -q "found 2" "$T/out.txt" || {
    bad "multihash: no clear error"
    return
  }
  ok "multi-hash-ambiguity"
}

# 7. unexpected probe success -> failure, file untouched.
t_unexpected_ok() {
  new_case
  export MOCK_HEAD_SND="$SHA_NEW"
  export MOCK_NIX_SND=ok
  fixture_flake "$SHA_OLD" "$HASH_OLD" "$T/wt/cdda/default.nix"
  cp "$T/wt/cdda/default.nix" "$T/before.nix"
  rc="$(run_updater)"
  [ "$rc" -ne 0 ] || {
    bad "unexpected-ok: exit 0"
    return
  }
  cmp -s "$T/before.nix" "$T/wt/cdda/default.nix" || {
    bad "unexpected-ok: file modified"
    return
  }
  grep -q "unexpectedly succeeded" "$T/out.txt" || {
    bad "unexpected-ok: no clear error"
    return
  }
  ok "unexpected-success"
}

t_unchanged
t_update
t_malformed
t_fetchfail
t_repair
t_multihash
t_unexpected_ok


t_unknown_arg() {
  new_case
  export MOCK_HEAD_SND="$SHA_NEW"
  export MOCK_NIX_SND=got MOCK_GOT_SND="$HASH_NEW"
  fixture_flake "$SHA_OLD" "$HASH_OLD" "$T/wt/cdda/default.nix"
  cp "$T/wt/cdda/default.nix" "$T/before.nix"
  rc="$(run_updater --dry-run)"
  [ "$rc" -ne 0 ] || {
    bad "unknown-arg: exit 0"
    return
  }
  cmp -s "$T/before.nix" "$T/wt/cdda/default.nix" || {
    bad "unknown-arg: file modified"
    return
  }
  grep -q "unknown argument" "$T/out.txt" || {
    bad "unknown-arg: no clear error"
    return
  }
  ok "unknown-arg"
}

t_phase2_restore() {
  new_case
  export MOCK_HEAD_SND="$SHA_NEW"
  export MOCK_NIX_SND=got MOCK_GOT_SND="$HASH_NEW"
  fixture_flake "$SHA_OLD" "$HASH_OLD" "$T/wt/cdda/default.nix"
  cp "$T/wt/cdda/default.nix" "$T/before.nix"
  # Fails in phase 2, after the placeholder hash and the new rev are
  # already staged: only the trap can put the file back.
  rc="$(UPDATER_TEST_FAULT=fail-after-stage run_updater)"
  [ "$rc" -ne 0 ] || {
    bad "phase2-restore: exit 0"
    return
  }
  cmp -s "$T/before.nix" "$T/wt/cdda/default.nix" || {
    bad "phase2-restore: pins not restored"
    diff "$T/before.nix" "$T/wt/cdda/default.nix"
    return
  }
  grep -qF "$FAKE" "$T/wt/cdda/default.nix" && {
    bad "phase2-restore: placeholder survived"
    return
  }
  ok "phase2-failure-restores"
}

t_verification_restore() {
  new_case
  export MOCK_HEAD_SND="$SHA_NEW"
  export MOCK_NIX_SND=got MOCK_GOT_SND="$HASH_NEW"
  fixture_flake "$SHA_OLD" "$HASH_OLD" "$T/wt/cdda/default.nix"
  cp "$T/wt/cdda/default.nix" "$T/before.nix"
  # Leaves a placeholder where the real hash should be, so the
  # post-write readback is what rejects it.
  rc="$(UPDATER_TEST_FAULT=corrupt-hash run_updater)"
  [ "$rc" -ne 0 ] || {
    bad "verification-restore: exit 0"
    return
  }
  cmp -s "$T/before.nix" "$T/wt/cdda/default.nix" || {
    bad "verification-restore: pins not restored"
    return
  }
  grep -q "post-write verification failed" "$T/out.txt" || {
    bad "verification-restore: not caught by readback"
    cat "$T/out.txt"
    return
  }
  ok "verification-failure-restores"
}

t_unknown_arg
t_phase2_restore
t_verification_restore

echo "pass=$PASS fail=$FAIL"

[ "$FAIL" -eq 0 ]
