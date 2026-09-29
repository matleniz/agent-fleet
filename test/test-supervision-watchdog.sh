#!/usr/bin/env bash
# test-supervision-watchdog.sh — unit and e2e test for worker supervision watchdog,
# deliverable verification, blocking foreground process detection, and retry/fallback.
#
# Covers:
# 1. Deliverable verification on exit (done-without-deliverable vs done rc=0).
# 2. Blocking foreground server child process detection in fleet ls and fleet status.
# 3. Auto-retry and pack fallback policy upon stall with supervision.log journaling.
# 4. Manual fleet retry command.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENGINE="$(cd "$SELF_DIR/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v tmux >/dev/null || { echo "SKIP: tmux not installed"; exit 0; }

TMP="$(mktemp -d "$HOME/fleet-watchdog-test.XXXXXX")"
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

SDIR="$FLEET_HOME/dispatch/sandbox"
mkdir -p "$SDIR"

# -----------------------------------------------------------------------------
# Part 1: Deliverable verification on exit
# -----------------------------------------------------------------------------
git -C "$ROOT/code" worktree add -q "$ROOT/wt/worker-deliv" -b worker-deliv

# 1a. Test check-deliverable helper directly
if python3 "$ENGINE/bin/fleet_common.py" check-deliverable "$ROOT/wt/worker-deliv" worker-deliv pr 2>/dev/null; then
  fail "check-deliverable should fail when worktree has no commits/push/PR"
fi

# 1b. Dispatch with deliverable requirement
taskfile="$TMP/task-deliv.txt"
printf "Task requiring PR\n" > "$taskfile"
"$ENGINE/bin/fleet" --project sandbox dispatch --deliverable pr worker-deliv "Task requiring PR" >/dev/null 2>&1 || fail "dispatch failed"

# Verify deliverable recorded in meta
meta_deliv="$(sed -n 's/^deliverable=//p' "$SDIR/worker-deliv.meta" 2>/dev/null)"
[ "$meta_deliv" = "pr" ] || fail "expected deliverable=pr in meta, got: $meta_deliv"

# Simulate worker exiting rc=0 without PR
printf 'done-without-deliverable' > "$SDIR/worker-deliv.status"
ls_out="$("$ENGINE/bin/fleet" --project sandbox ls 2>&1)" || fail "fleet ls failed: $ls_out"
echo "$ls_out" | grep -q "\[dispatch: done-without-deliverable\]" || fail "fleet ls missing done-without-deliverable: $ls_out"

status_out="$("$ENGINE/bin/fleet" --project sandbox status 2>&1)" || fail "status failed: $status_out"
echo "$status_out" | grep -q "done-without-deliverable" || fail "fleet status missing done-without-deliverable: $status_out"
echo "$status_out" | grep -q "missing deliverable" || fail "fleet status missing deliverable warning: $status_out"

wait_rc=0
"$ENGINE/bin/fleet" --project sandbox wait worker-deliv >/dev/null 2>&1 || wait_rc=$?
[ "$wait_rc" -eq 1 ] || fail "fleet wait expected rc=1 on done-without-deliverable, got $wait_rc"

# Simulate worker fulfilling PR requirement
echo "https://github.com/example/repo/pull/123" > "$SDIR/worker-deliv.pr"
if ! python3 "$ENGINE/bin/fleet_common.py" check-deliverable "$ROOT/wt/worker-deliv" worker-deliv pr 2>/dev/null; then
  fail "check-deliverable should pass when PR file is present"
fi
echo "PASS: 1. deliverable verification correctly detects missing deliverables"

# -----------------------------------------------------------------------------
# Part 2: Long-lived blocking server child process detection
# -----------------------------------------------------------------------------
git -C "$ROOT/code" worktree add -q "$ROOT/wt/worker-server" -b worker-server
tmux new-window -d -t "$SESS" -n worker-server "python3 -m http.server 18889"
printf 'running' > "$SDIR/worker-server.status"
NOW_ISO="$(date -u +%FT%TZ)"
cat > "$SDIR/worker-server.meta" <<EOF
machine=local
mode=dispatch
created=$NOW_ISO
EOF

sleep 1
pane_pid="$(tmux list-panes -t "$SESS:worker-server" -F '#{pane_pid}' 2>/dev/null | head -1)"
[ -n "$pane_pid" ] || fail "failed to get pane pid for worker-server"

detected="$(python3 "$ENGINE/bin/fleet_common.py" check-server "$pane_pid" 2>/dev/null)" || fail "check-server failed on running http.server"
echo "$detected" | grep -q "http.server" || fail "check-server expected http.server, got: $detected"

