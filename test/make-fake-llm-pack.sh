#!/usr/bin/env bash
# make-fake-llm-pack.sh <dest> — build a FLEET_PACKS_DIR that holds the real packs
# (symlinked) plus a `fakellm` pack: a stand-in for an agent CLI so the pipeline
# tests (judge / race / fanin) exercise the real headless launch path without any
# model. Sourced by nothing; run it, then `export FLEET_PACKS_DIR=<dest>`.
#
# fakellm behaves by the prompt's first line (the [fleet-pass:<kind>] tag every
# pass prompt starts with); every call is logged under $FLEET_HOME/fakellm/.
#   [fleet-pass:judge]       prints a finding + `VERDICT: CONCERNS`
#                            (or APPROVE if $FLEET_HOME/fakellm.verdict says so)
#   [fleet-pass:race-judge]  WINNER = first worktree, comments for the others
#   [fleet-pass:fanin]       one structured line per `### <worker>` + NEEDS-HUMAN
#   anything else (a worker) commits solution.txt in $PWD; a FOLLOW-UP prompt
#                            appends the review round and commits again
# $FLEET_HOME/fakellm.fail makes every call exit 1 (a dead / out-of-quota pack).
set -euo pipefail
DEST="${1:?usage: make-fake-llm-pack.sh <dest>}"
REAL="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../packs" && pwd)"
rm -rf "$DEST"; mkdir -p "$DEST/fakellm"
for d in "$REAL"/*; do ln -s "$d" "$DEST/$(basename "$d")"; done
cat > "$DEST/fakellm/pack.sh" <<'PACK'
# shellcheck shell=bash
pack_launch() { :; }
pack_has_sessions() { return 1; }
pack_worker_setup() { return 0; }
pack_barrier_files() { :; }
pack_install() { echo "(fakellm — no install)"; }
pack_doctor() { echo "fakellm (test double)"; }
pack_launch_headless() {
  local prompt="$1" model="${2:-}" log="${FLEET_HOME:?}/fakellm" base first
  mkdir -p "$log"
  base="$(mktemp "$log/call.XXXXXX")"
  printf '%s' "$prompt" > "$base.prompt"
  printf '%s' "$model" > "$base.model"
  printf '%s' "$PWD" > "$base.cwd"
  [ ! -f "$FLEET_HOME/fakellm.fail" ] || { echo "fakellm: simulated failure"; return 1; }
  first="$(printf '%s\n' "$prompt" | grep -m1 '^\[fleet-pass:' || true)"
  case "$first" in
    "[fleet-pass:judge]")
      echo "- hello.py: greet() ignores empty names"
      echo "VERDICT: $(cat "$FLEET_HOME/fakellm.verdict" 2>/dev/null || echo CONCERNS)" ;;
    "[fleet-pass:race-judge]")
      local w winner="" others=""
      for w in $(printf '%s\n' "$prompt" | sed -n 's/^=== WORKTREE \([^ ]*\) .*/\1/p'); do
        if [ -z "$winner" ]; then winner="$w"; else others="$others $w"; fi
      done
      printf 'WINNER: %s\nREASON: it is simpler. It also has tests.\n' "$winner"
      for w in $others; do printf '\n## Comments for %s\n- solution.txt: adopt the winner'"'"'s approach.\n' "$w"; done ;;
    "[fleet-pass:fanin]")
      printf '%s\n' "$prompt" | sed -n 's/^### \(.*\)$/- \1 | ok | did the task | files: 1 | risk: none/p'
      echo "NEEDS-HUMAN: none" ;;
    *)
      local me; me="$(basename "$PWD")"
      case "$prompt" in
        *"FOLLOW-UP (review round"*) echo "addressed review" >> solution.txt; git add -A; git -c user.name=fake -c user.email=fake@localhost commit -qm "address review" ;;
        *) echo "solution by $me" > solution.txt; git add -A; git -c user.name=fake -c user.email=fake@localhost commit -qm "add solution" ;;
      esac ;;
  esac
}
PACK
echo "$DEST"
