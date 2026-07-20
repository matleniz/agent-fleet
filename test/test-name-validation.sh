#!/usr/bin/env bash
# test-name-validation.sh — S2 fix: fleet_valid_name gates cmd_remote's `del`
# and `w`/`worker` cases and cmd_peek/cmd_send's window arg BEFORE any ssh
# string is built. Those sites thread a name/window UNQUOTED into a composed
# `ssh "$M_HOST" "docker exec ... $name ..."` string (bin/fleet); a name like
# `x; touch /tmp/PWNED #` escapes and runs on the remote box's HOST shell.
#
# No reachable remote machine is needed: rejection must happen strictly
# before ssh is invoked, so we point at the sandbox's intentionally
# unreachable placeholder machine ("vm", host vm.sandbox.invalid — see
# test/make-sandbox.sh) and assert:
#   - rc == 2
#   - fleet_valid_name's error message is printed
#   - the marker file the payload would `touch` never appears
#
# Covers: `fleet r del`, `fleet r w`, `fleet peek`, `fleet send`.
# Does NOT cover: what would happen on the remote shell if ssh DID reach a
# live host (would need a real reachable box) — only that our validation
# refuses before any ssh attempt, which is the whole point of the fix. If
# any of these sites regressed to run after ssh, this test would still pass
# (the unreachable host means ssh fails harmlessly either way) — the rc==2 +
# message assertions are what actually pin the fix in place.
#
#   test/test-name-validation.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"

# make-sandbox.sh requires its ROOT under $HOME; FLEET_HOME has no such
# constraint, so keep it alongside the other throwaway test config dirs.
ROOT="$(mktemp -d "$HOME/.fleet-name-test.XXXXXX")"
CONF="$(mktemp -d "${TMPDIR:-/tmp}/fleet-name-test-conf.XXXXXX")"
MARKER="$CONF/PWNED"
cleanup() { rm -rf "$ROOT" "$CONF"; }
trap cleanup EXIT

export FLEET_HOME="$CONF"
"$SELF_DIR/make-sandbox.sh" "$ROOT" >/dev/null 2>&1

FLEET="$REPO/bin/fleet"
PAYLOAD="x; touch $MARKER #"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

check() {  # <label> <expected-rc> <actual-rc> <output>
  local label="$1" exp_rc="$2" rc="$3" out="$4"
  if [ "$rc" != "$exp_rc" ]; then bad "$label: expected rc $exp_rc, got $rc (out: $out)"; return; fi
  if ! printf '%s' "$out" | grep -qi 'use only letters, digits'; then
    bad "$label: rc ok but validation message missing (out: $out)"; return
  fi
  ok "$label"
}

echo "[1] fleet r del <malicious name> — rejected before ssh"
out="$("$FLEET" --project sandbox r del "$PAYLOAD" 2>&1)"; rc=$?
check "r del" 2 "$rc" "$out"

echo "[2] fleet r w <malicious name> — rejected before ssh"
out="$("$FLEET" --project sandbox r w "$PAYLOAD" 2>&1)"; rc=$?
check "r w" 2 "$rc" "$out"

echo "[3] fleet peek <machine> <malicious window> — rejected before ssh"
out="$("$FLEET" --project sandbox peek vm "$PAYLOAD" 2>&1)"; rc=$?
check "peek" 2 "$rc" "$out"

echo "[4] fleet send <machine> <malicious window> <text> — rejected before ssh"
out="$("$FLEET" --project sandbox send vm "$PAYLOAD" "hello" 2>&1)"; rc=$?
check "send" 2 "$rc" "$out"

echo "[5] marker never created (rejection happened before any command execution)"
if [ -e "$MARKER" ]; then bad "marker file exists — injection executed!"
else ok "no marker file — payload never ran"
fi

echo
echo "name-validation tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
