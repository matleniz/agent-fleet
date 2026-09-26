#!/usr/bin/env bash
# test-resolve-conf.sh — regression for MAT-53: an explicit --project must win
# over an inherited FLEET_CONF. A coordinator whose env already has
# FLEET_CONF=A.env that runs `fleet --project B ...` must resolve B, not A.
# Also covers: FLEET_CONF still wins when no --project is given (child reuse),
# and FLEET_PROJECT is the soft default under that.
#
#   test/test-resolve-conf.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-resolve-conf.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export FLEET_HOME="$TMP/config"
mkdir -p "$FLEET_HOME/projects" "$TMP/code-a" "$TMP/code-b" "$TMP/wt-a" "$TMP/wt-b"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected '$3', got '$2'"; fi; }

cat > "$FLEET_HOME/projects/proj_a.env" <<EOF
CODE_REPO="$TMP/code-a"
WT_HOME="$TMP/wt-a"
HUB=""
AGENTS="claude"
EOF
cat > "$FLEET_HOME/projects/proj_b.env" <<EOF
CODE_REPO="$TMP/code-b"
WT_HOME="$TMP/wt-b"
HUB=""
AGENTS="claude"
EOF

# Helper: source fleet-config in a clean subshell, resolve, print basename of CONF.
resolve() {  # [explicit_proj]
  # shellcheck disable=SC1091
  (
    . "$REPO/bin/fleet-config.sh"
    fleet_resolve_conf "${1:-}"
    basename "$CONF" .env
  )
}

echo "[1] explicit --project wins over inherited FLEET_CONF (MAT-53)"
export FLEET_CONF="$FLEET_HOME/projects/proj_a.env"
unset FLEET_PROJECT || true
got="$(resolve proj_b)"
eq "FLEET_CONF=A + --project B -> B" "$got" "proj_b"

# Via the real CLI surface (fleet ls prints worktrees [PROJ_NAME]).
out="$(FLEET_CONF="$FLEET_HOME/projects/proj_a.env" \
  "$REPO/bin/fleet" --project proj_b ls 2>&1)" || true
if printf '%s' "$out" | grep -q 'worktrees \[proj_b\]'; then
  ok "fleet --project B ls lists B (not A) under inherited FLEET_CONF=A"
else
  bad "fleet ls did not resolve B; got: $out"
fi

echo "[2] FLEET_CONF still reused when no --project (child inheritance)"
got="$(resolve)"
eq "FLEET_CONF=A alone -> A" "$got" "proj_a"

echo "[3] FLEET_PROJECT is soft: loses to FLEET_CONF, wins when neither conf nor --project"
export FLEET_PROJECT=proj_b
got="$(resolve)"
eq "FLEET_CONF=A + FLEET_PROJECT=B (no --project) -> A" "$got" "proj_a"

unset FLEET_CONF || true
got="$(resolve)"
eq "FLEET_PROJECT=B alone -> B" "$got" "proj_b"

echo "[4] explicit --project also beats FLEET_PROJECT"
export FLEET_PROJECT=proj_a
got="$(resolve proj_b)"
eq "--project B + FLEET_PROJECT=A -> B" "$got" "proj_b"

echo
echo "resolve-conf tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
