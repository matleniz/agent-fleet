#!/usr/bin/env bash
# test-context.sh — tests for `fleet context` / bin/fleet-context.py, the
# front-loaded context reporter. Uses an isolated $FLEET_HOME + fixture with
# known file sizes; the reporter only reads files (never launches), so it is
# safe and deterministic.
#
#   test/test-context.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-context-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# Isolate everything the reporter reads: FLEET_HOME (config), and HOME (so the
# real ~/.agents/skills + ~/.claude/skills don't leak into the count).
export HOME="$TMP"
export FLEET_HOME="$TMP/config"
export FLEET_GLOBAL_AGENTS="$TMP/global-AGENTS.md"   # isolate from the real global
mkdir -p "$FLEET_HOME/projects"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected '$3', got '$2'"; fi; }

# ---- fixture with known sizes ----
export HUB="$TMP/hub" CODE="$TMP/code"; WT="$TMP/wt"
mkdir -p "$HUB/.agents/skills/alpha" "$HUB/.agents/skills/beta" "$CODE" "$WT"
printf 'GLOBAL rules here.\n'            > "$FLEET_GLOBAL_AGENTS"   # global instructions
printf '@AGENTS.md\n'                    > "$HUB/CLAUDE.md"          # hub bridge (11 b)
printf 'HUB instructions, fill in.\n'    > "$HUB/AGENTS.md"         # hub instructions
printf '# router\n- a -> a.md\n'         > "$HUB/INDEX.md"          # on-demand router
printf 'CODE repo rules.\n'              > "$CODE/AGENTS.md"        # code instructions
# Two skills: short description (front-loaded), long body (on-demand).
cat > "$HUB/.agents/skills/alpha/SKILL.md" <<'MD'
---
name: alpha
description: Does the alpha thing when asked.
---
This is the alpha skill body, which is only loaded on invocation and must NOT
count toward the front-loaded footprint. Padding padding padding padding.
MD
cat > "$HUB/.agents/skills/beta/SKILL.md" <<'MD'
---
name: beta
description: Handles beta cases end to end.
---
Beta body, on-demand only. More padding to make the body clearly bigger than the
description so the on-demand vs front-loaded split is unambiguous in the report.
MD

cat > "$FLEET_HOME/projects/x.env" <<EOF
CODE_REPO="$CODE"
HUB="$HUB"
WT_HOME="$WT"
AGENTS="claude"
EOF

ctx() { "$REPO/bin/fleet" --project x context "$@"; }

echo "[1] JSON structure + byte accuracy"
json="$(ctx --json 2>/dev/null)"
python3 - "$json" <<'PY'
import json, os, sys
r = json.loads(sys.argv[1])
hub = os.environ["HUB"]
def size(p): return os.path.getsize(p)
checks = []
coord = r["roles"]["coordinator"]
worker = r["roles"]["worker"]
by_label = {e["label"]: e for e in coord["files"]}
# hub instructions bytes match the real file
checks.append(("hub instructions bytes",
               by_label["hub instructions"]["bytes"], size(os.path.join(hub, "AGENTS.md"))))
# global instructions counted
checks.append(("global present in coordinator",
               "global instructions" in by_label, True))
# skills aggregate: two skills, front bytes = sum(name+desc), well under the bodies
sk = [e for e in coord["files"] if e["label"].startswith("skills ×")]
checks.append(("two skills counted", sk[0]["label"], "skills ×2 (descriptions)"))
# skill front-load must be much smaller than skill bodies (on-demand)
body = [e for e in r["on_demand"] if e["label"] == "skill bodies"][0]["bytes"]
checks.append(("skill descriptions < bodies", sk[0]["bytes"] < body, True))
# INDEX.md is on-demand, NOT in the coordinator subtotal files
checks.append(("INDEX not front-loaded",
               any("INDEX" in e["label"] for e in coord["files"]), False))
checks.append(("INDEX in on_demand",
               any("INDEX" in e["label"] for e in r["on_demand"]), True))
# worker has the dispatch preamble
checks.append(("worker has dispatch preamble",
               any("preamble" in e["label"] for e in worker["files"]), True))
# subtotal_bytes == sum of file bytes
checks.append(("coordinator subtotal consistent",
               coord["subtotal_bytes"], sum(e["bytes"] for e in coord["files"])))
fails = 0
for name, got, want in checks:
    if got == want:
        print("  ok   %s (%s)" % (name, got))
    else:
        print("  FAIL %s: expected %r, got %r" % (name, want, got)); fails += 1
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && ok "json checks passed" || bad "json checks failed"

echo "[2] text output + role filter"
out="$(ctx 2>/dev/null)"
printf '%s' "$out" | grep -q "COORDINATOR" && ok "text shows COORDINATOR" || bad "no COORDINATOR"
printf '%s' "$out" | grep -q "ON DEMAND"   && ok "text shows ON DEMAND"   || bad "no ON DEMAND"
printf '%s' "$out" | grep -qi "guard.*0 context\|0 context" && ok "notes the guard is 0-context" || bad "missing guard note"
wonly="$(ctx --role worker 2>/dev/null)"
printf '%s' "$wonly" | grep -q "COORDINATOR" && bad "--role worker leaked coordinator" || ok "--role worker excludes coordinator"

echo "[3] --budget exit codes"
# Coordinator front-load here is small (well under 1000 tokens).
ctx --budget 100000 >/dev/null 2>&1; eq "under budget -> exit 0" "$?" "0"
ctx --budget 1      >/dev/null 2>&1; eq "over budget -> exit 2"  "$?" "2"

echo
echo "context tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
