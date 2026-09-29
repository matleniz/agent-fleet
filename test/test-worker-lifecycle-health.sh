#!/usr/bin/env bash
# test-worker-lifecycle-health.sh — final e2e test covering worker health lifecycle.
#
# Covers the complete worker health & supervision flow:
# 1. Dispatch worker and verify initial healthy state (fleet ls & status)
# 2. Worker inactivity past WORKER_STALL_MINUTES flags stall in ls/status
# 3. fleet wait unblocks with exit code 3 on stall
# 4. Worktree activity resets stall signal
# 5. Worker finishes successfully (done rc=0) and fleet wait exits 0
# 6. Teardown / orphan pane reap on del (without worktree) and plain prune
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENGINE="$(cd "$SELF_DIR/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v tmux >/dev/null || { echo "SKIP: tmux not installed"; exit 0; }

TMP="$(mktemp -d "$HOME/fleet-lifecycle-health-test.XXXXXX")"
export FLEET_HOME="$TMP/fleet-home"
ROOT="$TMP/sandbox"
export PATH="$ENGINE/bin:$PATH"
SESS="fleet-sandbox"

cleanup() {
  tmux kill-session -t "$SESS" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

"$SELF_DIR/make-sandbox.sh" "$ROOT" >/dev/null 2>&1 || fail "sandbox build failed"

tmux kill-session -t "$SESS" 2>/dev/null || true
tmux new-session -d -s "$SESS" -n _home
tmux new-window -d -t "$SESS" -n hub "exec bash"

# Age the base commit so it predates worker creation
PAST_COMMIT_DATE="$(date -d '2 hours ago' --iso-8601=seconds)"
GIT_COMMITTER_DATE="$PAST_COMMIT_DATE" git -C "$ROOT/code" commit -q --amend --date="$PAST_COMMIT_DATE" --no-edit

# --- Step 1: Dispatch worker & verify healthy running state ----------------
git -C "$ROOT/code" worktree add -q "$ROOT/wt/worker-life" -b worker-life
tmux new-window -d -t "$SESS" -n worker-life "exec bash"

SDIR="$FLEET_HOME/dispatch/sandbox"
mkdir -p "$SDIR"
printf 'running' > "$SDIR/worker-life.status"
NOW_ISO="$(date -u +%FT%TZ)"
cat > "$SDIR/worker-life.meta" <<EOF
machine=local
mode=dispatch
created=$NOW_ISO
EOF

ls_out="$("$ENGINE/bin/fleet" --project sandbox ls 2>&1)" || fail "fleet ls failed: $ls_out"
echo "$ls_out" | grep -q "\[dispatch: running\]" || fail "initial fleet ls missing running: $ls_out"
if echo "$ls_out" | grep -q "stalled"; then fail "fresh worker reported stalled in ls: $ls_out"; fi

status_json="$("$ENGINE/bin/fleet" --project sandbox status --json)" || fail "status --json failed"
echo "$status_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
w = data["projects"][0]["machines"][0]["sessions"]["workers"][0]
assert w["name"] == "worker-life"
assert w["stalled"] is False
' || fail "initial status --json validation failed"
echo "PASS: step 1 - fresh worker running and healthy"

# --- Step 2: Worker inactivity past threshold triggers stall ---------------
PAST_ISO="$(date -u -d '30 minutes ago' +%FT%TZ)"
cat > "$SDIR/worker-life.meta" <<EOF
machine=local
mode=dispatch
created=$PAST_ISO
EOF
touch -d '30 minutes ago' "$SDIR/worker-life.status"
touch -d '30 minutes ago' "$SDIR/worker-life.meta"
git_ref="$ROOT/wt/worker-life/.git"
if [ -f "$git_ref" ]; then
  real_gitdir="$(sed 's/^gitdir: //' "$git_ref")"
  touch -d '30 minutes ago' "$real_gitdir/index"
else
  touch -d '30 minutes ago' "$ROOT/wt/worker-life/.git/index"
fi

ls_out="$("$ENGINE/bin/fleet" --project sandbox ls 2>&1)" || fail "fleet ls failed"
echo "$ls_out" | grep -q "\[dispatch: running (stalled)\]" || fail "fleet ls did not report running (stalled): $ls_out"

status_out="$("$ENGINE/bin/fleet" --project sandbox status 2>&1)" || fail "fleet status failed"
echo "$status_out" | grep -q "(running (stalled))" || fail "fleet status did not report running (stalled): $status_out"
echo "PASS: step 2 - inactive worker flagged as stalled in ls and status"

# --- Step 3: fleet wait exits 3 on stalled worker --------------------------
wait_rc=0
wait_out="$("$ENGINE/bin/fleet" --project sandbox wait worker-life 2>&1)" || wait_rc=$?
[ "$wait_rc" -eq 3 ] || fail "fleet wait expected rc=3, got $wait_rc ($wait_out)"
echo "$wait_out" | grep -q "running (stalled)" || fail "fleet wait missing running (stalled): $wait_out"
echo "PASS: step 3 - fleet wait wakes up and exits 3 on stalled worker"

# --- Step 4: Progress in worktree resets stall signal -----------------------
echo "active work" >> "$ROOT/wt/worker-life/hello.py"
touch "$ROOT/wt/worker-life/hello.py"

ls_out="$("$ENGINE/bin/fleet" --project sandbox ls 2>&1)" || fail "fleet ls failed"
echo "$ls_out" | grep -q "\[dispatch: running\]" || fail "fleet ls did not clear stalled: $ls_out"
if echo "$ls_out" | grep -q "stalled"; then fail "fleet ls still contains stalled after activity: $ls_out"; fi
echo "PASS: step 4 - worktree progress clears stall"

# --- Step 5: Worker finishes successfully -> fleet wait exits 0 ------------
printf 'done rc=0' > "$SDIR/worker-life.status"
wait_rc=0
"$ENGINE/bin/fleet" --project sandbox wait worker-life >/dev/null 2>&1 || wait_rc=$?
[ "$wait_rc" -eq 0 ] || fail "fleet wait expected rc=0 on success, got $wait_rc"
echo "PASS: step 5 - finished worker wait exits 0"

# --- Step 6: Worker teardown and orphan pane reap --------------------------
# Simulate finished dispatch pane renamed to _done-worker-life and worktree removed
tmux rename-window -t "$SESS:worker-life" "_done-worker-life"
git -C "$ROOT/code" worktree remove --force "$ROOT/wt/worker-life"

# del reaps leftover _done- pane when worktree is gone
del_out="$("$ENGINE/bin/fleet" --project sandbox del worker-life 2>&1)" || fail "fleet del failed: $del_out"
echo "$del_out" | grep -q "reaped leftover" || fail "fleet del did not report reap: $del_out"
if tmux list-windows -t "$SESS" -F '#{window_name}' | grep -Fxq '_done-worker-life'; then
  fail "fleet del left _done-worker-life behind"
fi

# Another idle _done orphan reaped by plain prune
tmux new-window -d -t "$SESS" -n "_done-other" "exec bash"
printf 'done rc=0' > "$SDIR/other.status"
prune_out="$("$ENGINE/bin/fleet" --project sandbox prune 2>&1)" || fail "fleet prune failed: $prune_out"
echo "$prune_out" | grep -qE 'reap +_done-other' || fail "plain prune did not reap _done-other: $prune_out"
if tmux list-windows -t "$SESS" -F '#{window_name}' | grep -Fxq '_done-other'; then
  fail "_done-other still present after prune"
fi
echo "PASS: step 6 - del and prune reap leftover _done- panes"

echo "PASS: full worker health lifecycle e2e passed"
