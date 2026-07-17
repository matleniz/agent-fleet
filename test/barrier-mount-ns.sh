#!/usr/bin/env bash
# barrier-mount-ns.sh <pack> — prove a mount-namespace pack's read-only-hub barrier.
#
# antigravity and copilot have no in-CLI per-path write-deny (agy has no deny
# mechanism; Copilot's `write` grant is binary and its repo hooks don't fire
# headless), so their barrier is an OS mount namespace applied at launch by
# _fleet_hub_ro_exec (packs/hub-mount-ns.sh), where $HUB is bind-mounted read-only.
# This exercises that mechanism directly — no CLI auth/network — and asserts a hub
# write is DENIED (including via a shell redirect, the residual hole the per-path
# packs cannot close), a hub read is allowed, a worktree write is allowed, and the
# COORDINATOR (cwd == hub) runs unconfined. Exits non-zero on any failure.
#
# Skips (exit 0) if unprivileged user namespaces are unavailable, matching the
# pack's fail-closed behavior: where the barrier cannot hold, the pack refuses the
# project rather than running unconfined.
#
#   test/barrier-mount-ns.sh antigravity
#   test/barrier-mount-ns.sh copilot
set -euo pipefail

pack="${1:?usage: barrier-mount-ns.sh <pack>  (antigravity|copilot)}"
SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PACK="$SELF_DIR/../packs/$pack/pack.sh"
[ -f "$PACK" ] || { echo "FAIL: no pack '$pack' ($PACK)" >&2; exit 1; }

fail() { echo "FAIL [$pack]: $*" >&2; exit 1; }

# Load the pack's functions (does not launch the CLI).
HUB=""; source "$PACK"

if ! _fleet_userns_ro_ok; then
  echo "SKIP [$pack]: no unprivileged user namespaces here (pack fails closed on hub projects)"
  exit 0
fi

hub="$(mktemp -d)"; wt="$(mktemp -d)"
trap 'rm -rf "$hub" "$wt"' EXIT
printf 'TRUTH\n' > "$hub/DOC.md"
export HUB="$hub"

# 1. hub write via shell redirect -> must be denied, file unchanged
if ( _fleet_hub_ro_exec bash -c 'echo HACKED >> "$0/DOC.md"' "$hub" ) 2>/dev/null; then
  fail "hub write succeeded (barrier fail-open)"
fi
[ "$(cat "$hub/DOC.md")" = "TRUTH" ] || fail "hub content mutated despite ro mount"

# 2. hub read -> must succeed
got="$( ( _fleet_hub_ro_exec bash -c 'cat "$0/DOC.md"' "$hub" ) 2>/dev/null )" \
  || fail "hub read failed under jail"
[ "$got" = "TRUTH" ] || fail "hub read returned '$got' not 'TRUTH'"

# 3. worktree write -> must succeed (the worker still does real work)
( _fleet_hub_ro_exec bash -c 'echo ok > "$0/f"' "$wt" ) 2>/dev/null || fail "worktree write failed"
[ -f "$wt/f" ] || fail "worktree file not created"

# 4. COORDINATOR role: launched IN the hub (cwd == hub) -> unconfined, CAN write
#    it (the coordinator is the hub's writer; only a worker is jailed).
( cd "$hub" && _fleet_hub_ro_exec bash -c 'echo COORD > "$0/coord-wrote"' "$hub" ) 2>/dev/null \
  || fail "coordinator (cwd=hub) write failed — jailed when it should not be"
[ -f "$hub/coord-wrote" ] || fail "coordinator write not persisted"

echo "PASS [$pack]: worker hub write denied (incl. shell redirect), hub read OK, worktree write OK, coordinator (cwd=hub) write OK"
