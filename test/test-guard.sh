#!/usr/bin/env bash
# test-guard.sh — unit + isolated-E2E tests for the resource guard rails
# (fleet-config.sh: per-machine limit resolution, guard_probe, fleet_guard, the
# per-worker heap cap fleet_node_heap_guard; bin/fleet: cmd_dispatch refuses
# before launching). Touches nothing real: it runs against a throwaway $FLEET_HOME
# under a temp dir and never launches an agent (every checked path is a refusal,
# which exits before any launch).
#
#   test/test-guard.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-guard-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export FLEET_HOME="$TMP/config"
mkdir -p "$FLEET_HOME/projects" "$FLEET_HOME/machines"

pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected '$3', got '$2'"; fi; }

# ---- 1. limit resolution (source fleet-config.sh, call fleet_load_machine) ----
echo "[1] per-machine limit resolution"
# shellcheck disable=SC1091
. "$REPO/bin/fleet-config.sh"
PROJ_NAME=test

# Built-in defaults when nothing is set.
fleet_load_machine local
eq "builtin MAX_WORKERS"      "$M_MAX_WORKERS"      "$FLEET_DEF_MAX_WORKERS"
eq "builtin MIN_FREE_MB"      "$M_MIN_FREE_MB"      "$FLEET_DEF_MIN_FREE_MB"
eq "builtin MIN_FREE_DISK_MB" "$M_MIN_FREE_DISK_MB" "$FLEET_DEF_MIN_FREE_DISK_MB"

# Global default (default.env / project .env, i.e. a shell var here) wins over built-in.
MAX_WORKERS=3 MIN_FREE_MB=1024 MIN_FREE_DISK_MB=2048 fleet_load_machine local
eq "global MAX_WORKERS wins"  "$M_MAX_WORKERS" "3"
eq "global MIN_FREE_MB wins"  "$M_MIN_FREE_MB" "1024"

# Per-machine file wins over the global default.
cat > "$FLEET_HOME/machines/vm.env" <<EOF
MACHINE_HOST="vm.invalid"
MACHINE_MAX_WORKERS=10
MACHINE_MIN_FREE_MB=4096
EOF
MAX_WORKERS=3 fleet_load_machine vm
eq "machine MAX_WORKERS wins over global" "$M_MAX_WORKERS" "10"
eq "machine MIN_FREE_MB wins over global" "$M_MIN_FREE_MB" "4096"
# A key the machine file omits still falls back to global/built-in.
MIN_FREE_DISK_MB=7777 fleet_load_machine vm
eq "machine omits disk -> global"         "$M_MIN_FREE_DISK_MB" "7777"

# machines/local.env carries the local box's own limits and wins over global.
cat > "$FLEET_HOME/machines/local.env" <<EOF
MACHINE_HOST="local"
MACHINE_MAX_WORKERS=1
EOF
MAX_WORKERS=9 fleet_load_machine local
eq "local.env MAX_WORKERS wins"  "$M_MAX_WORKERS" "1"
eq "local.env keeps M_LOCAL"     "$M_LOCAL" "1"
rm -f "$FLEET_HOME/machines/local.env"

# ---- 2. fleet_guard decisions (stub the probe: "count ram_mb disk_mb") ----
echo "[2] fleet_guard decisions"
PROBE_OUT="0 8000 50000"
guard_probe() { echo "$PROBE_OUT"; }   # override the real probe
M_NAME=test M_LOCAL=1
guard_rc() { local rc=0; fleet_guard 2>/dev/null || rc=$?; echo "$rc"; }

force="" FLEET_NO_GUARD=""
M_MAX_WORKERS=0 M_MIN_FREE_MB=0 M_MIN_FREE_DISK_MB=0
eq "all limits off -> allow" "$(guard_rc)" "0"

