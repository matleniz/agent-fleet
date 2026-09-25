#!/usr/bin/env bash
# test-claude-resume.sh — the claude pack's session-resume helpers:
#   _claude_proj_slug        the project-dir slug matches Claude Code's real rule
#                            (EVERY non-alphanumeric char -> '-', not just '/').
#   _claude_last_session_id  resume the last REAL conversation, skipping a
#                            reply-less .jsonl left by a launch aborted at startup
#                            (which otherwise shadows it via a fresh mtime — the
#                            "r doesn't load the last session" bug).
# Pure helper test: sources the pack, fakes $HOME/.claude/projects, no claude, no
# tmux, never touches the real ~/.claude. Exits non-zero on failure.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PACK="$SELF_DIR/../packs/claude/pack.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1" >&2; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', expected '$3')"; }

# shellcheck disable=SC1090  # path resolved at runtime
source "$PACK"

# --- 1. munging: every non-alphanumeric char -> '-', 1-for-1, no collapsing ----
eq "slug: slashes"              "$(_claude_proj_slug "/home/matleniz/mlops-hub")" "-home-matleniz-mlops-hub"
eq "slug: dot and underscore"   "$(_claude_proj_slug "/a/feature.v2_x")"          "-a-feature-v2-x"
eq "slug: no run collapsing"    "$(_claude_proj_slug "/x/a..b__c")"               "-x-a--b--c"

# --- fake HOME with a real dir of sessions ------------------------------------
HOME="$(mktemp -d "${TMPDIR:-/tmp}/fleet-resume.XXXXXX")"; export HOME
trap 'rm -rf "$HOME"' EXIT
cwd="/home/matleniz/mlops-hub"
d="$HOME/.claude/projects/$(_claude_proj_slug "$cwd")"; mkdir -p "$d"

mk() {  # <name> <mtime> <has-assistant:0|1> [bg]
  local f="$d/$1.jsonl"
  if [ "$3" = 1 ]; then
    local kind=""; [ "${4:-}" = bg ] && kind=',"sessionKind":"bg"'
    printf '%s\n' "{\"type\":\"user\"$kind}" '{"type":"assistant","timestamp":"x"}' > "$f"
  else printf '%s\n' '{"type":"queue-operation"}' > "$f"; fi
  touch -d "$2" "$f"
}
mk real-old  '2026-07-20 10:00:00' 1
mk real-last '2026-07-20 15:00:00' 1
mk aborted   '2026-07-20 15:05:00' 0        # NEWEST-but-one, reply-less
mk bg-agent  '2026-07-20 15:10:00' 1 bg     # NEWEST mtime, has replies, but background agent

# --- 2. last-session picks the newest REAL INTERACTIVE one, skipping the -------
#        reply-less 'aborted' AND the newer background-agent session.
eq "last id skips aborted + bg" "$(_claude_last_session_id "$cwd")" "real-last"

# a dir with ONLY a bg session -> empty (don't resume someone's background agent)
d4="$HOME/.claude/projects/$(_claude_proj_slug "/only/bg")"; mkdir -p "$d4"
printf '%s\n' '{"type":"user","sessionKind":"bg"}' '{"type":"assistant"}' > "$d4/b.jsonl"
eq "empty id when only a bg session" "$(_claude_last_session_id "/only/bg")" ""

# --- 3. pack_has_sessions resolves a dotted/underscored cwd (munging fix) ------
d2="$HOME/.claude/projects/$(_claude_proj_slug "/x/foo_bar.baz")"; mkdir -p "$d2"; : > "$d2/s.jsonl"
if pack_has_sessions "/x/foo_bar.baz"; then ok "pack_has_sessions on dotted/underscored cwd"
else bad "pack_has_sessions missed a dotted/underscored cwd"; fi

# --- 4. only reply-less sessions -> empty id (caller falls back to --continue) -
d3="$HOME/.claude/projects/$(_claude_proj_slug "/only/aborted")"; mkdir -p "$d3"
printf '%s\n' '{"type":"queue-operation"}' > "$d3/x.jsonl"
eq "empty id when no real session" "$(_claude_last_session_id "/only/aborted")" ""

# --- 5. no session dir at all -> empty id, no error ---------------------------
eq "empty id when no dir" "$(_claude_last_session_id "/nope/never")" ""

# --- 6. pack_launch modes: --continue resolves last id; --pick is bare --resume -
REC="$(mktemp)"; export REC
stub="$(mktemp -d)"
printf '#!/usr/bin/env bash\nprintf "%%s" "$*" > "$REC"\n' > "$stub/claude"; chmod +x "$stub/claude"
SELF_CFG="$SELF_DIR/../bin/fleet-config.sh"
fake_cwd="$(mktemp -d)/mlops-hub"; mkdir -p "$fake_cwd"
d_fake="$HOME/.claude/projects/$(_claude_proj_slug "$fake_cwd")"; mkdir -p "$d_fake"
printf '%s\n' '{"type":"user"}' '{"type":"assistant"}' > "$d_fake/sid-continue.jsonl"
touch -d '2026-07-20 16:00:00' "$d_fake/sid-continue.jsonl"

: > "$REC"
( cd "$fake_cwd"; PATH="$stub:$PATH"
  # shellcheck disable=SC1090
  source "$SELF_CFG"; source "$PACK"; pack_launch --continue ) || true
got="$(cat "$REC")"
case "$got" in *"--resume sid-continue"*) ok "pack_launch --continue passes last session id";;
  *) bad "pack_launch --continue (got '$got')";; esac

: > "$REC"
( cd "$fake_cwd"; PATH="$stub:$PATH"
  # shellcheck disable=SC1090
  source "$SELF_CFG"; source "$PACK"; pack_launch --pick ) || true
got="$(cat "$REC")"
case "$got" in *"--resume sid-continue"*) bad "pack_launch --pick must not resolve an id (got '$got')";;
  *"--resume"*) ok "pack_launch --pick passes bare --resume";;
  *) bad "pack_launch --pick (got '$got')";; esac

rm -rf "$stub" "$(dirname "$fake_cwd")"
rm -f "$REC"

echo "claude-resume tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
