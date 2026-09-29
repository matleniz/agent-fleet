#!/usr/bin/env bash
# test-route-e2e.sh — comprehensive group E2E for task routing:
# tests full lifecycle: global routing.env + project overrides,
# dispatch --auto across difficulties, quota fall-through, gate escalation,
# nested sub-worker depth bounding, and events.log verification.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
FLEET="$REPO/bin/fleet"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected '$3', got '$2'"; fi; }
has() { if grep -qF "$2" <<<"$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-route-e2e.XXXXXX")"
ROOT="$(mktemp -d "$HOME/.fleet-route-e2e-sandbox.XXXXXX")"
export FLEET_HOME="$TMP/config"
cleanup() { rm -rf "$TMP" "$ROOT"; }
trap cleanup EXIT

"$SELF_DIR/make-sandbox.sh" "$ROOT" >/dev/null 2>&1 \
  || { bad "sandbox build failed"; echo; echo "route-e2e: $pass passed, $fail failed"; exit 1; }

mkdir -p "$FLEET_HOME"
# Global routing.env
cat > "$FLEET_HOME/routing.env" <<'EOF'
ROUTE_EASY="stub:cheap gemini"
ROUTE_MEDIUM="stub:standard opencode"
ROUTE_HARD="claude:sonnet stub:strong"
ROUTE_ESCALATE="claude:sonnet stub:escalated"
ROUTE_CLAUDE="escalate-only"
ROUTE_MAX_DEPTH=2
EOF

conf="$FLEET_HOME/projects/sandbox.env"
cd "$ROOT/code" || exit 1

echo "[1] route reads global routing.env"
out_med="$("$FLEET" --project sandbox route)"
eq "global ROUTE_MEDIUM applied" "$out_med" "stub:standard"

echo "[2] project .env overrides global routing.env"
echo 'ROUTE_MEDIUM="stub:project-medium"' >> "$conf"
out_proj="$("$FLEET" --project sandbox route)"
eq "project override applied" "$out_proj" "stub:project-medium"

echo "[3] dispatch --auto routes to configured pack:model"
if command -v tmux >/dev/null 2>&1; then
  "$FLEET" --project sandbox dispatch --auto worker-auto "run routine task"
  sdir="$FLEET_HOME/dispatch/sandbox"
  [ -f "$sdir/events.log" ] || bad "events.log missing"
  has "events.log records project route" "worker-auto route stub:project-medium" "$(cat "$sdir/events.log")"
  tmux kill-window -t "fleet-sandbox:worker-auto" 2>/dev/null || true
else
  ok "tmux missing; skip live dispatch"
fi

echo "[4] quota fallback routes to next candidate"
# ROUTE_EASY is "stub:cheap gemini"
out_quota="$("$FLEET" --project sandbox route --difficulty easy --quota-exceeded stub)"
eq "quota exceeded stub falls through to gemini" "$out_quota" "gemini"
rm -f "$FLEET_HOME/quota/stub"

echo "[5] Claude escalate-only protected on hard route"
# Global ROUTE_HARD="claude:sonnet stub:strong", ROUTE_CLAUDE=escalate-only
out_hard="$("$FLEET" --project sandbox route --difficulty hard)"
eq "hard route skips claude to stub:strong" "$out_hard" "stub:strong"

echo "[6] escalation route selects Claude"
out_esc="$("$FLEET" --project sandbox route --escalate)"
eq "escalation selects claude:sonnet" "$out_esc" "claude:sonnet"

echo "[7] gate --escalate on failed checks triggers escalation"
echo 'GATE_CMDS="false"' >> "$conf"
set +e
gate_out="$("$FLEET" --project sandbox gate --escalate 2>&1)"
set -e
has "gate reports escalation" "automatic escalation target -> claude:sonnet" "$gate_out"

echo "[8] recursive worker dispatch depth bounding"
# At depth 0 -> can dispatch
# Inside worker at depth 1 -> can dispatch
# Inside sub-worker at depth 2 -> cannot dispatch (ROUTE_MAX_DEPTH=2)
set +e
depth_blocked="$(FLEET_DISPATCH_DEPTH=2 "$FLEET" --project sandbox dispatch --auto sub-worker "nested task" 2>&1)"
rc=$?
set -e
eq "dispatch at max depth blocked with rc 2" "$rc" "2"
has "depth limit error message" "max dispatch depth (2) reached" "$depth_blocked"

echo "[9] pack quota failure writes ledger and next route falls through to next candidate"
# Create a dummy pack 'mockquota' in a dedicated packs directory
fake_packs="$TMP/packs"
mkdir -p "$fake_packs/mockquota"
cp -r "$REPO/packs/"* "$fake_packs/"
cat > "$fake_packs/mockquota/pack.sh" <<'EOF'
pack_launch() { :; }
pack_launch_headless() { echo "Quota limit: 429 Monthly quota exceeded for account"; exit 1; }
pack_has_sessions() { return 1; }
pack_worker_setup() { :; }
pack_barrier_files() { :; }
pack_install() { :; }
pack_quota_pattern() { echo "Monthly quota exceeded"; }
EOF

export FLEET_PACKS_DIR="$fake_packs"
# Update project AGENTS and route preferences
sed -i 's/^AGENTS=.*/AGENTS="mockquota stub claude"/' "$conf"
echo 'ROUTE_EASY="mockquota stub:fallback"' >> "$conf"

# Create worktree and run worker with mockquota to trigger failure and quota pattern detection
"$SELF_DIR/../bin/new-worker" --project sandbox quota-worker >/dev/null 2>&1 >/dev/null 2>&1
qtask="$TMP/qtask"
echo "run failing task" > "$qtask"
set +e
"$FLEET" --project sandbox -a mockquota _dispatch-run quota-worker "$qtask"
q_rc=$?
set -e
eq "failing worker exited with 1" "$q_rc" "1"

# Verify ledger was written
ledger="$FLEET_HOME/quota/mockquota"
[ -f "$ledger" ] || bad "ledger $ledger was not created"
has "events.log records quota-exceeded" "quota-exceeded pack=mockquota" "$(cat "$FLEET_HOME/dispatch/sandbox/events.log")"

# The next fleet route falls through mockquota (because of active ledger) to stub:fallback
next_route="$("$FLEET" --project sandbox route --difficulty easy)"
eq "next route falls through active ledger to stub:fallback" "$next_route" "stub:fallback"

# Also verify dispatch --auto uses the next candidate
if command -v tmux >/dev/null 2>&1; then
  "$FLEET" --project sandbox dispatch --auto --difficulty easy worker-auto-fallback "fallback task"
  has "events.log records fallback route" "worker-auto-fallback route stub:fallback" "$(cat "$FLEET_HOME/dispatch/sandbox/events.log")"
  tmux kill-window -t "fleet-sandbox:worker-auto-fallback" 2>/dev/null || true
else
  ok "tmux missing; skip live fallback dispatch"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "PASS: all $pass tests passed"
  exit 0
else
  echo "FAIL: $fail test(s) failed out of $((pass+fail))"
  exit 1
fi
