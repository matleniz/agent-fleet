#!/usr/bin/env bash
# test-gate-spec-group-e2e.sh — group E2E for the two features that share ONE
# checks/report mechanism (bin/fleet_checks.py): the gate's convention checks and
# the dispatch spec's scope allowlist. One project, one story:
#   dispatch a worker with a spec (scope + checks) -> it leaves its scope ->
#   the exit path reports it -> the worker adds a tracker id -> ONE `fleet gate`
#   report carries both the scope finding and the convention finding, same
#   format, same severity handling -> fixing both turns the gate green.
# And the cross-cutting guarantee: with no spec and no GATE_CHECKS, dispatch and
# gate behave exactly as before.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
FLEET="$REPO/bin/fleet"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected '$3', got '$2'"; fi; }
has()    { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
hasnot() { if grep -qF -- "$2" <<<"$3"; then bad "$1 (unexpected: $2)"; else ok "$1"; fi; }

command -v tmux >/dev/null || { echo "SKIP: tmux not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-gatespec-test.XXXXXX")"
ROOT="$(mktemp -d "$HOME/.fleet-gatespec-sandbox.XXXXXX")"
export FLEET_HOME="$TMP/config"
SESS="fleet-sandbox"
cleanup() { tmux kill-session -t "$SESS" 2>/dev/null || true; rm -rf "$TMP" "$ROOT"; }
trap cleanup EXIT

"$SELF_DIR/make-sandbox.sh" "$ROOT" >/dev/null 2>&1 \
  || { bad "sandbox build failed"; echo "gate-spec: $pass passed, $fail failed"; exit 1; }
export FLEET_PACKS_DIR; FLEET_PACKS_DIR="$("$SELF_DIR/make-fake-llm-pack.sh" "$TMP/packs")"
export FLEET_WAIT_POLL=1
export PATH="$REPO/bin:$PATH"
conf="$FLEET_HOME/projects/sandbox.env"
printf 'AGENTS="fakellm"\n' >> "$conf"
SDIR="$FLEET_HOME/dispatch/sandbox"
cd "$ROOT/code" || exit 1
tmux kill-session -t "$SESS" 2>/dev/null || true
G() { git -c user.name=t -c user.email=t@localhost "$@"; }

echo "[1] defaults unchanged: no spec, no GATE_CHECKS"
"$FLEET" --project sandbox -a fakellm dispatch plain "write solution.txt" >/dev/null 2>&1
timeout 120 "$FLEET" --project sandbox wait plain >/dev/null 2>&1
eq "plain worker status" "$(cat "$SDIR/plain.status")" "done rc=0"
out="$(cd "$ROOT/wt/plain" && "$FLEET" --project sandbox gate 2>&1)"; rc=$?
eq  "plain gate rc" "$rc" "0"
has "plain gate is still the no-op" "no checks declared" "$out"

echo "[2] worker dispatched with a spec leaves its scope"
cat > "$TMP/task.spec" <<'SPEC'
scope = src/**
checks = scope no-tracker-ids
SPEC
"$FLEET" --project sandbox -a fakellm dispatch --spec "$TMP/task.spec" spec "write solution.txt" >/dev/null 2>&1
timeout 120 "$FLEET" --project sandbox wait spec >/dev/null 2>&1
eq  "advisory scope: worker still done" "$(cat "$SDIR/spec.status")" "done rc=0"
has "meta carries the spec" "checks=scope,no-tracker-ids" "$(cat "$SDIR/spec.meta")"
has "exit path reported it" "WARN scope solution.txt:1" "$(tmux capture-pane -p -S -50 -t "$SESS:_done-spec" 2>/dev/null)"

echo "[3] ONE gate report: scope finding + convention finding, same format"
id="ABC""-123"
printf 'x = 1  # %s\n' "$id" > "$ROOT/wt/spec/src.py"
( cd "$ROOT/wt/spec" && G add -A && G commit -qm "add src.py" )
out="$(cd "$ROOT/wt/spec" && "$FLEET" --project sandbox gate 2>&1)"; rc=$?
eq  "both advisory -> gate passes" "$rc" "0"
has "scope finding"      "WARN scope solution.txt:1" "$out"
has "convention finding" "WARN no-tracker-ids src.py:1" "$out"
has "one convention block, one check" "PASS — 1/1" "$out"

echo "[4] blocking severity is the same knob for both kinds"
sed -i 's/^checks=.*/checks=scope:blocking,no-tracker-ids:blocking/' "$SDIR/spec.meta"
out="$(cd "$ROOT/wt/spec" && "$FLEET" --project sandbox gate 2>&1)"; rc=$?
eq  "blocking -> gate fails" "$rc" "1"
has "scope BLOCK" "BLOCK scope solution.txt:1" "$out"
has "convention BLOCK" "BLOCK no-tracker-ids src.py:1" "$out"

echo "[5] fixing both turns the gate green"
sed -i "s/$id/none/" "$ROOT/wt/spec/src.py"
( cd "$ROOT/wt/spec" && G commit -qam "drop id" )
out="$(cd "$ROOT/wt/spec" && "$FLEET" --project sandbox gate --scope 'solution.txt,src.py' 2>&1)"; rc=$?
eq  "gate rc" "$rc" "0"
hasnot "no findings left" "BLOCK" "$out"

echo
echo "gate-spec: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
