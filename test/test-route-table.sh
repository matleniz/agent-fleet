#!/usr/bin/env bash
# test-route-table.sh — E2E test for task routing preferences table,
# difficulty/kind mapping, Claude policy, quota fall-through, depth limit,
# and dispatch auto integration.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
FLEET="$REPO/bin/fleet"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected '$3', got '$2'"; fi; }
has() { if grep -qF "$2" <<<"$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-route-test.XXXXXX")"
ROOT="$(mktemp -d "$HOME/.fleet-route-sandbox.XXXXXX")"
export FLEET_HOME="$TMP/config"
cleanup() { rm -rf "$TMP" "$ROOT"; }
trap cleanup EXIT

"$SELF_DIR/make-sandbox.sh" "$ROOT" >/dev/null 2>&1 \
  || { bad "sandbox build failed"; echo; echo "route-table: $pass passed, $fail failed"; exit 1; }

conf="$FLEET_HOME/projects/sandbox.env"
cd "$ROOT/code" || exit 1

echo "[1] default routing -> medium preference"
out="$("$FLEET" --project sandbox route)"
# sandbox AGENTS="stub claude gemini opencode cursor"
# Default ROUTE_MEDIUM="antigravity cursor copilot"
# antigravity not in AGENTS -> picks cursor
eq "default route picks cursor" "$out" "cursor"

echo "[2] explicit difficulty"
out_easy="$("$FLEET" --project sandbox route --difficulty easy)"
eq "easy route picks cursor" "$out_easy" "cursor"

echo "[3] kind-specific override"
echo 'ROUTE_KIND_DOC="opencode:haiku gemini"' >> "$conf"
out_doc="$("$FLEET" --project sandbox route --kind doc)"
eq "kind doc picks opencode:haiku" "$out_doc" "opencode:haiku"

echo "[4] Claude escalate-only policy skips Claude on normal route"
# Hard route with claude first
echo 'ROUTE_HARD="claude:sonnet opencode gemini"' >> "$conf"
out_hard="$("$FLEET" --project sandbox route --difficulty hard)"
eq "hard route skips claude to opencode" "$out_hard" "opencode"

echo "[5] ROUTE_CLAUDE=allowed permits Claude on normal route"
out_allowed="$(ROUTE_CLAUDE=allowed "$FLEET" --project sandbox route --difficulty hard)"
eq "ROUTE_CLAUDE=allowed picks claude:sonnet" "$out_allowed" "claude:sonnet"

echo "[6] escalation route allows Claude"
echo 'ROUTE_ESCALATE="claude:sonnet opencode"' >> "$conf"
out_esc="$("$FLEET" --project sandbox route --escalate)"
eq "escalation picks claude:sonnet" "$out_esc" "claude:sonnet"

echo "[7] ROUTE_CLAUDE=never skips Claude even on escalation"
out_never="$(ROUTE_CLAUDE=never "$FLEET" --project sandbox route --escalate)"
eq "ROUTE_CLAUDE=never falls through to opencode" "$out_never" "opencode"

echo "[8] quota error falls through to next candidate"
echo 'ROUTE_EASY="cursor opencode"' >> "$conf"
out_quota="$("$FLEET" --project sandbox route --difficulty easy --quota-exceeded cursor)"
eq "quota exceeded cursor falls through to opencode" "$out_quota" "opencode"
[ -f "$FLEET_HOME/quota/cursor" ] || bad "ledger $FLEET_HOME/quota/cursor missing"

echo "[9] recursion depth limit prevents runaway dispatch"
set +e
depth_out="$(FLEET_DISPATCH_DEPTH=2 "$FLEET" --project sandbox route 2>&1)"
rc=$?
set -e
eq "max depth reached exits 2" "$rc" "2"
has "max depth error message" "max dispatch depth" "$depth_out"

echo "[10] JSON output format"
json_out="$("$FLEET" --project sandbox route --difficulty easy --json)"
target="$(python3 -c "import json, sys; print(json.loads(sys.stdin.read())['target'])" <<<"$json_out")"
eq "json target parsed" "$target" "opencode"

echo "[11] dispatch --auto uses route and logs event"
# Dispatch stub worker via auto routing
echo 'ROUTE_EASY="stub:fast gemini"' >> "$conf"
# Ensure tmux session exists or create fake tmux / mock
if command -v tmux >/dev/null 2>&1; then
  "$FLEET" --project sandbox dispatch --auto --difficulty easy test-worker-1 "run quick check"
  sdir="$FLEET_HOME/dispatch/sandbox"
  [ -f "$sdir/events.log" ] || bad "events.log missing"
  has "events.log records routed worker" "test-worker-1 route stub:fast" "$(cat "$sdir/events.log")"
  # Clean up tmux window
  tmux kill-window -t "fleet-sandbox:test-worker-1" 2>/dev/null || true
else
  ok "tmux missing; skip live dispatch tmux spawn"
fi

echo "[12] gate --escalate logs escalation on failure"
echo 'GATE_CMDS="false"' >> "$conf"
set +e
gate_out="$("$FLEET" --project sandbox gate --escalate 2>&1)"
set -e
has "gate suggests escalation target" "automatic escalation target -> claude:sonnet" "$gate_out"
sdir="$FLEET_HOME/dispatch/sandbox"
if [ -f "$sdir/events.log" ]; then
  has "events.log has gate-escalate entry" "gate-escalate claude:sonnet" "$(cat "$sdir/events.log")"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "PASS: all $pass tests passed"
  exit 0
else
  echo "FAIL: $fail test(s) failed out of $((pass+fail))"
  exit 1
fi
