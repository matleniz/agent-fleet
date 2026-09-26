#!/usr/bin/env bash
# make-pack-interop.sh — disposable non-Claude project to dogfood cross-pack
# dispatch (agy ↔ cursor, plus other enabled packs).
#
#   test/make-pack-interop.sh [ROOT]   # default ROOT: ~/fleet-pack-interop
#
# Creates under ROOT:
#   code/     mini git repo (throwaway product code)
#   hub/      docs hub seeded by fleet-init + INTEROP.md matrix stub
#   wt/       worker worktrees
# Registers as project "pack-interop" with AGENTS without Claude:
#   antigravity,cursor,opencode,copilot,gemini  (first = default coordinator)
#
# Idempotent: re-run wipes ROOT and overwrites pack-interop.env (--force).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="${1:-$HOME/fleet-pack-interop}"
export FLEET_HOME="${FLEET_HOME:-$HOME/.config/fleet}"
NAME=pack-interop

case "$ROOT" in
  "$HOME"/*) ;;
  *) echo "error: ROOT must live under \$HOME (got: $ROOT)" >&2; exit 2 ;;
esac

if [ -e "$ROOT" ]; then
  echo "[pack-interop] wiping previous tree at $ROOT"
  # Drop leftover worktrees from a prior run so wipe does not leave git locks.
  if [ -d "$ROOT/code/.git" ]; then
    git -C "$ROOT/code" worktree list --porcelain 2>/dev/null \
      | awk '/^worktree /{print $2}' \
      | while read -r wt; do
          [ "$wt" = "$ROOT/code" ] && continue
          git -C "$ROOT/code" worktree remove --force "$wt" 2>/dev/null || true
        done
  fi
  rm -rf "$ROOT"
fi
mkdir -p "$ROOT"/{code,wt}

git -C "$ROOT/code" init -q -b main
cat > "$ROOT/code/hello.py" <<'PY'
def greet(name: str) -> str:
    return f"hello {name}"
PY
cat > "$ROOT/code/AGENTS.md" <<'MD'
# pack-interop code repo

Throwaway repo for agent-fleet cross-pack dogfood. Python, no deps.
Do not do product work here — smokes only.
MD
git -C "$ROOT/code" add -A
git -C "$ROOT/code" -c user.name=pack-interop -c user.email=pack-interop@localhost \
  commit -qm "init: pack-interop code repo"

# No Claude in AGENTS — antigravity is the default coordinator.
"$SELF_DIR/../bin/fleet-init" "$NAME" \
  --code "$ROOT/code" --hub "$ROOT/hub" --wt "$ROOT/wt" \
  --agents antigravity,cursor,opencode,copilot,gemini \
  --queue none --force

cat > "$ROOT/hub/INDEX.md" <<'MD'
# pack-interop hub — index

- [INTEROP.md](INTEROP.md) — dated PASS/FAIL/SKIP matrix for cross-pack dispatch
- Throwaway dogfood only; no product docs.
MD
cat > "$ROOT/hub/INTEROP.md" <<'MD'
# Cross-pack interop matrix

Filled by the dogfood run (date + results). Empty = not run yet.

| From (coord) | To (worker `-a`) | Mode | Result | Notes |
| --- | --- | --- | --- | --- |
| (shell) | antigravity | headless smoke | | |
| (shell) | cursor | headless smoke | | |
| (shell) | opencode | headless smoke | | |
| (shell) | gemini | headless smoke | | SKIP if no auth |
| (shell) | copilot | headless smoke | | SKIP if no headless token |
| antigravity | cursor | coord dispatch | | |
| cursor | antigravity | coord dispatch | | |
MD
git -C "$ROOT/hub" add -A
git -C "$ROOT/hub" -c user.name=pack-interop -c user.email=pack-interop@localhost \
  commit -qm "init: pack-interop hub"

echo "[pack-interop] ready:"
echo "  code : $ROOT/code"
echo "  hub  : $ROOT/hub"
echo "  wt   : $ROOT/wt"
echo "  conf : $FLEET_HOME/projects/${NAME}.env"
echo
echo "[pack-interop] try:"
echo "  fleet --project $NAME doctor"
echo "  fleet --project $NAME -a cursor dispatch smoke-cur \"Reply with exactly: OK\" main"
echo "  fleet --project $NAME -a antigravity dispatch smoke-agy \"Reply with exactly: OK\" main"
