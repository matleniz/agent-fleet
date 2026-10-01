# 03 — The queue: one inbox, humans apply

Every proposal from any agent lands in **one** place: a single tracker used as
an agent queue. The first-class backend is **GitHub Issues** — one private
issues repo per product plus a GitHub Project board — driven by `fleet issue`
(below). Linear (`QUEUE_KIND=linear`) still works as a **legacy** backend: the
skills keep a Linear branch, but `fleet issue` does not drive it. Issues are
labeled so triage is fast.

## Why a queue instead of live agent chat

The native "agent teams" feature lets agents message each other live. It works,
but every inter-agent message is a round trip through the model, so a 3-teammate
team burns roughly 3-4x the tokens of one session doing the work sequentially.
Live conversation is also re-sent each turn and defeats caching.

A queue is the frugal alternative. It is a **durable, structured handoff**:

- Written once, read when needed. Not re-sent every turn.
- Structured (fixed fields, labels), so it is unambiguous. This is the *good*
  version of "caveman" terseness: compress the handoff into a schema, not into
  terse prose. Terse prose saves a few tokens and buys ambiguity, and ambiguity
  causes rework, the most expensive outcome. A structured contract saves the
  tokens without the ambiguity.
- Asynchronous. The coordinator triages on its own schedule; workers pull when
  free.

This structured contract principle applies at two scopes:
- **Across branches and issues**: the tracker queue (GitHub Issues; Linear as legacy) coordinates the coordinator and workers asynchronously.
- **Within a worktree**: `HANDOFF.md` (template in `templates/HANDOFF.md`) coordinates switching agent CLIs or resuming paused sessions across context boundaries. Its 7-field schema (`task`, `status/result`, `reason`, `constraints`, `next steps`, `files touched`, `how to verify`) replaces unstructured inter-agent prose or re-reading long raw transcripts (see [02](02-roles-and-barrier.md)).

## The private issues repo pattern

Code repos can be public; the queue should not be. Each product gets its own
**private** issues repo (`<owner>/<product>-issues`: issues only, no code) and
one **GitHub Project board** linked to it. Findings, security notes and half-baked
plans stay private while the code ships in the open, and one product's queue
never mixes with another's. A PR in the (public) code repo closes the issue across
repos with `Closes <owner>/<product>-issues#<n>` in its body.

The project `.env` points at it (`templates/fleet.env`):

```bash
QUEUE_KIND="github"
QUEUE_GITHUB_REPO="<owner>/<product>-issues"
QUEUE_GITHUB_PROJECT="<board number>"     # GitHub Projects v2 number
# QUEUE_GITHUB_PROJECT_OWNER="<org>"      # board owner, default = repo owner
# QUEUE_NEEDS_LABEL="needs:<you>"         # "a human must decide" label, default needs:human
```

### Bootstrap a new queue repo

```bash
fleet --project <p> issue bootstrap --create \
  --area "cli=bin/, the CLI" --area "docs=docs/, README"
```

