#!/usr/bin/env bash
# test-server-detect.sh — blocking-server detection matches the executable and its
# first arguments only: a headless `claude -p "<real preamble>"` is NOT flagged
# (the preamble cites 'npm run dev', 'vite', ...), real server children are.
# Model-free, no tmux, no timing dependence (detection reads the live process table).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENGINE="$(cd "$SELF_DIR/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d)"
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/bin"

# The real preamble, extracted from bin/fleet (not a copy that could drift).
# shellcheck disable=SC2034,SC2154  # dest/name/HUB feed the eval'd bin/fleet snippet, which assigns preamble
build_preamble() {
  local dest="/tmp/wt/x" name="x" HUB="/tmp/hub"
  eval "$(sed -n '/local preamble="You are a code WORKER/,/Task follows\./p' "$ENGINE/bin/fleet")"
  printf '%s' "$preamble"
}
PREAMBLE="$(build_preamble)"
echo "$PREAMBLE" | grep -q "npm run dev" || fail "could not extract the real preamble"

for n in claude vite tool; do
  printf '#!/bin/bash\nsleep 60\n' > "$TMP/bin/$n"; chmod +x "$TMP/bin/$n"
done

detect() { python3 "$ENGINE/bin/fleet_common.py" check-server "$1" 2>/dev/null || true; }
start() { "$@" >/dev/null 2>&1 & PIDS+=("$!"); echo "$!"; }
# Wait until pid's exec'd command line shows up in ps (bounded, not a sleep guess).
ready() { for _ in $(seq 50); do ps -o args= -p "$1" 2>/dev/null | grep -q "$2" && return 0; sleep 0.1; done; fail "process $1 never showed $2"; }

# 1. Headless worker with the full preamble (+ task text): not flagged.
pid="$(start "$TMP/bin/claude" -p "$PREAMBLE

Fix the vite uvicorn --watch bug" --permission-mode auto)"
ready "$pid" "claude"
out="$(detect "$pid")"
[ -z "$out" ] || fail "headless claude -p flagged as server: $out"

# 2. Real servers are still flagged.
pid="$(start python3 -m http.server 0)"; ready "$pid" http.server
detect "$pid" | grep -q "http.server" || fail "http.server not detected"
pid="$(start "$TMP/bin/vite" --host)"; ready "$pid" vite
detect "$pid" | grep -q "vite" || fail "vite not detected"
pid="$(start "$TMP/bin/tool" --watch)"; ready "$pid" watch
detect "$pid" | grep -q -- "--watch" || fail "--watch not detected"

# 3. Real server as a child of a claude-like parent is flagged; the parent alone is not.
pid="$(start bash -c "\"$TMP/bin/claude\" -p \"$PREAMBLE\" & python3 -m http.server 0 & wait")"
ready "$pid" "bash -c"
for _ in $(seq 50); do out="$(detect "$pid")"; [ -n "$out" ] && break; sleep 0.1; done
echo "$out" | grep -q "http.server" || fail "child http.server not detected under parent: '$out'"

echo "PASS: test-server-detect"
