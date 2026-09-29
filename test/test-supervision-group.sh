#!/usr/bin/env bash
# test-supervision-group.sh — final group e2e test covering all supervision capabilities:
# 1. Deliverable verification (--deliverable pr, done-without-deliverable vs done rc=0)
# 2. Long foreground server child detection (blocked-on-foreground-process in ls and status)
# 3. Stall supervision and coordinator wakeup (fleet wait exit code 3 and parseable summary)
# 4. Auto-retry and pack fallback policy across AGENTS with supervision.log journaling
# 5. Full lifecycle completion and teardown
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENGINE="$(cd "$SELF_DIR/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v tmux >/dev/null || { echo "SKIP: tmux not installed"; exit 0; }

TMP="$(mktemp -d "$HOME/fleet-supervision-group-test.XXXXXX")"
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

export FLEET_WAIT_POLL=1
PAST_COMMIT_DATE="$(date -d '2 hours ago' --iso-8601=seconds)"
GIT_COMMITTER_DATE="$PAST_COMMIT_DATE" git -C "$ROOT/code" commit -q --amend --date="$PAST_COMMIT_DATE" --no-edit

tmux kill-session -t "$SESS" 2>/dev/null || true
tmux new-session -d -s "$SESS" -n _home
tmux new-window -d -t "$SESS" -n hub "exec bash"

SDIR="$FLEET_HOME/dispatch/sandbox"
mkdir -p "$SDIR"
echo "AGENTS=\"claude gemini\"" >> "$FLEET_HOME/projects/sandbox.env"
echo "WORKER_STALL_MINUTES=20" >> "$FLEET_HOME/projects/sandbox.env"

# --- 1. Dispatch worker with deliverable requirement & wake instruction ---
git -C "$ROOT/code" worktree add -q "$ROOT/wt/worker-grp" -b worker-grp
disp_out="$("$ENGINE/bin/fleet" --project sandbox dispatch --deliverable pr worker-grp "Complete feature with PR" 2>&1)" || fail "dispatch failed: $disp_out"
echo "$disp_out" | grep -q "wake coordinator: run 'fleet wait worker-grp' in background" || fail "missing wake hint in dispatch output"
meta_deliv="$(sed -n 's/^deliverable=//p' "$SDIR/worker-grp.meta" 2>/dev/null)"
[ "$meta_deliv" = "pr" ] || fail "deliverable=pr not saved in meta"
echo "PASS: 1. dispatch with deliverable check and wake hint"

# --- 2. Foreground blocking server detection ---
tmux kill-window -t "$SESS:worker-grp" 2>/dev/null || true
tmux new-window -d -t "$SESS" -n worker-grp "python3 -m http.server 19991"
sleep 1
ls_out="$("$ENGINE/bin/fleet" --project sandbox ls 2>&1)" || fail "fleet ls failed: $ls_out"
echo "$ls_out" | grep -q "blocked-on-foreground-process (http.server)" || fail "ls missing blocked-on-foreground-process: $ls_out"

status_json="$("$ENGINE/bin/fleet" --project sandbox status --json 2>&1)" || fail "status --json failed: $status_json"
echo "$status_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
w = [x for x in data["projects"][0]["machines"][0]["sessions"]["workers"] if x["name"] == "worker-grp"][0]
assert w["blocked_on_server"] == "http.server"
' || fail "status --json missing blocked_on_server"
echo "PASS: 2. foreground server detection"

# --- 3. Inactivity triggers stall & coordinator wake-up ---
past_iso="$(date -u -d '30 minutes ago' +%FT%TZ)"
sed -i "s/^created=.*/created=$past_iso/" "$SDIR/worker-grp.meta"
touch -d '30 minutes ago' "$SDIR/worker-grp.status"
git_ref="$ROOT/wt/worker-grp/.git"
if [ -f "$git_ref" ]; then
  real_gitdir="$(sed 's/^gitdir: //' "$git_ref")"
  touch -d '30 minutes ago' "$real_gitdir/index"
else
  touch -d '30 minutes ago' "$ROOT/wt/worker-grp/.git/index"
fi

wait_rc=0
wait_out="$("$ENGINE/bin/fleet" --project sandbox wait worker-grp 2>&1)" || wait_rc=$?
[ "$wait_rc" -eq 3 ] || fail "fleet wait expected rc=3 on stalled worker, got $wait_rc ($wait_out)"
echo "$wait_out" | grep -q "summary: worker=worker-grp" || fail "missing parseable summary in wait output"
echo "PASS: 3. stall detection and coordinator wake-up with parseable summary"

# --- 4. Auto-retry & fallback policy ---
echo "WORKER_MAX_RETRIES=1" >> "$FLEET_HOME/projects/sandbox.env"
source "$ENGINE/bin/fleet-config.sh"
fleet_resolve_conf sandbox >/dev/null 2>&1
PROJ_NAME="sandbox"
rotate_events_log() { :; }
cmd_dispatch() { :; }
source <(sed -n '/worker_trigger_retry_or_fallback()/,/^}/p' "$ENGINE/bin/fleet")
source <(sed -n '/worker_next_agent()/,/^}/p' "$ENGINE/bin/fleet")
source <(sed -n '/dispatch_state_dir()/,/^}/p' "$ENGINE/bin/fleet")
source <(sed -n '/dispatch_tmux()/,/^}/p' "$ENGINE/bin/fleet")

# First retry
worker_trigger_retry_or_fallback worker-grp "stall" || fail "first retry failed"
grep -q "worker-grp retry pack=claude attempt=1/1" "$SDIR/supervision.log" || fail "missing retry in supervision.log"

# Second retry exceeds max_retries -> falls back to gemini
worker_trigger_retry_or_fallback worker-grp "stall" || fail "fallback failed"
grep -q "worker-grp fallback from=claude to=gemini" "$SDIR/supervision.log" || fail "missing fallback in supervision.log"
echo "PASS: 4. auto-retry and pack fallback across AGENTS"

# --- 5. Deliverable verification on exit ---
# Worker finishes rc=0 but without PR -> done-without-deliverable
printf 'done-without-deliverable' > "$SDIR/worker-grp.status"
ls_out="$("$ENGINE/bin/fleet" --project sandbox ls 2>&1)" || fail "fleet ls failed: $ls_out"
echo "$ls_out" | grep -q "\[dispatch: done-without-deliverable\]" || fail "ls missing done-without-deliverable: $ls_out"

# Worker fulfills PR
echo "https://github.com/example/repo/pull/999" > "$SDIR/worker-grp.pr"
echo "finished code" >> "$ROOT/wt/worker-grp/hello.py"
git -C "$ROOT/wt/worker-grp" add hello.py
git -C "$ROOT/wt/worker-grp" commit -q -m "feat: complete feature"
printf 'done rc=0' > "$SDIR/worker-grp.status"

wait_rc=0
wait_out="$("$ENGINE/bin/fleet" --project sandbox wait worker-grp 2>&1)" || wait_rc=$?
[ "$wait_rc" -eq 0 ] || fail "fleet wait expected rc=0 on success, got $wait_rc ($wait_out)"
echo "$wait_out" | grep -q "commits=1" || fail "wait summary missing commits=1: $wait_out"
echo "$wait_out" | grep -q "pr=https://github.com/example/repo/pull/999" || fail "wait summary missing pr url: $wait_out"
echo "PASS: 5. deliverable check and clean completion"

echo "PASS: all group supervision e2e tests passed"
