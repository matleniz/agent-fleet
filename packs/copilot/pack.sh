# shellcheck shell=bash
# copilot pack — GitHub Copilot CLI (@github/copilot).
# Sourced by fleet_load_pack; must define the six required pack_* functions
# (pack_doctor is optional, used by `fleet doctor`).
# Verified against GitHub Copilot CLI 1.0.88 (bundled --help + a live barrier
# proof; sessions under ~/.copilot/session-state/<id>/workspace.yaml).
#
# LIMIT: Copilot CLI has no per-path write-deny. Its tool-permission `write`
# kind matches ALL file writes with no path argument (`copilot help permissions`:
# wildcard matching "will be extended in the very near future"), and its path
# permissions are binary (a dir is reachable read+write via --add-dir, or not at
# all — no read-only grant). Its hooks could deny per path, but repo-level hooks
# (.github/copilot/settings.local.json) are deferred/untrusted and DO NOT fire
# in headless mode. So this pack cannot make the hub read-only *from inside the
# CLI* the way claude/cursor/opencode/gemini do. Instead the barrier is enforced
# by the OS — the shared mount-namespace jail in packs/hub-mount-ns.sh
# (_fleet_hub_ro_exec / _fleet_userns_ro_ok), same mechanism as the antigravity
# pack: $HUB is bind-mounted read-only at launch. Drive the worker via `fleet w`,
# not a bare `copilot`. --add-dir "$HUB" lets the worker READ the hub (Copilot
# restricts file access to the cwd by default); the ro mount is what stops writes
# to it. The jail is per ROLE (from the launch cwd): a WORKER (cwd = worktree) is
# jailed; the COORDINATOR (launched in the hub) runs unconfined so it can write
# the hub. Projects WITHOUT a hub skip the jail entirely.
# shellcheck source=packs/hub-mount-ns.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../hub-mount-ns.sh"

# Most-recent Copilot session id whose cwd is $1, else empty. Copilot stores each
# session under ~/.copilot/session-state/<id>/workspace.yaml with a `cwd:` line;
# pick the newest matching one by workspace.yaml mtime.
_cop_session_for() {
  python3 - "$HOME/.copilot/session-state" "$1" <<'PY'
import os, sys
root, want = sys.argv[1], os.path.abspath(sys.argv[2])
best_id, best_mt = "", -1.0
try:
    entries = os.listdir(root)
except OSError:
    entries = []
for sid in entries:
    wf = os.path.join(root, sid, "workspace.yaml")
    try:
        cwd = ""
        with open(wf) as fh:
            for line in fh:
                if line.startswith("cwd:"):
                    cwd = line[4:].strip(); break
        if os.path.abspath(cwd) == want:
            mt = os.path.getmtime(wf)
            if mt > best_mt:
                best_mt, best_id = mt, sid
    except OSError:
        continue
print(best_id)
PY
}

