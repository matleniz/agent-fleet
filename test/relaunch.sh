#!/usr/bin/env bash
# relaunch.sh — prove `fleet w <name>` RELAUNCHES the agent in a window whose
# process died, and leaves an alive window untouched (no agent kill).
#
# The bug this pins down: windows are launched as "<cmd>; exec bash", so a dead
# agent leaves the window alive as a bare shell; the old select-or-create path
# would silently focus it instead of relaunching (the operator then ran the CLI
# by hand, outside the fleet posture). Detection subtlety (verified): tmux's
# #{pane_current_command} reports a shell for alive AND dead panes (the -c
# wrapper does no job control) — dead = the pane process has NO children.
#
# Scenarios (stub pack, no real agent, so no API in the way):
#   dead1  — pack_launch returns immediately → window falls back to bare bash →
#            a second `fleet w dead1` must respawn the launch (marker grows).
#   alive1 — pack_launch execs a long sleep (agent alive as pane child) →
#            a second `fleet w alive1` must NOT respawn (same pid, no marker).
#   hub    — same dead-window relaunch through bare `fleet` (the coordinator
#            path: cmd_hub → session_window hub), proving the fix is not
#            worker-only.
#   in-win — `fleet` typed INSIDE the dead hub window's own fallback shell (the
#            Ctrl+C-to-exit case) must relaunch in place, not no-op (needs the
#            context window_cmd exports + in_target_window in cmd_hub).
#
# Uses the DEFAULT tmux server but only the sandbox's own session
# (fleet-sandbox) + the fv-* views the attach attempts leave behind (no tty
# here, so the client never attaches and the view's self-destruct hook never
# fires); cleanup kills exactly those. FLEET_NO_GUARD=1: the resource guard
# counts every ^fleet session on the box and is not what this test proves.
# Exits non-zero on failure; skips without tmux.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENGINE="$(cd "$SELF_DIR/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v tmux >/dev/null || { echo "SKIP: tmux not installed"; exit 0; }
command -v ps   >/dev/null || { echo "SKIP: ps not installed (dead-detection needs it)"; exit 0; }

ROOT="$HOME/fleet-sandbox"
export FLEET_HOME="${FLEET_HOME:-$HOME/.config/fleet}"
# The window runs a bare `fleet` (production assumes ~/.local/bin symlinks); on
# a fresh tmux server (CI) windows inherit this PATH so the repo's bin resolves.
export PATH="$ENGINE/bin:$PATH"
"$SELF_DIR/make-sandbox.sh" "$ROOT" >/dev/null 2>&1 || fail "sandbox build failed"

# Stub pack. Absolute marker path baked in ($ROOT expands now): the window's
# environment is pinned by window_cmd (FLEET_* only), test vars don't reach it.
# Worker name (= worktree basename) selects the behavior: alive* stays running.
packs="$(mktemp -d)"; mkdir -p "$packs/stub"
cat > "$packs/stub/pack.sh" <<PACK
pack_launch()          { echo "\$(basename "\$PWD")" >> "$ROOT/launch.log"; case "\$(basename "\$PWD")" in alive*) exec sleep 300;; esac; }
pack_launch_headless() { : ; }
pack_has_sessions()    { return 1; }
pack_worker_setup()    { return 0; }
pack_barrier_files()   { : ; }
pack_install()         { echo "(stub)"; }
PACK
sed -i 's/^AGENTS=.*/AGENTS="stub"/' "$FLEET_HOME/projects/sandbox.env"

SESS="fleet-sandbox"
cleanup() {
  # Views first: they share the session's window group, so killing only the
  # original session would leave the windows (and the sleeps) alive in a view.
  tmux list-sessions -F '#{session_name}' 2>/dev/null \
    | grep "^fv-$SESS-" | while IFS= read -r s; do tmux kill-session -t "$s" 2>/dev/null || true; done
  tmux kill-session -t "$SESS" 2>/dev/null || true
  rm -rf "$packs"
}
trap cleanup EXIT

fleet_w() {  # <name> — run `fleet w <name> main`; the final attach has no tty here, so rc!=0 is expected
  FLEET_PACKS_DIR="$packs" FLEET_NO_GUARD=1 \
    "$ENGINE/bin/fleet" --project sandbox -a stub w "$1" main </dev/null >/dev/null 2>&1 || true
}

launches() {  # <name> — how many times the stub launched in that worktree/hub
  local c; c="$(grep -cx "$1" "$ROOT/launch.log" 2>/dev/null || true)"; echo "${c:-0}"
}
launched_more() { [ "$(launches "$1")" -gt "$2" ]; }  # <name> <n>
pane_pid() { tmux display-message -p -t "$SESS:$1" '#{pane_pid}' 2>/dev/null; }
wait_for() {  # <check-fn...> — poll up to 10s
  for _ in $(seq 1 50); do "$@" && return 0; sleep 0.2; done; return 1
}
pane_dead() { local p; p="$(pane_pid "$1")" && [ -n "$p" ] && ! ps -o pid= --ppid "$p" 2>/dev/null | grep -q .; }
pane_alive() { local p; p="$(pane_pid "$1")" && [ -n "$p" ] && ps -o pid= --ppid "$p" 2>/dev/null | grep -q .; }

