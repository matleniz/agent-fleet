#!/usr/bin/env bash
# test-fanin-e2e.sh — E2E for the OPTIONAL `fleet fanin` (hierarchical fan-in)
# with a fake pack (no model):
#   [1] never default: dispatching / waiting / gate launch no lead pass
#   [2] --dry-run: plans the groups, launches nothing, reports the direct-read size
#   [3] 5 finished workers, groups of 2 -> 3 lead passes, ONE report with a line
#       per worker, routed pack/model, measure.tsv row (hub tokens direct vs fan-in)
#   [4] a dead lead pass degrades to the raw digests of its group (no data lost)
#   [5] named workers restrict the batch; running workers are left out
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-fanin-test.XXXXXX")"
ROOT="$(mktemp -d "$HOME/.fleet-fanin-sandbox.XXXXXX")"
export FLEET_HOME="$TMP/config"
cleanup() { rm -rf "$TMP" "$ROOT"; }
trap cleanup EXIT

"$SELF_DIR/make-sandbox.sh" "$ROOT" >/dev/null 2>&1 \
  || { bad "sandbox build failed"; echo "fanin: $pass passed, $fail failed"; exit 1; }
export FLEET_PACKS_DIR; FLEET_PACKS_DIR="$("$SELF_DIR/make-fake-llm-pack.sh" "$TMP/packs")"
conf="$FLEET_HOME/projects/sandbox.env"
cat >> "$conf" <<'ENV'
AGENTS="fakellm stub"
ROUTE_KIND_FANIN="fakellm:lead-model"
ENV
SDIR="$FLEET_HOME/dispatch/sandbox"; mkdir -p "$SDIR"
calls() { find "$FLEET_HOME/fakellm" -name 'call.*.prompt' 2>/dev/null | wc -l; }
cd "$ROOT/code" || exit 1

# Five finished workers: a real worktree + commit + recorded task/status each.
for i in 1 2 3 4 5; do
  git -C "$ROOT/code" worktree add -q "$ROOT/wt/w$i" -b "w$i"
  echo "feature $i" > "$ROOT/wt/w$i/f$i.txt"
  git -C "$ROOT/wt/w$i" add -A
  git -C "$ROOT/wt/w$i" -c user.name=t -c user.email=t@localhost commit -qm "implement feature $i"
  printf 'implement feature %s: %s\n' "$i" "$(printf 'lorem ipsum %.0s' {1..20})" > "$SDIR/w$i.task"
  printf 'done rc=0' > "$SDIR/w$i.status"
done
printf 'running' > "$SDIR/w6.status"

echo "[1] never default-on"
"$FLEET" --project sandbox gate >/dev/null 2>&1
"$FLEET" --project sandbox wait w1 >/dev/null 2>&1
eq "no lead pass without 'fleet fanin'" "$(calls)" "0"

echo "[2] --dry-run plans, launches nothing"
out="$("$FLEET" --project sandbox fanin --group 2 --dry-run 2>&1)"
has "plans 3 groups" "5 worker(s) in 3 group(s) of <=2" "$out"
eq "still no pass" "$(calls)" "0"

echo "[3] 5 workers, groups of 2"
out="$("$FLEET" --project sandbox fanin --group 2 2>&1)"; rc=$?
eq "fanin rc" "$rc" "0"
eq "3 lead passes" "$(calls)" "3"
for i in 1 2 3 4 5; do has "report has a line for w$i" "- w$i | ok |" "$out"; done
hasnot "the running worker is left out" "w6" "$out"
eq "lead passes routed" "$(cat "$(ls -t "$FLEET_HOME"/fakellm/call.*.model | head -1)")" "lead-model"
lp="$(cat "$(grep -l 'fleet-pass:fanin' "$FLEET_HOME"/fakellm/call.*.prompt | head -1)")"
has "lead prompt carries worker digests" "implement feature" "$lp"
has "lead prompt forbids edits" "Do NOT modify" "$lp"
[ -f "$SDIR/fanin/latest.md" ] && ok "report written" || bad "no report file"
row="$(tail -1 "$SDIR/fanin/measure.tsv")"
has "measurement row logged" "n=5" "$row"
has "row has hub tokens" "hub_direct=" "$row"
direct="$(sed -n 's/.*hub_direct=\([0-9]*\).*/\1/p' <<<"$row")"
[ "${direct:-0}" -gt 0 ] && ok "direct-read estimate > 0 ($direct)" || bad "no direct-read estimate"
has "stderr states the measurement" "hub reads ~" "$out"

echo "[4] a dead lead pass degrades to raw digests"
touch "$FLEET_HOME/fakellm.fail"
out="$("$FLEET" --project sandbox fanin --group 3 2>&1)"; rc=$?
eq "still rc 0" "$rc" "0"
has "says which group fell back" "lead pass unusable" "$out"
has "raw digest kept (no data lost)" "### w1" "$out"
rm -f "$FLEET_HOME/fakellm.fail"

echo "[5] named workers restrict the batch"
before="$(calls)"
out="$("$FLEET" --project sandbox fanin --group 4 w2 w3 2>&1)"
has "w2 reported" "- w2 | ok |" "$out"
hasnot "w4 not reported" "- w4 |" "$out"
eq "one pass for one group" "$(calls)" "$((before + 1))"

echo
echo "fanin: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
