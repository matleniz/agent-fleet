# Worktree Handoff

> **Convention (cross-CLI handoff).** Sessions and conversation memory are
> proprietary to each CLI (Claude Code, Gemini CLI, Cursor, Opencode,
> Antigravity, Copilot) and cannot be loaded across agents. When switching
> agents in a worktree or pausing an in-progress task, write this file at the
> worktree root (`HANDOFF.md`). The receiving agent reads it first to acquire
> state instantly without re-reading transcripts or guessing intent.
>
> **Lifecycle:** `HANDOFF.md` is local working state only and must NOT be committed
> to the PR. Delete it or exclude it via `.git/info/exclude` before opening or
> updating the PR; the final summary belongs in the PR description.
> See `docs/02-roles-and-barrier.md` and `docs/03-queue.md`.

## Task
- **Ref / Ticket**: <!-- e.g. ABC-123, issue #42, or finding ID -->
- **Objective**: <!-- What the worktree is intended to achieve, scope, expected outcome -->

## Status & Result
- **Status**: <!-- completed | in-progress | blocked | failed -->
- **Result**: <!-- Concrete deliverable / outcome achieved so far, what was produced or changed -->

## Reason
<!-- Why the handoff is taking place (e.g. task completed, blocked on missing API key/credential,
context boundary reached to prevent compaction, switching CLI for specific capabilities
like IDE editing, mount-namespace isolation, or different reasoning model). -->

## Constraints
<!-- Invariants, barriers, conventions, and out-of-bounds files -->
- **Barrier**: <!-- e.g. hub read-only barrier active (never edit hub from worktree) -->
- **Conventions**: <!-- e.g. bash + python stdlib only, zero external deps, docs updated in same PR -->
- **Scope boundaries**: <!-- specific files or subsystems that must NOT be modified -->

## Next Steps
<!-- Ordered, actionable steps for the receiving agent -->
1. <!-- Next immediate step -->
2. <!-- Follow-up step -->
3. <!-- Final verification / PR opening (delete or exclude HANDOFF.md via .git/info/exclude before PR; put final summary in PR description) -->

## Files Touched
<!-- Modified, added, or deleted files with a short description of each change -->
- `path/to/file`: <!-- added | modified | deleted — summary of change -->

## How to Verify
<!-- Exact commands to test and verify the current worktree state -->
```bash
# Example verification commands:
fleet gate
bash test/relevant-test.sh
```
