#!/usr/bin/env bash
# test-worker-health.sh — worker supervision and stall health in fleet status.
#
# Verifies that fleet status (text and --json) exposes worker health metrics:
# last_activity, activity_age_sec, stall_threshold_sec, and stalled flag.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENGINE="$(cd "$SELF_DIR/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d "$HOME/fleet-health-test.XXXXXX")"
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

git -C "$ROOT/code" worktree add -q "$ROOT/wt/worker-health" -b worker-health
SDIR="$FLEET_HOME/dispatch/sandbox"
mkdir -p "$SDIR"

# 1. Fresh running worker
printf 'running' > "$SDIR/worker-health.status"
NOW_ISO="$(date -u +%FT%TZ)"
cat > "$SDIR/worker-health.meta" <<EOF
machine=local
mode=dispatch
created=$NOW_ISO
EOF

status_json="$("$ENGINE/bin/fleet" --project sandbox status --json)" || fail "fleet status --json failed: $status_json"
echo "$status_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
proj = data["projects"][0]
local_m = [m for m in proj["machines"] if m.get("local")][0]
workers = local_m["sessions"]["workers"]
assert len(workers) == 1, ("expected 1 worker, got %d" % len(workers))
w = workers[0]
assert w["name"] == "worker-health"
assert w["dispatch_status"] == "running"
assert w["stalled"] is False, ("expected stalled=False, got %s" % w["stalled"])
assert w["stall_threshold_sec"] == 1200, ("expected 1200, got %s" % w["stall_threshold_sec"])
assert w["last_activity"] is not None
assert w["activity_age_sec"] is not None and w["activity_age_sec"] < 30
' || fail "fresh worker JSON health validation failed"

status_text="$("$ENGINE/bin/fleet" --project sandbox status)" || fail "fleet status text failed: $status_text"
echo "$status_text" | grep -q "worker-health.*(running)" || fail "text status missing (running): $status_text"
if echo "$status_text" | grep -q "(running (stalled))"; then
  fail "fresh worker shown as stalled in text status: $status_text"
fi
echo "PASS: fresh worker exposes healthy non-stalled metrics in fleet status"

# 2. Worker inactive past threshold is flagged stalled
PAST_ISO="$(date -u -d '30 minutes ago' +%FT%TZ)"
cat > "$SDIR/worker-health.meta" <<EOF
machine=local
mode=dispatch
created=$PAST_ISO
EOF
touch -d '30 minutes ago' "$SDIR/worker-health.status"
touch -d '30 minutes ago' "$SDIR/worker-health.meta"
git_ref="$ROOT/wt/worker-health/.git"
if [ -f "$git_ref" ]; then
  real_gitdir="$(sed 's/^gitdir: //' "$git_ref")"
  touch -d '30 minutes ago' "$real_gitdir/index"
else
  touch -d '30 minutes ago' "$ROOT/wt/worker-health/.git/index"
fi

status_json="$("$ENGINE/bin/fleet" --project sandbox status --json)" || fail "fleet status --json failed: $status_json"
echo "$status_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
w = data["projects"][0]["machines"][0]["sessions"]["workers"][0]
assert w["stalled"] is True, ("expected stalled=True, got %s" % w["stalled"])
assert w["activity_age_sec"] >= 1700, ("expected age >= 1700, got %s" % w["activity_age_sec"])
' || fail "stalled worker JSON validation failed"

status_text="$("$ENGINE/bin/fleet" --project sandbox status)" || fail "fleet status text failed: $status_text"
echo "$status_text" | grep -q "(running (stalled))" || fail "text status missing (running (stalled)): $status_text"
echo "PASS: stalled worker flagged in JSON and text status"

# 3. Worktree activity resets stall in fleet status
echo "code change" >> "$ROOT/wt/worker-health/hello.py"
touch "$ROOT/wt/worker-health/hello.py"

status_json="$("$ENGINE/bin/fleet" --project sandbox status --json)" || fail "fleet status --json failed: $status_json"
echo "$status_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
w = data["projects"][0]["machines"][0]["sessions"]["workers"][0]
assert w["stalled"] is False, ("expected stalled=False after activity, got %s" % w["stalled"])
assert w["activity_age_sec"] < 10, ("expected fresh age, got %s" % w["activity_age_sec"])
' || fail "activity reset JSON validation failed"
echo "PASS: worktree activity resets stall in fleet status"

# 4. Project .env threshold customization and disable (0)
git -C "$ROOT/wt/worker-health" checkout -- hello.py
touch -d '30 minutes ago' "$SDIR/worker-health.status"
touch -d '30 minutes ago' "$SDIR/worker-health.meta"
if [ -f "$git_ref" ]; then
  real_gitdir="$(sed 's/^gitdir: //' "$git_ref")"
  touch -d '30 minutes ago' "$real_gitdir/index"
fi

echo "WORKER_STALL_MINUTES=50" >> "$FLEET_HOME/projects/sandbox.env"
status_json="$("$ENGINE/bin/fleet" --project sandbox status --json)" || fail "fleet status --json failed"
echo "$status_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
w = data["projects"][0]["machines"][0]["sessions"]["workers"][0]
assert w["stall_threshold_sec"] == 3000, ("expected 3000, got %s" % w["stall_threshold_sec"])
assert w["stalled"] is False, ("expected stalled=False (30m < 50m threshold), got %s" % w["stalled"])
' || fail "threshold override validation failed"

echo "WORKER_STALL_MINUTES=0" > "$FLEET_HOME/projects/sandbox.env.tmp"
grep -v "WORKER_STALL_MINUTES" "$FLEET_HOME/projects/sandbox.env" >> "$FLEET_HOME/projects/sandbox.env.tmp"
mv "$FLEET_HOME/projects/sandbox.env.tmp" "$FLEET_HOME/projects/sandbox.env"
echo "WORKER_STALL_MINUTES=0" >> "$FLEET_HOME/projects/sandbox.env"

status_json="$("$ENGINE/bin/fleet" --project sandbox status --json)" || fail "fleet status --json failed"
echo "$status_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
w = data["projects"][0]["machines"][0]["sessions"]["workers"][0]
assert w["stall_threshold_sec"] == 0
assert w["stalled"] is False
' || fail "WORKER_STALL_MINUTES=0 validation failed"
echo "PASS: project configuration overrides and disables stall threshold"

echo "PASS: all worker health status tests passed"
