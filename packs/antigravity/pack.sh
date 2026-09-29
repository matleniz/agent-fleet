# shellcheck shell=bash
# antigravity pack — Google Antigravity CLI (`agy`,
# install: curl -fsSL https://antigravity.google/cli/install.sh | bash).
# Sourced by fleet_load_pack; must define the six required pack_* functions
# (pack_doctor is optional, used by `fleet doctor`).
# Verified against the installed agy (2026-07; state under
# ~/.gemini/antigravity-cli/, conversations indexed in
# conversation_summaries.db with a workspace_uris column).
#
# LIMIT: agy has no per-path deny mechanism (no hooks, no permission rules —
# only trustedWorkspaces + --sandbox, whose own --sandbox is "terminal
# restrictions", not a filesystem write jail). So this pack cannot make the hub
# read-only *from inside the CLI* the way claude/cursor/opencode/gemini do.
# Instead the barrier is enforced by the OS — the shared mount-namespace jail in
# packs/hub-mount-ns.sh (_fleet_hub_ro_exec / _fleet_userns_ro_ok), also used by
# the copilot pack: $HUB is bind-mounted read-only at launch. Drive the worker
# via `fleet w`, not a bare `agy`. The jail is per ROLE (from the launch cwd):
# a WORKER (cwd = worktree) is jailed; the COORDINATOR (launched in the hub) runs
# unconfined so it can write the hub. Projects WITHOUT a hub skip the jail.
# agy restricts its file tools to the workspace (cwd) like Copilot, so launch
# also passes --add-dir "$HUB": that makes the hub READABLE by agy's own tools
# (the same read grant the per-path packs give), while the ro mount is what still
# denies writes to it.
# shellcheck source=packs/hub-mount-ns.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../hub-mount-ns.sh"

# Optional: indicates this pack requires userns mount namespace for hub isolation.
pack_requires_userns() { return 0; }

_agy_db="$HOME/.gemini/antigravity-cli/conversation_summaries.db"

# agy --continue is GLOBAL (most recent conversation anywhere), so resume is
# pinned per worktree via the summaries db + --conversation <id>. The launch
# goes through _fleet_hub_ro_exec: on a hub project agy runs jailed with the hub
# read-only, which is what makes --dangerously-skip-permissions acceptable here
# (the blast radius is the worktree; the shared truth cannot be corrupted).
# Modes: --continue / --pick / --resume (synonym). No picker — --pick falls back
# to continue-last for this cwd.
pack_launch() {
  local adddir=()
  [ -n "${HUB:-}" ] && adddir=(--add-dir "$HUB")
  case "${1:-}" in
    --resume|--continue|--pick)
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
      [ -n "$cid" ] && _fleet_hub_ro_exec agy --dangerously-skip-permissions "${adddir[@]}" --conversation "$cid"
      ;;
  esac
  _fleet_hub_ro_exec agy --dangerously-skip-permissions "${adddir[@]}"
}

# Headless launch for `fleet dispatch`: one task non-interactively, through the
# same mount-namespace jail as pack_launch (hub read-only, kernel-enforced).
# Flag order matters: agy's `-p` consumes the next argv as the prompt, so
# `--dangerously-skip-permissions` must NOT follow `-p` (MAT-14).
# $2 (optional): model, from `fleet dispatch --model` (`--model`, verified in
# agy --help; `agy models` lists the ids).
# shellcheck disable=SC2034  # read by fleet_model_args / fleet_pack_honors_model (bin/fleet-config.sh)
PACK_MODEL_FLAG=--model
pack_launch_headless() {
  local adddir=()
  [ -n "${HUB:-}" ] && adddir=(--add-dir "$HUB")
  fleet_model_args "${2:-}"
  _fleet_hub_ro_exec agy --dangerously-skip-permissions "${adddir[@]}" "${FLEET_MODEL_ARGS[@]}" -p "$1"
}

# fleet global: agy reuses ~/.gemini/, whose GEMINI.md is the global instructions
# file loaded every session (same file the gemini pack wires; idempotent).
# Symlink it to the canonical; back up a pre-existing real file.
pack_global_setup() {  # agy reads ~/.gemini/GEMINI.md, shared with the gemini pack
  fleet_symlink_global_setup agy "$1" "${2:-install}" "$HOME/.gemini/GEMINI.md" "wired (shared ~/.gemini/GEMINI.md)"
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

# Optional: pointer to the recorded conversation for <dir> (fleet chats). agy
# stores conversations in a sqlite db; the pointer is the db + the matching
# conversation_id (readable via sqlite3). Empty if none.
pack_chat_pointer() {
  [ -f "$_agy_db" ] || return 0
  local cid
  cid="$(python3 - "$_agy_db" "$1" <<'PY'
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
  [ -n "$cid" ] && echo "$_agy_db (conversation_id=$cid)"
}

# pack_worker_setup writes nothing: the barrier is a launch-time mount
# namespace (see _fleet_hub_ro_exec), not a file in the worktree.
pack_barrier_files() { :; }

# The read-only-hub barrier is enforced at launch (kernel bind mount), so setup
# only needs to guarantee that mechanism will hold. Fail CLOSED if unprivileged
# user namespaces are unavailable: without them we could not remount the hub
# read-only, and an instruction-only "barrier" is what docs/02 refuses.
pack_worker_setup() {
  [ -n "${HUB:-}" ] || return 0   # $1 (dest) unused: barrier is launch-time, nothing written
  _fleet_userns_ro_ok && return 0
  echo "error: the antigravity pack enforces its read-only hub barrier with an" >&2
  echo "  unprivileged mount namespace, but user namespaces are unavailable" >&2
  echo "  here. Enable unprivileged userns, use it on hub-less projects, or" >&2
  echo "  drop 'antigravity' from this project's AGENTS." >&2
  return 1
}

# Install line for the VM image / a fresh machine (auth: Google OAuth in TUI).
pack_install() { echo "curl -fsSL https://antigravity.google/cli/install.sh | bash"; }

# Optional: fleet doctor status line. Validates that the Google OAuth session
# is genuinely active (not just that the token file exists, MAT-124), using a
# lightweight time-bounded `agy models` check so expired sessions are flagged
# before headless dispatch stalls. Timeout defaults to 25s, configurable via
# AGY_DOCTOR_TIMEOUT (a slow network can take ~7s+). Exit 124 is distinguished
# from session expiry to avoid false "session expired" alerts.
pack_doctor() {
  fleet_doctor_preamble agy "curl -fsSL https://antigravity.google/cli/install.sh | bash" "${1:-}" || return
  local auth="no login found"
  local token="$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
  if [ -e "$token" ]; then
    local tcmd=()
    local timeout_sec="${AGY_DOCTOR_TIMEOUT:-25}"
    command -v timeout >/dev/null 2>&1 && tcmd=(timeout "$timeout_sec")
    local rc=0
    "${tcmd[@]}" agy models >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
      auth="logged in (Google OAuth)"
    elif [ "$rc" -eq 124 ]; then
      auth="auth check timed out (network?) — token present"
    else
      auth="session expired, run agy to log in"
    fi
  fi
  local jail="hub barrier: OS mount namespace"
  _fleet_userns_ro_ok || jail="hub barrier: UNAVAILABLE (no unprivileged userns — hub-less projects only)"
  echo "installed — $auth — $jail"
}
