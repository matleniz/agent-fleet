#!/usr/bin/env bash
# test-feedback-pipeline.sh — deterministic seams of the conversation-feedback
# pipeline (docs/04 "The conversation-feedback pipeline"). The compress/distill/
# finalize REASONING lives in skills (an agent), not code, so this tests only the
# code seams the pipeline hangs on: `fleet feedback config` (the model/runner
# knobs), `fleet chats --scan --since` (the compress pass's skip-already-seen
# lever), and `fleet-queue` (the backend a `project`-target lesson files to). No
# CLI/agent is ever launched; everything here only reads or resolves config.
#
#   test/test-feedback-pipeline.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-fbpipe-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
export FLEET_HOME="$TMP/config"
mkdir -p "$FLEET_HOME/projects"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected '$3', got '$2'"; fi; }
has() { if printf '%s' "$2" | grep -q -- "$3"; then ok "$1"; else bad "$1: '$3' not in output"; fi; }

# ---- fixture: a code repo (+ one worktree), a hub, one project ----
HUB="$TMP/hub"; CODE="$TMP/code"; WT="$TMP/wt"
mkdir -p "$HUB" "$WT"
git -C "$TMP" init -q -b main code
printf 'x = 1\n' > "$CODE/f.py"
git -C "$CODE" -c user.name=t -c user.email=t@localhost add -A
git -C "$CODE" -c user.name=t -c user.email=t@localhost commit -qm init
git -C "$CODE" worktree add -q -b feat-x "$WT/feat-x" >/dev/null 2>&1

cat > "$FLEET_HOME/projects/x.env" <<EOF
CODE_REPO="$CODE"
HUB="$HUB"
WT_HOME="$WT"
AGENTS="claude"
QUEUE_KIND="github"
QUEUE_GITHUB_REPO="owner/repo"
EOF

