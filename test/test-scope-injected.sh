#!/usr/bin/env bash
# test-scope-injected.sh — regression: the scope check must ignore the untracked
# files fleet itself injects into a worktree (every pack's pack_barrier_files +
# dispatch sidecars), while still checking real worker changes, including a
# tracked file modified under an injected-looking dir. Model-free, tmux-free.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CHECKS="$REPO/bin/fleet_checks.py"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-scopeinj-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1
G() { git -c user.name=t -c user.email=t@localhost "$@"; }
G init -q -b main . && mkdir -p src .cursor
echo a > src/a.txt; echo '{}' > .cursor/tracked.json
G add -A && G commit -qm base
G checkout -q -b work
run() { python3 "$CHECKS" run --root . --base main --checks scope:blocking --scope "src/**"; }

echo "[1] injected untracked files are not scope violations"
echo b > src/b.txt
mkdir -p .cursor/rules .claude .gemini
for f in .cursor/cli.json .cursor/rules/00-fleet-user.mdc .claude/settings.local.json \
         .claude/fleet-mcp.json .gemini/settings.json opencode.json \
         .dispatch-marker .model-marker .fleet-witness; do echo x > "$f"; done
eq "clean" "$(run)" ""

echo "[2] a real out-of-scope untracked file is still flagged"
echo y > stray.txt
eq "stray flagged" "$(run)" "BLOCK scope stray.txt:1 changed outside the allowed scope (src/**)"
rm stray.txt

echo "[3] a tracked file modified under .cursor/ is still flagged"
echo z >> .cursor/tracked.json
eq "tracked flagged" "$(run)" "BLOCK scope .cursor/tracked.json:1 changed outside the allowed scope (src/**)"

echo "scope-injected: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
