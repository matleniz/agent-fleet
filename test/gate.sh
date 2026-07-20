#!/usr/bin/env bash
# gate.sh — E2E for `fleet gate` (the project-declared pre-PR validation gate)
# against a throwaway sandbox. Proves the whole contract:
#
#   [1] no GATE_CMDS            -> no-op, rc 0, says so
#   [2] all checks pass         -> rc 0, PASS n/n, passing output SUPPRESSED
#   [3] failing checks          -> rc 1, ALL failures reported (run-all, not
#                                  stop-at-first), failing output shown
#   [4] auto-fix inside a check -> rc 0 + a note that files were modified
#   [5] huge failing output     -> capped at 200 lines with a truncation marker
#   [6] comments + blank lines in GATE_CMDS are skipped
#
# Touches nothing real: FLEET_HOME is a throwaway temp dir and the sandbox is
# built by test/make-sandbox.sh under a throwaway ROOT.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
FLEET="$REPO/bin/fleet"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected '$3', got '$2'"; fi; }
has()    { if grep -qF "$2" <<<"$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
hasnot() { if grep -qF "$2" <<<"$3"; then bad "$1 (unexpected: $2)"; else ok "$1"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-gate-test.XXXXXX")"
ROOT="$(mktemp -d "$HOME/.fleet-gate-sandbox.XXXXXX")"
export FLEET_HOME="$TMP/config"
cleanup() { rm -rf "$TMP" "$ROOT"; }
trap cleanup EXIT

"$SELF_DIR/make-sandbox.sh" "$ROOT" >/dev/null 2>&1 \
  || { bad "sandbox build failed"; echo; echo "gate: $pass passed, $fail failed"; exit 1; }

conf="$FLEET_HOME/projects/sandbox.env"
cp "$conf" "$TMP/base.env"
# The gate runs checks from the cwd's repo root, like a worker in its worktree.
cd "$ROOT/code" || exit 1

# set_gate: reset the sandbox .env and declare GATE_CMDS from stdin (multiline,
# quotes in commands preserved — the value must not itself contain a `"`).
set_gate() {
  cp "$TMP/base.env" "$conf"
  { printf 'GATE_CMDS="'; cat; printf '"\n'; } >> "$conf"
}

echo "[1] no GATE_CMDS -> no-op rc 0"
cp "$TMP/base.env" "$conf"
out="$("$FLEET" --project sandbox gate 2>&1)"; rc=$?
eq  "no-op rc" "$rc" "0"
has "no-op says no checks declared" "no checks declared" "$out"

echo "[2] all pass -> rc 0, passing output suppressed"
# The command LINE is echoed (gate: ok <line>) but its OUTPUT must not be, so
# assert on an output string the line itself does not contain.
set_gate <<'EOF'
printf '%s-%s\n' SUPPRESSED MARKER
true
EOF
out="$("$FLEET" --project sandbox gate 2>&1)"; rc=$?
eq     "pass rc" "$rc" "0"
has    "PASS summary" "PASS — 2/2" "$out"
hasnot "passing command output suppressed" "SUPPRESSED-MARKER" "$out"

echo "[3] failures -> rc 1, all failures reported with their output"
set_gate <<'EOF'
false
sh -c 'echo BOOM-A; exit 3'
echo fine
EOF
out="$("$FLEET" --project sandbox gate 2>&1)"; rc=$?
eq  "fail rc" "$rc" "1"
has "run-all summary counts both failures" "2/3 check(s) failed" "$out"
has "first failing command named"  "FAIL  false" "$out"
has "second failure's own output shown" "BOOM-A" "$out"
has "second failure's rc shown" "(rc=3)" "$out"

echo "[4] auto-fix inside a passing check -> note to commit the changes"
set_gate <<'EOF'
sed -i s/hello/HELLO/ hello.py
grep -q HELLO hello.py
EOF
out="$("$FLEET" --project sandbox gate 2>&1)"; rc=$?
eq  "auto-fix rc" "$rc" "0"
has "auto-fix note" "checks modified files" "$out"
git -C "$ROOT/code" checkout -q -- hello.py

echo "[5] huge failing output -> capped at 200 lines with a truncation marker"
set_gate <<'EOF'
seq 300 && false
EOF
out="$("$FLEET" --project sandbox gate 2>&1)"; rc=$?
eq  "truncation rc" "$rc" "1"
has "truncation marker" "output truncated" "$out"
if grep -qx '150' <<<"$out"; then ok "line within the cap shown"; else bad "line within the cap missing"; fi
if grep -qx '300' <<<"$out"; then bad "line past the cap leaked"; else ok "lines past the cap dropped"; fi

echo "[6] comments and blank lines in GATE_CMDS skipped"
set_gate <<'EOF'
# a comment, not a check

true
true
EOF
out="$("$FLEET" --project sandbox gate 2>&1)"; rc=$?
eq  "comment/blank rc" "$rc" "0"
has "only the real checks counted" "PASS — 2/2" "$out"

echo
echo "gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
