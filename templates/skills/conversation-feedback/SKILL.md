---
name: conversation-feedback
description: Scheduled fleet retro on how the work actually went. Reads the recorded conversations across every project and worker on this machine, distills RECURRING method mistakes into lessons, and files each new lesson back to the queue (per project) plus a dated global digest — so the fix lands where it is front-loaded next time instead of being lost in a log. Report-only. Trigger on the conversation-feedback schedule, or when asked to run the fleet retro / "what did we keep getting wrong".
---

# Conversation-feedback routine (fleet-wide, report-only)

You analyze how the fleet's work actually went and turn it into durable method
improvements. You read conversations; you never change code, never push, never
touch prod. Your only outputs are queue proposals and a local digest. A human
applies them (docs/03, docs/04).

This is the loop that scales *learning* the way the fleet scales *work*: every
session otherwise repeats avoidable mistakes. You catch what recurs and route it
to where it will be read first — `AGENTS.md`, a skill, the global instructions —
through the same proposal path a worker uses.

## 1. Read the input

```
fleet chats --scan --all --parse --json
```

This inventories every recorded conversation on this machine (the hub +
every worktree, every project, every enabled pack) and, for each Claude Code
transcript it can open, attaches a `parsed` block: `counts`
(user_prompts / assistant_turns / tool_use / tool_errors), a `tools` histogram,
the real `user_prompts` (machine chatter already stripped), and `tool_errors`.

Coverage is claude-first: entries without a `parsed` key (other packs, or a
pointer that is not a readable file) are inventory only — note them as
un-analyzed, do not guess their content. Local machine only; do not try to reach
remote machines here.

## 2. Distill lessons (recurring, not one-off)

You are looking for **method** patterns, not a per-session summary. Signal to
weigh:

- **User corrections.** A short follow-up prompt right after the agent acted
  ("no, do it differently", "in French", "don't edit the hub") is the user
  fixing the agent's default. The *second* prompt is the lesson, not the first.
- **Repeated tool errors** across sessions (same command failing, same denied
  write) — a missing durable instruction, not bad luck.
- **Patterns that recur across projects or workers**, not a single incident. One
  slip is noise; the same slip in three sessions is a lesson. The `count` a
  fingerprint accrues in the ledger (step 3) is itself evidence of recurrence.
- **What the durable instructions should have said** so the agent would have got
  it right the first time. That sentence is the deliverable.

Discard: one-offs, user typos, anything you cannot ground in a transcript.
Prefer few high-confidence lessons over a long speculative list.

## 3. Dedup against the seen ledger

For each candidate lesson, build a short **fingerprint** — a stable canonical
phrase for the lesson itself, not this run's wording (e.g.
`worker edits hub instead of filing a proposal`). Then:

```
fleet feedback seen "<fingerprint>"     # exit 0 = already surfaced, 1 = new
```

- **Exit 0 (seen):** do NOT re-file. It is already in the queue or was applied.
  Still record the recurrence so its count and project list stay current
  (`fleet feedback record "<fingerprint>" --project <p>`), and fold it into the
  digest's "still recurring" section — a lesson that keeps coming back after a
  fix is a stronger signal for the human.
- **Exit 1 (new):** proceed to file it (step 4), then
  `fleet feedback record "<fingerprint>" --project <p> --note "<issue id>"`.

The ledger is machine-wide state, not per-project; the same lesson seen in two
projects is one entry tracking both.

## 4a. File each new lesson to the queue (per project)

One lesson = one issue, filed against the project it came from. Resolve the
backend with `fleet-queue` (as `propose-doc-change` does) and follow that skill's
transport details (Linear MCP / GraphQL, `gh issue create`, or `none` → surface
to the user). Labels:

- **`type:doc-proposal`** when the fix is a concrete edit to a trusted doc /
  skill / `AGENTS.md` (front-load the missing instruction).
- **`type:workflow`** when it is a how-we-work retro item with no single target
  file yet.

Plus the umbrella `agent` label. Never create labels; leave state at the default
(never Done); never close your own issue. Tracker language per your global
context, regardless of the conversation language.

Body (routine-shaped — you have no branch/worktree, unlike `propose-doc-change`):

```
## Source
conversation-feedback routine, run <YYYY-MM-DD>, project <name>

## Pattern
<the recurring mistake, one or two lines>

## Evidence
<how often / where: e.g. "3 sessions, 2 projects"; cite a transcript path or a
 quoted user correction. Never paste a whole transcript.>

## Proposed method change
<the durable instruction that should exist, and WHERE it belongs: which
 AGENTS.md / skill / global file. Concrete enough for the coordinator to apply.>
```

## 4b. Write the global digest

Append a dated, machine-wide digest aggregating cross-project method trends
(what recurred most, what is still coming back after a fix, coverage gaps like
un-analyzed non-claude packs). Derive the year from today's date; never hardcode
it. Write it as a local file — the routine's report, not a push:

```
$FLEET_HOME/feedback-digests/<YYYY-MM-DD>.md
```

(`$FLEET_HOME` defaults to `~/.config/fleet`.) This is instance state, never a
repo commit. The digest gives the human the whole-fleet view the per-project
issues cannot.

## Rules (report-only, mechanical)

- Read transcripts; file queue issues; write the digest file. Nothing else.
- Never edit code or a hub doc, never `git push`, never touch prod. If you catch
  yourself about to, stop — that is a worker's job via `resolve-finding`, not
  this routine's.
- Ground every lesson in a transcript. No lesson you cannot cite.
- Do not paste transcript contents into an issue or the digest; summarize and
  cite the path. Transcripts are local and private.
- End by telling the user: issues filed (identifiers), lessons skipped as already
  seen, and the digest path.
