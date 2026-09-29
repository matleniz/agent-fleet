#!/usr/bin/env bash
# test-orphan-windows.sh — MAT-122: tmux windows that outlive their worktree
# (or were never tied to one) must show up in `fleet ls` / `fleet status`, and
# `fleet prune --windows` must reap them. Live orphans need --force.
#
# Needs tmux. Builds a throwaway sandbox under a temp FLEET_HOME so the real
# sandbox / production config are untouched. Exits non-zero on failure; skips
# (exit 0) without tmux.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENGINE="$(cd "$SELF_DIR/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v tmux >/dev/null || { echo "SKIP: tmux not installed"; exit 0; }

TMP="$(mktemp -d "$HOME/fleet-orphan-test.XXXXXX")"
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

# Isolated session matching the sandbox's LOCAL_TMUX default (fleet-sandbox).
tmux kill-session -t "$SESS" 2>/dev/null || true
tmux new-session -d -s "$SESS" -n _home
tmux new-window -d -t "$SESS" -n hub "exec bash"

# --- fixture: three orphan shapes ---
# 1) no-worktree idle (ad-hoc pane, like the stray `cursor` window)
tmux new-window -d -t "$SESS" -n stray-idle "exec bash"
# 2) deleted-path live (cwd wiped while a process still runs — the reported bug)
deldir="$(mktemp -d)"
tmux new-window -d -t "$SESS" -n gone-live -c "$deldir" "exec sleep 600"
rm -rf "$deldir"
# 3) reserved windows must NEVER be reported as orphans
# (_home + hub already exist)

# Give tmux a beat to refresh pane_current_path after the rmdir.
for _ in $(seq 1 20); do
  path="$(tmux display-message -p -t "$SESS:gone-live" '#{pane_current_path}' 2>/dev/null || true)"
  case "$path" in *" (deleted)") break ;; esac
  sleep 0.1
done
case "$(tmux display-message -p -t "$SESS:gone-live" '#{pane_current_path}')" in
  *" (deleted)") ;;
  *) fail "fixture: gone-live pane path never showed (deleted)" ;;
esac

# --- fleet ls surfaces orphans ---
ls_out="$("$ENGINE/bin/fleet" --project sandbox ls 2>&1)" || fail "fleet ls errored"
echo "$ls_out" | grep -q "orphan windows" || fail "fleet ls missing orphan section: $ls_out"
echo "$ls_out" | grep -qE 'stray-idle +idle +no-worktree' \
  || fail "fleet ls missing idle no-worktree orphan: $ls_out"
echo "$ls_out" | grep -qE 'gone-live +live +deleted-path' \
  || fail "fleet ls missing live deleted-path orphan: $ls_out"
echo "$ls_out" | grep -qE ' (hub|_home) ' && fail "fleet ls reported reserved window as orphan: $ls_out"
echo "PASS: fleet ls lists orphan windows (idle + live) and skips hub/_home"

# --- fleet status --json includes orphans[] ---
json="$("$ENGINE/bin/fleet" --project sandbox status --json 2>&1)" \
  || fail "fleet status --json errored"
python3 -c '
import json, os, sys
data = json.loads(sys.stdin.read())
proj = data["projects"][0]
sess = None
for m in proj["machines"]:
    if m.get("local") and m.get("sessions") is not None:
        sess = m["sessions"]; break
assert sess is not None, "no local sessions"
orphans = {o["name"]: o for o in sess.get("orphans") or []}
assert "stray-idle" in orphans, orphans
assert orphans["stray-idle"]["reason"] == "no-worktree"
assert orphans["stray-idle"]["live"] is False
assert "gone-live" in orphans, orphans
assert orphans["gone-live"]["reason"] == "deleted-path"
assert orphans["gone-live"]["live"] is True
assert "hub" not in orphans and "_home" not in orphans
print("PASS: status --json orphans[] matches ls")
' <<<"$json"

# --- plain prune reports orphans but does not kill ---
prune_out="$("$ENGINE/bin/fleet" --project sandbox prune 2>&1)" || fail "fleet prune errored"
echo "$prune_out" | grep -q "orphan windows" || fail "plain prune did not report orphans: $prune_out"
tmux list-windows -t "$SESS" -F '#{window_name}' | grep -Fxq stray-idle \
  || fail "plain prune killed stray-idle (must only report)"
tmux list-windows -t "$SESS" -F '#{window_name}' | grep -Fxq gone-live \
  || fail "plain prune killed gone-live (must only report)"
echo "PASS: plain fleet prune reports orphans without killing"

# --- prune --windows reaps idle, skips live without --force ---
win_out="$("$ENGINE/bin/fleet" --project sandbox prune --windows 2>&1)" \
  || fail "fleet prune --windows errored"
echo "$win_out" | grep -qE 'reap +stray-idle' || fail "did not reap idle orphan: $win_out"
echo "$win_out" | grep -qE 'skip +gone-live.*live' \
  || fail "did not skip live orphan without --force: $win_out"
if tmux list-windows -t "$SESS" -F '#{window_name}' 2>/dev/null | grep -Fxq stray-idle; then
  fail "stray-idle still present after prune --windows"
fi
tmux list-windows -t "$SESS" -F '#{window_name}' | grep -Fxq gone-live \
  || fail "gone-live was killed without --force"
echo "PASS: prune --windows reaps idle, skips live"

# --- --force prune --windows kills the live orphan ---
force_out="$("$ENGINE/bin/fleet" --project sandbox --force prune --windows 2>&1)" \
  || fail "fleet --force prune --windows errored"
echo "$force_out" | grep -qE 'reap +gone-live' || fail "did not reap live orphan with --force: $force_out"
if tmux list-windows -t "$SESS" -F '#{window_name}' 2>/dev/null | grep -Fxq gone-live; then
  fail "gone-live still present after --force prune --windows"
fi
# Reserved windows survive
tmux list-windows -t "$SESS" -F '#{window_name}' | grep -Fxq _home \
  || fail "_home was killed"
tmux list-windows -t "$SESS" -F '#{window_name}' | grep -Fxq hub \
  || fail "hub was killed"
echo "PASS: --force prune --windows reaps live orphans; hub/_home kept"

echo "PASS: orphan window detect + prune --windows (MAT-122)"
