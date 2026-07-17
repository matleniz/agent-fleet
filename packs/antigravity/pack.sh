# antigravity pack — Google Antigravity CLI (`agy`,
# install: curl -fsSL https://antigravity.google/cli/install.sh | bash).
# Sourced by fleet_load_pack; must define the five required pack_* functions
# (pack_doctor is optional, used by `fleet doctor`).
# Verified against the installed agy (2026-07; state under
# ~/.gemini/antigravity-cli/, conversations indexed in
# conversation_summaries.db with a workspace_uris column).
#
# LIMIT: agy has no per-path deny mechanism (no hooks, no permission rules —
# only trustedWorkspaces + --sandbox, whose own --sandbox is "terminal
# restrictions", not a filesystem write jail). So this pack cannot make the hub
# read-only *from inside the CLI* the way claude/cursor/opencode/gemini do.
# Instead the barrier is enforced by the OS: pack_launch runs agy inside an
# unprivileged mount namespace where $HUB is bind-mounted read-only (kernel
# deny). This is STRONGER than the per-path packs — it also blocks the shell
# redirect hole (see docs/02) — but only exists at launch, so drive the worker
# via `fleet w`, not a bare `agy` in the worktree. Requires unprivileged user
# namespaces; pack_worker_setup probes for them and fails closed if absent.
# Projects WITHOUT a hub skip the jail entirely.
# agy restricts its file tools to the workspace (cwd) like Copilot, so launch
# also passes --add-dir "$HUB": that makes the hub READABLE by agy's own tools
# (the same read grant the per-path packs give), while the ro mount is what still
# denies writes to it.

_agy_db="$HOME/.gemini/antigravity-cli/conversation_summaries.db"

# Run "$@" confined so $HUB is read-only, enforced by the kernel via a bind
# mount remounted read-only inside a private mount namespace. Fails CLOSED: if
# the namespace or the ro remount cannot be set up, the command does NOT run
# (never exec agy unconfined on a hub project). No hub -> run "$@" as-is.
# --map-root-user grants CAP_SYS_ADMIN for mount inside the userns; files agy
# creates still map back to the real user outside. cwd (the worktree) carries
# through unshare, so agy launches in the worktree.
_agy_hub_ro_exec() {
  [ -n "${HUB:-}" ] || exec "$@"
  exec unshare --user --map-root-user --mount -- bash -c '
    hub=$1; shift
    mount --bind "$hub" "$hub" && mount -o remount,bind,ro "$hub" || {
      echo "antigravity: could not establish the read-only hub barrier —" >&2
      echo "  refusing to launch (fail closed)." >&2
      exit 97
    }
    exec "$@"
  ' _ "$HUB" "$@"
}

# True iff we can create a userns AND remount a bind read-only inside it (i.e.
# the launch-time barrier will actually hold). Probes on a throwaway dir.
_agy_userns_ro_ok() {
  local t rc; t="$(mktemp -d)" || return 1
  unshare --user --map-root-user --mount -- bash -c '
    mount --bind "$1" "$1" 2>/dev/null && mount -o remount,bind,ro "$1" 2>/dev/null \
      && ! (echo x >"$1/probe") 2>/dev/null
  ' _ "$t" 2>/dev/null; rc=$?
  rm -rf "$t" 2>/dev/null
  return $rc
}

# agy --continue is GLOBAL (most recent conversation anywhere), so resume is
# pinned per worktree via the summaries db + --conversation <id>. The launch
# goes through _agy_hub_ro_exec: on a hub project agy runs jailed with the hub
# read-only, which is what makes --dangerously-skip-permissions acceptable here
# (the blast radius is the worktree; the shared truth cannot be corrupted).
pack_launch() {
  local adddir=()
  [ -n "${HUB:-}" ] && adddir=(--add-dir "$HUB")
  if [ "${1:-}" = "--resume" ]; then
    local cid
    cid="$(python3 - "$_agy_db" "$PWD" <<'PY'
import sqlite3, sys
try:
    db = sqlite3.connect(sys.argv[1])
    row = db.execute(
        "SELECT conversation_id FROM conversation_summaries "
        "WHERE workspace_uris LIKE ? ORDER BY last_modified_time DESC LIMIT 1",
        (f"%{sys.argv[2]}%",)).fetchone()
    print(row[0] if row else "")
except Exception:
    print("")
PY
)"
    [ -n "$cid" ] && _agy_hub_ro_exec agy --dangerously-skip-permissions "${adddir[@]}" --conversation "$cid"
  fi
  _agy_hub_ro_exec agy --dangerously-skip-permissions "${adddir[@]}"
}

