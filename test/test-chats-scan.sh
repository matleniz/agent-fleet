#!/usr/bin/env bash
# test-chats-scan.sh — tests for `fleet chats --scan` (bin/fleet-chats-scan.py)
# and the claude transcript parser (bin/fleet_chat_parse.py), the input side of
# the conversation-feedback routine. Uses an isolated $FLEET_HOME + $HOME with
# fake claude transcripts placed exactly where the claude pack's
# pack_chat_pointer looks (~/.claude/projects/<dir-slug>/*.jsonl). Both tools
# only read, so this is safe and deterministic — no CLI is ever launched.
#
#   test/test-chats-scan.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-chats-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
export FLEET_HOME="$TMP/config"
mkdir -p "$FLEET_HOME/projects"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected '$3', got '$2'"; fi; }

# ---- fixture: a code repo (+ one worktree) and a hub ----
HUB="$TMP/hub"; CODE="$TMP/code"; WT="$TMP/wt"
mkdir -p "$HUB" "$WT"
git -C "$TMP" init -q -b main code
printf 'x = 1\n' > "$CODE/f.py"
git -C "$CODE" add -A
git -C "$CODE" -c user.name=t -c user.email=t@localhost commit -qm init
git -C "$CODE" worktree add -q -b feat-x "$WT/feat-x" >/dev/null 2>&1

cat > "$FLEET_HOME/projects/x.env" <<EOF
CODE_REPO="$CODE"
HUB="$HUB"
WT_HOME="$WT"
AGENTS="claude"
EOF

