# shellcheck shell=bash
# gemini pack — Gemini CLI (@google/gemini-cli).
# Sourced by fleet_load_pack; must define the six required pack_* functions
# (pack_doctor is optional, used by `fleet doctor`).
# Verified against gemini-cli 0.50.0 (bundled docs + empirical checks).

# Launch Gemini in the CURRENT directory (caller cd's first).
# --approval-mode yolo is the equivalent of claude's skipped permissions.
pack_launch() {
  local resume=()
  [ "${1:-}" = "--resume" ] && resume=(--resume latest)
  fleet_node_heap_guard   # V8 heap cap (anti-crash): OOM-kill a leaking worker cleanly
  exec gemini --approval-mode yolo "${resume[@]}"
}

# Headless launch for `fleet dispatch`: one task non-interactively, same bypass
# posture as pack_launch (barrier is the BeforeTool hook, unaffected).
pack_launch_headless() { fleet_node_heap_guard; exec gemini -p "$1" --approval-mode yolo; }

# fleet global: ~/.gemini/GEMINI.md is Gemini's global instructions file, loaded
# every session (docs: hierarchical global + project context). Symlink it to the
# canonical (backs up a pre-existing real file). Antigravity reuses ~/.gemini/,
# so this also covers agy. mode=status only reports. Echoes a status word.
pack_global_setup() {  # ~/.gemini/GEMINI.md is Gemini's native global file
  fleet_symlink_global_setup gemini "$1" "${2:-install}" "$HOME/.gemini/GEMINI.md"
}

# Gemini stores sessions in ~/.gemini/tmp/<project-name>/chats/. The dir->name
# mapping lives in ~/.gemini/projects.json, but every tmp dir also carries a
# .project_root file holding the absolute project path — match on that instead
# of parsing JSON.
pack_has_sessions() {
  local dir="$1" d
  for d in "$HOME/.gemini/tmp"/*/; do
    [ -f "$d.project_root" ] || continue
    [ "$(cat "$d.project_root" 2>/dev/null)" = "$dir" ] || continue
    ls "$d"chats/* >/dev/null 2>&1 && return 0
  done
  return 1
}

# Optional: readable pointer to the recorded conversation for <dir> (fleet chats).
pack_chat_pointer() {
  local dir="$1" d
  for d in "$HOME/.gemini/tmp"/*/; do
    [ -f "$d.project_root" ] || continue
    [ "$(cat "$d.project_root" 2>/dev/null)" = "$dir" ] || continue
    ls "$d"chats/* >/dev/null 2>&1 && { echo "${d}chats/"; return 0; }
  done
}

# Worktree-relative files pack_worker_setup writes (the core ignores them
# when judging a worktree dirty for del/prune).
pack_barrier_files() { echo ".gemini/settings.json"; }

# Per-worktree setup: the read-only-hub barrier, Gemini flavor.
# context.includeDirectories makes the hub readable with Gemini's native tools;
# the BeforeTool hook blocks write_file/replace on hub paths. Gemini's hook
# contract matches Claude Code's (tool_input JSON with file_path on stdin,
# exit 2 = block with stderr as the reason), so hub-readonly-guard.py is
# reused unchanged. context.fileName also lets Gemini read the repo's
# existing context files (AGENTS.md / CLAUDE.md) during the transition.
# Uses $HUB and $GUARD from the caller (new-worker). No hub -> nothing to do.
pack_worker_setup() {
  local dest="$1"
  [ -n "${HUB:-}" ] || return 0
  mkdir -p "$dest/.gemini"
  # json.dump, not a heredoc: an interpolated $HUB with JSON-special chars
  # would produce settings that silently fail open.
  python3 - "$dest/.gemini/settings.json" <<'PY'
import json, os, sys
hub, guard = os.environ["HUB"], os.environ["GUARD"]
cfg = {
    "context": {
        "fileName": ["AGENTS.md", "GEMINI.md", "CLAUDE.md"],
        "includeDirectories": [hub],
    },
    "hooks": {
        "BeforeTool": [{
            "matcher": "write_file|replace",
            "hooks": [{"name": "hub-readonly-guard", "type": "command",
                       "command": f"{guard} {hub}"}],
        }],
    },
}
json.dump(cfg, open(sys.argv[1], "w"), indent=2)
PY
}

# Install line for the VM image / a fresh machine
# (auth: Google OAuth on first run, or GEMINI_API_KEY).
pack_install() { echo "npm install -g @google/gemini-cli"; }

# Optional: fleet doctor status line.
pack_doctor() {
  command -v gemini >/dev/null || { echo "NOT INSTALLED (npm i -g @google/gemini-cli)"; return; }
  [ "${1:-}" = probe ] && { fleet_write_probe; return; }
  local v auth="NO AUTH (set GEMINI_API_KEY in ~/.gemini/.env; OAuth for individuals was retired)"
  v="$(gemini --version 2>/dev/null | head -1)"
  { [ -n "${GEMINI_API_KEY:-}" ] || grep -q GEMINI_API_KEY "$HOME/.gemini/.env" 2>/dev/null; } && auth="API key configured"
  echo "installed (v$v) — $auth"
}
