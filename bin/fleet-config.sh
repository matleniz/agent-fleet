#!/usr/bin/env bash
# fleet-config.sh — sourced by new-worker and fleet. Resolves the active project
# config into $CONF, sources it (exports CODE_REPO / HUB / WT_HOME / ...), and
# exports FLEET_CONF so a child process (new-worker called by fleet) reuses
# the exact same config without re-resolving.
#
# Resolution order (NO implicit default: outside a known project dir you must
# name the project — a silent fallback once sent commands to the wrong project):
#   1. $FLEET_CONF (already resolved by a parent) if it points to a file
#   2. explicit project name (arg to fleet_resolve_conf) or $FLEET_PROJECT
#   3. auto-detect: a projects/*.env whose CODE_REPO, HUB or WT_HOME contains $PWD
#   4. error, listing known projects

FLEET_ROOT="${FLEET_HOME:-$HOME/.config/fleet}"

# Canonical per-user global-instructions file (see `fleet global`). Defined here
# so both fleet and the packs' pack_worker_setup can resolve it identically.
global_canon() { echo "${FLEET_GLOBAL_AGENTS:-$HOME/.agents/AGENTS.md}"; }

# Isolation guard (transition period). The new tools must NEVER resolve the
# legacy claude-fleet config: a fallback there would let this fleet drive the
# old fleet's real projects (see AGENTS.md). FLEET_HOME is the one knob that
# could point here by mistake — refuse loudly instead of reading it. Cutover is
# explicit via fleet-migrate, never a silent fallback.
case "$(readlink -f "$FLEET_ROOT" 2>/dev/null || printf '%s' "$FLEET_ROOT")" in
  */claude-fleet|*/claude-fleet/*|*/.config/claude-fleet|*/.config/claude-fleet/*)
    echo "error: FLEET_HOME resolves to the legacy claude-fleet config ($FLEET_ROOT)." >&2
    echo "  agent-fleet must not read the legacy fleet. Unset FLEET_HOME or point" >&2
    echo "  it at ~/.config/fleet; migrate real projects with fleet-migrate." >&2
    exit 2
  ;;
esac

FLEET_PROJECTS="$FLEET_ROOT/projects"
# Global pool of machines a session can run on (see fleet_machines below).
FLEET_MACHINES="$FLEET_ROOT/machines"

# Resource guard rails — built-in defaults for the per-machine limits enforced
# before a worker launches (fleet_guard in bin/fleet). Each is overridable per
# machine (MACHINE_MAX_WORKERS / MACHINE_MIN_FREE_MB / MACHINE_MIN_FREE_DISK_MB
# in machines/<name>.env) and globally (MAX_WORKERS / MIN_FREE_MB /
# MIN_FREE_DISK_MB in default.env or a project .env). A limit of 0 disables that
# check. See docs/07-machine-and-solo.md.
FLEET_DEF_MAX_WORKERS=6         # live workers per machine
FLEET_DEF_MIN_FREE_MB=2048      # MemAvailable floor, MB
FLEET_DEF_MIN_FREE_DISK_MB=5120 # free disk floor on WT_HOME's filesystem, MB

# Per-worker V8 heap cap (anti-crash on small boxes). The admission guard above
# only gates at launch; once running, node-based agent CLIs leak unbounded and can
# OOM the whole host with no re-check. When WORKER_NODE_MAX_MB (project/global) or
# this built-in is >0, the node packs export NODE_OPTIONS=--max-old-space-size so a
# runaway worker is OOM-killed cleanly (rc!=0, fleet sees it via .status) instead
# of dragging the box down. 0 = off (the generic default: a shipped cap would
# surprise big-box users; a small box opts in via WORKER_NODE_MAX_MB, like the
# guard floors). See docs/07-machine-and-solo.md.
FLEET_DEF_WORKER_NODE_MAX_MB=0  # V8 old-space cap per node worker, MB (0 = off)

_fleet_list() {
  echo "known projects (--project <name>):" >&2
  if [ -d "$FLEET_PROJECTS" ]; then
    local f
    for f in "$FLEET_PROJECTS"/*.env; do
      [ -e "$f" ] || continue
      local b; b="$(basename "$f" .env)"
      [ "$b" = "default" ] && continue
      echo "  $b" >&2
    done
  fi
}

_fleet_field() { ( . "$1" >/dev/null 2>&1; printf '%s' "${!2:-}" ); }

_fleet_find_by_cwd() {
  [ -d "$FLEET_PROJECTS" ] || return 1
  local pwd_abs; pwd_abs="$(pwd -P)"
  local f cr hb wt root
  for f in "$FLEET_PROJECTS"/*.env; do
    [ -e "$f" ] || continue
    cr="$(_fleet_field "$f" CODE_REPO)"
    hb="$(_fleet_field "$f" HUB)"
    wt="$(_fleet_field "$f" WT_HOME)"
    for root in "$cr" "$hb" "$wt"; do
      [ -n "$root" ] || continue
      root="${root%/}"   # a trailing slash in the .env would defeat the match
      case "$pwd_abs/" in "$root"/*|"$root/") echo "$f"; return 0;; esac
    done
  done
  return 1
}

# Agent packs. A pack is packs/<name>/pack.sh defining: pack_launch,
# pack_launch_headless, pack_has_sessions, pack_worker_setup, pack_barrier_files,
# pack_install (required), plus optional pack_doctor (status line for
# `fleet doctor`) and optional pack_global_setup <canonical> [install|status]
# (wire this CLI's per-user global-instructions file at <canonical> for
# `fleet global`; a CLI with no global file defines optional pack_global_inject
# <dir> instead — the core injects the canonical into each worktree
# (pack_worker_setup) and the hub (cmd_hub); see the cursor pack). Optional
# functions are NOT checked here — call sites guard them with `declare -F`.
# pack_launch_headless <prompt> runs one task non-interactively
# for `fleet dispatch`, with the same barrier + bypass posture as pack_launch.
# pack_barrier_files echoes the worktree-relative paths the pack writes during
# pack_worker_setup (one per line, possibly none) — the core uses it to ignore
# those untracked files when judging a worktree dirty (del/prune).
# A project enables packs via AGENTS="claude gemini" in its .env (first = the
# default). When iterating over several packs, load each in a subshell so their
# function definitions never collide.
FLEET_PACKS_DIR="${FLEET_PACKS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/packs}"

fleet_agents() { echo "${AGENTS:-claude}"; }

fleet_default_agent() {
  # shellcheck disable=SC2086
  set -- $(fleet_agents); echo "$1"
}

fleet_agent_enabled() {
  local a
  for a in $(fleet_agents); do [ "$a" = "$1" ] && return 0; done
  return 1
}

fleet_load_pack() {
  local pack="$1" f="$FLEET_PACKS_DIR/$1/pack.sh"
  if [ ! -f "$f" ]; then
    echo "error: unknown agent pack '$pack' ($f not found)" >&2
    echo "available packs:" >&2
    ls "$FLEET_PACKS_DIR" 2>/dev/null | sed 's/^/  /' >&2
    exit 2
  fi
  . "$f"
  local fn
  for fn in pack_launch pack_launch_headless pack_has_sessions pack_worker_setup pack_barrier_files pack_install; do
    declare -F "$fn" >/dev/null || { echo "error: pack '$pack' does not define $fn()" >&2; exit 2; }
  done
}

# Shared write-probe (fleet doctor --write-probe), called from each pack's
# `pack_doctor probe`. Launches the pack HEADLESS in the CURRENT (throwaway) dir
# asking it to write a witness file, then reports PASS/FAIL. Reuses the pack's
# real pack_launch_headless (via a subshell so its exec is contained and control
# returns), so the probe exercises the exact launch `fleet dispatch` uses — the
# whole point is to catch a box that ACCEPTS a launch but writes nothing (org
# disables bypass; a userns-less mount-ns pack fails closed; a broken login).
# Run AFTER fleet_load_pack (pack_launch_headless must be in scope).
fleet_write_probe() {
  rm -f .fleet-witness
  ( pack_launch_headless 'Create a file named .fleet-witness containing the text OK in the current directory, then stop. Do nothing else.' ) >/dev/null 2>&1 || true
  if [ -f .fleet-witness ]; then
    echo "write-probe: PASS (headless mode can write here)"
  else
    echo "write-probe: FAIL (headless wrote nothing — check managed permissions / login / userns)"
  fi
}

# Per-worker V8 heap cap, applied at launch by the NODE packs (claude/gemini/
# opencode/copilot) — call from pack_launch / pack_launch_headless before exec.
# Reads WORKER_NODE_MAX_MB (project/global .env, re-sourced in the launch window)
# or the built-in default; 0 disables. Appends to any NODE_OPTIONS already set and
# leaves an existing --max-old-space-size alone (never fights a caller's value).
# A no-op on non-node CLIs, but scoped to the node packs so the intent is explicit.
fleet_node_heap_guard() {
  local mb="${WORKER_NODE_MAX_MB:-$FLEET_DEF_WORKER_NODE_MAX_MB}"
  case "$mb" in ''|*[!0-9]*) mb=0 ;; esac
  [ "$mb" = 0 ] && return 0
  case "${NODE_OPTIONS:-}" in *--max-old-space-size=*) return 0 ;; esac
  export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--max-old-space-size=$mb"
}

# Defaults + exports read by the packs' pack_worker_setup (called by both
# new-worker and fleet's refresh path, after fleet_resolve_conf).
fleet_export_worker_env() {
  local bin_dir; bin_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
  GUARD="${GUARD:-$bin_dir/hub-readonly-guard.py}"
  NOTIFY="${NOTIFY:-$bin_dir/fleet-notify}"
  export HUB="${HUB:-}" GUARD NOTIFY NTFY_TOPIC="${NTFY_TOPIC:-}"
}

fleet_resolve_conf() {
  local proj="${1:-${FLEET_PROJECT:-}}"
  if [ -n "${FLEET_CONF:-}" ] && [ -f "$FLEET_CONF" ]; then
    CONF="$FLEET_CONF"
  elif [ -n "$proj" ]; then
    CONF="$FLEET_PROJECTS/$proj.env"
    [ -f "$CONF" ] || { echo "error: no project '$proj' ($CONF)" >&2; _fleet_list; exit 2; }
  elif CONF="$(_fleet_find_by_cwd)"; then
    :
  else
    echo "error: no project resolved — you are not inside a known project's repo or hub." >&2
    echo "Name it explicitly: fleet --project <name> ...  (or export FLEET_PROJECT)" >&2
    _fleet_list; exit 2
  fi
  # Cross-project defaults (e.g. MACHINES_DEFAULT) sourced BEFORE the project
  # conf, so the project always wins. Never a place for a default project.
  [ -f "$FLEET_ROOT/default.env" ] && . "$FLEET_ROOT/default.env"
  . "$CONF"
  export FLEET_CONF="$CONF"
}

# ---- machines (N per project) --------------------------------------------
# A machine is a place a session runs: the local box, or a VM running the
# deploy/ container. Global pool at $FLEET_MACHINES/<name>.env, each defining
# MACHINE_HOST (ssh host/alias; "local" or empty = this box), MACHINE_CONTAINER
# (default fleet), MACHINE_TMUX (default fleet), MACHINE_ENGINE_DIR (default
# agent-fleet), MACHINE_PROJECT (default the active project's name on that box).
# A project selects machines with MACHINES="local vm-gpu" in its .env; "local"
# is assumed when MACHINES is unset. Machines common to every project go in
# MACHINES_DEFAULT (default.env). A single legacy REMOTE_HOST with no MACHINES
# synthesizes a machine named "remote" (no config file needed).

fleet_machines() {  # active project's machine list (space-separated, display order)
  if [ -n "${MACHINES:-}" ]; then echo "$MACHINES"; return; fi
  local out="local"
  [ -n "${REMOTE_HOST:-}" ] && out="local remote"
  if [ -n "${MACHINES_DEFAULT:-}" ]; then
    local m
    for m in $MACHINES_DEFAULT; do
      case " $out " in *" $m "*) ;; *) out="$out $m" ;; esac
    done
  fi
  echo "$out"
}

# The project's first non-local machine (what bare `fleet r` targets), or empty.
fleet_remote_machine() {
  local m
  for m in $(fleet_machines); do [ "$m" = local ] || { echo "$m"; return 0; }; done
  return 1
}

# Populate M_NAME/M_LOCAL/M_HOST/M_CONTAINER/M_TMUX/M_ENGINE/M_PROJECT for a
# machine name (in the CALLER's shell — not a subshell). Loud non-zero on an
# unknown machine. Needs PROJ_NAME set by the caller (fleet does before this).
fleet_load_machine() {
  local name="$1"
  local proj="${PROJ_NAME:-$(basename "${CONF:-project}" .env)}"
  M_NAME="$name" M_LOCAL=0 M_HOST="" M_CONTAINER="" M_TMUX="" M_ENGINE="" M_PROJECT=""
  # Resource-guard limits (fleet_guard): global (default.env / project .env) over
  # built-in; a machine file may further override below.
  M_MAX_WORKERS="${MAX_WORKERS:-$FLEET_DEF_MAX_WORKERS}"
  M_MIN_FREE_MB="${MIN_FREE_MB:-$FLEET_DEF_MIN_FREE_MB}"
  M_MIN_FREE_DISK_MB="${MIN_FREE_DISK_MB:-$FLEET_DEF_MIN_FREE_DISK_MB}"
  # Implicit local box (no machines/local.env): use the global/built-in limits.
  # A machines/local.env (MACHINE_HOST=local) falls through to the file branch so
  # the box can carry its own limits, distinct from a project's defaults.
  if [ "$name" = local ] && [ ! -f "$FLEET_MACHINES/local.env" ]; then
    M_LOCAL=1 M_HOST=local M_TMUX="${LOCAL_TMUX:-fleet-$proj}" M_PROJECT="$proj"
    return 0
  fi
  local f="$FLEET_MACHINES/$name.env"
  if [ -f "$f" ]; then
    local MACHINE_HOST="" MACHINE_CONTAINER="" MACHINE_TMUX="" MACHINE_ENGINE_DIR="" MACHINE_PROJECT=""
    local MACHINE_MAX_WORKERS="" MACHINE_MIN_FREE_MB="" MACHINE_MIN_FREE_DISK_MB=""
    . "$f"
    M_HOST="$MACHINE_HOST"
    [ -n "$M_HOST" ] || { echo "error: machine '$name': set MACHINE_HOST in $f" >&2; return 2; }
    M_CONTAINER="${MACHINE_CONTAINER:-fleet}" M_TMUX="${MACHINE_TMUX:-fleet}"
    M_ENGINE="${MACHINE_ENGINE_DIR:-agent-fleet}" M_PROJECT="${MACHINE_PROJECT:-$proj}"
    # Per-machine limits win over the global/built-in values set above.
    M_MAX_WORKERS="${MACHINE_MAX_WORKERS:-$M_MAX_WORKERS}"
    M_MIN_FREE_MB="${MACHINE_MIN_FREE_MB:-$M_MIN_FREE_MB}"
    M_MIN_FREE_DISK_MB="${MACHINE_MIN_FREE_DISK_MB:-$M_MIN_FREE_DISK_MB}"
    if [ "$M_HOST" = local ]; then
      M_LOCAL=1; M_TMUX="${MACHINE_TMUX:-${LOCAL_TMUX:-fleet-$proj}}"
    fi
    return 0
  fi
  if [ "$name" = remote ] && [ -n "${REMOTE_HOST:-}" ]; then
    M_HOST="$REMOTE_HOST" M_CONTAINER="${REMOTE_CONTAINER:-fleet}" M_TMUX="${REMOTE_TMUX:-fleet}"
    M_ENGINE="${REMOTE_ENGINE_DIR:-agent-fleet}" M_PROJECT="${REMOTE_PROJECT:-$proj}"
    return 0
  fi
  echo "error: unknown machine '$name' (no $f)." >&2
  if [ -d "$FLEET_MACHINES" ] && ls "$FLEET_MACHINES"/*.env >/dev/null 2>&1; then
    echo "known machines:" >&2
    ls "$FLEET_MACHINES"/*.env 2>/dev/null | sed 's#.*/##; s#\.env$##; s#^#  #' >&2
  fi
  return 2
}

