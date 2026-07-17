#!/usr/bin/env bash
# test-mcp-profile.sh — the lean worker MCP profile (WORKER_MCP -> pack_mcp_profile).
# Sources each supporting pack and asserts the allowlist lands in the worktree
# config AND the barrier settings the pack already wrote are preserved (the
# profile merges into, not overwrites, the settings file). No CLI is launched.
#
#   test/test-mcp-profile.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# Assert a python bool expression over the parsed JSON at <file> is True.
jassert() {  # <file> <py-expr-on-cfg> <label>
  local out
  out="$(python3 -c 'import json,sys; cfg=json.load(open(sys.argv[1])); print(bool('"$2"'))' "$1" 2>/dev/null)"
  [ "$out" = True ] && ok "$3" || bad "$3 (got: '$out')"
}

echo "[gemini] mcp.allowed allowlist + merge + none"
d="$(mktemp -d)"; mkdir -p "$d/.gemini"
printf '{"context":{"fileName":["AGENTS.md"]},"hooks":{"BeforeTool":[]}}' > "$d/.gemini/settings.json"  # pretend barrier
( source "$REPO/packs/gemini/pack.sh"; pack_mcp_profile "$d" "linear github" )
jassert "$d/.gemini/settings.json" 'cfg["mcp"]["allowed"]==["linear","github"]' "allowlist written"
jassert "$d/.gemini/settings.json" '"context" in cfg and "hooks" in cfg'        "barrier keys preserved (merge)"
( source "$REPO/packs/gemini/pack.sh"; pack_mcp_profile "$d" "none" )
jassert "$d/.gemini/settings.json" 'cfg["mcp"]["allowed"]==[]'                  "none -> empty list"
rm -rf "$d"

echo "[claude] enabledMcpjsonServers allowlist + merge"
d="$(mktemp -d)"; mkdir -p "$d/.claude"
printf '{"permissions":{"allow":["Read(/hub/**)"]},"hooks":{"PreToolUse":[]}}' > "$d/.claude/settings.local.json"
( source "$REPO/packs/claude/pack.sh"; pack_mcp_profile "$d" "linear" )
jassert "$d/.claude/settings.local.json" 'cfg["enabledMcpjsonServers"]==["linear"]'   "allowlist written"
jassert "$d/.claude/settings.local.json" 'cfg.get("enableAllProjectMcpServers")==False' "enableAll disabled"
jassert "$d/.claude/settings.local.json" '"permissions" in cfg and "hooks" in cfg'    "barrier keys preserved (merge)"
rm -rf "$d"

echo "[hub-less] pack_mcp_profile creates the config when none exists yet"
d="$(mktemp -d)"
( source "$REPO/packs/gemini/pack.sh"; pack_mcp_profile "$d" "linear" )
jassert "$d/.gemini/settings.json" 'cfg["mcp"]["allowed"]==["linear"]' "created from scratch (no prior barrier file)"
rm -rf "$d"

echo "[wiring] fleet_setup_worktree applies barrier + profile in one pass"
d="$(mktemp -d)"; hub="$(mktemp -d)"
( FLEET_HOME="$(mktemp -d)"; export FLEET_HOME   # keep the legacy-config guard happy
  source "$REPO/bin/fleet-config.sh"
  export HUB="$hub" GUARD="$REPO/bin/hub-readonly-guard.py"
  WORKER_MCP="linear" fleet_setup_worktree gemini "$d" )
jassert "$d/.gemini/settings.json" 'cfg["mcp"]["allowed"]==["linear"]' "fleet_setup_worktree wired the MCP profile"
jassert "$d/.gemini/settings.json" '"hooks" in cfg'                    "same call also wrote the barrier"
rm -rf "$d" "$hub"

echo
echo "mcp-profile tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
