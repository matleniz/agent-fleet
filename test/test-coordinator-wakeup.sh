#!/usr/bin/env bash
# test-coordinator-wakeup.sh — e2e test for coordinator wakeup via fleet wait and dispatch --wait.
#
# Covers:
# 1. fleet dispatch output includes coordinator wakeup instruction.
# 2. fleet wait outputs parseable summary on worker exit (duration, commits, pr).
# 3. fleet wait --json returns structured JSON list.
# 4. fleet wait triggers notification hook (FLEET_NOTIFY_HOOK).
# 5. fleet dispatch --wait blocks and propagates worker exit code.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENGINE="$(cd "$SELF_DIR/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v tmux >/dev/null || { echo "SKIP: tmux not installed"; exit 0; }

TMP="$(mktemp -d "$HOME/fleet-wakeup-test.XXXXXX")"
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

# 1. Test dispatch output carries coordinator wakeup instruction
git -C "$ROOT/code" worktree add -q "$ROOT/wt/worker-wake-1" -b worker-wake-1
dispatch_out="$("$ENGINE/bin/fleet" --project sandbox dispatch worker-wake-1 "do something" 2>&1)" || fail "dispatch failed: $dispatch_out"
echo "$dispatch_out" | grep -q "wake coordinator: run 'fleet wait worker-wake-1' in background" || fail "dispatch output missing coordinator wake hint: $dispatch_out"
echo "PASS: 1. dispatch output contains coordinator wake instruction"

# 2. Test fleet wait output formatting and parseable summary
printf 'done rc=0' > "$SDIR/worker-wake-1.status"
NOW_ISO="$(date -u +%FT%TZ)"
cat > "$SDIR/worker-wake-1.meta" <<EOF
machine=local
mode=dispatch
created=$NOW_ISO
EOF

# Add a commit in worker worktree to verify commits in summary
echo "wake progress" >> "$ROOT/wt/worker-wake-1/hello.py"
git -C "$ROOT/wt/worker-wake-1" add hello.py
git -C "$ROOT/wt/worker-wake-1" commit -q -m "completed task"

wait_rc=0
wait_out="$("$ENGINE/bin/fleet" --project sandbox wait worker-wake-1 2>&1)" || wait_rc=$?
[ "$wait_rc" -eq 0 ] || fail "fleet wait expected rc=0, got $wait_rc ($wait_out)"
echo "$wait_out" | grep -q "worker-wake-1.*done rc=0" || fail "fleet wait missing status line: $wait_out"
echo "$wait_out" | grep -q "summary: worker=worker-wake-1 status=\"done rc=0\" duration=" || fail "fleet wait missing summary line: $wait_out"
echo "$wait_out" | grep -q "commits=1" || fail "fleet wait summary missing commits=1: $wait_out"
echo "PASS: 2. fleet wait outputs parseable summary line"

# 3. Test fleet wait --json
wait_json="$("$ENGINE/bin/fleet" --project sandbox wait --json worker-wake-1)" || fail "fleet wait --json failed: $wait_json"
echo "$wait_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert isinstance(data, list) and len(data) == 1
item = data[0]
assert item["worker"] == "worker-wake-1"
assert item["status"] == "done rc=0"
assert item["commits"] == 1
assert "duration_sec" in item
' || fail "fleet wait --json output invalid: $wait_json"
echo "PASS: 3. fleet wait --json returns structured data"

# 4. Test notification hook
HOOK_LOG="$TMP/hook.log"
HOOK_SCRIPT="$TMP/notify-hook.sh"
cat > "$HOOK_SCRIPT" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$HOOK_LOG"
EOF
chmod +x "$HOOK_SCRIPT"

FLEET_NOTIFY_HOOK="$HOOK_SCRIPT" "$ENGINE/bin/fleet" --project sandbox wait worker-wake-1 >/dev/null 2>&1 || fail "wait with notify hook failed"
[ -f "$HOOK_LOG" ] || fail "notification hook was not executed"
grep -q "worker-wake-1 done rc=0 0" "$HOOK_LOG" || fail "notification hook payload unexpected: $(cat "$HOOK_LOG")"
echo "PASS: 4. notification hook executed on worker completion"

# 5. Test dispatch --wait blocks and propagates rc
git -C "$ROOT/code" worktree add -q "$ROOT/wt/worker-wake-2" -b worker-wake-2
(
  sleep 1
  printf 'done rc=0' > "$SDIR/worker-wake-2.status"
) &
bg_pid=$!

disp_wait_rc=0
disp_wait_out="$("$ENGINE/bin/fleet" --project sandbox dispatch --wait worker-wake-2 "blocking task" 2>&1)" || disp_wait_rc=$?
wait "$bg_pid" 2>/dev/null || true
[ "$disp_wait_rc" -eq 0 ] || fail "dispatch --wait expected rc=0, got $disp_wait_rc ($disp_wait_out)"
echo "$disp_wait_out" | grep -q "worker-wake-2.*done rc=0" || fail "dispatch --wait missing completion output: $disp_wait_out"
echo "PASS: 5. dispatch --wait blocks until completion and propagates rc"

echo "PASS: all coordinator wakeup e2e tests passed"