# ---- resource guard rail --------------------------------------------------
# Refuse a new worker when the target machine is at a resource limit — the guard
# against dispatching until the box OOMs or fills its disk. Co-located with
# fleet_load_machine because it reads the M_* it populates. Enforced by fleet in
# cmd_dispatch (local) and cmd_worker (the resolved target machine).

# A shell snippet that prints "count ram_mb disk_mb" for a machine:
#   count   = live worker windows (tmux, minus each session's _home + hub windows
#             — the coordinator's own RAM is caught by the MemAvailable floor)
#   ram_mb  = MemAvailable, MB   ·   disk_mb = free disk on <disk-path>, MB
# A tool that is missing or measures nothing yields 0 for that field; fleet_guard
# treats a 0 RAM/disk reading as "unknown" and skips that floor (fail-open on a
# failed probe rather than blocking spuriously). Args: <session-regex> <disk-path>.
guard_probe_snippet() {  # <session-name-regex> <disk-path>
  local sess="$1" disk="$2"
  cat <<PROBE
c=0
if command -v tmux >/dev/null 2>&1; then
  for s in \$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E '$sess'); do
    w=\$(tmux list-windows -t "\$s" -F '#{window_name}' 2>/dev/null | grep -vcE '^(_home|hub)\$')
    c=\$((c + w))
  done
