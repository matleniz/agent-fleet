#!/usr/bin/env bash
# test-race-e2e.sh — E2E for `fleet race` with a fake pack (no model):
#   [1] run: one task fanned to 2 worktrees (each a real headless dispatch)
#   [2] judge: a routed pass compares the diffs, recommends a winner, drafts
#       per-loser markdown comments (never for the winner)
#   [3] comment: the human adds their own markdown comments
#   [4] steer: comments re-dispatched to the loser's own worktree as a follow-up
#       prompt through `fleet dispatch`; the winner is left alone
#   [5] guard rails: no steering a running worker, no comments -> nothing sent
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
FLEET="$REPO/bin/fleet"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected '$3', got '$2'"; fi; }
has()    { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
hasnot() { if grep -qF -- "$2" <<<"$3"; then bad "$1 (unexpected: $2)"; else ok "$1"; fi; }

command -v tmux >/dev/null || { echo "SKIP: tmux not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-race-test.XXXXXX")"
ROOT="$(mktemp -d "$HOME/.fleet-race-sandbox.XXXXXX")"
export FLEET_HOME="$TMP/config"
SESS="fleet-sandbox"
cleanup() { tmux kill-session -t "$SESS" 2>/dev/null || true; rm -rf "$TMP" "$ROOT"; }
trap cleanup EXIT

"$SELF_DIR/make-sandbox.sh" "$ROOT" >/dev/null 2>&1 \
  || { bad "sandbox build failed"; echo "race: $pass passed, $fail failed"; exit 1; }
export FLEET_PACKS_DIR; FLEET_PACKS_DIR="$("$SELF_DIR/make-fake-llm-pack.sh" "$TMP/packs")"
export FLEET_WAIT_POLL=1
export PATH="$REPO/bin:$PATH"   # the dispatch tmux window runs `fleet` from PATH
conf="$FLEET_HOME/projects/sandbox.env"
cat >> "$conf" <<'ENV'
AGENTS="fakellm stub"
ROUTE_HARD="fakellm:judge-model"
ENV
SDIR="$FLEET_HOME/dispatch/sandbox"
RDIR="$SDIR/race/r1"
cd "$ROOT/code" || exit 1
tmux kill-session -t "$SESS" 2>/dev/null || true

echo "[1] race run fans one task to 2 worktrees"
out="$("$FLEET" --project sandbox race run --packs "fakellm fakellm" r1 "write solution.txt" 2>&1)"; rc=$?
eq "run rc" "$rc" "0"
has "announces both" "2 worktree(s) started" "$out"
timeout 120 "$FLEET" --project sandbox wait >/dev/null 2>&1
for w in r1-a r1-b; do
  eq "$w has the worker's commit" "$(git -C "$ROOT/wt/$w" log --format=%s -1 2>/dev/null)" "add solution"
done
has "ls lists members" "r1-b" "$("$FLEET" --project sandbox race ls r1 2>&1)"
"$FLEET" --project sandbox race run r1 "again" >/dev/null 2>&1; eq "re-running a race name is refused" "$?" "2"
"$FLEET" --project sandbox race run --n 1 rx "t" >/dev/null 2>&1; eq "a race needs >= 2 worktrees" "$?" "2"

echo "[2] race judge recommends a winner and drafts loser comments"
out="$("$FLEET" --project sandbox race judge r1 2>&1)"; rc=$?
eq "judge rc" "$rc" "0"
has "recommendation printed" "WINNER: r1-a" "$out"
has "human decides" "YOU decide" "$out"
eq "winner recorded" "$(cat "$RDIR/winner")" "r1-a"
[ -s "$RDIR/comments/r1-b.md" ] && ok "loser comments drafted" || bad "no comments for r1-b"
[ ! -e "$RDIR/comments/r1-a.md" ] && ok "no comments for the winner" || bad "winner got comments"
jm="$(cat "$(ls -t "$FLEET_HOME"/fakellm/call.*.model | head -1)")"
eq "judge pass routed" "$jm" "judge-model"

echo "[3] the human adds a markdown comment"
printf '## extra\n- please also add a docstring\n' | "$FLEET" --project sandbox race comment r1 r1-b - >/dev/null 2>&1
has "human comment stacked" "please also add a docstring" "$(cat "$RDIR/comments/r1-b.md")"

echo "[4] steer re-dispatches the comments to the loser's own worktree"
out="$("$FLEET" --project sandbox race steer r1 --all 2>&1)"; rc=$?
eq "steer rc" "$rc" "0"
has "one worktree steered" "1 worktree(s) re-dispatched" "$out"
timeout 120 "$FLEET" --project sandbox wait >/dev/null 2>&1
eq "loser got a follow-up commit" "$(git -C "$ROOT/wt/r1-b" log --format=%s -1)" "address review"
eq "winner untouched" "$(git -C "$ROOT/wt/r1-a" log --format=%s -1)" "add solution"
fp="$(grep -l 'FOLLOW-UP (review round 1)' "$FLEET_HOME"/fakellm/call.*.prompt | head -1)"
[ -n "$fp" ] && ok "follow-up prompt reached the pack" || bad "no follow-up prompt logged"
fpt="$(cat "$fp" 2>/dev/null)"
has "follow-up carries the judge comment" "adopt the winner" "$fpt"
has "follow-up carries the human comment" "please also add a docstring" "$fpt"
has "follow-up carries the original task" "write solution.txt" "$fpt"
has "follow-up shows the preferred sibling diff" "solution by r1-a" "$fpt"
eq "cwd of the follow-up is the loser's worktree" "$(cat "${fp%.prompt}.cwd")" "$ROOT/wt/r1-b"
[ ! -e "$RDIR/comments/r1-b.md" ] && [ -f "$RDIR/comments/r1-b.sent-1.md" ] && ok "comments archived after sending" || bad "comments not archived"
eq "round counter" "$(cat "$RDIR/rounds.r1-b")" "1"
has "events.log records the steer" "r1-b race-steer round=1" "$(cat "$SDIR/events.log")"

echo "[5] guard rails"
out="$("$FLEET" --project sandbox race steer r1 --all 2>&1)"
has "nothing left to steer" "nothing to steer" "$out"
printf 'x\n' | "$FLEET" --project sandbox race comment r1 r1-b - >/dev/null 2>&1
printf 'running' > "$SDIR/r1-b.status"
out="$("$FLEET" --project sandbox race steer r1 r1-b 2>&1)"
has "running worker is not steered" "still running" "$out"
printf 'done rc=0' > "$SDIR/r1-b.status"
"$FLEET" --project sandbox race comment r1 nope - </dev/null >/dev/null 2>&1; eq "unknown member refused" "$?" "2"

echo
echo "race: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
