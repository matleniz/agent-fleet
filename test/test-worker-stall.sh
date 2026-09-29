#!/usr/bin/env bash
# test-worker-stall.sh — unit stall detection, metrics, and commands.
#
# Covers stall detection logic in fleet_common (check-stall and stall-info),
# worker health metrics in fleet status (--json and text), stall visibility in
# fleet ls, exit codes in fleet wait, worktree activity reset, and project
# WORKER_STALL_MINUTES configuration.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENGINE="$(cd "$SELF_DIR/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d "$HOME/fleet-stall-test.XXXXXX")"
export FLEET_HOME="$TMP/fleet-home"
ROOT="$TMP/sandbox"
export PATH="$ENGINE/bin:$PATH"

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

"$SELF_DIR/make-sandbox.sh" "$ROOT" >/dev/null 2>&1 || fail "sandbox build failed"

# Age the base commit so it predates simulated worker activity
PAST_COMMIT_DATE="$(date -d '2 hours ago' --iso-8601=seconds)"
GIT_COMMITTER_DATE="$PAST_COMMIT_DATE" git -C "$ROOT/code" commit -q --amend --date="$PAST_COMMIT_DATE" --no-edit

# Helper to age worker status and worktree git metadata
age_worker() {
  local name="$1"
  local wt="$2"
  local age="$3"
  local past_iso
  past_iso="$(date -u -d "$age" +%FT%TZ)"
  cat > "$SDIR/$name.meta" <<EOF
machine=local
mode=dispatch
created=$past_iso
EOF
  touch -d "$age" "$SDIR/$name.status"
  touch -d "$age" "$SDIR/$name.meta"
  local git_ref="$wt/.git"
  if [ -f "$git_ref" ]; then
    local real_gitdir
    real_gitdir="$(sed 's/^gitdir: //' "$git_ref")"
    touch -d "$age" "$real_gitdir/index"
  else
    touch -d "$age" "$wt/.git/index"
  fi
}

# Create a worker worktree
git -C "$ROOT/code" worktree add -q "$ROOT/wt/worker-stall" -b worker-stall
SDIR="$FLEET_HOME/dispatch/sandbox"
mkdir -p "$SDIR"

# 1. Fresh running worker (healthy, not stalled)
printf 'running' > "$SDIR/worker-stall.status"
NOW_ISO="$(date -u +%FT%TZ)"
cat > "$SDIR/worker-stall.meta" <<EOF
machine=local
mode=dispatch
created=$NOW_ISO
EOF

if python3 "$ENGINE/bin/fleet_common.py" check-stall "$ROOT/wt/worker-stall" "$SDIR/worker-stall.status" "$SDIR/worker-stall.meta"; then
  fail "fresh worker incorrectly flagged as stalled by check-stall"
fi

stall_info_json="$(python3 "$ENGINE/bin/fleet_common.py" stall-info "$ROOT/wt/worker-stall" "$SDIR/worker-stall.status" "$SDIR/worker-stall.meta")"
echo "$stall_info_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["stalled"] is False, ("expected stalled=False, got %s" % data["stalled"])
assert data["stall_threshold_sec"] == 1200, ("expected 1200, got %s" % data["stall_threshold_sec"])
assert data["last_activity"] is not None
assert data["activity_age_sec"] is not None and data["activity_age_sec"] < 30
' || fail "fresh worker stall-info JSON validation failed"

status_json="$("$ENGINE/bin/fleet" --project sandbox status --json)" || fail "fleet status --json failed: $status_json"
echo "$status_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
w = data["projects"][0]["machines"][0]["sessions"]["workers"][0]
assert w["name"] == "worker-stall"
assert w["dispatch_status"] == "running"
assert w["stalled"] is False
assert w["stall_threshold_sec"] == 1200
assert w["last_activity"] is not None
assert w["activity_age_sec"] is not None and w["activity_age_sec"] < 30
' || fail "fresh worker fleet status JSON validation failed"

status_text="$("$ENGINE/bin/fleet" --project sandbox status)" || fail "fleet status text failed: $status_text"
echo "$status_text" | grep -q "worker-stall.*(running)" || fail "text status missing (running): $status_text"
if echo "$status_text" | grep -q "(running (stalled))"; then
  fail "fresh worker shown as stalled in text status: $status_text"
fi

ls_out="$("$ENGINE/bin/fleet" --project sandbox ls 2>&1)" || fail "fleet ls failed: $ls_out"
echo "$ls_out" | grep -q "\[dispatch: running\]" || fail "fleet ls missing [dispatch: running]: $ls_out"
if echo "$ls_out" | grep -q "stalled"; then
  fail "fresh worker marked stalled in fleet ls: $ls_out"
fi
echo "PASS: fresh running worker is healthy in check-stall, stall-info, status, and ls"

# 2. Worker with no activity for > 20m is stalled
age_worker worker-stall "$ROOT/wt/worker-stall" "30 minutes ago"

if ! python3 "$ENGINE/bin/fleet_common.py" check-stall "$ROOT/wt/worker-stall" "$SDIR/worker-stall.status" "$SDIR/worker-stall.meta"; then
  fail "inactive worker not detected as stalled by check-stall"
fi

status_json="$("$ENGINE/bin/fleet" --project sandbox status --json)" || fail "fleet status --json failed: $status_json"
echo "$status_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
w = data["projects"][0]["machines"][0]["sessions"]["workers"][0]
assert w["stalled"] is True, ("expected stalled=True, got %s" % w["stalled"])
assert w["activity_age_sec"] >= 1700, ("expected age >= 1700, got %s" % w["activity_age_sec"])
' || fail "stalled worker fleet status JSON validation failed"

