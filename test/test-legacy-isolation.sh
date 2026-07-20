#!/usr/bin/env bash
# test-legacy-isolation.sh — the Python fleet tools must refuse a FLEET_HOME
# that resolves to the legacy claude-fleet config (fleet_common.assert_not_legacy),
# mirroring the bash guard in fleet-config.sh. Without this, fleet-status.py /
# fleet-context.py / fleet-chats-scan.py / fleet-feedback.py would happily read
# the legacy fleet's real projects (see AGENTS.md — the isolation this repo
# depends on during the transition period). Touches nothing real: every FLEET_HOME
# here is a throwaway dir under a temp root, never ~/.config/fleet.
#
#   test/test-legacy-isolation.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-legacy-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# args per tool that reach ROOT resolution (module-level, before any subcommand
# work happens) — --all / --help are enough since assert_not_legacy runs before
# argparse gets a chance to do anything.
declare -A TOOL_ARGS=(
  [fleet-status]="--all"
  [fleet-context]="--help"
  [fleet-chats-scan]="--all"
  [fleet-feedback]="list"
)

LEGACY_HOME="$TMP/claude-fleet"
mkdir -p "$LEGACY_HOME"

echo "[1] legacy FLEET_HOME is refused by every tool"
for tool in fleet-status fleet-context fleet-chats-scan fleet-feedback; do
  # shellcheck disable=SC2086 # intentional word-splitting of the args string
  out="$(FLEET_HOME="$LEGACY_HOME" python3 "$REPO/bin/$tool.py" ${TOOL_ARGS[$tool]} 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then ok "$tool: exits non-zero ($rc)"
  else bad "$tool: exited 0 against a legacy FLEET_HOME"; fi
  if printf '%s' "$out" | grep -q 'legacy claude-fleet config'; then
    ok "$tool: prints the legacy-guard message"
  else
    bad "$tool: legacy-guard message missing; got: $out"
  fi
done

echo "[2] legacy guard also fires through a symlink (readlink -f semantics)"
LEGACY_REAL="$TMP/real-legacy/claude-fleet"
mkdir -p "$LEGACY_REAL"
LEGACY_LINK="$TMP/link-to-legacy"
ln -s "$LEGACY_REAL" "$LEGACY_LINK"
out="$(FLEET_HOME="$LEGACY_LINK" python3 "$REPO/bin/fleet-status.py" --all 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'legacy claude-fleet config'; then
  ok "fleet-status: symlink to a legacy path is also refused"
else
  bad "fleet-status: symlink to a legacy path was NOT refused; rc=$rc out=$out"
fi

echo "[3] control case: a normal FLEET_HOME is NOT rejected by the legacy guard"
NORMAL_HOME="$TMP/normal-config"
mkdir -p "$NORMAL_HOME/projects" "$NORMAL_HOME/machines"
for tool in fleet-status fleet-context fleet-chats-scan fleet-feedback; do
  # shellcheck disable=SC2086 # intentional word-splitting of the args string
  out="$(FLEET_HOME="$NORMAL_HOME" python3 "$REPO/bin/$tool.py" ${TOOL_ARGS[$tool]} 2>&1)"
  if printf '%s' "$out" | grep -q 'legacy claude-fleet config'; then
    bad "$tool: a normal FLEET_HOME was rejected by the legacy guard; got: $out"
  else
    ok "$tool: normal FLEET_HOME not flagged as legacy (may still fail for other reasons)"
  fi
done

echo
echo "legacy-isolation tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
