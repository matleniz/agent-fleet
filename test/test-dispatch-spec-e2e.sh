#!/usr/bin/env bash
# test-dispatch-spec-e2e.sh — E2E for the structured dispatch spec: deliverable /
# scope / checks given as flags or a --spec file instead of prose markers.
# Uses the fake pack (test/make-fake-llm-pack.sh): its worker commits
# solution.txt at the worktree root, so scope "solution.txt" is honoured and
# scope "src/**" is violated. Proves:
#   - no spec: behaviour unchanged (no scope check, no warning)
#   - scope violation is reported (advisory by default: status stays done rc=0)
#   - scope:blocking -> done-out-of-scope, fleet wait rc 1
#   - a worker inside its scope is clean
#   - deliverable via --spec / flag reaches the meta and drives the exit check
#   - prose markers still work, with a deprecation warning
#   - the same scope check runs in `fleet gate` (one mechanism)
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-spec-test.XXXXXX")"
ROOT="$(mktemp -d "$HOME/.fleet-spec-sandbox.XXXXXX")"
export FLEET_HOME="$TMP/config"
SESS="fleet-sandbox"
cleanup() { tmux kill-session -t "$SESS" 2>/dev/null || true; rm -rf "$TMP" "$ROOT"; }
trap cleanup EXIT

"$SELF_DIR/make-sandbox.sh" "$ROOT" >/dev/null 2>&1 \
  || { bad "sandbox build failed"; echo "dispatch-spec: $pass passed, $fail failed"; exit 1; }
export FLEET_PACKS_DIR; FLEET_PACKS_DIR="$("$SELF_DIR/make-fake-llm-pack.sh" "$TMP/packs")"
export FLEET_WAIT_POLL=1
export PATH="$REPO/bin:$PATH"   # the dispatch tmux window runs `fleet` from PATH
conf="$FLEET_HOME/projects/sandbox.env"
printf 'AGENTS="fakellm"\n' >> "$conf"
SDIR="$FLEET_HOME/dispatch/sandbox"
cd "$ROOT/code" || exit 1
tmux kill-session -t "$SESS" 2>/dev/null || true

# run <name> <dispatch args...>: dispatch, wait, print the status file.
run() { local n="$1"; shift; "$FLEET" --project sandbox -a fakellm dispatch "$@" "$n" "write solution.txt" 2>"$TMP/$n.err" >/dev/null
        timeout 120 "$FLEET" --project sandbox wait "$n" >"$TMP/$n.wait" 2>&1; echo $? >"$TMP/$n.rc"; }
status() { cat "$SDIR/$1.status" 2>/dev/null; }
pane() { tmux capture-pane -p -S -50 -t "$SESS:_done-$1" 2>/dev/null || tmux capture-pane -p -S -50 -t "$SESS:$1" 2>/dev/null; }

echo "[1] no spec: unchanged"
run plain
eq  "status" "$(status plain)" "done rc=0"
hasnot "no scope in meta" "scope=" "$(cat "$SDIR/plain.meta")"
hasnot "no deprecation warning" "deprecated" "$(cat "$TMP/plain.err")"
hasnot "no scope report in the pane" "WARN scope" "$(pane plain)"

echo "[2] scope violated, advisory by default"
run adv --scope "src/**"
eq  "status stays done rc=0" "$(status adv)" "done rc=0"
has "meta records the scope" "scope=src/**" "$(cat "$SDIR/adv.meta")"
has "violation reported file:line" "WARN scope solution.txt:1" "$(pane adv)"
has "event logged" "adv scope-violation" "$(cat "$SDIR/events.log")"

echo "[3] scope violated, blocking"
run blk --scope "src/**" --checks "scope:blocking"
eq  "status" "$(status blk)" "done-out-of-scope"
eq  "fleet wait rc" "$(cat "$TMP/blk.rc")" "1"
has "BLOCK line" "BLOCK scope solution.txt:1" "$(pane blk)"

echo "[4] worker inside its scope is clean (spec file)"
cat > "$TMP/ok.spec" <<'SPEC'
# a spec file
scope = solution.txt
checks = scope:blocking
SPEC
run good --spec "$TMP/ok.spec"
eq  "status" "$(status good)" "done rc=0"
hasnot "no finding" "scope solution.txt" "$(pane good)"

echo "[5] deliverable via spec file; flag beats spec"
printf 'deliverable=push\n' > "$TMP/d.spec"
run dsp --spec "$TMP/d.spec"
has "meta deliverable from spec" "deliverable=push" "$(cat "$SDIR/dsp.meta")"
eq  "no remote: commits count as pushed, worker done" "$(status dsp | cut -c1-4)" "done"
run dfl --spec "$TMP/d.spec" --deliverable pr
has "flag wins over spec" "deliverable=pr" "$(cat "$SDIR/dfl.meta")"

echo "[6] prose markers still work, with a deprecation warning"
"$FLEET" --project sandbox -a fakellm dispatch mk "[deliverable: push] write solution.txt" 2>"$TMP/mk.err" >/dev/null
timeout 120 "$FLEET" --project sandbox wait mk >/dev/null 2>&1
has "marker parsed into meta" "deliverable=push" "$(cat "$SDIR/mk.meta")"
has "deprecation warning" "deprecated" "$(cat "$TMP/mk.err")"

echo "[7] bad spec / scope rejected before any worker starts"
out="$("$FLEET" --project sandbox -a fakellm dispatch --scope 'a b;rm' bad "t" 2>&1)"; rc=$?
eq  "bad scope rc" "$rc" "2"
printf 'colour=red\n' > "$TMP/bad.spec"
"$FLEET" --project sandbox -a fakellm dispatch --spec "$TMP/bad.spec" bad "t" >/dev/null 2>&1; eq "unknown spec key rc" "$?" "2"
[ ! -e "$SDIR/bad.meta" ] && ok "no worker created" || bad "worker created for a bad spec"

echo "[8] the SAME scope check runs in fleet gate for a dispatched worker"
out="$(cd "$ROOT/wt/blk" && "$FLEET" --project sandbox gate 2>&1)"; rc=$?
eq  "gate rc (blocking scope from the worker's meta)" "$rc" "1"
has "same report line" "BLOCK scope solution.txt:1" "$out"
out="$(cd "$ROOT/wt/adv" && "$FLEET" --project sandbox gate 2>&1)"; rc=$?
eq  "advisory gate rc" "$rc" "0"
has "advisory line" "WARN scope solution.txt:1" "$out"
out="$(cd "$ROOT/wt/adv" && "$FLEET" --project sandbox gate --scope 'solution.txt' 2>&1)"; rc=$?
hasnot "--scope flag overrides the meta scope" "WARN scope" "$out"

echo
echo "dispatch-spec: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
