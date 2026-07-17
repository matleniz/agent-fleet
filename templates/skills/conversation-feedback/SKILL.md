---
name: conversation-feedback
description: Stage C of the fleet retro (docs/04). Reads the compressed session notes (stage B, conversation-compress) — not raw transcripts — distills RECURRING method mistakes into lessons, dedups them against the seen ledger, and files each new lesson back to the queue (per project) or the digest (fleet-wide / upstream). Report-only. The reasoning can run local or elsewhere (FEEDBACK_RUNNER); dedup, filing, and the digest always run LOCAL. Trigger on the distill schedule, or when asked to run the fleet retro / "what did we keep getting wrong".
---

# Conversation-feedback routine (stage C: distill + finalize, report-only)

You turn the fleet's compressed session notes into durable method improvements.
You read **notes**, not raw transcripts (stage B, `conversation-compress`, already
compressed them). You never change code, never push, never touch prod. Your outputs
are queue proposals and a local digest. A human applies them (docs/03, docs/04).

This is the loop that scales *learning* the way the fleet scales *work*: every
session otherwise repeats avoidable mistakes. You catch what recurs and route it to
where it will be read first — `AGENTS.md`, a skill, the global instructions.

## 0. Know your runner

```
fleet feedback config
```

reports `FEEDBACK_RUNNER` (local | ssh | cloud), `FEEDBACK_MODEL_DISTILL`, and the
notes/digests dirs. The **reasoning** in steps 1-2 (notes → candidate lessons) is
the only part that can run off-box:

- **local** (default): do it all in this session.
- **ssh / cloud**: ship the notes (with `transcript` paths stripped — they are
  private) to the runner, get candidate lessons back. The transport is instance-side
  wiring (docs/04); if it is not set up, fall back to reasoning locally.

**Dedup (the ledger), filing, and the digest (steps 3-4) ALWAYS run local**, here,
because they touch the machine-wide ledger and the queue backend's credentials —
neither leaves the box. A cloud runner only ever returns candidate lessons.

## 1. Read the notes

Read every `*.json` under the notes dir (`fleet feedback config` →
`FEEDBACK_NOTES_DIR`, default `$FLEET_HOME/feedback-notes/`). Each note is a
compressed session: `corrections`, `recurring_errors`, a `candidate_lesson`, its
`project`/`role`/`worktree`, and a local `transcript` path for citation.

If the notes dir is empty or stale, stage B has not run — say so and stop; do not
fall back to raw transcripts (that is B's job, and it must run local + cheap).

## 2. Distill lessons (recurring, not one-off)

You are looking for **method** patterns across notes, not a per-session summary:

- **User corrections** that repeat — the same default being fixed in several
  sessions. The correction is the lesson.
- **Repeated tool errors** across sessions (same command failing, same denied
  write) — a missing durable instruction, not bad luck.
- **Patterns that recur across projects or workers**, not a single incident. One
  slip is noise; the same slip in three sessions is a lesson. A fingerprint's
  ledger `count` (step 3) is itself evidence of recurrence.
- **What the durable instructions should have said** so the agent would have got it
  right the first time. That sentence is the deliverable.

For each lesson decide its **target**:

- `project` — specific to one project; belongs in that project's `AGENTS.md` / hub /
  skill. Files to that project's queue (step 4a).
- `global` — fleet-wide method, belongs in the per-user global instructions
  (`~/.agents/AGENTS.md`) or a personal skill. Goes to the digest (step 4b), not a
  queue.
- `upstream` — a generic lesson about the fleet tooling itself, worth sending to the
  public agent-fleet repo. Goes to the digest's upstream-candidates section (step
  4b), **never auto-filed** (the repo is public and must stay project-name-free; you
  sanitize and open the issue by hand).

Discard: one-offs, user typos, anything you cannot ground in a note. Prefer few
high-confidence lessons over a long speculative list.

## 3. Dedup against the seen ledger

For each candidate lesson, build a short **fingerprint** — a stable canonical phrase
for the lesson itself, not this run's wording (e.g.
`worker edits hub instead of filing a proposal`). Then:

```
fleet feedback seen "<fingerprint>"     # exit 0 = already surfaced, 1 = new
```

- **Exit 0 (seen):** do NOT re-file. Still record the recurrence so its count and
  project list stay current (`fleet feedback record "<fingerprint>" --project <p>`)
  and fold it into the digest's "still recurring" section — a lesson that keeps
  coming back after a fix is a stronger signal for the human.
- **Exit 1 (new):** file it (step 4), then
  `fleet feedback record "<fingerprint>" --project <p> --note "<issue id or 'digest'>"`.

The ledger is machine-wide and target-agnostic; the same lesson seen in two projects
is one entry tracking both.

## 4a. File each new `project` lesson to the queue

One lesson = one issue, filed against the project it came from. Resolve the backend
with `fleet-queue` (as `propose-doc-change` does) and follow that skill's transport
details (Linear MCP / GraphQL, `gh issue create`, or `none` → surface to the user).
Labels: **`type:doc-proposal`** for a concrete edit to a trusted doc / skill /
`AGENTS.md`; **`type:workflow`** for a how-we-work item with no single target file.
Plus the umbrella `agent` label. Never create labels; leave state at the default;
never close your own issue. Tracker language per your global context.

Body (routine-shaped — you have no branch/worktree, unlike `propose-doc-change`):

```
## Source
conversation-feedback routine, run <YYYY-MM-DD>, project <name>

## Pattern
<the recurring mistake, one or two lines>

## Evidence
<how often / where: e.g. "3 sessions, 2 projects"; cite a transcript path from a
 note or a quoted correction. Never paste a whole transcript.>

## Proposed method change
<the durable instruction that should exist, and WHERE it belongs: which
 AGENTS.md / skill / global file. Concrete enough for the coordinator to apply.>
```

## 4b. Write the global digest

Append a dated, machine-wide digest. Derive the year from today's date; never
hardcode it. Write it as a local file (`fleet feedback config` → `FEEDBACK_DIGESTS_DIR`,
default `$FLEET_HOME/feedback-digests/<YYYY-MM-DD>.md`) — the routine's report, never
a push. It carries the whole-fleet view the per-project issues cannot, and it is the
home for the two targets that have no queue:

```
# Fleet feedback digest — <YYYY-MM-DD>

## Cross-project trends
<what recurred most, across which projects>

## Still recurring (filed before, back again)
<seen-ledger hits with high count — a fix that did not take>

## Global lessons (apply to ~/.agents/AGENTS.md or a personal skill)
<each `global`-target lesson: the pattern + the durable instruction + where it
 belongs. This is your actionable list — you apply these by hand.>

## Upstream candidates for agent-fleet (sanitize, then file by hand)
<each `upstream`-target lesson, stated generically with ZERO project/company/repo
 names — a method or tooling improvement to the fleet itself. Never auto-filed.>

## Coverage gaps
<packs left un-analyzed (no parser yet), stale notes, anything skipped>
```

## Rules (report-only, mechanical)

- Read notes; file queue issues; write the digest file. Nothing else.
- Never edit code or a hub doc, never `git push`, never touch prod, never auto-file
  to the public agent-fleet repo. If you catch yourself about to, stop — that is a
  worker's job via `resolve-finding`, not this routine's.
- Ground every lesson in a note (which cites its transcript). No lesson you cannot
  cite.
- Do not paste transcript contents into an issue or the digest; summarize and cite
  the path. Notes and transcripts are local and private; strip transcript paths
  before any payload leaves the machine.
- End by telling the user: issues filed (identifiers), lessons skipped as already
  seen, global + upstream lessons written to the digest, and the digest path.
