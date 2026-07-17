#!/usr/bin/env bash
# docs-sync.sh — guard against bin/ <-> docs drift, the repo's one real risk
# (AGENTS.md: "bin/ and the docs move in the same commit"). It checks COMMAND
# coverage: every user-facing fleet subcommand in the dispatch table must be
# documented as `fleet <cmd>` in README.md or docs/. Internal subcommands
# (underscore-prefixed, e.g. _dispatch-run) are exempt. This catches the common
# drift — a command added or renamed in bin/fleet with no doc update — without
# needing to launch anything. Extend with flag/config checks as the schema grows.
# Exits non-zero listing any undocumented command.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$SELF_DIR/.."
FLEET="$ROOT/bin/fleet"
README="$ROOT/README.md"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$FLEET" ]  || fail "no bin/fleet at $FLEET"
[ -f "$README" ] || fail "no README.md at $README"

# Subcommands from the main `case "$sub" in ... esac` dispatch table.
subs="$(awk '/^case "\$sub" in/{f=1;next} /^esac/{f=0} f' "$FLEET" \
  | sed -n 's/^  \([a-z_][a-z0-9-]*\)).*/\1/p')"
[ -n "$subs" ] || fail "could not extract subcommands from bin/fleet (dispatch table moved?)"

missing=""
count=0
for s in $subs; do
  case "$s" in _*) continue ;; esac   # internal, not user-facing
  count=$((count + 1))
  # Documented iff it appears used as a command ("fleet ... <s>") in README or docs.
  if ! grep -qE "fleet.* ${s}\b" "$README" "$ROOT"/docs/*.md; then
    missing="$missing $s"
  fi
done

if [ -n "$missing" ]; then
  echo "FAIL: fleet subcommands not documented as 'fleet <cmd>' in README.md or docs/:" >&2
  for s in $missing; do echo "  - $s" >&2; done
  echo "Document each one (AGENTS.md: bin/ and docs move in the same commit)." >&2
  exit 1
fi

echo "PASS: all $count user-facing fleet subcommands are documented."
