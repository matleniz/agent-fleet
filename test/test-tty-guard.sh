#!/usr/bin/env bash
# test-tty-guard.sh — interactive session commands (which end in a tmux attach:
# local `switch-client`/`attach`, remote `ssh -t` + `docker exec -it`) need a
# controlling terminal. An agent's Bash tool has no tty, and neither does a
# piped/redirected invocation, so tmux would abort with the cryptic
# "open terminal failed: not a terminal" (and ssh with "Pseudo-terminal will not
# be allocated"). `tty_or_die` (bin/fleet) catches the no-tty case and prints an
# actionable message pointing at `fleet dispatch` instead.
#
# Real bug this pins: a worker (agent, no tty) ran `fleet r hub` and got the
# cryptic tmux error. Here we force the no-tty path with `</dev/null` (so the
# result is the same whether the test runner is on a tty or not) and assert:
#   - rc == 2
#   - the actionable message is printed (our marker, not tmux's raw error)
#   - NO tmux window / worktree side effect for the paths that must fail early
#
# Covers the three interactive entry points that route through session_attach /
# session_window: `fleet attach` (local), `fleet r` (remote attach), `fleet r
# hub` (remote coordinator). The local `fleet w`/`fleet hub` paths deliberately
# still create their window/worktree before failing the attach (the relaunch
# mechanism depends on it — see test/relaunch.sh), so they are covered there.
#
#   test/test-tty-guard.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"

# make-sandbox.sh requires its ROOT under $HOME; FLEET_HOME is unconstrained.
ROOT="$(mktemp -d "$HOME/.fleet-tty-test.XXXXXX")"
CONF="$(mktemp -d "${TMPDIR:-/tmp}/fleet-tty-test-conf.XXXXXX")"
cleanup() { rm -rf "$ROOT" "$CONF"; }
trap cleanup EXIT

export FLEET_HOME="$CONF"
"$SELF_DIR/make-sandbox.sh" "$ROOT" >/dev/null 2>&1

FLEET="$REPO/bin/fleet"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# <label> <output> <rc> — assert the no-tty guard fired cleanly.
check() {
  local label="$1" out="$2" rc="$3"
  if [ "$rc" != 2 ]; then bad "$label: expected rc 2, got $rc (out: $out)"; return; fi
  # Our marker, not tmux's raw error (our message intentionally quotes that
  # phrase, so we key on the actionable text that only we emit).
  if ! printf '%s' "$out" | grep -q 'interactive session command'; then
    bad "$label: rc ok but actionable message missing (out: $out)"; return
  fi
  if ! printf '%s' "$out" | grep -q 'fleet dispatch'; then
    bad "$label: message does not point at 'fleet dispatch' (out: $out)"; return
  fi
  ok "$label"
}

echo "[1] fleet attach (local) — no tty => actionable error, not a raw tmux failure"
out="$("$FLEET" --project sandbox attach </dev/null 2>&1)"; rc=$?
check "attach" "$out" "$rc"

echo "[2] fleet r (remote attach) — no tty => actionable error before ssh"
out="$("$FLEET" --project sandbox r </dev/null 2>&1)"; rc=$?
check "r" "$out" "$rc"

echo "[3] fleet r hub (remote coordinator) — the reported bug"
out="$("$FLEET" --project sandbox r hub </dev/null 2>&1)"; rc=$?
check "r hub" "$out" "$rc"

echo "[4] fleet r hub creates NO remote window (ensure runs inside the ssh, gated before it)"
# The sandbox's remote machine is an unreachable placeholder; if the guard let
# execution reach `exec ssh`, we'd see an ssh/connection error in the output.
if printf '%s' "$out" | grep -qiE 'ssh:|could not resolve|connection|docker exec'; then
  bad "r hub: reached ssh despite no tty (out: $out)"
else
  ok "r hub short-circuited before ssh"
fi

echo
echo "tty-guard: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