ls_out="$("$ENGINE/bin/fleet" --project sandbox ls 2>&1)" || fail "fleet ls failed: $ls_out"
echo "$ls_out" | grep -q "blocked-on-foreground-process (http.server)" || fail "fleet ls missing blocked-on-foreground-process: $ls_out"

status_json="$("$ENGINE/bin/fleet" --project sandbox status --json 2>&1)" || fail "status --json failed: $status_json"
echo "$status_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
w = [x for x in data["projects"][0]["machines"][0]["sessions"]["workers"] if x["name"] == "worker-server"][0]
assert w["blocked_on_server"] == "http.server", ("expected http.server, got: %s" % w["blocked_on_server"])
assert any("http.server" in c for c in w["child_processes"]), ("expected http.server in child_processes: %s" % w["child_processes"])
' || fail "status --json validation failed for blocked server"
echo "PASS: 2. blocking foreground server detection exposed in ls and status"

# -----------------------------------------------------------------------------
# Part 3: Auto-retry and pack fallback policy
# -----------------------------------------------------------------------------
git -C "$ROOT/code" worktree add -q "$ROOT/wt/worker-retry" -b worker-retry
echo "AGENTS=\"claude gemini\"" >> "$FLEET_HOME/projects/sandbox.env"
echo "WORKER_MAX_RETRIES=1" >> "$FLEET_HOME/projects/sandbox.env"

cat > "$SDIR/worker-retry.meta" <<EOF
machine=local
mode=dispatch
created=$NOW_ISO
pack=claude
retries=0
EOF
printf 'running' > "$SDIR/worker-retry.status"
printf 'Initial brief task for worker retry\n' > "$SDIR/worker-retry.task"
tmux new-window -d -t "$SESS" -n worker-retry "exec bash"

# First stall triggers auto-retry with claude (attempt 1/1)
# Age worker to trigger stall
past_iso="$(date -u -d '30 minutes ago' +%FT%TZ)"
sed -i "s/^created=.*/created=$past_iso/" "$SDIR/worker-retry.meta"
touch -d '30 minutes ago' "$SDIR/worker-retry.status"
git_ref="$ROOT/wt/worker-retry/.git"
if [ -f "$git_ref" ]; then
  real_gitdir="$(sed 's/^gitdir: //' "$git_ref")"
  touch -d '30 minutes ago' "$real_gitdir/index"
else
  touch -d '30 minutes ago' "$ROOT/wt/worker-retry/.git/index"
fi

# Invoke fleet wait (which should trigger retry)
# Set mock/subshell dispatch by testing worker_trigger_retry_or_fallback directly
source "$ENGINE/bin/fleet-config.sh"
fleet_resolve_conf sandbox >/dev/null 2>&1

PROJ_NAME="sandbox"
rotate_events_log() { :; }
cmd_dispatch() { echo "mock dispatch $*"; return 0; }
source <(sed -n '/worker_trigger_retry_or_fallback()/,/^}/p' "$ENGINE/bin/fleet")
source <(sed -n '/worker_next_agent()/,/^}/p' "$ENGINE/bin/fleet")
source <(sed -n '/dispatch_state_dir()/,/^}/p' "$ENGINE/bin/fleet")
source <(sed -n '/dispatch_tmux()/,/^}/p' "$ENGINE/bin/fleet")

# Trigger retry 1/1
worker_trigger_retry_or_fallback worker-retry "stall" || fail "retry attempt 1 failed"
[ -f "$SDIR/supervision.log" ] || fail "supervision.log was not created"
grep -q "worker-retry retry pack=claude attempt=1/1 reason=stall" "$SDIR/supervision.log" || fail "supervision.log missing retry line: $(cat "$SDIR/supervision.log")"

# Trigger next retry: since retries=1 is at max_retries (1), should fall back to gemini!
worker_trigger_retry_or_fallback worker-retry "stall" || fail "fallback to gemini failed"
grep -q "worker-retry fallback from=claude to=gemini" "$SDIR/supervision.log" || fail "supervision.log missing fallback line: $(cat "$SDIR/supervision.log")"
new_pack="$(sed -n 's/^pack=//p' "$SDIR/worker-retry.meta")"
[ "$new_pack" = "gemini" ] || fail "expected pack=gemini after fallback, got: $new_pack"

echo "PASS: 3. retry and fallback policy re-dispatches and falls back across AGENTS"

# -----------------------------------------------------------------------------
# Part 4: Manual fleet retry command
# -----------------------------------------------------------------------------
"$ENGINE/bin/fleet" --project sandbox retry --pack claude worker-retry >/dev/null 2>&1 || fail "fleet retry command failed"
grep -q "manual-retry" "$SDIR/supervision.log" || fail "supervision.log missing manual-retry event"
echo "PASS: 4. manual fleet retry successfully re-dispatches worker"

echo "PASS: all supervision watchdog and fallback tests passed"
