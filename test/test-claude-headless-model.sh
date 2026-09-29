#!/usr/bin/env bash
# test-claude-headless-model.sh — the claude pack's headless launch must not
# silently no-op on a model that cannot run under auto mode, and `wait-summary`
# must flag a clean rc=0 exit that changed nothing. Stub `claude` only, no model.
#
# Layer 1: pack_launch_headless — haiku (alias or full id) fails fast (rc!=0,
#   reason on stderr, the CLI never invoked); sonnet / opus / no model still get
#   the unchanged `-p ... --permission-mode auto` launch.
# Layer 2: a stub that stalls on a permission prompt (exit 0, writes nothing) is
#   reported "[no changes]" by wait-summary; a commit or a dirty tree clears it.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENGINE="$(cd "$SELF_DIR/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"; export REC="$TMP/rec"
# Stub: records argv, then behaves like a run stalled on a permission prompt
# (says so, writes nothing, exits 0).
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf 'invoked %s' "$*" > "$REC"
echo "I'm waiting for permission to create the file. Please approve the write action."
exit 0
STUB
chmod +x "$TMP/bin/claude"

launch() {  # <model or ""> -> sets rc, err
  : > "$REC"; rc=0
  err="$( ( PATH="$TMP/bin:$PATH"; source "$ENGINE/bin/fleet-config.sh"
            source "$ENGINE/packs/claude/pack.sh"
            pack_launch_headless "task" "$1" ) 2>&1 >/dev/null )" || rc=$?
}

for m in haiku claude-haiku-4-5-20251001 Haiku; do
  launch "$m"
  [ "$rc" -ne 0 ] || fail "$m: expected non-zero rc"
  case "$err" in *"model '$m' cannot run headless"*) ;; *) fail "$m: no clear reason on stderr (got: $err)";; esac
  [ ! -s "$REC" ] || fail "$m: claude was invoked despite the refusal"
done
echo "PASS (layer 1a): haiku models fail fast with a reason"

for m in sonnet opus ""; do
  launch "$m"
  [ "$rc" -eq 0 ] || fail "'$m': unexpected rc=$rc ($err)"
  got="$(cat "$REC")"
  case "$got" in *"-p task --permission-mode auto"*) ;; *) fail "'$m': launch changed (got: $got)";; esac
  if [ -n "$m" ]; then case "$got" in *"--model $m"*) ;; *) fail "'$m': --model lost (got: $got)";; esac; fi
done
echo "PASS (layer 1b): sonnet / opus / default launch unchanged"

# ---------- Layer 2: [no changes] advisory ----------
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
wt="$TMP/wt"; git init -q -b main "$wt"
git -C "$wt" commit -q --allow-empty -m base
sf="$TMP/w1.status"; printf 'done rc=0' > "$sf"
summ() { python3 "$ENGINE/bin/fleet_common.py" wait-summary "$wt" "$sf" "" main "$@"; }

summ | grep -q '\[no changes\]' || fail "clean rc=0 with 0 commits not flagged: $(summ)"
summ --json | grep -q '"empty": true' || fail "json lacks empty=true"
# barrier / sidecar files alone still count as empty
: > "$wt/.dispatch-marker"
summ | grep -q '\[no changes\]' || fail "sidecar-only tree not flagged"
git -C "$wt" checkout -q -b work
echo x > "$wt/hello.txt"
summ | grep -q '\[no changes\]' && fail "dirty tree wrongly flagged"
git -C "$wt" add hello.txt; git -C "$wt" commit -q -m work
summ | grep -q '\[no changes\]' && fail "committed work wrongly flagged"
git -C "$wt" checkout -q main; git -C "$wt" branch -q -D work
printf 'done rc=1' > "$sf"
summ | grep -q '\[no changes\]' && fail "failed run wrongly flagged"
echo "PASS (layer 2): [no changes] only for a clean rc=0 no-op"
