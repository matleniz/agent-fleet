#!/usr/bin/env bash
# test-new-worker.sh — S6 + S7 regression tests for worker creation.
#
#   [1] fleet_valid_name (bin/fleet-config.sh) rejects '.', '..' and any
#       all-dots name (path-traversal-adjacent), while still accepting a
#       legitimate name that merely contains a dot (e.g. "feature.v2").
#   [2] bin/new-worker: two concurrent `new-worker` calls for the SAME name
#       race past the dest/branch pre-checks — exactly one must win, the
#       other must fail cleanly (message + rc != 0, no `set -e` raw-git-error
#       death), and no half-created worktree/branch may be left behind.
#
# Touches nothing real: FLEET_HOME is a throwaway temp dir and the sandbox is
# built by test/make-sandbox.sh under a throwaway ROOT, never ~/.config/fleet
# or a real repo.
#
#   test/test-new-worker.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected '$3', got '$2'"; fi; }

# ---- 1. fleet_valid_name: '.', '..', all-dots rejected; dotted name kept ----
echo "[1] fleet_valid_name — reject '.', '..', all-dots; keep 'feature.v2'"
# shellcheck disable=SC1091
. "$REPO/bin/fleet-config.sh"

for n in . .. ...; do
  out="$(fleet_valid_name "$n" "worker name" 2>&1)"; rc=$?
  eq "reject '$n' rc"  "$rc" "2"
  case "$out" in *"error:"*) ok "reject '$n' has an error message" ;; *) bad "reject '$n' message missing (got: $out)" ;; esac
done

out="$(fleet_valid_name "feature.v2" "worker name" 2>&1)"; rc=$?
eq "'feature.v2' rc"  "$rc" "0"
[ -z "$out" ] && ok "'feature.v2' no error output" || bad "'feature.v2' unexpected output: $out"

# Sanity: pre-existing behavior untouched (invalid charset still rejected).
out="$(fleet_valid_name "foo/bar" "worker name" 2>&1)"; rc=$?
eq "'foo/bar' still rejected rc" "$rc" "2"

# ---- 2. new-worker TOCTOU: two concurrent creates of the SAME name ----
echo "[2] new-worker — concurrent same-name creation: exactly one winner, clean loser, no half state"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-new-worker-test.XXXXXX")"
ROOT="$(mktemp -d "$HOME/.fleet-new-worker-sandbox.XXXXXX")"
export FLEET_HOME="$TMP/config"
cleanup() { rm -rf "$TMP" "$ROOT"; }
trap cleanup EXIT

"$SELF_DIR/make-sandbox.sh" "$ROOT" >/dev/null 2>&1 || { bad "sandbox build failed"; echo; echo "test-new-worker: $pass passed, $fail failed"; exit 1; }

name="race-$$"
out1="$TMP/out1" out2="$TMP/out2"

"$REPO/bin/new-worker" --project sandbox "$name" >"$out1" 2>&1 &
p1=$!
"$REPO/bin/new-worker" --project sandbox "$name" >"$out2" 2>&1 &
p2=$!

rc1=0; rc2=0
wait "$p1" || rc1=$?
wait "$p2" || rc2=$?

wins=0 losses=0
for rc in "$rc1" "$rc2"; do
  if [ "$rc" -eq 0 ]; then wins=$((wins+1)); else losses=$((losses+1)); fi
done
eq "exactly one winner" "$wins" "1"
eq "exactly one loser"  "$losses" "1"

# Whichever one lost must have exited cleanly with a message, not a bare git
# stack trace / set -e death (rc would still be non-zero either way, but we
# also check for an "error:" line so a silent set -e kill doesn't pass).
loser_out=""
[ "$rc1" -ne 0 ] && loser_out="$out1"
[ "$rc2" -ne 0 ] && loser_out="$out2"
if [ -n "$loser_out" ] && grep -q "^error:" "$loser_out"; then
  ok "loser printed a clean error message"
else
  bad "loser did not print a clean error message (out: $(cat "$loser_out" 2>/dev/null))"
fi

# Exactly one worktree dir and one branch must exist — no phantom half state
# from the loser (a stray dest dir, or a branch ref pointing nowhere).
wt_count="$(git -C "$ROOT/code" worktree list --porcelain 2>/dev/null | grep -c "^worktree .*/wt/$name\$")"
eq "exactly one worktree registered for '$name'" "$wt_count" "1"

branch_count="$(git -C "$ROOT/code" for-each-ref "refs/heads/$name" | wc -l | tr -d ' ')"
eq "exactly one branch '$name'" "$branch_count" "1"

[ -d "$ROOT/wt/$name" ] && ok "winner's worktree dir exists" || bad "winner's worktree dir missing"

echo
echo "test-new-worker: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
