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
# by the OS (same mechanism as the antigravity pack): pack_launch runs copilot
# inside an unprivileged mount namespace where $HUB is bind-mounted read-only
# (kernel deny). This is STRONGER than the per-path packs — it also blocks the
# shell-redirect hole (see docs/02) — but only exists at launch, so drive the
# worker via `fleet w`, not a bare `copilot` in the worktree. --add-dir "$HUB"
# lets the worker READ the hub (Copilot restricts file access to the cwd by
# default); the ro mount is what stops writes to it. Projects WITHOUT a hub skip
# the jail entirely. Requires unprivileged user namespaces; pack_worker_setup
# probes for them and fails closed if absent.

# Run "$@" confined so $HUB is read-only, enforced by the kernel via a bind mount
# remounted read-only inside a private mount namespace. Fails CLOSED: if the
# namespace or the ro remount cannot be set up, the command does NOT run (never
# exec copilot unconfined on a hub project). No hub -> run "$@" as-is.
# --map-root-user grants CAP_SYS_ADMIN for mount inside the userns; files copilot
# creates still map back to the real user outside. cwd (the worktree) carries
# through unshare, so copilot launches in the worktree.
_cop_hub_ro_exec() {
  [ -n "${HUB:-}" ] || exec "$@"
  exec unshare --user --map-root-user --mount -- bash -c '
    hub=$1; shift
    mount --bind "$hub" "$hub" && mount -o remount,bind,ro "$hub" || {
      echo "copilot: could not establish the read-only hub barrier —" >&2
      echo "  refusing to launch (fail closed)." >&2
      exit 97
    }
    exec "$@"
  ' _ "$HUB" "$@"
}

# True iff we can create a userns AND remount a bind read-only inside it (i.e.
# the launch-time barrier will actually hold). Probes on a throwaway dir.
_cop_userns_ro_ok() {
  local t rc; t="$(mktemp -d)" || return 1
  unshare --user --map-root-user --mount -- bash -c '
    mount --bind "$1" "$1" 2>/dev/null && mount -o remount,bind,ro "$1" 2>/dev/null \
      && ! (echo x >"$1/probe") 2>/dev/null
  ' _ "$t" 2>/dev/null; rc=$?
  rm -rf "$t" 2>/dev/null
  return $rc
}

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
    [ -n "$sid" ] && _cop_hub_ro_exec copilot --allow-all-tools "${adddir[@]}" --resume="$sid"
  fi
  _cop_hub_ro_exec copilot --allow-all-tools "${adddir[@]}"
}

# Headless launch for `fleet dispatch`: one task non-interactively, through the
# same jail. --allow-all-tools is required for non-interactive mode (per --help).
pack_launch_headless() {
  local adddir=()
  [ -n "${HUB:-}" ] && adddir=(--add-dir "$HUB")
  _cop_hub_ro_exec copilot -p "$1" --allow-all-tools "${adddir[@]}"
}

# pack_worker_setup writes nothing: the barrier is a launch-time mount namespace
# (see _cop_hub_ro_exec), not a file in the worktree.
pack_barrier_files() { :; }

# The read-only-hub barrier is enforced at launch (kernel bind mount), so setup
# only needs to guarantee that mechanism will hold. Fail CLOSED if unprivileged
# user namespaces are unavailable: without them we could not remount the hub
# read-only, and an instruction-only "barrier" is what docs/02 refuses.
# (No hub -> nothing to enforce.) Copilot reads the worktree's AGENTS.md natively
# as custom instructions, so no context file is written here.
pack_worker_setup() {
  local dest="$1"
  [ -n "${HUB:-}" ] || return 0
  _cop_userns_ro_ok && return 0
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
  local v auth="no env token (copilot login for interactive; COPILOT_GITHUB_TOKEN for headless)"
  v="$(copilot --version 2>/dev/null | head -1 | sed 's/^GitHub Copilot CLI //; s/\.$//')"
  { [ -n "${COPILOT_GITHUB_TOKEN:-}" ] || [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; } && auth="token in env"
  local jail="hub barrier: OS mount namespace"
  _cop_userns_ro_ok || jail="hub barrier: UNAVAILABLE (no unprivileged userns — hub-less projects only)"
  echo "installed ($v) — $auth — $jail"
}
