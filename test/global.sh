#!/usr/bin/env bash
# global.sh — prove `fleet global` installs ONE canonical per-user instructions
# file and wires every capable CLI to it, without touching the real HOME or any
# real agent CLI (HOME is sandboxed; the CLIs are stubbed on PATH so the
# installed-checks pass).
#
# Native wiring: claude @import, opencode symlink, gemini + antigravity share
# ~/.gemini/GEMINI.md (symlink). cursor has no user-level global file, so it gets
# the per-worktree fallback (an always-apply .cursor/rules/*.mdc regenerated from
# the canonical, git-excluded). Asserts migration, all wirings, the status
# report, idempotency, template seeding, and the cursor fallback + git-exclude.
set -euo pipefail

ENGINE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

stub="$(mktemp -d)"; H="$(mktemp -d)"; H2="$(mktemp -d)"; WT="$(mktemp -d)"
trap 'rm -rf "$stub" "$H" "$H2" "$WT"' EXIT
for c in claude opencode gemini agy; do printf '#!/usr/bin/env bash\nexit 0\n' >"$stub/$c"; chmod +x "$stub/$c"; done
run() { HOME="$1" PATH="$stub:$PATH" "$ENGINE/bin/fleet" "${@:2}"; }

# --- sandbox 1: existing CLAUDE.md -> migration path + native wirings ---
mkdir -p "$H/.claude" "$H/.gemini"
printf '# perso\n- rule ALPHA\n' > "$H/.claude/CLAUDE.md"
printf '# old gemini global\n' > "$H/.gemini/GEMINI.md"     # pre-existing real file -> must be backed up

run "$H" global >/dev/null 2>&1 || fail "fleet global errored"
canon="$H/.agents/AGENTS.md"

[ -f "$canon" ] || fail "canonical not created"
grep -q "rule ALPHA" "$canon" || fail "CLAUDE.md content not migrated into canonical"
[ "$(cat "$H/.claude/CLAUDE.md")" = "@$canon" ] || fail "CLAUDE.md not reduced to @import (got: $(cat "$H/.claude/CLAUDE.md"))"
{ [ -f "$H/.claude/CLAUDE.md.bak" ] && grep -q "rule ALPHA" "$H/.claude/CLAUDE.md.bak"; } || fail "no CLAUDE.md.bak with original content"
{ [ -L "$H/.config/opencode/AGENTS.md" ] && [ "$(readlink -f "$H/.config/opencode/AGENTS.md")" = "$(readlink -f "$canon")" ]; } || fail "opencode not symlinked to canonical"
{ [ -L "$H/.gemini/GEMINI.md" ] && [ "$(readlink -f "$H/.gemini/GEMINI.md")" = "$(readlink -f "$canon")" ]; } || fail "gemini/antigravity GEMINI.md not symlinked to canonical"
{ [ -f "$H/.gemini/GEMINI.md.bak" ] && grep -q "old gemini global" "$H/.gemini/GEMINI.md.bak"; } || fail "pre-existing GEMINI.md not backed up"
echo "PASS: migration + claude @import + opencode symlink + gemini/antigravity GEMINI.md symlink (backup kept)"

# --- status report ---
out="$(run "$H" global status 2>/dev/null)"
for p in claude opencode gemini antigravity; do echo "$out" | grep -qE "$p +wired" || fail "$p not reported wired ($out)"; done
echo "$out" | grep -qE "cursor +project rule" || fail "cursor not reported as project-rule fallback ($out)"
echo "PASS: status reports claude/opencode/gemini/antigravity wired, cursor project-rule fallback"

# --- idempotency ---
run "$H" global >/dev/null 2>&1 || fail "second fleet global errored"
[ "$(grep -cxF "@$canon" "$H/.claude/CLAUDE.md")" -eq 1 ] || fail "duplicate @import after 2nd run"
[ "$(grep -c 'rule ALPHA' "$canon")" -eq 1 ] || fail "canonical mutated on 2nd run"
{ [ -L "$H/.gemini/GEMINI.md" ] && [ ! -e "$H/.gemini/GEMINI.md.bak.bak" ]; } || fail "gemini re-symlink not idempotent"
echo "PASS: idempotent (no duplicate import / re-migration / double backup)"

# --- sandbox 2: no CLAUDE.md -> template seed (CLEAN payload, not the wrapper) ---
run "$H2" global >/dev/null 2>&1 || fail "fleet global (fresh) errored"
seeded="$H2/.agents/AGENTS.md"
grep -q "global context" "$seeded" || fail "canonical not seeded from template when no CLAUDE.md"
grep -q "Template: global context file" "$seeded" && fail "canonical seeded WITH the template wrapper header (payload not extracted)"
grep -q '```' "$seeded" && fail "canonical still has a code fence (payload not extracted from the template)"
[ "$(cat "$H2/.claude/CLAUDE.md")" = "@$H2/.agents/AGENTS.md" ] || fail "fresh claude bridge not written"
echo "PASS: template seeding yields the clean fenced payload (no wrapper header / fence)"

# --- cursor per-worktree fallback (no native global file) ---
git -C "$WT" init -q
(
  export FLEET_GLOBAL_AGENTS="$canon"          # canonical from sandbox 1 (has rule ALPHA)
  source "$ENGINE/bin/fleet-config.sh"
  source "$ENGINE/packs/cursor/pack.sh"
  HUB="" pack_worker_setup "$WT"
)
mdc="$WT/.cursor/rules/00-fleet-user.mdc"
[ -f "$mdc" ] || fail "cursor fallback rule not written"
grep -q "alwaysApply: true" "$mdc" || fail "cursor rule missing alwaysApply frontmatter"
grep -q "rule ALPHA" "$mdc" || fail "cursor rule missing canonical content"
grep -qxF ".cursor/rules/00-fleet-user.mdc" "$WT/.git/info/exclude" || fail "cursor rule not git-excluded"
echo "PASS: cursor per-worktree fallback (always-apply rule from canonical, git-excluded)"

# --- cursor hub (coordinator) coverage: pack_global_inject on an arbitrary dir ---
HUBDIR="$(mktemp -d)"; git -C "$HUBDIR" init -q
( export FLEET_GLOBAL_AGENTS="$canon"; source "$ENGINE/packs/cursor/pack.sh"; pack_global_inject "$HUBDIR" )
[ -f "$HUBDIR/.cursor/rules/00-fleet-user.mdc" ] || fail "pack_global_inject did not write the hub rule"
grep -q "rule ALPHA" "$HUBDIR/.cursor/rules/00-fleet-user.mdc" || fail "hub rule missing canonical content"
grep -qxF ".cursor/rules/00-fleet-user.mdc" "$HUBDIR/.git/info/exclude" || fail "hub rule not git-excluded"
rm -rf "$HUBDIR"
echo "PASS: pack_global_inject covers an arbitrary dir (hub coordinator)"
