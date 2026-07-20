#!/usr/bin/env bash
# global.sh — prove `fleet global` installs ONE canonical per-user instructions
# file and wires every capable CLI to it, without touching the real HOME or any
# real agent CLI (HOME is sandboxed; the CLIs are stubbed on PATH so the
# installed-checks pass).
#
# Native wiring: claude @import, opencode symlink, gemini + antigravity share
# ~/.gemini/GEMINI.md (symlink), copilot symlink (~/.copilot/copilot-instructions.md).
# cursor has no user-level global file, so it gets the per-worktree fallback (an
# always-apply .cursor/rules/*.mdc regenerated from the canonical, git-excluded).
# Asserts migration, all wirings, the status report, idempotency, template
# seeding, and the cursor fallback + git-exclude.
set -euo pipefail

ENGINE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

stub="$(mktemp -d)"; H="$(mktemp -d)"; H2="$(mktemp -d)"; WT="$(mktemp -d)"
trap 'rm -rf "$stub" "$H" "$H2" "$WT"' EXIT
for c in claude opencode gemini agy copilot agent; do printf '#!/usr/bin/env bash\nexit 0\n' >"$stub/$c"; chmod +x "$stub/$c"; done
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
{ [ -L "$H/.copilot/copilot-instructions.md" ] && [ "$(readlink -f "$H/.copilot/copilot-instructions.md")" = "$(readlink -f "$canon")" ]; } || fail "copilot copilot-instructions.md not symlinked to canonical"
echo "PASS: migration + claude @import + opencode/gemini/antigravity/copilot symlinks (backups kept)"

# --- status report ---
out="$(run "$H" global status 2>/dev/null)"
for p in claude opencode gemini antigravity copilot; do echo "$out" | grep -qE "$p +wired" || fail "$p not reported wired ($out)"; done
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

# --- fleet global skills: engine templates -> per-user install + claude symlink ---
H3="$(mktemp -d)"; trap 'rm -rf "$stub" "$H" "$H2" "$WT" "$H3"' EXIT

# status on a fresh HOME: everything not-installed
out="$(run "$H3" global skills 2>/dev/null)"
grep -q "dispatch-work.*not-installed" <<<"$out" || fail "skills status: dispatch-work should be not-installed (got: $out)"

# sync one skill: canonical install + claude per-skill symlink
run "$H3" global skills sync dispatch-work >/dev/null 2>&1 || fail "skills sync dispatch-work errored"
[ -f "$H3/.agents/skills/dispatch-work/SKILL.md" ] || fail "sync did not install the canonical copy"
[ -L "$H3/.claude/skills/dispatch-work" ] || fail "sync did not create the claude symlink"
[ "$(readlink -f "$H3/.claude/skills/dispatch-work")" = "$(readlink -f "$H3/.agents/skills/dispatch-work")" ] \
  || fail "claude symlink points to the wrong place"
out="$(run "$H3" global skills 2>/dev/null)"
grep -q "dispatch-work.*in-sync.*claude:linked" <<<"$out" \
  || fail "skills status: freshly synced skill should be in-sync + linked"

# local customization shows as drift; a named sync replaces it and keeps a .bak
echo "LOCAL TWEAK" >> "$H3/.agents/skills/dispatch-work/SKILL.md"
out="$(run "$H3" global skills 2>/dev/null)"
grep -q "dispatch-work.*drifted" <<<"$out" || fail "skills status: local edit should show drifted"
run "$H3" global skills sync dispatch-work >/dev/null 2>&1 || fail "re-sync errored"
grep -q "LOCAL TWEAK" "$H3/.agents/skills/dispatch-work.bak/SKILL.md" || fail "re-sync lost the previous copy (.bak missing the local edit)"
diff -rq "$ENGINE/templates/skills/dispatch-work" "$H3/.agents/skills/dispatch-work" >/dev/null || fail "re-sync did not restore the template content"

# a pre-existing REAL dir at ~/.claude/skills (hand copy) is converted to a symlink, backup kept
rm -f "$H3/.claude/skills/dispatch-work"
mkdir -p "$H3/.claude/skills/dispatch-work"; echo "OLD HAND COPY" > "$H3/.claude/skills/dispatch-work/SKILL.md"
run "$H3" global skills sync dispatch-work >/dev/null 2>&1 || fail "sync over hand copy errored"
[ -L "$H3/.claude/skills/dispatch-work" ] || fail "hand copy not converted to a symlink"
grep -q "OLD HAND COPY" "$H3/.claude/skills/dispatch-work.bak/SKILL.md" || fail "hand copy not backed up"

# guardrails: no bulk no-name sync; unknown skill errors
run "$H3" global skills sync >/dev/null 2>&1 && fail "sync with no name should error (no silent bulk sync)"
run "$H3" global skills sync no-such-skill >/dev/null 2>&1 && fail "sync of an unknown skill should error"

# --all installs every template skill
run "$H3" global skills sync --all >/dev/null 2>&1 || fail "sync --all errored"
for d in "$ENGINE"/templates/skills/*/; do
  s="$(basename "$d")"
  [ -f "$H3/.agents/skills/$s/SKILL.md" ] || fail "--all missed skill $s"
done
echo "PASS: fleet global skills (status drift, targeted sync + .bak, claude symlink convergence, --all)"
