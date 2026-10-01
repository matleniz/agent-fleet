#!/usr/bin/env bash
# test-dispatch-model-routing.sh — `fleet dispatch --model` validation at the top
# of cmd_dispatch, with stub CLIs only (no model):
#   - a Claude model (opus / sonnet / haiku / claude-*, any case) without -a goes
#     to the claude pack, not the project's default pack; an explicit -a wins;
#     a non-Claude model keeps the default pack; claude not enabled -> clear error
#   - a model the pack cannot run headless (claude + haiku) is refused BEFORE any
#     worktree / state is created (exit 2, reason on stderr), via the optional
#     pack_model_supported hook
#   - a fast launch failure (rc!=0) keeps its reason, shown by `fleet wait`
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
FLEET="$REPO/bin/fleet"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected '$3', got '$2'"; fi; }
has()    { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1 (missing: $2 in: $3)"; fi; }
hasnot() { if grep -qF -- "$2" <<<"$3"; then bad "$1 (unexpected: $2)"; else ok "$1"; fi; }

command -v tmux >/dev/null || { echo "SKIP: tmux not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-modelroute.XXXXXX")"
ROOT="$(mktemp -d "$HOME/.fleet-modelroute-sandbox.XXXXXX")"
export FLEET_HOME="$TMP/config"
SESS="fleet-sandbox"
cleanup() { tmux kill-session -t "$SESS" 2>/dev/null || true; rm -rf "$TMP" "$ROOT"; }
trap cleanup EXIT

"$SELF_DIR/make-sandbox.sh" "$ROOT" >/dev/null 2>&1 \
  || { bad "sandbox build failed"; echo "dispatch-model-routing: $pass passed, $fail failed"; exit 1; }
export FLEET_PACKS_DIR; FLEET_PACKS_DIR="$("$SELF_DIR/make-fake-llm-pack.sh" "$TMP/packs")"
export FLEET_WAIT_POLL=1
unset FLEET_DISPATCH_DEPTH   # this test may itself run inside a dispatched worker
i=0
# Stub `claude`: records argv, fails fast like a dead quota.
mkdir -p "$TMP/bin"; REC="$TMP/bin/claude.rec"   # the stub finds it via $0 (a reused tmux server may carry a stale env)
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s' "$*" > "$(dirname "$0")/claude.rec"
echo "Claude usage limit reached. Your limit will reset at 5pm."
exit 1
STUB
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$REPO/bin:$PATH"
conf="$FLEET_HOME/projects/sandbox.env"
printf 'AGENTS="fakellm claude"\n' >> "$conf"
SDIR="$FLEET_HOME/dispatch/sandbox"
WT="$ROOT/wt"
cd "$ROOT/code" || exit 1
tmux kill-session -t "$SESS" 2>/dev/null || true

# disp <name> [-a PACK] [dispatch flags...]  (-a is a global flag: goes before the subcommand)
disp() { local n="$1" a=(); shift
         if [ "${1:-}" = "-a" ]; then a=(-a "$2"); shift 2; fi
         "$FLEET" --project sandbox "${a[@]}" dispatch "$@" "$n" "do it" 2>&1; }

echo "[1] Claude model without -a -> claude pack (default pack is fakellm)"
out="$(disp r1 --model opus)"
has "routed to claude" "(claude, headless, model=opus)" "$out"
timeout 60 "$FLEET" --project sandbox wait r1 >"$TMP/r1.wait" 2>&1; echo $? >"$TMP/r1.rc"
has "stub got --model opus" "--model opus" "$(cat "$REC")"
eq  "status" "$(cat "$SDIR/r1.status")" "done rc=1"
has "wait shows the failure reason" "usage limit reached" "$(cat "$TMP/r1.wait")"

echo "[2] case-insensitive, claude-* ids, explicit -a wins, non-Claude model keeps default"
has "Sonnet -> claude" "(claude," "$(disp r2 --model Sonnet)"
has "claude-sonnet-4-5 -> claude" "(claude," "$(disp r3 --model claude-sonnet-4-5)"
has "-a fakellm wins" "(fakellm," "$(disp r4 -a fakellm --model sonnet)"
has "other model -> default pack" "(fakellm," "$(disp r5 --model some/model-x)"
has "no model -> default pack" "(fakellm," "$(disp r6)"

echo "[3] claude pack not enabled for the project"
sed -i 's/^AGENTS=.*/AGENTS="fakellm"/' "$conf"
out="$(disp r7 --model opus)"; rc=$?
has "clear error" "claude pack is not enabled" "$out"
[ ! -d "$WT/r7" ] && ok "no worktree" || bad "worktree r7 created"
sed -i 's/^AGENTS=.*/AGENTS="fakellm claude"/' "$conf"

echo "[4] haiku on the claude pack is refused before any worktree/state"
for args in "--model haiku" "-a claude --model claude-haiku-4-5-20251001" "--model Haiku"; do
  n="h$((++i))"
  # shellcheck disable=SC2086
  case "$args" in "-a claude "*) out="$("$FLEET" --project sandbox -a claude dispatch ${args#-a claude } "$n" "do it" 2>&1)"; rc=$? ;;
                  *) out="$("$FLEET" --project sandbox dispatch $args "$n" "do it" 2>&1)"; rc=$? ;; esac
  eq  "$args: exit" "$rc" "2"
  has "$args: reason" "cannot run headless" "$out"
  [ ! -d "$WT/$n" ] && ok "$args: no worktree" || bad "$args: worktree created"
  [ ! -e "$SDIR/$n.status" ] && [ ! -e "$SDIR/$n.meta" ] && ok "$args: no state" || bad "$args: state written"
done
hasnot "haiku never reached the CLI" "haiku" "$(cat "$REC")"

echo "[5] a pack without the hook accepts any model"
has "fakellm + haiku ok" "(fakellm," "$(disp r8 -a fakellm --model haiku)"

echo "dispatch-model-routing: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