fi
r=\$(awk '/^MemAvailable:/{print int(\$2/1024); exit}' /proc/meminfo 2>/dev/null); [ -n "\$r" ] || r=0
d=\$(df -Pm "$disk" 2>/dev/null | awk 'NR==2{print \$4; exit}'); [ -n "\$d" ] || d=0
echo "\$c \$r \$d"
PROBE
}

# Probe the target machine's usage. Local sums every fleet* tmux session on the
# box (machine-wide: honest even with several projects running); remote counts
# the container's one tmux session over ssh+docker (same transport as
# session_window), base64'd so the snippet's own quotes survive the nesting.
guard_probe() {  # -> "count ram_mb disk_mb"  (reads M_LOCAL/M_TMUX/M_HOST/M_CONTAINER/WT_HOME)
  local snippet
  if [ "${M_LOCAL:-0}" = 1 ]; then
    snippet="$(guard_probe_snippet '^fleet' "${WT_HOME:-$HOME}")"
    bash -c "$snippet"
  else
    local b64
    snippet="$(guard_probe_snippet "^${M_TMUX}\$" '$HOME')"
    b64="$(printf '%s' "$snippet" | base64 | tr -d '\n')"
    ssh "$M_HOST" "docker exec ${M_CONTAINER:-fleet} bash -lc 'echo $b64 | base64 -d | bash'" 2>/dev/null || echo "0 0 0"
  fi
}

