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

echo "[claude] strict --mcp-config profile (fleet-mcp.json distilled from all sources)"
d="$(mktemp -d)"; h="$(mktemp -d)"; mkdir -p "$d/.claude"
printf '{"mcpServers":{"linear":{"command":"linear-mcp"},"projonly":{"command":"po"}}}' > "$d/.mcp.json"
cat > "$h/.claude.json" <<'JSON'
{"mcpServers":{"github":{"command":"gh-mcp"}},
 "projects":{"/some/repo":{"mcpServers":{"sentry":{"command":"sentry-mcp"}}}}}
JSON
( source "$REPO/packs/claude/pack.sh"; HOME="$h" pack_mcp_profile "$d" "linear github sentry" )
jassert "$d/.claude/fleet-mcp.json" 'set(cfg["mcpServers"])=={"linear","github","sentry"}' "keeps allowlisted servers across project + user-top + user-project sources"
jassert "$d/.claude/fleet-mcp.json" 'cfg["mcpServers"]["linear"]["command"]=="linear-mcp"' "def carried from project .mcp.json"
jassert "$d/.claude/fleet-mcp.json" 'cfg["mcpServers"]["github"]["command"]=="gh-mcp"'     "def carried from ~/.claude.json top-level"
jassert "$d/.claude/fleet-mcp.json" 'cfg["mcpServers"]["sentry"]["command"]=="sentry-mcp"' "def carried from ~/.claude.json per-project"
jassert "$d/.claude/fleet-mcp.json" '"projonly" not in cfg["mcpServers"]'                  "non-allowlisted server excluded"
( source "$REPO/packs/claude/pack.sh"; HOME="$h" pack_mcp_profile "$d" "none" )
jassert "$d/.claude/fleet-mcp.json" 'cfg["mcpServers"]=={}'                                "none -> zero servers"
( source "$REPO/packs/claude/pack.sh"; HOME="$h" pack_mcp_profile "$d" "linear notreal" )
jassert "$d/.claude/fleet-mcp.json" 'set(cfg["mcpServers"])=={"linear"}'                   "unknown server name dropped (not in any source)"
rm -rf "$d" "$h"

echo "[claude] launch injects --strict-mcp-config only when a profile exists"
d="$(mktemp -d)"; mkdir -p "$d/.claude"; printf '{"mcpServers":{}}' > "$d/.claude/fleet-mcp.json"
out="$( cd "$d" || exit; source "$REPO/packs/claude/pack.sh"; _claude_mcp_flags; printf '%s' "${FLEET_MCP_FLAGS[*]}" )"
case "$out" in
  *--strict-mcp-config*--mcp-config*) ok "strict flags injected when profile present" ;;
  *) bad "expected strict flags, got: '$out'" ;;
esac
d2="$(mktemp -d)"
out2="$( cd "$d2" || exit; source "$REPO/packs/claude/pack.sh"; _claude_mcp_flags; printf '%s' "${FLEET_MCP_FLAGS[*]}" )"
[ -z "$out2" ] && ok "no flags when no profile (opt-in preserved)" || bad "expected empty, got: '$out2'"
rm -rf "$d" "$d2"

echo "[opencode] allowlist by disabling non-allowed global servers + merge + none"
d="$(mktemp -d)"; g="$(mktemp -d)"
printf '{"mcp":{"alpha":{"enabled":true},"beta":{"enabled":true}}}' > "$g/opencode.json"  # global catalogue
printf '{"permission":{"edit":"deny"}}' > "$d/opencode.json"                              # pretend barrier
( source "$REPO/packs/opencode/pack.sh"; OPENCODE_CONFIG="$g/opencode.json" pack_mcp_profile "$d" "alpha" )
jassert "$d/opencode.json" 'cfg["mcp"]["beta"]["enabled"] is False'          "non-allowed global server disabled"
jassert "$d/opencode.json" 'cfg["mcp"].get("alpha",{}).get("enabled") is not False' "allowed server left enabled"
jassert "$d/opencode.json" 'cfg["permission"]["edit"]=="deny"'               "barrier preserved (merge)"
( source "$REPO/packs/opencode/pack.sh"; OPENCODE_CONFIG="$g/opencode.json" pack_mcp_profile "$d" "none" )
jassert "$d/opencode.json" 'cfg["mcp"]["alpha"]["enabled"] is False and cfg["mcp"]["beta"]["enabled"] is False' "none -> all disabled"
rm -rf "$d" "$g"

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