M_MAX_WORKERS=6 M_MIN_FREE_MB=2048 M_MIN_FREE_DISK_MB=5120
PROBE_OUT="2 8000 50000"; eq "under all limits -> allow" "$(guard_rc)" "0"
PROBE_OUT="6 8000 50000"; eq "count at cap -> refuse"      "$(guard_rc)" "2"
PROBE_OUT="7 8000 50000"; eq "count over cap -> refuse"    "$(guard_rc)" "2"
PROBE_OUT="1 500 50000";  eq "RAM below floor -> refuse"   "$(guard_rc)" "2"
PROBE_OUT="1 8000 500";   eq "disk below floor -> refuse"  "$(guard_rc)" "2"
PROBE_OUT="1 0 0";        eq "RAM/disk unknown(0) -> skip floors -> allow" "$(guard_rc)" "0"

# Bypass paths, even when a limit is clearly tripped.
PROBE_OUT="9 100 100"
force=1 FLEET_NO_GUARD=""; eq "--force bypasses"        "$(guard_rc)" "0"
force="" FLEET_NO_GUARD=1;  eq "FLEET_NO_GUARD bypasses" "$(guard_rc)" "0"
force="" FLEET_NO_GUARD=""

# ---- 3. isolated E2E: cmd_dispatch refuses before any launch ----
echo "[3] fleet dispatch refuses at the disk floor (no launch)"
mkdir -p "$TMP/code" "$TMP/wt"
cat > "$FLEET_HOME/projects/x.env" <<EOF
CODE_REPO="$TMP/code"
WT_HOME="$TMP/wt"
AGENTS="claude"
MIN_FREE_DISK_MB=999999999
EOF
out="$("$REPO/bin/fleet" --project x dispatch a "do a thing" 2>&1)"; rc=$?
eq "dispatch exits non-zero" "$rc" "2"
if printf '%s' "$out" | grep -q 'fleet-guard'; then ok "dispatch prints guard refusal"
else bad "dispatch refusal message missing; got: $out"; fi
# The worktree must NOT have been created (guard fired before new-worker).
if [ -z "$(ls -A "$TMP/wt" 2>/dev/null)" ]; then ok "no worktree created (refused before launch)"
else bad "a worktree was created despite refusal"; fi

# --force lets it past the guard (then fails later for lack of a real repo/agent,
# which is fine — we only assert the guard no longer blocks).
out="$("$REPO/bin/fleet" --project x --force dispatch a "do a thing" 2>&1)"; rc=$?
if printf '%s' "$out" | grep -q 'fleet-guard'; then bad "--force still hit the guard: $out"
else ok "--force skips the guard"; fi

# ---- 4. per-worker heap cap (fleet_node_heap_guard) ----
echo "[4] fleet_node_heap_guard (NODE_OPTIONS heap cap)"
heap() { ( unset NODE_OPTIONS; export NODE_OPTIONS="${1?}"; WORKER_NODE_MAX_MB="$2" \
  FLEET_DEF_WORKER_NODE_MAX_MB="$3"; fleet_node_heap_guard; printf '%s' "${NODE_OPTIONS:-}" ); }
# args: <preset NODE_OPTIONS> <WORKER_NODE_MAX_MB> <built-in default>
eq "off by default (0)"              "$(heap '' '' 0)"      ""
eq "WORKER_NODE_MAX_MB sets cap"     "$(heap '' 2048 0)"    "--max-old-space-size=2048"
eq "built-in default applies"        "$(heap '' '' 3000)"   "--max-old-space-size=3000"
eq "project wins over built-in"      "$(heap '' 1024 3000)" "--max-old-space-size=1024"
eq "appends, preserves existing"     "$(heap '--enable-source-maps' 512 0)" "--enable-source-maps --max-old-space-size=512"
eq "keeps caller's own cap"          "$(heap '--max-old-space-size=256' 4096 0)" "--max-old-space-size=256"
eq "non-numeric -> off"              "$(heap '' abc 0)"     ""

echo
echo "guard tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