# Fail-fast (the coordinator waits for a slot and retries); bypass with --force
# (the caller's $force) or FLEET_NO_GUARD=1. Reads M_* — call AFTER
# fleet_load_machine. Returns 2 (and explains on stderr) when a limit trips.
fleet_guard() {
  [ -n "${force:-}" ] && return 0
  [ "${FLEET_NO_GUARD:-}" = 1 ] && return 0
  local maxw="${M_MAX_WORKERS:-0}" minmb="${M_MIN_FREE_MB:-0}" mindisk="${M_MIN_FREE_DISK_MB:-0}"
  [ "$maxw" = 0 ] && [ "$minmb" = 0 ] && [ "$mindisk" = 0 ] && return 0   # all off
  local usage count ram disk
  usage="$(guard_probe)"
  read -r count ram disk <<<"$usage"
  count="${count//[!0-9]/}"; ram="${ram//[!0-9]/}"; disk="${disk//[!0-9]/}"
  count="${count:-0}"; ram="${ram:-0}"; disk="${disk:-0}"
  local why=""
  [ "$maxw" != 0 ] && [ "$count" -ge "$maxw" ] && why="workers ${count}/${maxw} at cap"
  [ -z "$why" ] && [ "$minmb" != 0 ] && [ "$ram" -gt 0 ] && [ "$ram" -lt "$minmb" ] \
    && why="RAM ${ram}MB < ${minmb}MB floor"
  [ -z "$why" ] && [ "$mindisk" != 0 ] && [ "$disk" -gt 0 ] && [ "$disk" -lt "$mindisk" ] \
    && why="disk ${disk}MB < ${mindisk}MB floor"
  [ -z "$why" ] && return 0
  {
    echo "error: [fleet-guard ${M_NAME:-?}] refused: $why"
    echo "  now: ${count} workers, ${ram}MB RAM free, ${disk}MB disk free on ${M_NAME:-?}"
    echo "  free a slot (fleet ls / fleet wait) or override with --force / FLEET_NO_GUARD=1."
  } >&2
  return 2
}