Idempotent. It creates the repo (private, only with `--create`), applies the
label taxonomy below (`--force`: existing labels are updated, not duplicated),
writes the conventions `README.md` (from `templates/queue-README.md`) and the
issue forms (`.github/ISSUE_TEMPLATE/`) when absent (`--overwrite` rewrites
them), creates or reuses the board (found by `QUEUE_GITHUB_PROJECT`, else by
title; `--board-title`, default the product name), links it to the repo, sets
its Status options to the five columns, then prints the `.env` lines to paste.
A board whose Status options differ is not rewritten unless `--reset-columns`
(rewriting the options resets existing items' column). Needs `gh` with the
`project` token scope (`gh auth refresh -s project`). `fleet init` prints this
command for a new github-queue project.

## Labels (the taxonomy)

Same names in every queue repo, so humans, the coordinator and workers filter
the same way everywhere:

| Label | Meaning |
|---|---|
| `type:bug` / `type:feature` / `type:improvement` / `type:chore` | kind of work |
| `type:epic` | parent issue; its work items are GitHub **sub-issues** |
| `type:doc-proposal` | proposed edit to a trusted doc (hub, `AGENTS.md`, a skill) |
| `type:workflow` | how-we-work item with no single target file |
| `priority:p1-urgent` … `priority:p4-low` | order |
| `area:*` | per product (e.g. `area:cli`, `area:docs`), set at bootstrap |
| `status:in-progress` / `status:in-review` / `status:blocked` | where it stands (mirrors the board) |
| `needs:human` (`QUEUE_NEEDS_LABEL`) | waiting for a human decision |
| `agent` | filed by an agent (worker, coordinator, retro) |

Every issue has one `type:*`, one `priority:*`, and an `area:*` when it applies.
The body uses four sections: `## Context` (why, links, file:line), `## Problem /
Goal`, `## Do`, `## Acceptance` (commands and expected result). A `needs:*`
issue also carries a `### Decision needed` section listing the options and a
recommendation.

## Lifecycle and `fleet issue`

Status lives in two places that must agree: the board's **Status** column
(Backlog / In progress / In review / Blocked / Done) and one `status:*` label.
Agents never hand-roll `gh project` GraphQL for that; one `fleet issue` call
moves both and posts the lifecycle comment:

| Step | Command | Board | Label | Comment |
|---|---|---|---|---|
| file | `fleet issue new --type T --priority P [--area A] [--parent N] [--needs-human] "<title>" <body-file\|->` | Backlog | type/priority/area + `agent` | — (sub-issue of N) |
| start | `fleet issue start <n> [--note ..]` | In progress | `status:in-progress` | `Started by <worker>` |
| PR open | `fleet issue review <n> [--note ..]` | In review | `status:in-review` | the note, if any |
| blocked | `fleet issue block <n> --note "<blocker>"` | Blocked | `status:blocked` | `Blocked: <blocker>` |
| done | merge of the PR (`Closes <repo>#<n>`) | Done | cleared | — |
| close by hand | `fleet issue done <n> --note "<why>"` | Done | cleared | the why (closes it) |

`<worker>` is the worktree name (the coordinator in the hub; `--by` overrides).
Only the coordinator or the human closes an issue by hand; a worker's issue is
closed by the merge. Without `QUEUE_GITHUB_PROJECT` the commands still set labels
and comments and warn that the board was not updated. `fleet issue` refuses any
`QUEUE_KIND` other than `github`.

Who does what: the **human** files anything and answers `needs:*`; the
**coordinator** files and triages issues and epics, dispatches workers, reviews
and merges; a **worker** takes one issue, opens one PR, files doc changes as
`type:doc-proposal`, never edits the hub, never merges.

### Linear (legacy)

`QUEUE_KIND=linear` + `QUEUE_LINEAR_TEAM` / `QUEUE_LINEAR_PROJECT_ID` /
`QUEUE_LINEAR_PROJECT_NAME` keeps working for projects already on it: the skills
file and update issues through the Linear MCP/API, with the same `type:` labels
and lifecycle in Linear's own workflow states. There is no `fleet issue` for it.

## One tracker language

Pick one language for everything written to the tracker (issues, titles,
descriptions, comments) and hold to it regardless of the language the operator is
talking in. A mixed-language queue is hard to triage and search. This is a
convention the agents drift off during long runs, so state it in the hub's
AGENTS.md and, for determinism, back it with a before-tool hook reminder on the
tracker's write tools (see [04](04-routines.md) for the hook pattern). Keep it a
reminder, not a hard non-ASCII block — that false-positives on accented proper
nouns. Repo docs are separate: they follow each repo's own language.

## Two hard rules

1. **Report, never auto-apply.** Agents propose. A human applies. No routine
   pushes code or touches production.
2. **One inbox.** Deduped. Triaged on a cadence (e.g. each morning). The
   coordinator integrates or closes.

## Finding lifecycle

```
  routine / review          the queue               worker              remote
  ────────────────    →    ────────────    →    ────────────    →    ────────
  finds an issue           issue created         new-worker           branch
  (report only)            + label + dedup       resolve-finding      + PR
                                                  verify → fix →       (human
                                                  test → PR            merges)
```

Two skills sit on this pipeline:

- `propose-doc-change` (worker side): from a worktree, file a doc change as a
  queue issue instead of editing the hub.
- `resolve-finding` (worker side): take one issue, verify it against the code,
  branch, fix, run the project's declared checks in one shot (`fleet gate`,
  no-op if none are declared — see [06](06-token-economy.md)), test with a
  regression, open a PR, update the issue. Out-of-scope work (someone else's
  area, an infra repo) is handed back, not forced.

On the coordinator side, two skills:

- `process-agent-queue` (inbound triage): read the queue, dedup, label, integrate
  doc proposals into the hub, dispatch existing code findings to workers.
- `dispatch-work` (outbound planning): when the coordinator has a new piece of work
  to build across several workers, partition it by **file ownership, not pipeline
  phase** (streams that share a file are one stream or a dependency chain, never
  parallel), file one issue per stream, dispatch one worker/branch/PR each, and
  sequence the merges. The same queue, driven from the planning end.

## Keeping the hub fresh (without rewriting it constantly)

A stale hub is worse than no hub: agents assert false facts from it, and the
whole cheap-context win collapses because everything has to be re-verified. But
updating docs in real time is expensive and mostly wasted. The resolution follows
the same event-first principle as routines:

- **Detection is a norm, not a task.** A standing rule (in the hub's AGENTS.md):
  when a session touches code and finds the hub wrong or silent, it *flags* the
  drift (worker → `type:doc-proposal`), it does not rewrite the hub. Detection is
  near-free because the session is already in that code; this turns every session
  into a sensor.
- **The real trigger is the merge.** Doc drift is caused by a change landing. So
  a PR that alters a behavior the hub describes files its doc-proposal in the same
  pass (part of "done"). The update rides the event that caused the drift.
- **The coordinator fixes a queue, not a vibe.** It processes accumulated
  `type:doc-proposal` items at a checkpoint (end of a batch, before relying
  heavily on the hub, before a release), applying a known list instead of
  rediscovering drift.
- **A low-frequency drift-audit routine is the backstop only** ([04](04-routines.md)),
  catching what nobody flagged. Not the primary mechanism.
- **Target trusted-fact docs.** Index, architecture, schemas, endpoints must be
  fresh; dated journals stay historical under a dated banner. Do not spend
  freshness effort on the whole hub.
