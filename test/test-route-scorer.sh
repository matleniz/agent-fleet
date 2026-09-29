#!/usr/bin/env bash
# test-route-scorer.sh — E2E test for the optional ROUTE_SCORER hook:
# verifies task complexity scoring, threshold-based difficulty mapping,
# kind extraction, graceful fallback on scorer failure, and dispatch integration.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
FLEET="$REPO/bin/fleet"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected '$3', got '$2'"; fi; }
has() { if grep -qF "$2" <<<"$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-scorer-test.XXXXXX")"
ROOT="$(mktemp -d "$HOME/.fleet-scorer-sandbox.XXXXXX")"
export FLEET_HOME="$TMP/config"
cleanup() { rm -rf "$TMP" "$ROOT"; }
trap cleanup EXIT

"$SELF_DIR/make-sandbox.sh" "$ROOT" >/dev/null 2>&1 \
  || { bad "sandbox build failed"; echo; echo "route-scorer: $pass passed, $fail failed"; exit 1; }

conf="$FLEET_HOME/projects/sandbox.env"
cd "$ROOT/code" || exit 1

# Configure distinct routes
cat >> "$conf" <<'EOF'
ROUTE_EASY="opencode:haiku gemini"
ROUTE_MEDIUM="gemini opencode"
ROUTE_HARD="opencode:deep gemini"
EOF

# Mock scorer script
mock_scorer="$TMP/mock-scorer.sh"
cat > "$mock_scorer" <<'EOF'
#!/usr/bin/env bash
input="$*"
[ -z "$input" ] && input="$(cat - 2>/dev/null || true)"
if grep -qi "complex" <<<"$input"; then
  echo "hard"
elif grep -qi "trivial" <<<"$input"; then
  echo "easy"
elif grep -qi "numeric-high" <<<"$input"; then
  echo "0.85"
elif grep -qi "numeric-low" <<<"$input"; then
  echo "0.15"
elif grep -qi "error-out" <<<"$input"; then
  echo "fatal model error" >&2
  exit 1
elif grep -qi "kind-doc" <<<"$input"; then
  echo "kind=doc"
else
  echo "medium"
fi
EOF
chmod +x "$mock_scorer"

echo 'ROUTE_SCORER="'"$mock_scorer"'"' >> "$conf"
echo 'ROUTE_KIND_DOC="stub:doc gemini"' >> "$conf"

echo "[1] keyword scoring -> hard"
out_hard="$("$FLEET" --project sandbox route --task "complex architectural refactor")"
eq "scorer selects hard route" "$out_hard" "opencode:deep"

echo "[2] keyword scoring -> easy"
out_easy="$("$FLEET" --project sandbox route --task "trivial typo fix")"
eq "scorer selects easy route" "$out_easy" "opencode:haiku"

echo "[3] numeric threshold scoring -> high score (>= 0.70) maps to hard"
out_num_high="$("$FLEET" --project sandbox route --task "numeric-high task description")"
eq "high numeric score maps to hard" "$out_num_high" "opencode:deep"

echo "[4] numeric threshold scoring -> low score (< 0.35) maps to easy"
out_num_low="$("$FLEET" --project sandbox route --task "numeric-low task description")"
eq "low numeric score maps to easy" "$out_num_low" "opencode:haiku"

echo "[5] kind extraction from scorer"
out_kind="$("$FLEET" --project sandbox route --task "kind-doc task")"
eq "scorer specifies kind=doc" "$out_kind" "stub:doc"

echo "[6] fallback on scorer exit failure"
out_fail="$("$FLEET" --project sandbox route --task "error-out failure")"
eq "scorer failure falls back to default medium" "$out_fail" "gemini"

echo "[7] task file input honored by scorer"
tf="$TMP/task.txt"
printf "complex refactor from file\n" > "$tf"
out_file="$("$FLEET" --project sandbox route --task-file "$tf")"
eq "scorer reads task from file" "$out_file" "opencode:deep"

echo "[8] explicit difficulty flag overrides scorer"
out_override="$("$FLEET" --project sandbox route --task "complex architectural refactor" --difficulty easy)"
eq "explicit --difficulty easy overrides scorer hard" "$out_override" "opencode:haiku"

echo "[9] dispatch --auto uses ROUTE_SCORER when difficulty unset"
if command -v tmux >/dev/null 2>&1; then
  "$FLEET" --project sandbox dispatch --auto scorer-worker "trivial cleanup"
  sdir="$FLEET_HOME/dispatch/sandbox"
  [ -f "$sdir/events.log" ] || bad "events.log missing"
  has "events.log records easy route from scorer" "scorer-worker route opencode:haiku" "$(cat "$sdir/events.log")"
  tmux kill-window -t "fleet-sandbox:scorer-worker" 2>/dev/null || true
else
  ok "tmux missing; skip live dispatch"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "PASS: all $pass tests passed"
  exit 0
else
  echo "FAIL: $fail test(s) failed out of $((pass+fail))"
  exit 1
fi
