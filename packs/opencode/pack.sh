# shellcheck shell=bash
# opencode pack — opencode (sst/opencode, npm opencode-ai).
# Sourced by fleet_load_pack; must define the six required pack_* functions
# (pack_doctor is optional, used by `fleet doctor`).
# Verified against opencode 1.17.18 (config schema + empirical checks).
#
# opencode scopes sessions by git REPO (projectID = root commit), not by
# worktree — every worktree of one repo shares a project. A bare --continue
# could therefore resume another worker's session. Both functions below filter
# on the session's `directory` field instead, keeping resume per-worktree.

# Launch opencode in the CURRENT directory (caller cd's first).
# --auto auto-approves everything not explicitly denied — the hub edit rules
# in opencode.json are explicit denies, so the barrier survives it.
pack_launch() {
  fleet_node_heap_guard   # V8 heap cap (anti-crash): OOM-kill a leaking worker cleanly
  if [ "${1:-}" = "--resume" ]; then
    local sid
    sid="$(opencode session list --format json 2>/dev/null | python3 -c '
import json, os, sys
try: sessions = json.load(sys.stdin)
except Exception: sessions = []
cwd = os.getcwd()
for s in sessions:  # newest first
    if s.get("directory") == cwd:
        print(s["id"]); break
')"
    [ -n "$sid" ] && exec opencode --auto -s "$sid"
  fi
  exec opencode --auto
}

# Headless launch for `fleet dispatch`: run one task non-interactively. --auto
# auto-approves everything not explicitly denied, so the hub edit denies in
# opencode.json still hold (same posture as pack_launch's interactive --auto).
pack_launch_headless() { fleet_node_heap_guard; exec opencode run --auto "$1"; }

# fleet global: opencode reads ~/.config/opencode/AGENTS.md natively (and also
# ~/.claude/CLAUDE.md), so symlink it at the canonical per-user file. Backs up a
# pre-existing real file. mode=status only reports. Echoes a status word.
pack_global_setup() {  # ~/.config/opencode/AGENTS.md is opencode's native global file
  fleet_symlink_global_setup opencode "$1" "${2:-install}" "$HOME/.config/opencode/AGENTS.md"
}

# `opencode session list` boots the whole node CLI (~1s). The list is
# repo-scoped and identical from any worktree of the repo, so when the caller
# provides a per-invocation cache dir (fleet ls exports FLEET_CACHE_DIR),
# fetch it once and reuse it across worktrees.
_opencode_session_json() {
  local dir="$1" cache="" json
  if [ -n "${FLEET_CACHE_DIR:-}" ] && [ -d "${FLEET_CACHE_DIR:-}" ]; then
    cache="$FLEET_CACHE_DIR/opencode-sessions.json"
  fi
  if [ -n "$cache" ] && [ -f "$cache" ]; then cat "$cache"; return; fi
  if json="$(cd "$dir" 2>/dev/null && opencode session list --format json 2>/dev/null)"; then
    # Cache only a SUCCESSFUL listing: a cached transient failure would hide
    # every worktree's sessions for the rest of the invocation.
    if [ -n "$cache" ]; then printf '%s' "$json" > "$cache"; fi
  else
    json='[]'
  fi
  printf '%s' "$json"
}

pack_has_sessions() {
  local dir="$1"
  _opencode_session_json "$dir" | python3 -c '
import json, sys
try: sessions = json.load(sys.stdin)
except Exception: sessions = []
sys.exit(0 if any(s.get("directory") == sys.argv[1] for s in sessions) else 1)
' "$dir"
}

# Optional: pointer to the recorded conversation for <dir> (fleet chats).
# opencode sessions are repo-scoped (not a per-worktree file), so the pointer is
# the list command filtered to this directory. Only shown when one exists.
pack_chat_pointer() {
  local dir="$1"
  pack_has_sessions "$dir" 2>/dev/null || return 0
  echo "opencode session list --format json  | jq '.[]|select(.directory==\"$dir\")'"
}

# Worktree-relative files pack_worker_setup writes (the core ignores them
# when judging a worktree dirty for del/prune).
pack_barrier_files() { echo "opencode.json"; }

# Per-worktree setup: the read-only-hub barrier, opencode flavor — purely
# declarative, no hook needed. permission.external_directory grants native
# reads on the hub (outside the project root); permission.edit deny blocks
# the edit/write/patch tools on it. Explicit denies hold under --auto.
#
# CRITICAL (verified in sst/opencode source, tool/edit.ts): the edit
# permission is matched against path.relative(worktree, filePath), NOT the
# absolute path — an absolute-only deny pattern silently never matches and
# the "barrier" lets hub writes through. So the deny is written in RELATIVE
# form (computed here, since worktree depth varies per project), with the
# absolute form kept as a second pattern in case the matching changes.
# Uses $HUB from the caller (new-worker). No hub -> nothing to do.
pack_worker_setup() {
  local dest="$1"
  [ -n "${HUB:-}" ] || return 0
  # json.dump, not a heredoc: an interpolated $HUB with JSON-special chars
  # would produce a deny pattern that silently never matches (fail-open).
  python3 - "$dest" <<'PY'
import json, os, sys
dest, hub = sys.argv[1], os.environ["HUB"]
rel = os.path.relpath(hub, dest)
cfg = {
    "$schema": "https://opencode.ai/config.json",
    "permission": {
        "external_directory": {f"{hub}/**": "allow"},
        "edit": {f"{rel}/**": "deny", f"{hub}/**": "deny"},
    },
}
json.dump(cfg, open(os.path.join(dest, "opencode.json"), "w"), indent=2)
PY
}

# Install line for the VM image / a fresh machine
# (auth: `opencode auth login` per provider; free gateway models need none).
# Optional: lean worker MCP profile (fleet WORKER_MCP). opencode merges configs
# and has no allowlist key — only a per-server "enabled" (verified: a project
# opencode.json with mcp.<name>.enabled=false suppresses a globally-defined
# server). So to allowlist, enumerate the servers opencode would load (from the
# global config) and set enabled:false for every one NOT in the allowlist, in the
# worktree's opencode.json (which the barrier already wrote). "none" disables all.
# Best-effort: only servers visible in the standard global config are gated.
pack_mcp_profile() {  # <dest> <allowlist>
  local dest="$1"
  WORKER_MCP_ALLOW="$2" \
  OPENCODE_GLOBAL="${OPENCODE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json}" \
  python3 - "$dest/opencode.json" <<'PY'
import json, os, sys
allow = set(os.environ["WORKER_MCP_ALLOW"].split())
if allow == {"none"}: allow = set()
names = set()
try: names |= set(json.load(open(os.environ.get("OPENCODE_GLOBAL", ""))).get("mcp", {}).keys())
except Exception: pass
try: cfg = json.load(open(sys.argv[1]))
except Exception: cfg = {}
names |= set(cfg.get("mcp", {}).keys())   # also gate servers the project itself defines
mcp = cfg.setdefault("mcp", {})
for n in names - allow:
    mcp.setdefault(n, {})["enabled"] = False
json.dump(cfg, open(sys.argv[1], "w"), indent=2)
PY
}

pack_install() { echo "npm install -g opencode-ai"; }

# Optional: fleet doctor status line.
pack_doctor() {
  fleet_doctor_preamble opencode "npm i -g opencode-ai" "${1:-}" || return
  local v n; v="$(opencode --version 2>/dev/null | head -1)"
  n="$(python3 -c 'import json;print(len(json.load(open("'"$HOME"'/.local/share/opencode/auth.json"))))' 2>/dev/null || echo 0)"
  echo "installed ($v) — $n provider credential(s); free gateway models need none"
}
