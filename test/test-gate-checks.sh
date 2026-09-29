#!/usr/bin/env bash
# test-gate-checks.sh — unit + E2E for the gate's opt-in convention checks
# (bin/fleet_checks.py, wired into `fleet gate` via GATE_CHECKS). A throwaway
# repo carries exactly one violation per check; proves each check reports
# file:line, advisory vs blocking exit codes, per-check enable/disable, and that
# a project that enables nothing is unchanged. Model-free, tmux-free.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
FLEET="$REPO/bin/fleet"
CHECKS="$REPO/bin/fleet_checks.py"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected '$3', got '$2'"; fi; }
has()    { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
hasnot() { if grep -qF -- "$2" <<<"$3"; then bad "$1 (unexpected: $2)"; else ok "$1"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-gatechecks-test.XXXXXX")"
ROOT="$(mktemp -d "$HOME/.fleet-gatechecks-sandbox.XXXXXX")"
export FLEET_HOME="$TMP/config"
trap 'rm -rf "$TMP" "$ROOT"' EXIT

"$SELF_DIR/make-sandbox.sh" "$ROOT" >/dev/null 2>&1 \
  || { bad "sandbox build failed"; echo "gate-checks: $pass passed, $fail failed"; exit 1; }
conf="$FLEET_HOME/projects/sandbox.env"
cp "$conf" "$TMP/base.env"
cd "$ROOT/code" || exit 1
G() { git -c user.name=t -c user.email=t@localhost "$@"; }

# Baseline on main: a clean docs/test/ci layout.
mkdir -p bin docs test .github/workflows
echo 'echo tool' > bin/tool
echo '# Docs' > docs/guide.md
echo 'echo t' > test/listed.sh
printf 'run: bash test/listed.sh\n' > .github/workflows/ci.yml
G add -A && G commit -qm "baseline"

# The feature branch: one violation per check.
G checkout -q -b feature
id="ABC""-123"                                   # built, so this file has no literal id
printf 'x = 1  # see %s\n' "$id" > hello.py       # no-tracker-ids   hello.py:1
echo 'echo changed' >> bin/tool                   # (docs-with-bin fires on the "bare" branch below)
echo 'echo t' > test/orphan.sh                    # tests-listed-in-ci (but a test DID change)
printf '# Guide\n\nSee `docs/missing.md` and `docs/guide.md`.\n' > docs/guide.md   # paths-exist docs/guide.md:3
G add -A && G commit -qm "feature"

echo "[1] unit: each check reports exactly its violation as file:line"
out="$(python3 "$CHECKS" run --root . --base main --checks no-tracker-ids)"
has "tracker id at file:line" "WARN no-tracker-ids hello.py:1" "$out"
out="$(python3 "$CHECKS" run --root . --base main --checks docs-with-bin)"
eq "docs and a test changed alongside bin/ -> clean" "$out" ""
out="$(python3 "$CHECKS" run --root . --base main --checks tests-listed-in-ci)"
has "orphan test named" "WARN tests-listed-in-ci test/orphan.sh:1" "$out"
hasnot "listed test not flagged" "test/listed.sh" "$out"
out="$(python3 "$CHECKS" run --root . --base main --checks paths-exist)"
has "missing path at file:line" "WARN paths-exist docs/guide.md:3" "$out"
hasnot "existing path not flagged" "docs/guide.md does not" "$out"

echo "[2] unit: docs-with-bin flags docs AND test when neither changed"
G checkout -q -b bare main
echo 'echo other' >> bin/tool; G commit -qam "bin only"
out="$(python3 "$CHECKS" run --root . --base main --checks docs-with-bin)"
has "no doc" "no doc changed" "$out"
has "no test" "no test changed" "$out"
G checkout -q feature

echo "[3] unit: severity and exit codes"
python3 "$CHECKS" run --root . --base main --checks no-tracker-ids >/dev/null; eq "advisory rc" "$?" "0"
out="$(python3 "$CHECKS" run --root . --base main --checks no-tracker-ids:blocking)"; rc=$?
eq  "blocking rc" "$rc" "1"
has "blocking label" "BLOCK no-tracker-ids hello.py:1" "$out"
python3 "$CHECKS" run --root . --checks bogus >/dev/null 2>&1; eq "unknown check rc" "$?" "2"
out="$(python3 "$CHECKS" run --root . --base main --checks paths-exist)"
hasnot "disabled checks stay silent" "no-tracker-ids" "$out"

echo "[4] E2E: fleet gate — nothing enabled = unchanged"
cp "$TMP/base.env" "$conf"
out="$("$FLEET" --project sandbox gate 2>&1)"; rc=$?
eq "no config rc" "$rc" "0"
has "still the no-op message" "no checks declared" "$out"
printf 'GATE_CMDS="true"\n' >> "$conf"
out="$("$FLEET" --project sandbox gate 2>&1)"; rc=$?
eq "GATE_CMDS only rc" "$rc" "0"
has "PASS 1/1" "PASS — 1/1" "$out"
hasnot "no convention report" "convention checks" "$out"

echo "[5] E2E: fleet gate — advisory findings reported, gate still passes"
cp "$TMP/base.env" "$conf"
printf 'GATE_CMDS="true"\nGATE_CHECKS="no-tracker-ids tests-listed-in-ci paths-exist"\n' >> "$conf"
out="$("$FLEET" --project sandbox gate 2>&1)"; rc=$?
eq  "advisory rc" "$rc" "0"
has "tracker" "WARN no-tracker-ids hello.py:1" "$out"
has "ci" "WARN tests-listed-in-ci test/orphan.sh:1" "$out"
has "paths" "WARN paths-exist docs/guide.md:3" "$out"
has "counted as one check" "PASS — 2/2" "$out"

echo "[5b] E2E: docs-with-bin through the gate, on a branch that changed bin/ only"
G checkout -q bare
sed -i 's/^GATE_CHECKS=.*/GATE_CHECKS="docs-with-bin"/' "$conf"
out="$("$FLEET" --project sandbox gate 2>&1)"; rc=$?
eq  "advisory rc" "$rc" "0"
has "no doc reported at file:line" "WARN docs-with-bin bin/tool:1 code changed but no doc" "$out"
has "no test reported" "no test changed" "$out"
G checkout -q feature

echo "[6] E2E: fleet gate — blocking finding fails the gate; per-check disable"
cp "$TMP/base.env" "$conf"
printf 'GATE_CHECKS="no-tracker-ids:blocking paths-exist"\n' >> "$conf"
out="$("$FLEET" --project sandbox gate 2>&1)"; rc=$?
eq  "blocking rc" "$rc" "1"
has "BLOCK line" "BLOCK no-tracker-ids hello.py:1" "$out"
has "gate FAIL summary" "1/1 check(s) failed" "$out"
hasnot "unlisted check not run" "tests-listed-in-ci" "$out"
sed -i 's/^GATE_CHECKS=.*/GATE_CHECKS="paths-exist"/' "$conf"
"$FLEET" --project sandbox gate >/dev/null 2>&1; eq "tracker check disabled -> passes" "$?" "0"

echo "[7] E2E: bad GATE_CHECKS fails loudly"
sed -i 's/^GATE_CHECKS=.*/GATE_CHECKS="nope"/' "$conf"
out="$("$FLEET" --project sandbox gate 2>&1)"; rc=$?
eq  "misconfigured rc" "$rc" "1"
has "names the bad check" "unknown check 'nope'" "$out"

echo
echo "gate-checks: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
