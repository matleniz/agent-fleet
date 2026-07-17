# shellcheck shell=bash
# hub-mount-ns.sh — shared OS-level read-only-hub barrier, sourced by the packs
# whose CLI has NO per-path write-deny (antigravity, copilot). Not a pack (no
# pack.sh), so the pack iterators skip it.
#
# The barrier is moved out of the CLI and into the OS: the agent runs inside an
# unprivileged mount namespace where $HUB is bind-mounted READ-ONLY (a kernel
# deny). This is STRONGER than the per-path packs — it also blocks the shell
# redirect hole (see docs/02) — but only exists at launch, so the worker must be
# driven via `fleet w`, not a bare CLI in the worktree. Requires unprivileged
# user namespaces; pack_worker_setup probes and fails closed if absent.

# Run "$@" confined so $HUB is read-only, via a bind mount remounted read-only
# inside a private mount namespace. Fails CLOSED: if the namespace or the ro
# remount cannot be set up, the command does NOT run (never exec the agent
# unconfined on a hub project). No hub -> run "$@" as-is. --map-root-user grants
# CAP_SYS_ADMIN for mount inside the userns; files the agent creates still map
# back to the real user outside. cwd (the worktree) carries through unshare.
_fleet_hub_ro_exec() {
  [ -n "${HUB:-}" ] || exec "$@"
  exec unshare --user --map-root-user --mount -- bash -c '
    hub=$1; shift
    mount --bind "$hub" "$hub" && mount -o remount,bind,ro "$hub" || {
      echo "fleet: could not establish the read-only hub barrier —" >&2
      echo "  refusing to launch (fail closed)." >&2
      exit 97
    }
    exec "$@"
  ' _ "$HUB" "$@"
}

# True iff we can create a userns AND remount a bind read-only inside it (i.e.
# the launch-time barrier will actually hold). Probes on a throwaway dir.
_fleet_userns_ro_ok() {
  local t rc; t="$(mktemp -d)" || return 1
  unshare --user --map-root-user --mount -- bash -c '
    mount --bind "$1" "$1" 2>/dev/null && mount -o remount,bind,ro "$1" 2>/dev/null \
      && ! (echo x >"$1/probe") 2>/dev/null
  ' _ "$t" 2>/dev/null; rc=$?
  rm -rf "$t" 2>/dev/null
  return $rc
}
