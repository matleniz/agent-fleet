# __REPO__

Private issue queue for **__PRODUCT__**. Issues only, no code; the code lives in
__CODE_REPOS__. Everything here is written in **English**, whoever writes it.

## Who does what

| Actor | Does |
|---|---|
| **Human** (the owner) | Files anything, answers `__NEEDS__`, approves new dependencies and gate changes. |
| **Coordinator** (agent session in the docs hub) | Files and triages issues and epics, dispatches workers through `fleet`, reviews and merges PRs, keeps the docs hub in sync. |
| **Worker** (agent in a code-repo worktree, launched by `fleet`) | Takes one issue, works on a branch, opens one PR, proposes doc changes as `type:doc-proposal` issues. Never edits the docs hub, never merges. |

Agents change an issue's state with `fleet issue` (it keeps the board's Status
column and the `status:*` label in sync): `fleet issue new|start|review|block|done`.

## Lifecycle

1. **Open** = backlog. Every issue has one `type:*`, one `priority:*`, and an `area:*` when it applies.
2. **Start**: add `status:in-progress` and comment `Started by <worker-name>` (`fleet issue start <n>`).
3. **PR**: the PR body says `Closes __SLUG__#<n>`; swap to `status:in-review` (`fleet issue review <n>`).
4. **Done**: the merge closes the issue. Only the coordinator or the human closes by hand (with a comment saying why: `fleet issue done <n> --note "..."`).
5. **Blocked**: `status:blocked` plus a comment naming the blocker (`fleet issue block <n> --note "..."`).
6. **Needs a decision**: `__NEEDS__` plus a `### Decision needed` section listing the options and a recommendation. The human answers in a comment; the coordinator removes the label.

**Epics**: label `type:epic`; the work items are GitHub **sub-issues** of the epic
(`fleet issue new --parent <epic> ...`). Large audits and plans go in the epic body.

## Labels

| Label | Meaning |
|---|---|
| `type:bug` / `type:feature` / `type:improvement` / `type:chore` | kind of work |
| `type:epic` | parent of sub-issues |
| `type:doc-proposal` | proposed edit to a trusted doc (hub, `AGENTS.md`, skill) |
| `type:workflow` | how-we-work item with no single target file |
| `priority:p1-urgent` … `priority:p4-low` | order |
__AREA_ROWS__| `status:in-progress` / `status:in-review` / `status:blocked` | where it stands |
| `__NEEDS__` | waiting for the human's decision |
| `agent` | filed by an agent |

## Issue body

```markdown
## Context
Why this exists, links (issue, PR, doc section, file:line).
## Problem / Goal
## Do
## Acceptance
Commands to run and the expected result.
```

No secrets, tokens or raw personal data in issues, even though the repo is private.