mk_transcript() {  # <dir> <session-id>
  local slug d
  # Match Claude Code's real slug (every non-alnum -> '-'), = pack.sh
  # _claude_proj_slug; a mktemp path has a '.', so 's#/#-#g' would misplace it.
  slug="$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"
  d="$HOME/.claude/projects/$slug"
  mkdir -p "$d"
  cat > "$d/$2.jsonl" <<JSONL
{"type":"user","sessionId":"$2","cwd":"$1","gitBranch":"main","version":"2.1.0","timestamp":"2026-07-01T10:00:00.000Z","message":{"role":"user","content":"do the thing"}}
{"type":"assistant","timestamp":"2026-07-01T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}},{"type":"text","text":"done"}]}}
{"type":"user","timestamp":"2026-07-01T10:00:08.000Z","message":{"role":"user","content":"no, do it differently"}}
JSONL
  printf '%s\n' "$d/$2.jsonl"
}
HUB_TR="$(mk_transcript "$HUB" hubsession)"
WT_TR="$(mk_transcript "$WT/feat-x" wtsession)"

echo "[1] feedback config — built-in defaults (no default.env)"
cfg="$("$REPO/bin/fleet" feedback config 2>/dev/null)"
has "reports FEEDBACK_MODEL_COMPRESS=haiku" "$cfg" "FEEDBACK_MODEL_COMPRESS=haiku"
has "reports FEEDBACK_MODEL_DISTILL=sonnet" "$cfg" "FEEDBACK_MODEL_DISTILL=sonnet"
has "reports FEEDBACK_RUNNER=local" "$cfg" "FEEDBACK_RUNNER=local"
has "notes dir under FLEET_HOME" "$cfg" "FEEDBACK_NOTES_DIR=$FLEET_HOME/feedback-notes"
has "digests dir under FLEET_HOME" "$cfg" "FEEDBACK_DIGESTS_DIR=$FLEET_HOME/feedback-digests"

echo "[2] feedback config --json is valid and carries the fields"
cfgj="$("$REPO/bin/fleet" feedback config --json 2>/dev/null)"
python3 - "$cfgj" <<'PY'
import json, sys
r = json.loads(sys.argv[1])
need = {"model_compress", "model_distill", "runner", "notes_dir", "digests_dir"}
missing = need - set(r)
sys.exit(1 if missing else 0)
PY
[ $? -eq 0 ] && ok "config --json has every field" || bad "config --json missing a field"

echo "[3] default.env overrides the built-ins"
cat > "$FLEET_HOME/default.env" <<EOF
FEEDBACK_MODEL_COMPRESS=my-cheap
FEEDBACK_MODEL_DISTILL=my-strong
FEEDBACK_RUNNER=cloud
EOF
cfg2="$("$REPO/bin/fleet" feedback config 2>/dev/null)"
has "override compress model" "$cfg2" "FEEDBACK_MODEL_COMPRESS=my-cheap"
has "override distill model" "$cfg2" "FEEDBACK_MODEL_DISTILL=my-strong"
has "override runner" "$cfg2" "FEEDBACK_RUNNER=cloud"
rm -f "$FLEET_HOME/default.env"

echo "[4] empty model override means 'CLI default' (no forced model)"
printf 'FEEDBACK_MODEL_COMPRESS=\n' > "$FLEET_HOME/default.env"
cfg3="$("$REPO/bin/fleet" feedback config 2>/dev/null)"
line="$(printf '%s\n' "$cfg3" | grep '^FEEDBACK_MODEL_COMPRESS=')"
eq "explicit-empty compress stays empty" "$line" "FEEDBACK_MODEL_COMPRESS="
rm -f "$FLEET_HOME/default.env"

echo "[5] chats --scan --since drops transcripts untouched since the cutoff"
touch -d '2026-06-01T00:00:00' "$HUB_TR"      # old: before cutoff
touch -d '2026-07-10T00:00:00' "$WT_TR"       # new: after cutoff
since_json="$("$REPO/bin/fleet" --project x chats --scan --since 2026-07-01 --json 2>/dev/null)"
python3 - "$since_json" <<'PY'
import json, sys
r = json.loads(sys.argv[1])
convs = r["projects"][0]["conversations"]
roles = sorted(c["role"] for c in convs)
# only the newer (worker) transcript survives the --since filter
sys.exit(0 if roles == ["worker"] else 1)
PY
[ $? -eq 0 ] && ok "--since kept only the transcript newer than the cutoff" || bad "--since filter wrong set"

echo "[6] chats --scan without --since still sees both"
allj="$("$REPO/bin/fleet" --project x chats --scan --json 2>/dev/null)"
n="$(printf '%s' "$allj" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["projects"][0]["conversations"]))')"
eq "no --since sees both transcripts" "$n" "2"

echo "[7] chats --scan --since rejects a non-ISO value (exit 2, no crash)"
"$REPO/bin/fleet" --project x chats --scan --since not-a-date --json >/dev/null 2>&1
eq "bad --since exits 2" "$?" "2"

echo "[8] fleet-queue resolves the backend a 'project'-target lesson files to"
q="$("$REPO/bin/fleet-queue" --project x 2>/dev/null)"
has "queue kind resolved" "$q" "QUEUE_KIND=github"
has "github repo resolved" "$q" "QUEUE_GITHUB_REPO=owner/repo"

echo "[9] --history sees ALL sessions incl. a finished (deleted) worker"
# A second hub session, and an ORPHANED worker: its ~/.claude history exists but no
# live git worktree does (the normal case after fleet del/prune). The default scan
# must miss it; --history must find it.
mk_transcript "$HUB" hubsession2 >/dev/null
mk_transcript "$WT/gone-worker" gonesession >/dev/null   # note: no `git worktree add`
histj="$("$REPO/bin/fleet" --project x chats --scan --history --json 2>/dev/null)"
python3 - "$histj" <<'PY'
import json, sys
convs = json.loads(sys.argv[1])["projects"][0]["conversations"]
coord = [c for c in convs if c["role"] == "coordinator"]
work = {c["worktree"] for c in convs if c["role"] == "worker"}
checks = [
    ("history: both hub sessions (one entry per file)", len(coord), 2),
    ("history: live worker feat-x present", "feat-x" in work, True),
    ("history: ORPHANED worker gone-worker present", "gone-worker" in work, True),
    ("history: entries are files", all(c["is_file"] for c in convs), True),
]
fails = 0
for name, got, want in checks:
    if got == want: print("  ok   %s (%r)" % (name, got))
    else: print("  FAIL %s: expected %r, got %r" % (name, want, got)); fails += 1
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && ok "history-mode checks passed" || bad "history-mode checks failed"

echo "[10] default mode still collapses to one latest pointer per live location"
defj="$("$REPO/bin/fleet" --project x chats --scan --json 2>/dev/null)"
python3 - "$defj" <<'PY'
import json, sys
convs = json.loads(sys.argv[1])["projects"][0]["conversations"]
coord = [c for c in convs if c["role"] == "coordinator"]
work = {c["worktree"] for c in convs if c["role"] == "worker"}
# one coordinator pointer (latest of the two hub sessions), the orphaned worker
# has no live worktree so it must be absent in the default mode.
checks = [("default: one coordinator pointer", len(coord), 1),
          ("default: orphaned worker absent", "gone-worker" in work, False)]
fails = 0
for name, got, want in checks:
    if got == want: print("  ok   %s (%r)" % (name, got))
    else: print("  FAIL %s: expected %r, got %r" % (name, want, got)); fails += 1
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && ok "default-mode checks passed" || bad "default-mode checks failed"

echo
echo "feedback-pipeline tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