# A valid claude JSONL transcript at the path the claude pack derives from a dir:
# ~/.claude/projects/<abs-dir with / -> ->. Write one for the hub, one for the
# worktree, so the scan finds a coordinator entry and a worker entry.
mk_transcript() {  # <dir> <session-id>
  local slug d
  # Claude Code's real slug: every non-alphanumeric char -> '-' (not just '/').
  # Must match packs/claude/pack.sh _claude_proj_slug, or a mktemp path (which
  # contains a '.') would land the fixture where the pack won't look.
  slug="$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"
  d="$HOME/.claude/projects/$slug"
  mkdir -p "$d"
  cat > "$d/$2.jsonl" <<JSONL
{"type":"user","sessionId":"$2","cwd":"$1","gitBranch":"main","version":"2.1.0","timestamp":"2026-07-01T10:00:00.000Z","message":{"role":"user","content":"do the thing"}}
{"type":"assistant","timestamp":"2026-07-01T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"tool_use","name":"Bash","input":{}},{"type":"text","text":"done"}]}}
{"type":"user","timestamp":"2026-07-01T10:00:06.000Z","message":{"role":"user","content":[{"type":"tool_result","is_error":true,"content":"boom failed"}]}}
{"type":"user","isMeta":true,"timestamp":"2026-07-01T10:00:07.000Z","message":{"role":"user","content":"meta noise, not a real prompt"}}
{"type":"user","timestamp":"2026-07-01T10:00:08.000Z","message":{"role":"user","content":"no, do it differently"}}
JSONL
}
mk_transcript "$HUB" hubsession
mk_transcript "$WT/feat-x" wtsession

scan() { "$REPO/bin/fleet" --project x chats --scan "$@"; }

echo "[1] --scan --json finds coordinator + worker claude conversations"
json="$(scan --json 2>/dev/null)"
FLEET_HUB="$HUB" FLEET_WT="$WT" python3 - "$json" <<'PY'
import json, os, sys
r = json.loads(sys.argv[1])
hub, wt = os.environ["FLEET_HUB"], os.environ["FLEET_WT"]
p = r["projects"][0]
convs = p["conversations"]
checks = [("machine local", r["machine"], "local"),
          ("project name", p["name"], "x"),
          ("all pack==claude", all(c["pack"] == "claude" for c in convs), True),
          ("all is_file", all(c["is_file"] for c in convs), True)]
coord = [c for c in convs if c["role"] == "coordinator"]
worker = [c for c in convs if c["role"] == "worker"]
checks.append(("one coordinator entry", len(coord), 1))
checks.append(("coordinator dir == hub", coord and coord[0]["dir"], hub))
checks.append(("coordinator pointer under ~/.claude", coord and "/.claude/projects/" in coord[0]["pointer"], True))
checks.append(("one worker entry", len(worker), 1))
checks.append(("worker worktree name", worker and worker[0]["worktree"], "feat-x"))
fails = 0
for name, got, want in checks:
    if got == want: print("  ok   %s (%r)" % (name, got))
    else: print("  FAIL %s: expected %r, got %r" % (name, want, got)); fails += 1
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && ok "scan json checks passed" || bad "scan json checks failed"

echo "[2] text output is human-readable"
out="$(scan 2>/dev/null)"
printf '%s' "$out" | grep -q "recorded conversation" && ok "text has a header" || bad "no header"
printf '%s' "$out" | grep -q "coordinator" && ok "text lists coordinator" || bad "no coordinator line"
printf '%s' "$out" | grep -q "worker feat-x" && ok "text lists worker" || bad "no worker line"

echo "[3] --all discovers the project without --project"
alljson="$("$REPO/bin/fleet" --project x chats --scan --all --json 2>/dev/null)"
n="$(printf '%s' "$alljson" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["projects"]))')"
[ "$n" -ge 1 ] && ok "--all found >=1 project ($n)" || bad "--all found no projects"

echo "[4] parser extracts the method signal from a claude transcript"
tr="$HOME/.claude/projects/$(printf '%s' "$HUB" | sed 's/[^A-Za-z0-9]/-/g')/hubsession.jsonl"
pjson="$(python3 "$REPO/bin/fleet_chat_parse.py" "$tr" 2>/dev/null)"
python3 - "$pjson" <<'PY'
import json, sys
r = json.loads(sys.argv[1])
c = r["counts"]
checks = [("real user prompts (meta excluded)", c["user_prompts"], 2),
          ("assistant turns", c["assistant_turns"], 1),
          ("tool_use counted", c["tool_use"], 1),
          ("tool errors counted", c["tool_errors"], 1),
          ("Bash in histogram", r["tools"].get("Bash"), 1),
          ("session id", r["session_id"], "hubsession"),
          ("git branch", r["git_branch"], "main"),
          ("first prompt captured", r["user_prompts"][0], "do the thing"),
          ("correction captured", r["user_prompts"][1], "no, do it differently")]
fails = 0
for name, got, want in checks:
    if got == want: print("  ok   %s (%r)" % (name, got))
    else: print("  FAIL %s: expected %r, got %r" % (name, want, got)); fails += 1
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && ok "parser checks passed" || bad "parser checks failed"

echo "[5] parser rejects a non-claude pointer (fail-safe, not a crash)"
notclaude="$TMP/notclaude.txt"; printf 'just a shell command\n' > "$notclaude"
err="$(python3 "$REPO/bin/fleet_chat_parse.py" "$notclaude" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("error","-"))')"
[ "$err" != "-" ] && ok "non-claude input reported as error, no crash" || bad "expected an error field"

echo "[5b] --parse attaches the method signal to claude entries"
pjson2="$(scan --parse --json 2>/dev/null)"
FLEET_HUB="$HUB" python3 - "$pjson2" <<'PY'
import json, sys
r = json.loads(sys.argv[1])
convs = r["projects"][0]["conversations"]
withp = [c for c in convs if "parsed" in c]
checks = [("every claude entry got parsed", len(withp), len(convs)),
          ("parsed carries counts", all("counts" in c["parsed"] for c in withp), True),
          ("parsed found a user prompt", all(c["parsed"]["counts"]["user_prompts"] >= 1 for c in withp), True)]
fails = 0
for name, got, want in checks:
    if got == want: print("  ok   %s (%r)" % (name, got))
    else: print("  FAIL %s: expected %r, got %r" % (name, want, got)); fails += 1
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && ok "parse-inline checks passed" || bad "parse-inline checks failed"

# ---- cursor fixture: a cursor project over the same repo/hub/worktree ----
# Cursor records a JSONL transcript at
# ~/.cursor/projects/<slug>/agent-transcripts/<uuid>/<uuid>.jsonl, where <slug> is
# the abs cwd with non-alnum -> '-' and NO leading dash (claude keeps the leading
# dash; cursor drops it). Must match packs/cursor/pack.sh _cursor_proj_slug.
cat > "$FLEET_HOME/projects/xc.env" <<EOF
CODE_REPO="$CODE"
HUB="$HUB"
WT_HOME="$WT"
AGENTS="cursor"
EOF

mk_cursor_transcript() {  # <dir> <uuid>
  local slug d
  slug="$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g; s/^-*//')"
  d="$HOME/.cursor/projects/$slug/agent-transcripts/$2"
  mkdir -p "$d"
  # role-tagged turns, no top-level type; human turns wrapped in
  # <timestamp>/<user_query>; a headless auto-continue nudge as a user turn (must
  # be filtered); a {type:turn_ended} control line (must be ignored).
  cat > "$d/$2.jsonl" <<'JSONL'
{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Mon, Jul 21, 2026</timestamp>\n<user_query>You are a code WORKER. do the thing</user_query>"}]}}
{"role":"assistant","message":{"content":[{"type":"text","text":"okay"},{"type":"tool_use","name":"Shell","input":{}},{"type":"tool_use","name":"Read","input":{}}]}}
{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Mon, Jul 21, 2026</timestamp>\n<user_query>no, do it differently</user_query>"}]}}
{"role":"user","message":{"content":[{"type":"text","text":"<user_query>Briefly inform the user about the task result and perform any follow-up actions</user_query>"}]}}
{"type":"turn_ended","status":"completed"}
JSONL
}
mk_cursor_transcript "$HUB" 11111111-1111-1111-1111-111111111111
mk_cursor_transcript "$WT/feat-x" 22222222-2222-2222-2222-222222222222

echo "[5c] parser extracts the signal from a cursor transcript (unwrap + nudge filtered)"
cslug="$(printf '%s' "$HUB" | sed 's/[^A-Za-z0-9]/-/g; s/^-*//')"
ctr="$HOME/.cursor/projects/$cslug/agent-transcripts/11111111-1111-1111-1111-111111111111/11111111-1111-1111-1111-111111111111.jsonl"
cpjson="$(python3 "$REPO/bin/fleet_chat_parse.py" "$ctr" 2>/dev/null)"
python3 - "$cpjson" <<'PY'
import json, sys
r = json.loads(sys.argv[1])
c = r["counts"]
checks = [("real user prompts (nudge excluded)", c["user_prompts"], 2),
          ("assistant turns", c["assistant_turns"], 1),
          ("tool_use counted", c["tool_use"], 2),
          ("tool errors always 0 (no tool_result in cursor)", c["tool_errors"], 0),
          ("Shell in histogram", r["tools"].get("Shell"), 1),
          ("session id from filename", r["session_id"], "11111111-1111-1111-1111-111111111111"),
          ("started None (cursor has no per-turn ts)", r["started"], None),
          ("first prompt unwrapped", r["user_prompts"][0], "You are a code WORKER. do the thing"),
          ("correction unwrapped", r["user_prompts"][1], "no, do it differently")]
fails = 0
for name, got, want in checks:
    if got == want: print("  ok   %s (%r)" % (name, got))
    else: print("  FAIL %s: expected %r, got %r" % (name, want, got)); fails += 1
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && ok "cursor parser checks passed" || bad "cursor parser checks failed"

echo "[5d] --history --parse discovers cursor transcripts via pack_chat_history"
chjson="$("$REPO/bin/fleet" --project xc chats --scan --history --parse --json 2>/dev/null)"
python3 - "$chjson" <<'PY'
import json, sys
r = json.loads(sys.argv[1])
convs = r["projects"][0]["conversations"]
coord = [c for c in convs if c["role"] == "coordinator"]
worker = [c for c in convs if c["role"] == "worker"]
checks = [("all pack==cursor", all(c["pack"] == "cursor" for c in convs), True),
          ("all is_file", all(c["is_file"] for c in convs), True),
          ("one coordinator entry", len(coord), 1),
          ("one worker entry", len(worker), 1),
          ("worker worktree name", worker and worker[0]["worktree"], "feat-x"),
          ("cursor entries got parsed", all("parsed" in c for c in convs), True),
          ("parsed found 2 prompts", all(c["parsed"]["counts"]["user_prompts"] == 2 for c in convs), True)]
fails = 0
for name, got, want in checks:
    if got == want: print("  ok   %s (%r)" % (name, got))
    else: print("  FAIL %s: expected %r, got %r" % (name, want, got)); fails += 1
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && ok "cursor history/parse checks passed" || bad "cursor history/parse checks failed"

echo "[6] seen ledger dedups by normalized fingerprint"
LEDGER="$TMP/ledger.json"
fb() { "$REPO/bin/fleet" feedback --file "$LEDGER" "$@"; }
fb seen "worker edits hub instead of proposing" >/dev/null 2>&1; eq "unseen fingerprint -> exit 1" "$?" "1"
fb record "worker edits hub instead of proposing" --project x >/dev/null 2>&1; eq "record -> exit 0" "$?" "0"
fb seen "worker edits hub instead of proposing" >/dev/null 2>&1; eq "recorded fingerprint -> exit 0" "$?" "0"
# normalization: different case/whitespace collapses to the same entry
fb seen "WORKER  edits   HUB instead of proposing" >/dev/null 2>&1; eq "normalized variant seen -> exit 0" "$?" "0"
# a genuinely different lesson is still new
fb seen "worker force-pushes over main" >/dev/null 2>&1; eq "different lesson -> exit 1" "$?" "1"
# record across a second project appends the project, does not duplicate the entry
fb record "worker edits hub instead of proposing" --project y >/dev/null 2>&1
n_entries="$(fb list --json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["entries"]))')"
eq "one ledger entry after cross-project record" "$n_entries" "1"
projs="$(fb list --json 2>/dev/null | python3 -c 'import json,sys; e=list(json.load(sys.stdin)["entries"].values())[0]; print(",".join(sorted(e["projects"])))')"
eq "entry tracks both projects" "$projs" "x,y"
cnt="$(fb list --json 2>/dev/null | python3 -c 'import json,sys; e=list(json.load(sys.stdin)["entries"].values())[0]; print(e["count"])')"
eq "count incremented across runs" "$cnt" "2"

echo
echo "chats-scan tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
