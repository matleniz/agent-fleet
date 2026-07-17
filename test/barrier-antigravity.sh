#!/usr/bin/env bash
# barrier-antigravity.sh — prove the antigravity pack's read-only-hub barrier.
#
# Unlike the per-path packs (claude/cursor/opencode/gemini), agy has no in-CLI
# deny mechanism: the barrier is an OS mount namespace applied at launch by
# _fleet_hub_ro_exec (see packs/antigravity/pack.sh), where $HUB is bind-mounted
# read-only. This test exercises that mechanism directly — no agy auth/network
# needed — and asserts a hub write is DENIED (including via a shell redirect,
# the residual hole the per-path packs cannot close), a hub read is allowed, and
# a worktree write is allowed. Exits non-zero on any failure.
#
# Skips (exit 0) if unprivileged user namespaces are unavailable, matching the
# pack's fail-closed behavior: where the barrier cannot hold, the pack refuses
# the project rather than running unconfined.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PACK="$SELF_DIR/../packs/antigravity/pack.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Load the pack's functions (does not launch agy).
HUB=""; source "$PACK"

if ! _fleet_userns_ro_ok; then
  echo "SKIP: no unprivileged user namespaces here (pack fails closed on hub projects)"
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

echo "PASS: hub write denied (incl. shell redirect), hub read OK, worktree write OK"