# ---------- Scenario 1: dead window is relaunched ----------
: > "$ROOT/launch.log"
fleet_w dead1
wait_for test -d "$ROOT/wt/dead1" || fail "fleet w never created the dead1 worktree"
wait_for launched_more dead1 0 || fail "stub agent never launched in the dead1 window"
wait_for pane_dead dead1 || fail "dead1 window never fell back to a bare shell"
n_before="$(launches dead1)"
pid_before="$(pane_pid dead1)"

fleet_w dead1
wait_for launched_more dead1 "$n_before" \
  || fail "dead window was NOT relaunched (launch count stuck at $n_before — silent-select regression)"
[ "$(pane_pid dead1)" != "$pid_before" ] || fail "relaunch did not respawn the pane (same pid $pid_before)"
tmux list-windows -t "$SESS" -F '#{window_name}' | grep -Fxq dead1 \
  || fail "relaunch lost the dead1 window"
echo "PASS (scenario 1): fleet w relaunched the agent in a dead window (respawn, same window)"

# ---------- Scenario 2: alive window is left untouched ----------
fleet_w alive1
wait_for test -d "$ROOT/wt/alive1" || fail "fleet w never created the alive1 worktree"
# Wait for the LAUNCH MARKER, not just pane children: the in-window fleet is a
# pane child while it is still creating the worktree, before the agent starts —
# capturing the count then would race the first launch's own log line.
wait_for launched_more alive1 0 || fail "stub agent never launched in the alive1 window"
wait_for pane_alive alive1 || fail "stub agent not running in the alive1 window"
n_before="$(launches alive1)"
pid_before="$(pane_pid alive1)"

fleet_w alive1
sleep 1   # give a wrong respawn time to happen before asserting it did not
[ "$(pane_pid alive1)" = "$pid_before" ] || fail "ALIVE window was respawned (agent killed!) — pid $pid_before -> $(pane_pid alive1)"
[ "$(launches alive1)" = "$n_before" ] || fail "alive window relaunched the agent (count $n_before -> $(launches alive1))"
pane_alive alive1 || fail "alive1 agent no longer running after reopen"
echo "PASS (scenario 2): fleet w left the alive window's agent untouched"

# ---------- Scenario 3: the coordinator (bare `fleet`, hub window) too ----------
fleet_hub() {
  FLEET_PACKS_DIR="$packs" FLEET_NO_GUARD=1 \
    "$ENGINE/bin/fleet" --project sandbox -a stub </dev/null >/dev/null 2>&1 || true
}
fleet_hub
wait_for launched_more hub 0 || fail "stub agent never launched in the hub window"
wait_for pane_dead hub || fail "hub window never fell back to a bare shell"
n_before="$(launches hub)"
pid_before="$(pane_pid hub)"

fleet_hub
wait_for launched_more hub "$n_before" \
  || fail "dead COORDINATOR window was NOT relaunched (count stuck at $n_before)"
[ "$(pane_pid hub)" != "$pid_before" ] || fail "hub relaunch did not respawn the pane"
echo "PASS (scenario 3): bare fleet relaunched a dead coordinator (hub) window"

# ---------- Scenario 4: `fleet` typed INSIDE the dead window's fallback shell ----------
# The Ctrl+C-to-exit case: the agent dies, the operator is left at the window's
# bare shell and types `fleet` THERE. That fleet is a child of the pane, so the
# dead-detection reads the window as alive and the old code just re-selected it
# and exited — the operator was stuck (no relaunch). The fix: window_cmd exports
# the launch context into the fallback shell (so bare `fleet` resolves the same
# project) and in_target_window makes cmd_hub relaunch this role in place.
wait_for pane_dead hub || fail "hub window not a bare shell before scenario 4"
n_before="$(launches hub)"
# A BARE `fleet` (no --project, no FLEET_* on the send-keys line): it must resolve
# purely from the context window_cmd exported into this fallback shell.
tmux send-keys -t "$SESS:hub" "fleet" Enter
wait_for launched_more hub "$n_before" \
  || fail "in-window bare fleet did NOT relaunch from the fallback shell (count stuck at $n_before)"
tmux list-windows -t "$SESS" -F '#{window_name}' | grep -Fxq hub \
  || fail "in-window relaunch lost the hub window"
echo "PASS (scenario 4): bare fleet from the dead window's own shell relaunched in place"
