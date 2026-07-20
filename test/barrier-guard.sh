#!/usr/bin/env bash
# barrier-guard.sh — prove the shared read-only-hub guard (hub-readonly-guard.py)
# blocks the right paths and allows the rest. This guard IS the barrier for the
# claude and gemini packs (both hand it the tool-call JSON on stdin and treat
# exit 2 as "block"), so it is the most-used barrier in the repo yet had no
# dedicated test. This exercises it directly — no CLI, no auth, no network — the
# way the packs' hooks invoke it: `hub-readonly-guard.py <hub>` reading JSON on
# stdin. Exits non-zero on any failure.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
GUARD="$SELF_DIR/../bin/hub-readonly-guard.py"
[ -x "$GUARD" ] || { echo "FAIL: guard not executable: $GUARD" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }

hub="$(mktemp -d)"; wt="$(mktemp -d)"
# A sibling that shares the hub's path prefix, to catch a "/hub" pattern wrongly
# matching "/hub-sibling" (the guard must require a path separator after the hub).
sib="${hub}-sibling"; mkdir -p "$sib" "$hub/sub"
trap 'rm -rf "$hub" "$wt" "$sib"' EXIT

# expect <want-rc> <desc> <hub-arg> <json>   (guard reads JSON on stdin)
expect() {
  local want="$1" desc="$2" hubarg="$3" json="$4" got
  set +e; printf '%s' "$json" | "$GUARD" "$hubarg" >/dev/null 2>&1; got=$?; set -e
  [ "$got" = "$want" ] || fail "$desc: expected rc=$want, got rc=$got"
  echo "  ok: $desc (rc=$got)"
}

# --- BLOCK (exit 2): any write whose target is inside the hub ---
expect 2 "hub top-level file blocked"  "$hub" "{\"tool_input\":{\"file_path\":\"$hub/DOC.md\"}}"
expect 2 "hub nested file blocked"     "$hub" "{\"tool_input\":{\"file_path\":\"$hub/sub/deep.md\"}}"
expect 2 "hub dir itself blocked"      "$hub" "{\"tool_input\":{\"file_path\":\"$hub\"}}"
expect 2 "hub via 'path' key blocked"  "$hub" "{\"tool_input\":{\"path\":\"$hub/x.md\"}}"
expect 2 "hub notebook_path blocked"   "$hub" "{\"tool_input\":{\"notebook_path\":\"$hub/n.ipynb\"}}"

# --- ALLOW (exit 0): everything else ---
expect 0 "worktree file allowed"       "$hub" "{\"tool_input\":{\"file_path\":\"$wt/code.py\"}}"
expect 0 "prefix-sibling NOT blocked"  "$hub" "{\"tool_input\":{\"file_path\":\"$sib/DOC.md\"}}"
expect 0 "no hub configured -> allow"  ""     "{\"tool_input\":{\"file_path\":\"$hub/DOC.md\"}}"
expect 2 "malformed JSON -> fail closed" "$hub" "not json at all"
expect 0 "no target path -> allow"     "$hub" "{\"tool_input\":{}}"

# --- symlink bypass (S1): a literal path outside the hub that resolves,
# via a symlink, to a file inside it must still be blocked ---
symlinked_file="$hub/symlinked.md"
: > "$symlinked_file"
file_link="$wt/link-to-hub-file.md"
ln -s "$symlinked_file" "$file_link"
expect 2 "symlink to hub file blocked" "$hub" "{\"tool_input\":{\"file_path\":\"$file_link\"}}"

dir_link="$wt/link-to-hub-dir"
ln -s "$hub" "$dir_link"
expect 2 "symlinked dir + subpath blocked" "$hub" "{\"tool_input\":{\"file_path\":\"$dir_link/sousfichier.md\"}}"

# --- hub via \$HUB env instead of argv (packs may rely on either) ---
got=0
set +e; printf '%s' "{\"tool_input\":{\"file_path\":\"$hub/DOC.md\"}}" | HUB="$hub" "$GUARD" >/dev/null 2>&1; got=$?; set -e
[ "$got" = 2 ] || fail "hub via \$HUB env: expected rc=2, got rc=$got"
echo "  ok: hub via \$HUB env blocked (rc=$got)"

echo "PASS: hub-readonly-guard.py blocks hub writes and allows the rest."
