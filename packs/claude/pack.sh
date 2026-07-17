# claude pack — Claude Code CLI (@anthropic-ai/claude-code).
# Sourced by fleet_load_pack; must define the five required pack_* functions
# (pack_doctor is optional, used by `fleet doctor`).
# Iso-functional port of the pre-pack behavior: same launch flags, same
# session detection, same barrier settings written per worktree.

# Exploration/search subagents default to a CHEAP model instead of inheriting the
# main (Opus) model. Since Claude Code v2.1.198 native subagents inherit the
# parent model, so throwaway digs launched from an Opus session run on Opus and
# burn tokens. This is the fleet's "isolate throwaway exploration" lever (docs 06)
# applied to Claude's own subagents. Respects a value already set in the
# environment (e.g. your ~/.bashrc), so overriding is just exporting it yourself.
pack_claude_subagent_model() {
  export CLAUDE_CODE_SUBAGENT_MODEL="${CLAUDE_CODE_SUBAGENT_MODEL:-sonnet}"
}

# Launch Claude Code in the CURRENT directory (caller cd's first).
# Workers run in AUTO mode: autonomous, but a server-side classifier gates each
# action (local edits / installs from a manifest / push to the worker's own branch
# pass; prod deploys, force-push, curl|bash, out-of-scope writes get blocked). We
# can NOT use --dangerously-skip-permissions here: the org's managed
# remote-settings.json sets permissions.disableBypassPermissionsMode:"disable",
# which silently downgrades that flag to prompting → every write auto-denied. That
# managed key does not touch auto mode, so auto mode is the working autonomous
# posture (revert to --dangerously-skip-permissions if the org lifts the policy).
# The read-only-hub barrier (PreToolUse hook) holds in any mode. Main model is
# chosen by hand via /model, subagents via pack_claude_subagent_model above.
pack_launch() {
  local resume=()
  [ "${1:-}" = "--resume" ] && resume=(--continue)
  pack_claude_subagent_model
  exec claude --permission-mode auto "${resume[@]}"
}

# Headless launch for `fleet dispatch`: run one task non-interactively in the same
# AUTO mode as pack_launch, so the worker has shell/tool access. Caveat: with no
# human to approve, a repeated classifier block (3x in a row / 20x total) aborts
# the session — for work that trips the classifier, prefer interactive `fleet w`.
# The read-only-hub barrier (PreToolUse hook) is unaffected.
# $2 (optional): the model for this worker, from `fleet dispatch --model` (else
# the account default). --model is a real claude flag (verified against v2.1.x).
pack_launch_headless() {
  pack_claude_subagent_model
  exec claude -p "$1" --permission-mode auto ${2:+--model "$2"}
}

# fleet global: point Claude's user file (~/.claude/CLAUDE.md) at the canonical
# per-user instructions via a one-line @import (same bridge idiom fleet-init
# uses). Idempotent; prepends the import if the file already has other content so
# nothing is lost. mode=status only reports. Echoes a status word.
pack_global_setup() {
  local canon="$1" mode="${2:-install}" f="$HOME/.claude/CLAUDE.md" imp="@$1"
  command -v claude >/dev/null || { echo "skipped:not-installed"; return 0; }
  if [ -f "$f" ] && grep -qxF "$imp" "$f"; then echo "wired"; return 0; fi
  [ "$mode" = status ] && { echo "not-wired"; return 0; }
  mkdir -p "$HOME/.claude"
  if [ -s "$f" ]; then { printf '%s\n' "$imp"; cat "$f"; } > "$f.tmp" && mv "$f.tmp" "$f"
  else printf '%s\n' "$imp" > "$f"; fi
  echo "wired"
}

# Claude Code stores sessions per project dir under ~/.claude/projects/,
# with the absolute path munged (slashes -> dashes), one .jsonl per session.
pack_has_sessions() {
  local d="$HOME/.claude/projects/$(printf '%s' "$1" | sed 's#/#-#g')"
  [ -d "$d" ] && ls "$d"/*.jsonl >/dev/null 2>&1
}

# Worktree-relative files pack_worker_setup writes (the core ignores them
# when judging a worktree dirty for del/prune).
pack_barrier_files() { echo ".claude/settings.local.json"; }

# Per-worktree setup: the read-only-hub barrier. allow:Read +
# additionalDirectories make the hub readable; the PreToolUse hook
# (hub-readonly-guard.py) is what actually blocks Write/Edit to it — a deny
# rule would not override an additionalDirectories root (see docs/02).
# If the project sets NTFY_TOPIC, also wire attention notifications
# (Notification = waiting on a permission/idle, Stop = turn finished) through
# bin/fleet-notify. Uses $HUB, $GUARD, $NOTIFY from the caller.
pack_worker_setup() {
  local dest="$1"
  [ -z "${HUB:-}" ] && [ -z "${NTFY_TOPIC:-}" ] && return 0
  mkdir -p "$dest/.claude"
  python3 - "$dest/.claude/settings.local.json" <<PY
import json, os, sys
hub, guard = os.environ.get("HUB", ""), os.environ.get("GUARD", "")
topic = os.environ.get("NTFY_TOPIC", "")
notify = os.environ.get("NOTIFY", "")
label = os.path.basename(os.path.dirname(os.path.dirname(sys.argv[1])))  # worker dir name
cfg = {}
if hub:
    cfg["permissions"] = {"allow": [f"Read({hub}/**)"], "additionalDirectories": [hub]}
    cfg.setdefault("hooks", {})["PreToolUse"] = [{
        "matcher": "Write|Edit|MultiEdit|NotebookEdit",
        "hooks": [{"type": "command", "command": f"{guard} {hub}"}],
    }]
if topic and notify:
    h = cfg.setdefault("hooks", {})
    h["Notification"] = [{"hooks": [{"type": "command", "command": f"{notify} {topic} {label} needs-attention"}]}]
    h["Stop"] = [{"hooks": [{"type": "command", "command": f"{notify} {topic} {label} done"}]}]
json.dump(cfg, open(sys.argv[1], "w"), indent=2)
PY
}

# Install line for the VM image / a fresh machine (auth: one-time OAuth login).
pack_install() { echo "npm install -g @anthropic-ai/claude-code"; }

# Optional: fleet doctor status line. With arg "probe" (fleet doctor --write-probe)
# it runs a real witness write in the CURRENT (throwaway) dir to prove auto mode
# can actually write here — the org's managed remote-settings.json can silently
# deny every write, and a plain launch fails open (rc=0, nothing written).
pack_doctor() {
  command -v claude >/dev/null || { echo "NOT INSTALLED (npm i -g @anthropic-ai/claude-code)"; return; }
  if [ "${1:-}" = probe ]; then
    rm -f .fleet-witness
    claude -p 'Create a file named .fleet-witness containing the text OK in the current directory, then stop. Do nothing else.' \
      --permission-mode auto >/dev/null 2>&1 || true
    if [ -f .fleet-witness ]; then echo "write-probe: PASS (auto mode can write here)"
    else echo "write-probe: FAIL (auto mode wrote nothing — check managed permissions / login)"; fi
    return
  fi
  local v; v="$(claude --version 2>/dev/null | head -1)"
  local auth="no login found"
  [ -f "$HOME/.claude/.credentials.json" ] && auth="logged in (OAuth)"
  echo "installed ($v) — $auth"
}
