#!/usr/bin/env bash
# entrypoint.sh — runs on every container start, then hands off to CMD.
# Re-wires the PATH symlinks (~/.local/bin -> the baked tooling in the image at
# /opt/agent-fleet/bin). Those symlinks live on the persistent /home/fleet volume
# but point at image paths; a rebuild or a fresh volume can leave them absent or
# stale, which is how `fleet: command not found` shows up after a rebuild. Doing
# it here makes PATH self-healing on every start, so fleet-vm-setup no longer has
# to be re-run just to fix PATH. Idempotent. Keep this list in sync with the same
# loop in install.sh.
set -euo pipefail
FLEET_SRC="${FLEET_SRC:-/opt/agent-fleet}"
mkdir -p "$HOME/.local/bin"
for t in fleet new-worker fleet-assess fleet-queue fleet-init fleet-migrate; do
  [ -e "$FLEET_SRC/bin/$t" ] && ln -sf "$FLEET_SRC/bin/$t" "$HOME/.local/bin/$t"
done
exec "$@"
