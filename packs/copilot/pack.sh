# shellcheck shell=bash
# copilot pack — GitHub Copilot CLI (@github/copilot).
# Sourced by fleet_load_pack; must define the six required pack_* functions
# (pack_doctor is optional, used by `fleet doctor`).
# Verified against GitHub Copilot CLI 1.0.70 (bundled --help + a live barrier
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
# to it. Projects WITHOUT a hub skip the jail entirely.
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

# Launch Copilot in the CURRENT directory (caller cd's first), through the
# mount-namespace jail (hub read-only, kernel-enforced) — that is what makes
# --allow-all-tools acceptable here (blast radius is the worktree; the shared
# truth cannot be corrupted). NOT --allow-all: that also disables path
# verification. --continue is not reliably cwd-scoped, so resume is pinned per
# worktree via the newest session whose cwd is $PWD.
pack_launch() {
  local adddir=()
  [ -n "${HUB:-}" ] && adddir=(--add-dir "$HUB")
  if [ "${1:-}" = "--resume" ]; then
    local sid; sid="$(_cop_session_for "$PWD")"
    [ -n "$sid" ] && _fleet_hub_ro_exec copilot --allow-all-tools "${adddir[@]}" --resume="$sid"
  fi
  _fleet_hub_ro_exec copilot --allow-all-tools "${adddir[@]}"
}

# Headless launch for `fleet dispatch`: one task non-interactively, through the
# same jail. --allow-all-tools is required for non-interactive mode (per --help).
pack_launch_headless() {
  local adddir=()
  [ -n "${HUB:-}" ] && adddir=(--add-dir "$HUB")
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

# Install line for the VM image / a fresh machine. Auth: `copilot login` (OAuth
# device flow; on a box without a system keychain, rerun and accept plaintext
# storage), or a token in COPILOT_GITHUB_TOKEN / GH_TOKEN / GITHUB_TOKEN (the
# headless path — a fine-grained PAT with the "Copilot Requests" permission).
pack_install() { echo "npm install -g @github/copilot"; }

# Optional: fleet doctor status line.
# Copilot does not persist a credential file we can read (a device-flow login
# lands in the OS keychain, or falls back to plaintext / the gh CLI token), so we
# report the fleet-relevant signal instead: an env token is what makes headless
# `fleet dispatch` reliable. No env token -> point at both auth paths.
pack_doctor() {
  command -v copilot >/dev/null || { echo "NOT INSTALLED (npm i -g @github/copilot)"; return; }
  [ "${1:-}" = probe ] && { fleet_write_probe; return; }
  local v auth="no env token (copilot login for interactive; COPILOT_GITHUB_TOKEN for headless)"
  v="$(copilot --version 2>/dev/null | head -1 | sed 's/^GitHub Copilot CLI //; s/\.$//')"
  { [ -n "${COPILOT_GITHUB_TOKEN:-}" ] || [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; } && auth="token in env"
  local jail="hub barrier: OS mount namespace"
  _fleet_userns_ro_ok || jail="hub barrier: UNAVAILABLE (no unprivileged userns — hub-less projects only)"
  echo "installed ($v) — $auth — $jail"
}