# Headless launch for `fleet dispatch`: one task non-interactively, through the
# same mount-namespace jail as pack_launch (hub read-only, kernel-enforced).
pack_launch_headless() {
  local adddir=()
  [ -n "${HUB:-}" ] && adddir=(--add-dir "$HUB")
  _agy_hub_ro_exec agy -p --dangerously-skip-permissions "${adddir[@]}" "$1"
}

# fleet global: agy reuses ~/.gemini/, whose GEMINI.md is the global instructions
# file loaded every session (same file the gemini pack wires; idempotent).
# Symlink it to the canonical; back up a pre-existing real file.
pack_global_setup() {
  local canon="$1" mode="${2:-install}" f="$HOME/.gemini/GEMINI.md"
  command -v agy >/dev/null || { echo "skipped:not-installed"; return 0; }
  if [ -L "$f" ] && [ "$(readlink -f "$f" 2>/dev/null)" = "$(readlink -f "$canon" 2>/dev/null)" ]; then
    echo "wired (shared ~/.gemini/GEMINI.md)"; return 0
  fi
  [ "$mode" = status ] && { echo "not-wired"; return 0; }
  mkdir -p "$HOME/.gemini"
  [ -f "$f" ] && [ ! -L "$f" ] && cp "$f" "$f.bak"
  ln -sfn "$canon" "$f"
  echo "wired (shared ~/.gemini/GEMINI.md)"
}

pack_has_sessions() {
  local dir="$1"
  [ -f "$_agy_db" ] || return 1
  python3 - "$_agy_db" "$dir" <<'PY'
import sqlite3, sys
try:
    db = sqlite3.connect(sys.argv[1])
    row = db.execute(
        "SELECT 1 FROM conversation_summaries WHERE workspace_uris LIKE ? LIMIT 1",
        (f"%{sys.argv[2]}%",)).fetchone()
    sys.exit(0 if row else 1)
except Exception:
    sys.exit(1)
PY
}

# pack_worker_setup writes nothing: the barrier is a launch-time mount
# namespace (see _agy_hub_ro_exec), not a file in the worktree.
pack_barrier_files() { :; }

# The read-only-hub barrier is enforced at launch (kernel bind mount), so setup
# only needs to guarantee that mechanism will hold. Fail CLOSED if unprivileged
# user namespaces are unavailable: without them we could not remount the hub
# read-only, and an instruction-only "barrier" is what docs/02 refuses.
pack_worker_setup() {
  local dest="$1"
  [ -n "${HUB:-}" ] || return 0
  _agy_userns_ro_ok && return 0
  echo "error: the antigravity pack enforces its read-only hub barrier with an" >&2
  echo "  unprivileged mount namespace, but user namespaces are unavailable" >&2
  echo "  here. Enable unprivileged userns, use it on hub-less projects, or" >&2
  echo "  drop 'antigravity' from this project's AGENTS." >&2
  return 1
}

# Install line for the VM image / a fresh machine (auth: Google OAuth in TUI).
pack_install() { echo "curl -fsSL https://antigravity.google/cli/install.sh | bash"; }

# Optional: fleet doctor status line.
pack_doctor() {
  command -v agy >/dev/null || { echo "NOT INSTALLED (curl -fsSL https://antigravity.google/cli/install.sh | bash)"; return; }
  local auth="no login found"
  [ -e "$HOME/.gemini/antigravity-cli/antigravity-oauth-token" ] && auth="logged in (Google OAuth)"
  local jail="hub barrier: OS mount namespace"
  _agy_userns_ro_ok || jail="hub barrier: UNAVAILABLE (no unprivileged userns — hub-less projects only)"
  echo "installed — $auth — $jail"
}
