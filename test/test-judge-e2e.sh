#!/usr/bin/env bash
# test-judge-e2e.sh — E2E for the advisory post-gate judge (`fleet judge`,
# `fleet gate --review`, GATE_REVIEW=1) with a fake pack (no model):
#   [1] fleet judge: one fresh headless pass over the diff + task, verdict printed
#   [2] the router picks the pack/model (ROUTE_HARD / ROUTE_KIND_JUDGE), claude is
#       never the default even when listed first (ROUTE_CLAUDE=escalate-only)
#   [3] gate without review: NO pass is launched (default behavior unchanged)
#   [4] gate --review / GATE_REVIEW=1: pass launched only after checks pass;
#       failing checks -> rc 1 and no review
#   [5] advisory: a CONCERNS verdict or a dead pack never changes the gate rc
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-judge-test.XXXXXX")"
ROOT="$(mktemp -d "$HOME/.fleet-judge-sandbox.XXXXXX")"
export FLEET_HOME="$TMP/config"
cleanup() { rm -rf "$TMP" "$ROOT"; }
trap cleanup EXIT

"$SELF_DIR/make-sandbox.sh" "$ROOT" >/dev/null 2>&1 \
  || { bad "sandbox build failed"; echo "judge: $pass passed, $fail failed"; exit 1; }
export FLEET_PACKS_DIR; FLEET_PACKS_DIR="$("$SELF_DIR/make-fake-llm-pack.sh" "$TMP/packs")"
conf="$FLEET_HOME/projects/sandbox.env"
cat >> "$conf" <<'ENV'
AGENTS="claude fakellm"
ROUTE_HARD="claude:sonnet fakellm:strong-model"
ENV
calls() { find "$FLEET_HOME/fakellm" -name 'call.*.prompt' 2>/dev/null | wc -l; }

# A worker worktree with a real change on its own branch.
git -C "$ROOT/code" worktree add -q "$ROOT/wt/w1" -b w1
printf 'def shout(name):\n    return name.upper()\n' > "$ROOT/wt/w1/shout.py"
git -C "$ROOT/wt/w1" add -A
git -C "$ROOT/wt/w1" -c user.name=t -c user.email=t@localhost commit -qm "add shout"
cd "$ROOT/wt/w1" || exit 1

echo "[1] fleet judge runs one fresh pass and prints the verdict"
out="$("$FLEET" --project sandbox judge --task "add a shout helper" 2>&1)"; rc=$?
eq "judge rc" "$rc" "0"
has "verdict printed" "VERDICT: CONCERNS" "$out"
has "summary line" "verdict CONCERNS via fakellm:strong-model" "$out"
eq "one pass launched" "$(calls)" "1"
p="$(cat "$(find "$FLEET_HOME/fakellm" -name 'call.*.prompt' | head -1)")"
has "prompt carries the task" "add a shout helper" "$p"
has "prompt carries the diff" "def shout(name)" "$p"
has "prompt forbids edits" "Do NOT modify" "$p"

echo "[2] router picks the pack/model; claude is not the default"
m="$(cat "$(find "$FLEET_HOME/fakellm" -name 'call.*.model' | head -1)")"
eq "routed model" "$m" "strong-model"
echo 'ROUTE_KIND_JUDGE="fakellm:judge-model"' >> "$conf"
"$FLEET" --project sandbox judge >/dev/null 2>&1
last="$(ls -t "$FLEET_HOME"/fakellm/call.*.model | head -1)"
eq "ROUTE_KIND_JUDGE wins over ROUTE_HARD" "$(cat "$last")" "judge-model"
"$FLEET" --project sandbox judge --with fakellm:explicit >/dev/null 2>&1
last="$(ls -t "$FLEET_HOME"/fakellm/call.*.model | head -1)"
eq "--with overrides the router" "$(cat "$last")" "explicit"

echo "[3] gate without review launches no pass"
echo 'GATE_CMDS="true"' >> "$conf"
before="$(calls)"
gout="$("$FLEET" --project sandbox gate 2>&1)"; grc=$?
eq "gate rc" "$grc" "0"
has "gate passes" "gate: PASS" "$gout"
eq "no pass by default" "$(calls)" "$before"

echo "[4] gate --review / GATE_REVIEW=1 review after the checks pass"
gout="$("$FLEET" --project sandbox gate --review 2>&1)"; grc=$?
eq "gate --review rc" "$grc" "0"
has "review ran after PASS" "VERDICT: CONCERNS" "$gout"
eq "one more pass" "$(calls)" "$((before + 1))"
before="$(calls)"
gout="$(GATE_REVIEW=1 "$FLEET" --project sandbox gate 2>&1)"; grc=$?
eq "GATE_REVIEW=1 rc" "$grc" "0"
has "GATE_REVIEW=1 reviews" "verdict CONCERNS" "$gout"
eq "GATE_REVIEW=1 launched one pass" "$(calls)" "$((before + 1))"
before="$(calls)"
sed -i 's/^GATE_CMDS=.*/GATE_CMDS="false"/' "$conf"
gout="$("$FLEET" --project sandbox gate --review 2>&1)"; grc=$?
eq "failing checks -> rc 1" "$grc" "1"
hasnot "no review when checks fail" "VERDICT" "$gout"
eq "no pass when checks fail" "$(calls)" "$before"

echo "[5] advisory: never blocks"
sed -i 's/^GATE_CMDS=.*/GATE_CMDS="true"/' "$conf"
touch "$FLEET_HOME/fakellm.fail"
gout="$("$FLEET" --project sandbox gate --review 2>&1)"; grc=$?
eq "dead pack: gate rc unchanged" "$grc" "0"
has "says the change was not judged" "NOT judged" "$gout"
rm -f "$FLEET_HOME/fakellm.fail"
echo APPROVE > "$FLEET_HOME/fakellm.verdict"
gout="$("$FLEET" --project sandbox gate --review 2>&1)"; grc=$?
eq "APPROVE verdict rc" "$grc" "0"
has "APPROVE surfaced" "verdict APPROVE" "$gout"

echo
echo "judge: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
