# shellcheck shell=bash
# claude pack — Claude Code CLI (@anthropic-ai/claude-code).
# Sourced by fleet_load_pack; must define the six required pack_* functions
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
  fleet_node_heap_guard   # V8 heap cap (anti-crash): OOM-kill a leaking worker cleanly
  _claude_mcp_flags
  exec claude --permission-mode auto "${FLEET_MCP_FLAGS[@]}" "${resume[@]}"
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
  fleet_node_heap_guard
  _claude_mcp_flags
  exec claude -p "$1" --permission-mode auto "${FLEET_MCP_FLAGS[@]}" ${2:+--model "$2"}
}

# fleet global: point Claude's user file (~/.claude/CLAUDE.md) at the canonical
# per-user instructions via a one-line @import (same bridge idiom fleet-init
# uses). Idempotent; prepends the import if the file already has other content so
# nothing is lost. mode=status only reports. Echoes a status word.
pack_global_setup() {
  local mode="${2:-install}" f="$HOME/.claude/CLAUDE.md" imp="@$1"
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
  local d; d="$HOME/.claude/projects/$(printf '%s' "$1" | sed 's#/#-#g')"
  [ -d "$d" ] && ls "$d"/*.jsonl >/dev/null 2>&1
}

# Optional: a READABLE pointer to this pack's recorded conversation for an agent
# that ran in <dir> — for `fleet chats` (cross-agent reprise; transcripts are not
# CLI-portable, so a new agent READS it, it does not resume it). Empty if none.
pack_chat_pointer() {
  local d; d="$HOME/.claude/projects/$(printf '%s' "$1" | sed 's#/#-#g')"
  [ -d "$d" ] && ls "$d"/*.jsonl >/dev/null 2>&1 || return 0
  ls -t "$d"/*.jsonl 2>/dev/null | head -1
}

# Worktree-relative files pack_worker_setup / pack_mcp_profile write (the core
# ignores them when judging a worktree dirty for del/prune). fleet-mcp.json holds
# the WORKER_MCP strict profile and may carry server credentials copied from
# ~/.claude.json — it must never be committed; listing it here keeps it untracked
# and out of del/prune's dirty check (it lives under .claude/, normally gitignored).
pack_barrier_files() { printf '%s\n' ".claude/settings.local.json" ".claude/fleet-mcp.json"; }

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

# Optional: lean worker MCP profile (fleet WORKER_MCP). FULL isolation for claude,
# in two layers:
#   1) settings.local.json enabledMcpjsonServers — the project .mcp.json gate
#      (kept for the case launch runs without the strict flag).
#   2) .claude/fleet-mcp.json — a filtered {"mcpServers": {...}} distilled from
#      EVERY CLI MCP source (project .mcp.json + ~/.claude.json top-level and its
#      per-project mcpServers), keeping only the allowlisted names. pack_launch
#      then launches with `--strict-mcp-config --mcp-config <that file>`, so
#      claude ignores ALL other MCP config (project AND user-scope ~/.claude.json)
#      and connects only the allowlist. "none" -> zero servers.
# Both are merged/rewritten idempotently, so a fleet refresh re-applies them.
# CAVEAT: a name not found in any CLI source is dropped (e.g. a claude.ai account
# connector, which is not in ~/.claude.json and cannot be fed via --mcp-config).
# fleet-mcp.json can contain server credentials from ~/.claude.json — it is a
# barrier file (never committed); see pack_barrier_files.
# Fill the global array FLEET_MCP_FLAGS with the WORKER_MCP strict-profile flags,
# if pack_mcp_profile generated a filtered config for this worktree (cwd): adds
# `--strict-mcp-config --mcp-config <abs path>` so claude connects ONLY the
# allowlisted servers. Empties the array when the profile is not in use
# (WORKER_MCP unset), so a normal launch is unaffected. Called by pack_launch /
# pack_launch_headless (defined above; bash resolves it at call time).
_claude_mcp_flags() {
  FLEET_MCP_FLAGS=()
  local mc="$PWD/.claude/fleet-mcp.json"
  [ -f "$mc" ] && FLEET_MCP_FLAGS=(--strict-mcp-config --mcp-config "$mc")
}

pack_mcp_profile() {  # <dest> <allowlist>
  local dest="$1"; mkdir -p "$dest/.claude"
  WORKER_MCP_ALLOW="$2" WORKER_MCP_DEST="$dest" python3 <<'PY'
import json, os
allow = os.environ["WORKER_MCP_ALLOW"].split()
if allow == ["none"]: allow = []
dest = os.environ["WORKER_MCP_DEST"]

def load(path):
    try:
        with open(os.path.expanduser(path)) as fh: return json.load(fh)
    except Exception: return {}

# Layer 1: the project .mcp.json gate in settings.local.json.
settings = os.path.join(dest, ".claude", "settings.local.json")
cfg = load(settings)
cfg["enableAllProjectMcpServers"] = False
cfg["enabledMcpjsonServers"] = allow
with open(settings, "w") as fh: json.dump(cfg, fh, indent=2)

# Layer 2: the strict config — filtered server defs from every CLI source.
# Precedence (last wins): user per-project, user top-level, then project .mcp.json.
candidates = {}
uj = load("~/.claude.json")
user_top = uj.get("mcpServers") or {}
user_proj = {}
for pv in (uj.get("projects") or {}).values():
    if isinstance(pv, dict):
        user_proj.update(pv.get("mcpServers") or {})
proj = load(os.path.join(dest, ".mcp.json")).get("mcpServers") or {}
for src in (user_proj, user_top, proj):
    for name, defn in src.items(): candidates[name] = defn
filtered = {n: candidates[n] for n in allow if n in candidates}
with open(os.path.join(dest, ".claude", "fleet-mcp.json"), "w") as fh:
    json.dump({"mcpServers": filtered}, fh, indent=2)
PY
}

# Install line for the VM image / a fresh machine (auth: one-time OAuth login).
pack_install() { echo "npm install -g @anthropic-ai/claude-code"; }

# Optional: fleet doctor status line. With arg "probe" (fleet doctor --write-probe)
# it runs a real witness write in the CURRENT (throwaway) dir via the shared
# fleet_write_probe, proving auto mode can actually write here — the org's
# managed remote-settings.json can silently deny every write, and a plain launch
# fails open (rc=0, nothing written).
pack_doctor() {
  fleet_doctor_preamble claude "npm i -g @anthropic-ai/claude-code" "${1:-}" || return
  local v; v="$(claude --version 2>/dev/null | head -1)"
  local auth="no login found"
  [ -f "$HOME/.claude/.credentials.json" ] && auth="logged in (OAuth)"
  echo "installed ($v) — $auth"
}
