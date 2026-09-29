#!/usr/bin/env bash
# test-worker-stall.sh — headless worker stall detection in fleet ls and fleet wait.
#
# A running headless worker with no worktree progress for WORKER_STALL_MINUTES
# is flagged as stalled so coordinators wake up (fleet wait exits 3). Activity
# in the worktree resets the stall clock; setting WORKER_STALL_MINUTES=0 disables it.
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

# Age the initial commit so it predates our simulated worker creation time
PAST_COMMIT_DATE="$(date -d '2 hours ago' --iso-8601=seconds)"
GIT_COMMITTER_DATE="$PAST_COMMIT_DATE" git -C "$ROOT/code" commit -q --amend --date="$PAST_COMMIT_DATE" --no-edit

# Create a worker worktree
git -C "$ROOT/code" worktree add -q "$ROOT/wt/worker-stall" -b worker-stall
SDIR="$FLEET_HOME/dispatch/sandbox"
mkdir -p "$SDIR"

# 1. Fresh running worker (healthy, not stalled)
printf 'running' > "$SDIR/worker-stall.status"
cat > "$SDIR/worker-stall.meta" <<EOF
machine=local
mode=dispatch
created=$(date -u +%FT%TZ)
EOF

if python3 "$ENGINE/bin/fleet_common.py" check-stall "$ROOT/wt/worker-stall" "$SDIR/worker-stall.status" "$SDIR/worker-stall.meta"; then
  fail "fresh worker incorrectly flagged as stalled"
fi

ls_out="$("$ENGINE/bin/fleet" --project sandbox ls 2>&1)" || fail "fleet ls failed: $ls_out"
echo "$ls_out" | grep -q "\[dispatch: running\]" || fail "fleet ls missing [dispatch: running]: $ls_out"
if echo "$ls_out" | grep -q "stalled"; then
  fail "fresh worker marked stalled in fleet ls: $ls_out"
fi
echo "PASS: fresh running worker is not stalled in fleet ls"

# 2. Worker with no activity for > 20m is stalled
# Push timestamps back 30 minutes
PAST_ISO="$(date -u -d '30 minutes ago' +%FT%TZ)"
cat > "$SDIR/worker-stall.meta" <<EOF
machine=local
mode=dispatch
created=$PAST_ISO
EOF
touch -d '30 minutes ago' "$SDIR/worker-stall.status"
touch -d '30 minutes ago' "$SDIR/worker-stall.meta"

# Worktree index / gitdir mtimes pushed back
git_ref="$ROOT/wt/worker-stall/.git"
if [ -f "$git_ref" ]; then
  real_gitdir="$(sed 's/^gitdir: //' "$git_ref")"
  touch -d '30 minutes ago' "$real_gitdir/index"
else
  touch -d '30 minutes ago' "$ROOT/wt/worker-stall/.git/index"
fi

if ! python3 "$ENGINE/bin/fleet_common.py" check-stall "$ROOT/wt/worker-stall" "$SDIR/worker-stall.status" "$SDIR/worker-stall.meta"; then
  fail "inactive worker not detected as stalled by check-stall"
fi

ls_out="$("$ENGINE/bin/fleet" --project sandbox ls 2>&1)" || fail "fleet ls failed: $ls_out"
echo "$ls_out" | grep -q "\[dispatch: running (stalled)\]" || fail "fleet ls did not report running (stalled): $ls_out"
echo "PASS: inactive worker reported as [dispatch: running (stalled)] in fleet ls"

# fleet wait stops blocking and exits 3 on stalled worker
wait_rc=0
wait_out="$("$ENGINE/bin/fleet" --project sandbox wait worker-stall 2>&1)" || wait_rc=$?
[ "$wait_rc" -eq 3 ] || fail "fleet wait expected rc=3 on stalled worker, got rc=$wait_rc ($wait_out)"
echo "$wait_out" | grep -q "running (stalled)" || fail "fleet wait output missing running (stalled): $wait_out"
echo "PASS: fleet wait exits 3 on stalled worker"

# 3. Worktree activity resets stall
echo "# progress" >> "$ROOT/wt/worker-stall/hello.py"
touch "$ROOT/wt/worker-stall/hello.py"

if python3 "$ENGINE/bin/fleet_common.py" check-stall "$ROOT/wt/worker-stall" "$SDIR/worker-stall.status" "$SDIR/worker-stall.meta"; then
  fail "active worktree with dirty file still flagged as stalled"
fi

ls_out="$("$ENGINE/bin/fleet" --project sandbox ls 2>&1)" || fail "fleet ls failed: $ls_out"
echo "$ls_out" | grep -q "\[dispatch: running\]" || fail "fleet ls did not reset to [dispatch: running]: $ls_out"
echo "PASS: worktree progress resets stall signal"

# 4. WORKER_STALL_MINUTES=0 disables stall detection
git -C "$ROOT/wt/worker-stall" checkout -- hello.py
touch -d '30 minutes ago' "$SDIR/worker-stall.status"
touch -d '30 minutes ago' "$SDIR/worker-stall.meta"
if [ -f "$git_ref" ]; then
  real_gitdir="$(sed 's/^gitdir: //' "$git_ref")"
  touch -d '30 minutes ago' "$real_gitdir/index"
else
  touch -d '30 minutes ago' "$ROOT/wt/worker-stall/.git/index"
fi

echo "WORKER_STALL_MINUTES=0" >> "$FLEET_HOME/projects/sandbox.env"
ls_out="$("$ENGINE/bin/fleet" --project sandbox ls 2>&1)" || fail "fleet ls failed: $ls_out"
if echo "$ls_out" | grep -q "stalled"; then
  fail "WORKER_STALL_MINUTES=0 did not disable stall detection in fleet ls: $ls_out"
fi
echo "PASS: WORKER_STALL_MINUTES=0 disables stall detection"

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

echo "PASS: all worker stall detection tests passed"
