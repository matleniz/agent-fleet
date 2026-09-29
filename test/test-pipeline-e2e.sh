#!/usr/bin/env bash
# test-pipeline-e2e.sh — group E2E for the three features that share one headless
# review/aggregation primitive (fleet_pass): judge, race, fanin. One fake pack,
# one project, the whole story:
#   race run -> wait -> race judge -> comment -> steer -> wait ->
#   gate --review on the winner (advisory judge) -> fanin over the race workers
# and the cross-cutting guarantees:
#   - every pass went through pack_launch_headless with the ROUTED model
#   - claude, listed first everywhere, was never chosen (ROUTE_CLAUDE default)
#   - nothing is default-on: plain gate / dispatch / wait launched no pass
#   - the pass kinds are exactly race_judge, judge, fanin (one primitive)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
FLEET="$REPO/bin/fleet"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected '$3', got '$2'"; fi; }
has()    { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }

command -v tmux >/dev/null || { echo "SKIP: tmux not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-pipeline-test.XXXXXX")"
ROOT="$(mktemp -d "$HOME/.fleet-pipeline-sandbox.XXXXXX")"
export FLEET_HOME="$TMP/config"
SESS="fleet-sandbox"
cleanup() { tmux kill-session -t "$SESS" 2>/dev/null || true; rm -rf "$TMP" "$ROOT"; }
trap cleanup EXIT

"$SELF_DIR/make-sandbox.sh" "$ROOT" >/dev/null 2>&1 \
  || { bad "sandbox build failed"; echo "pipeline: $pass passed, $fail failed"; exit 1; }
export FLEET_PACKS_DIR; FLEET_PACKS_DIR="$("$SELF_DIR/make-fake-llm-pack.sh" "$TMP/packs")"
export FLEET_WAIT_POLL=1
export PATH="$REPO/bin:$PATH"   # the dispatch tmux window runs `fleet` from PATH
conf="$FLEET_HOME/projects/sandbox.env"
cat >> "$conf" <<'ENV'
AGENTS="claude fakellm"
ROUTE_HARD="claude:sonnet fakellm:strong-model"
ROUTE_KIND_FANIN="claude:haiku fakellm:lead-model"
GATE_CMDS="true"
ENV
SDIR="$FLEET_HOME/dispatch/sandbox"
calls() { find "$FLEET_HOME/fakellm" -name 'call.*.prompt' 2>/dev/null | wc -l; }
kinds() { grep -h -m1 -o '^\[fleet-pass:[a-z-]*\]' "$FLEET_HOME"/fakellm/call.*.prompt 2>/dev/null | sort | uniq -c | sed 's/^ *//' | tr '\n' ';'; }
cd "$ROOT/code" || exit 1
tmux kill-session -t "$SESS" 2>/dev/null || true

echo "[1] race: two packs-worth of workers on one task"
"$FLEET" --project sandbox race run --packs "fakellm fakellm" g "write solution.txt" >/dev/null 2>&1
timeout 120 "$FLEET" --project sandbox wait >/dev/null 2>&1
eq "workers ran as headless dispatches, no pass yet" "$(grep -l 'fleet-pass:' "$FLEET_HOME"/fakellm/call.*.prompt 2>/dev/null | wc -l)" "0"
eq "both worktrees committed" "$(git -C "$ROOT/wt/g-a" log --format=%s -1)/$(git -C "$ROOT/wt/g-b" log --format=%s -1)" "add solution/add solution"

echo "[2] judge -> comment -> steer -> wait"
out="$("$FLEET" --project sandbox race judge g 2>&1)"
has "winner recommended" "WINNER: g-a" "$out"
echo "- extra human note" | "$FLEET" --project sandbox race comment g g-b - >/dev/null 2>&1
"$FLEET" --project sandbox race steer g --all --toward g-a >/dev/null 2>&1
timeout 120 "$FLEET" --project sandbox wait >/dev/null 2>&1
eq "loser steered by its comments" "$(git -C "$ROOT/wt/g-b" log --format=%s -1)" "address review"
eq "winner untouched" "$(git -C "$ROOT/wt/g-a" log --format=%s -1)" "add solution"

echo "[3] gate on the winner: plain = no pass, --review = advisory judge"
before="$(calls)"
( cd "$ROOT/wt/g-a" && "$FLEET" --project sandbox gate >/dev/null 2>&1 ); eq "plain gate rc" "$?" "0"
eq "plain gate launched no pass" "$(calls)" "$before"
gout="$(cd "$ROOT/wt/g-a" && "$FLEET" --project sandbox gate --review 2>&1)"; grc=$?
eq "gate --review rc" "$grc" "0"
has "advisory verdict shown" "VERDICT: CONCERNS" "$gout"

echo "[4] fanin over the race workers"
before="$(calls)"
fout="$("$FLEET" --project sandbox fanin --group 2 g-a g-b 2>&1)"
has "one report line per worker" "- g-a | ok |" "$fout"
has "and for the other" "- g-b | ok |" "$fout"
eq "one lead pass for the one group" "$(calls)" "$((before + 1))"

echo "[5] one primitive, routed, never claude"
eq "pass kinds" "$(kinds)" "1 [fleet-pass:fanin];1 [fleet-pass:judge];1 [fleet-pass:race-judge];"
models="$(cat "$FLEET_HOME"/fakellm/call.*.model | sort -u | tr '\n' ' ')"
has "routed models only" "strong-model" "$models"
has "fan-in used its kind list" "lead-model" "$models"
eq "claude (listed first everywhere) never ran a pass" "$(cat "$FLEET_HOME"/fakellm/call.*.model | grep -c 'sonnet\|haiku')" "0"
ev="$(cat "$SDIR/events.log")"
has "events: race run" "race-run 2" "$ev"
has "events: steer" "g-b race-steer round=1" "$ev"

echo
echo "pipeline: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
