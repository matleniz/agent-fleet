#!/usr/bin/env bash
# make-sandbox.sh — create a disposable sandbox project to test the fleet tools
# without touching any real repo or the production fleet config.
#
#   test/make-sandbox.sh [ROOT]     # default ROOT: ~/fleet-sandbox
#
# Creates under ROOT:
#   code/     a mini git repo (the "code repo"), one commit, a main branch
#   hub/      a mini docs hub, seeded by fleet-init (INDEX, AGENTS.md +
#             CLAUDE.md bridge, coordinator skills) + two sandbox docs
#   wt/       empty dir where worker worktrees will be created
# and registers the project as "sandbox" via THIS repo's bin/fleet-init
# (so the E2E exercises the real new-project flow, hub seed and base-ref
# auto-detection included) in the DEV config dir ($FLEET_HOME, default
# ~/.config/fleet) — never in the legacy prod dir.
#
# Idempotent: re-run to recreate from scratch (ROOT is wiped if it exists;
# fleet-init --force overwrites the previous sandbox.env).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="${1:-$HOME/fleet-sandbox}"
export FLEET_HOME="${FLEET_HOME:-$HOME/.config/fleet}"

case "$ROOT" in
  "$HOME"/*) ;;
  *) echo "error: ROOT must live under \$HOME (got: $ROOT)" >&2; exit 2 ;;
esac

if [ -e "$ROOT" ]; then
  echo "[sandbox] wiping previous sandbox at $ROOT"
  rm -rf "$ROOT"
fi
mkdir -p "$ROOT"/{code,wt}

git -C "$ROOT/code" init -q -b main
cat > "$ROOT/code/hello.py" <<'PY'
def greet(name: str) -> str:
    return f"hello {name}"
PY
cat > "$ROOT/code/AGENTS.md" <<'MD'
# sandbox code repo

Tiny throwaway repo used to test the fleet tooling. Python, no deps.
MD
git -C "$ROOT/code" add -A
git -C "$ROOT/code" -c user.name=sandbox -c user.email=sandbox@localhost \
  commit -qm "init: sandbox code repo"

# Register through the real flow: fleet-init seeds hub/ (git init, INDEX,
# AGENTS.md + CLAUDE.md bridge, coordinator skills, .gemini/settings.json for
# the gemini pack) and auto-detects the base ref from code/ (no origin ->
# the checked-out branch, main).
"$SELF_DIR/../bin/fleet-init" sandbox \
  --code "$ROOT/code" --hub "$ROOT/hub" --wt "$ROOT/wt" \
  --agents claude,gemini,opencode,cursor --queue none --force

# Sandbox-specific hub content on top of the seed, committed (the seed
# deliberately does not commit).
cat > "$ROOT/hub/INDEX.md" <<'MD'
# sandbox hub — index

- [architecture.md](architecture.md) — how the (fake) system fits together
- [operations.md](operations.md) — how to run it
MD
cat > "$ROOT/hub/architecture.md" <<'MD'
# Architecture

One module, `hello.py`. It greets people. That is the whole system.
MD
cat > "$ROOT/hub/operations.md" <<'MD'
# Operations

Run `python -c "import hello; print(hello.greet('world'))"` from code/.
MD
git -C "$ROOT/hub" add -A
git -C "$ROOT/hub" -c user.name=sandbox -c user.email=sandbox@localhost \
  commit -qm "init: sandbox hub"

# Machine registry: register a placeholder VM and select it, so the sandbox
# exercises the N-machine surface (fleet ls / machines / status). The host is
# unreachable on purpose — the point is config resolution and the tree shape,
# not a live remote (that needs a real container).
"$SELF_DIR/../bin/fleet" --project sandbox machines add vm vm.sandbox.invalid >/dev/null 2>&1 || true
grep -q '^MACHINES=' "$FLEET_HOME/projects/sandbox.env" \
  || printf 'MACHINES="local vm"\n' >> "$FLEET_HOME/projects/sandbox.env"

echo "[sandbox] ready:"
echo "  code : $ROOT/code   (1 commit, branch main)"
echo "  hub  : $ROOT/hub    (seeded by fleet-init + INDEX + 2 docs)"
echo "  wt   : $ROOT/wt"
echo "  conf : $FLEET_HOME/projects/sandbox.env"
echo "  machines: local + vm (placeholder)   ·   registry: $FLEET_HOME/machines/"
echo
echo "[sandbox] try:"
echo "  fleet --project sandbox machines           # selected + registry pool"
echo "  fleet --project sandbox ls                 # worktrees, per-machine header"
echo "  fleet --project sandbox status --json      # the whole tree (UI contract)"
echo "  fleet --project sandbox w my-task          # a worker in tmux (local)"
echo "  fleet --project sandbox peek local my-task # dump its terminal"