status_text="$("$ENGINE/bin/fleet" --project sandbox status)" || fail "fleet status text failed: $status_text"
echo "$status_text" | grep -q "(running (stalled))" || fail "text status missing (running (stalled)): $status_text"

ls_out="$("$ENGINE/bin/fleet" --project sandbox ls 2>&1)" || fail "fleet ls failed: $ls_out"
echo "$ls_out" | grep -q "\[dispatch: running (stalled)\]" || fail "fleet ls did not report running (stalled): $ls_out"

wait_rc=0
wait_out="$("$ENGINE/bin/fleet" --project sandbox wait worker-stall 2>&1)" || wait_rc=$?
[ "$wait_rc" -eq 3 ] || fail "fleet wait expected rc=3 on stalled worker, got rc=$wait_rc ($wait_out)"
echo "$wait_out" | grep -q "running (stalled)" || fail "fleet wait output missing running (stalled): $wait_out"
echo "PASS: inactive worker reported as stalled in check-stall, status, ls, and wait"

# 3. Worktree activity resets stall
echo "# progress" >> "$ROOT/wt/worker-stall/hello.py"
touch "$ROOT/wt/worker-stall/hello.py"

if python3 "$ENGINE/bin/fleet_common.py" check-stall "$ROOT/wt/worker-stall" "$SDIR/worker-stall.status" "$SDIR/worker-stall.meta"; then
  fail "active worktree with dirty file still flagged as stalled by check-stall"
fi

status_json="$("$ENGINE/bin/fleet" --project sandbox status --json)" || fail "fleet status --json failed: $status_json"
echo "$status_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
w = data["projects"][0]["machines"][0]["sessions"]["workers"][0]
assert w["stalled"] is False, ("expected stalled=False after activity, got %s" % w["stalled"])
assert w["activity_age_sec"] < 10, ("expected fresh age, got %s" % w["activity_age_sec"])
' || fail "activity reset JSON validation failed"

status_text="$("$ENGINE/bin/fleet" --project sandbox status)" || fail "fleet status text failed: $status_text"
echo "$status_text" | grep -q "worker-stall.*(running)" || fail "text status did not reset: $status_text"
if echo "$status_text" | grep -q "(running (stalled))"; then
  fail "text status still shows stalled after activity: $status_text"
fi

ls_out="$("$ENGINE/bin/fleet" --project sandbox ls 2>&1)" || fail "fleet ls failed: $ls_out"
echo "$ls_out" | grep -q "\[dispatch: running\]" || fail "fleet ls did not reset to [dispatch: running]: $ls_out"
echo "PASS: worktree progress resets stall signal in check-stall, status, and ls"

# 4. Project WORKER_STALL_MINUTES configuration (override and disable)
git -C "$ROOT/wt/worker-stall" checkout -- hello.py
age_worker worker-stall "$ROOT/wt/worker-stall" "30 minutes ago"

echo "WORKER_STALL_MINUTES=50" >> "$FLEET_HOME/projects/sandbox.env"
status_json="$("$ENGINE/bin/fleet" --project sandbox status --json)" || fail "fleet status --json failed"
echo "$status_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
w = data["projects"][0]["machines"][0]["sessions"]["workers"][0]
assert w["stall_threshold_sec"] == 3000, ("expected 3000, got %s" % w["stall_threshold_sec"])
assert w["stalled"] is False, ("expected stalled=False (30m < 50m threshold), got %s" % w["stalled"])
' || fail "threshold override validation failed"

sed -i '/WORKER_STALL_MINUTES/d' "$FLEET_HOME/projects/sandbox.env"
echo "WORKER_STALL_MINUTES=0" >> "$FLEET_HOME/projects/sandbox.env"

status_json="$("$ENGINE/bin/fleet" --project sandbox status --json)" || fail "fleet status --json failed"
echo "$status_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
w = data["projects"][0]["machines"][0]["sessions"]["workers"][0]
assert w["stall_threshold_sec"] == 0
assert w["stalled"] is False
' || fail "WORKER_STALL_MINUTES=0 validation failed"

ls_out="$("$ENGINE/bin/fleet" --project sandbox ls 2>&1)" || fail "fleet ls failed: $ls_out"
if echo "$ls_out" | grep -q "stalled"; then
  fail "WORKER_STALL_MINUTES=0 did not disable stall detection in fleet ls: $ls_out"
fi

if WORKER_STALL_MINUTES=0 python3 "$ENGINE/bin/fleet_common.py" check-stall "$ROOT/wt/worker-stall" "$SDIR/worker-stall.status" "$SDIR/worker-stall.meta"; then
  fail "check-stall should return non-zero when WORKER_STALL_MINUTES=0"
fi
echo "PASS: WORKER_STALL_MINUTES overrides threshold and disables detection (0)"

# 5. fleet wait exit codes on completed workers
sed -i '/WORKER_STALL_MINUTES/d' "$FLEET_HOME/projects/sandbox.env"
printf 'done rc=0' > "$SDIR/worker-stall.status"
wait_rc=0
"$ENGINE/bin/fleet" --project sandbox wait worker-stall >/dev/null 2>&1 || wait_rc=$?
[ "$wait_rc" -eq 0 ] || fail "fleet wait expected rc=0 on done rc=0, got $wait_rc"

printf 'done rc=1' > "$SDIR/worker-stall.status"
wait_rc=0
"$ENGINE/bin/fleet" --project sandbox wait worker-stall >/dev/null 2>&1 || wait_rc=$?
[ "$wait_rc" -eq 1 ] || fail "fleet wait expected rc=1 on done rc=1, got $wait_rc"
echo "PASS: fleet wait exits 0 on success and 1 on worker failure"

echo "PASS: all worker stall detection and health unit tests passed"
