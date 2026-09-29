#!/usr/bin/env bash
# test-stale-done-windows.sh — leftover `_done-*` panes after worktree removal.
#
# Orphan detect + `prune --windows`. The remaining gap: when the
# worktree is already gone, `fleet del <name>` used to error out and leave the
# idle `_done-<name>` pane; plain `fleet prune` only reported orphans. Both
# paths must reap safe idle `_done-*` leftovers without a hand `tmux kill-window`.
#
# Needs tmux. Throwaway FLEET_HOME. Skips (exit 0) without tmux.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENGINE="$(cd "$SELF_DIR/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v tmux >/dev/null || { echo "SKIP: tmux not installed"; exit 0; }

TMP="$(mktemp -d "$HOME/fleet-stale-done-test.XXXXXX")"
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

# --- fixture: finished-dispatch pane whose worktree is already gone ----------
# Simulate: dispatch renamed to _done-gone, worktree removed outside fleet
# (or a prior del that only removed the tree). Idle bash = safe to reap.
tmux new-window -d -t "$SESS" -n _done-gone "exec bash"
mkdir -p "$FLEET_HOME/dispatch/sandbox"
printf 'done rc=0' > "$FLEET_HOME/dispatch/sandbox/gone.status"
printf 'mode=dispatch\n' > "$FLEET_HOME/dispatch/sandbox/gone.meta"

# Non-_done idle orphan must NOT be auto-reaped by plain prune.
tmux new-window -d -t "$SESS" -n stray-idle "exec bash"

# --- fleet del <name> with no worktree still reaps _done-<name> --------------
del_out="$("$ENGINE/bin/fleet" --project sandbox del gone 2>&1)" \
  || fail "fleet del gone (no worktree) errored: $del_out"
echo "$del_out" | grep -q "reaped leftover" \
  || fail "del did not report leftover reap: $del_out"
if tmux list-windows -t "$SESS" -F '#{window_name}' 2>/dev/null | grep -Fxq -- '_done-gone'; then
  fail "fleet del left _done-gone behind"
fi
[ ! -f "$FLEET_HOME/dispatch/sandbox/gone.status" ] \
  || fail "del left gone.status behind"
echo "PASS: fleet del reaps leftover _done-<name> when worktree is already gone"

# --- plain prune auto-reaps idle _done-* orphans, keeps other idle orphans ---
tmux new-window -d -t "$SESS" -n _done-old "exec bash"
printf 'done rc=0' > "$FLEET_HOME/dispatch/sandbox/old.status"

prune_out="$("$ENGINE/bin/fleet" --project sandbox prune 2>&1)" \
  || fail "fleet prune errored: $prune_out"
echo "$prune_out" | grep -qE 'reap +_done-old' \
  || fail "plain prune did not reap idle _done-old: $prune_out"
if tmux list-windows -t "$SESS" -F '#{window_name}' 2>/dev/null | grep -Fxq -- '_done-old'; then
  fail "_done-old still present after plain prune"
fi
tmux list-windows -t "$SESS" -F '#{window_name}' | grep -Fxq stray-idle \
  || fail "plain prune killed stray-idle (must only auto-reap idle _done-*)"
echo "PASS: plain prune auto-reaps idle _done-* orphans; leaves other orphans"

# Reserved windows survive
tmux list-windows -t "$SESS" -F '#{window_name}' | grep -Fxq _home \
  || fail "_home was killed"
tmux list-windows -t "$SESS" -F '#{window_name}' | grep -Fxq hub \
  || fail "hub was killed"

echo "PASS: stale _done- window cleanup (del without worktree + prune idle _done-)"