# Returns the name of the first available headless token env var, or empty if none.
# Precedence follows Copilot CLI docs: COPILOT_GITHUB_TOKEN, GH_TOKEN, GITHUB_TOKEN.
_cop_headless_token() {
  if [ -n "${COPILOT_GITHUB_TOKEN:-}" ]; then
    echo "COPILOT_GITHUB_TOKEN"
  elif [ -n "${GH_TOKEN:-}" ]; then
    echo "GH_TOKEN"
  elif [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "GITHUB_TOKEN"
  fi
}

# True iff interactive credentials exist (managed config.json or gh CLI token).
_cop_has_interactive_login() {
  local conf="${COPILOT_HOME:-$HOME/.copilot}/config.json"
  if [ -f "$conf" ]; then
    python3 - "$conf" <<'PY' 2>/dev/null && return 0
import json, sys
try:
    with open(sys.argv[1]) as f:
        clean = "".join(line for line in f if not line.strip().startswith("//"))
        d = json.loads(clean)
        if d.get("copilotTokens") or d.get("loggedInUsers"):
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
PY
  fi
  if command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Optional: indicates this pack requires userns mount namespace for hub isolation.
pack_requires_userns() { return 0; }

# Optional: quota error pattern in worker output or pane.
pack_quota_pattern() { echo "exceeded your monthly quota"; }

# True iff recent Copilot logs (last 24h by default) contain a quota-exceeded error.
_cop_recent_quota_error() {
  local logdir="${COPILOT_HOME:-$HOME/.copilot}/logs"
  [ -d "$logdir" ] || return 1
  local pat; pat="$(pack_quota_pattern)"
  python3 - "$logdir" "$pat" <<'PY'
import glob, os, sys, time
logdir, pat = sys.argv[1], sys.argv[2]
try:
    logs = sorted(glob.glob(os.path.join(logdir, "process-*.log")), key=os.path.getmtime, reverse=True)
except OSError:
    sys.exit(1)
now = time.time()
window = int(os.environ.get("COPILOT_QUOTA_WINDOW_SEC", "86400"))
for log in logs[:10]:
    try:
        if now - os.path.getmtime(log) > window:
            break
        with open(log, errors="ignore") as f:
            c = f.read()
            if pat in c or "402 You have exceeded" in c:
                sys.exit(0)
    except OSError:
        pass
sys.exit(1)
PY
}

# Launch Copilot in the CURRENT directory (caller cd's first), through the
# mount-namespace jail (hub read-only, kernel-enforced) — that is what makes
# --allow-all-tools acceptable here (blast radius is the worktree; the shared
# truth cannot be corrupted). NOT --allow-all: that also disables path
# verification. --continue is not reliably cwd-scoped, so resume is pinned per
# worktree via the newest session whose cwd is $PWD.
# Modes: --continue / --pick / --resume (synonym). No picker — --pick falls back.
pack_launch() {
  local adddir=()
  [ -n "${HUB:-}" ] && adddir=(--add-dir "$HUB")
  fleet_node_heap_guard   # V8 heap cap (anti-crash): OOM-kill a leaking worker cleanly
  if _cop_recent_quota_error; then
    echo "warning: copilot monthly quota exceeded in recent logs (check GitHub billing)" >&2
  fi
  case "${1:-}" in
    --resume|--continue|--pick)
      local sid; sid="$(_cop_session_for "$PWD")"
      [ -n "$sid" ] && _fleet_hub_ro_exec copilot --allow-all-tools "${adddir[@]}" --resume="$sid"
      ;;
  esac
  _fleet_hub_ro_exec copilot --allow-all-tools "${adddir[@]}"
}

# Headless launch for `fleet dispatch`: one task non-interactively, through the
# same jail. --allow-all-tools is required for non-interactive mode (per --help).
# Fails early if a monthly quota exceeded error is present in recent logs.
pack_launch_headless() {
  local adddir=()
  [ -n "${HUB:-}" ] && adddir=(--add-dir "$HUB")
  fleet_node_heap_guard
  if [ "${FLEET_COPILOT_IGNORE_QUOTA:-0}" != 1 ] && _cop_recent_quota_error; then
    echo "error: copilot monthly quota exceeded (check GitHub billing; quota error in recent logs)" >&2
    return 1
  fi
  _fleet_hub_ro_exec copilot -p "$1" --allow-all-tools "${adddir[@]}"
}

# pack_worker_setup writes nothing: the barrier is a launch-time mount namespace
# (see _fleet_hub_ro_exec), not a file in the worktree.
pack_barrier_files() { :; }

# The read-only-hub barrier is enforced at launch (kernel bind mount), so setup
# only needs to guarantee that mechanism will hold. Fail CLOSED if unprivileged
# user namespaces are unavailable: without them we could not remount the hub
# read-only, and an instruction-only "barrier" is what docs/02 refuses.
# (No hub -> nothing to enforce.) Copilot reads the worktree's AGENTS.md natively
# as custom instructions, so no context file is written here.
pack_worker_setup() {
  [ -n "${HUB:-}" ] || return 0   # $1 (dest) unused: barrier is launch-time, nothing written
  _fleet_userns_ro_ok && return 0
  echo "error: the copilot pack enforces its read-only hub barrier with an" >&2
  echo "  unprivileged mount namespace, but user namespaces are unavailable" >&2
  echo "  here. Enable unprivileged userns, use it on hub-less projects, or" >&2
  echo "  drop 'copilot' from this project's AGENTS." >&2
  return 1
}

# Copilot stores sessions under ~/.copilot/session-state/<id>/, one workspace.yaml
# per session carrying its cwd. Match on that.
pack_has_sessions() {
  [ -n "$(_cop_session_for "$1")" ]
}

# Optional: pointer to the recorded conversation for <dir> (fleet chats) — the
# session-state dir of the newest session whose cwd is <dir>. Empty if none.
pack_chat_pointer() {
  local sid; sid="$(_cop_session_for "$1")"
  [ -n "$sid" ] && echo "$HOME/.copilot/session-state/$sid/"
}

# fleet global: Copilot CLI reads a native per-user instructions file at
# ~/.copilot/copilot-instructions.md (relocated by $COPILOT_HOME), applied to every
# session regardless of project — symlink it to the canonical. (A repo's AGENTS.md
# is read natively too, but that is project context, not per-user identity.)
pack_global_setup() {
  fleet_symlink_global_setup copilot "$1" "${2:-install}" "${COPILOT_HOME:-$HOME/.copilot}/copilot-instructions.md"
}

# Install line for the VM image / a fresh machine. Auth: `copilot login` (OAuth
# device flow; on a box without a system keychain, rerun and accept plaintext
# storage), or a token in COPILOT_GITHUB_TOKEN / GH_TOKEN / GITHUB_TOKEN (the
# headless path — a fine-grained PAT with the "Copilot Requests" permission).
pack_install() { echo "npm install -g @github/copilot"; }

# Optional: fleet doctor status line.
# Reports CLI version, auth status (headless env token vs interactive login),
# quota status (detected from recent Copilot logs), and hub barrier jail.
pack_doctor() {
  fleet_doctor_preamble copilot "npm i -g @github/copilot" "${1:-}" || return
  local v auth quota=""
  v="$(copilot --version 2>/dev/null | head -1 | sed 's/^GitHub Copilot CLI //; s/\.$//')"
  local tok; tok="$(_cop_headless_token)"
  if [ -n "$tok" ]; then
    auth="token in env ($tok)"
  elif _cop_has_interactive_login; then
    auth="interactive login (no env token — export COPILOT_GITHUB_TOKEN for headless dispatch)"
  else
    auth="no login found (copilot login for interactive; COPILOT_GITHUB_TOKEN for headless)"
  fi
  if _cop_recent_quota_error; then
    quota="quota exceeded (check GitHub billing; see ~/.copilot/logs)"
  fi
  local jail="hub barrier: OS mount namespace"
  _fleet_userns_ro_ok || jail="hub barrier: UNAVAILABLE (no unprivileged userns — hub-less projects only)"
  echo "installed ($v) — $auth${quota:+ — $quota} — $jail"
}
