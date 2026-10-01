---
name: dispatch-work
description: Coordinator role. Break a piece of work too big for one coherent change into non-overlapping parallel workstreams, file each as a queue issue, dispatch one worker (branch + PR) per stream, and sequence merges so the PRs do not conflict. Use when you have new work to build across several workers (a feature, a migration, a multi-part change) and want to parallelize it safely. Runs fleet-queue to find the project's queue first.
---

# Dispatch a batch of work (coordinator role)

You have a piece of work to build. This skill turns it into parallel workstreams
that land as clean, non-conflicting PRs. It is the FORWARD-planning counterpart of
`process-agent-queue` (which triages findings that come IN) and `resolve-finding`
(which a worker runs on ONE issue).

## First: should this be parallel at all?

Parallelism is across **independent workstreams, never inside one coherent change**
(see docs 01 and 06). Before splitting, check the shape:

- **One coherent change** (write-heavy, one consistent context, touching a shared
  core file): keep it in ONE worker, ONE branch, ONE PR. Splitting it loses context
  and causes rework, the most expensive outcome. Do NOT manufacture parallelism.
- **Several workstreams that touch DISJOINT files**: parallelize. This is the case
  this skill is for.

The test is **file ownership, not conceptual phases**. A "research / crawl /
correlate / verify" split whose stages all edit the same `scan.py` is NOT
independent: those are phases of one change, and parallel workers on them collide.
Partition by the FILES each stream writes, not by the steps of the pipeline.

## Steps

1. **Find the queue.** Run `fleet-queue` for this project's backend and coordinates:
   - `QUEUE_KIND=github` (the default) → the private issues repo
     `QUEUE_GITHUB_REPO` + its board; file and move issues with `fleet issue`
     (never hand-roll `gh project` calls). Conventions: the issues repo's README.
   - `QUEUE_KIND=none` → no tracker; track the streams yourself and brief workers
     directly. Everything below still applies except the issue-filing.
   - `QUEUE_KIND=linear` (legacy) → the configured Linear team/project, through
     its MCP/API (no `fleet issue`).

   Do this first, every time. The queue is wherever `fleet-queue` says, not where
   you assume (it is not the tracker some other project uses).

2. **Partition by file ownership.** Express the work as a set of streams where no
   two write the same file. If two must touch the same file, they are NOT
   independent: either fold them into one stream, or make one depend on the other
   (sequence, do not parallelize). State each stream's file scope explicitly.

3. **File one issue per stream** in the queue. Each issue states, in the four
   standard sections (`## Context` / `## Problem / Goal` / `## Do` /
   `## Acceptance`): the scope (which files/module), what "done" means (commands
   + expected result), and any dependency on another stream's issue. A batch of
   streams is an **epic**: file the parent first, then each stream as its
   sub-issue. On github:
   ```bash
   fleet issue new --type epic --priority p2 "<the whole piece of work>" epic.md
   fleet issue new --type feature --priority p2 --area <area> --parent <epic-n> \
     "<stream title>" stream.md        # repeat per stream; prints the issue URL
   ```
   (`--type bug|feature|improvement|chore|...`, `--priority p1..p4`; `agent` is
   added for you; `--needs-human` + a `### Decision needed` section when the human
   must choose first.) Tracker language per your global context file (English by
   default).

4. **Dispatch one worker per independent stream.** A worker that is itself an agent
   is dispatched headless:
   `fleet dispatch <name> "run resolve-finding on issue <id>"`
   (use `fleet w <name>` instead if you are a human driving interactively). One
   stream = one worker = one branch = one PR. Add `--machine <vm>` to run the
   worker on a VM (delegated to its container) or `--model <m>` to pick its model,
   and `--scope '<globs>' --checks scope:blocking` to pin the stream's file
   ownership. The worker claims the issue (`fleet issue start <n>`), and its PR
   body carries `Closes <QUEUE_GITHUB_REPO>#<n>` so the merge closes it; tell it
   so in the brief if it does not run `resolve-finding`.
   Streams with a dependency wait: dispatch the upstream first, dispatch the
   downstream only once the upstream PR has merged.

5. **Track via the queue + fleet.** `fleet status` shows each worker's commits above
   base and flags a finished worker that produced none (`[empty: finished, no
   commits]`); rc=0 is process-exited, not a delivered result. `fleet wait
   [<name>]` blocks until workers finish. Follow each PR and its checks through the
   queue (the board shows In progress / In review / Blocked at a glance).

6. **Sequence the merges.** Independent PRs merge in any order. A dependency chain
   merges upstream-first; the downstream worker rebases on the merged base and
   re-runs its tests. Keep each PR small and file-scoped so the merges stay clean.

## Rules

- Every launch goes through `fleet` (`fleet dispatch` / `fleet w`). NEVER launch
  an agent CLI by hand (raw `claude`/`gemini`/`tmux new-window`) and never hand
  the human a launch script that does — the `fleet` launch carries the posture
  (permission mode, read-only-hub barrier, MCP profile, resource guard) and a
  hand launch silently loses all of it. A batch script is fine only if every
  line is a `fleet` command.
- Parallelize across independent workstreams; never split one coherent change.
- Partition by file ownership, not by pipeline phase.
- One stream = one issue = one worker = one branch = one PR.
- Run `fleet-queue` first; use the queue it reports, not the one you assume.
- Tracker language is fixed (your global context file), regardless of the
  conversation language.
- Dispatch and report; do not merge production changes yourself without the human's
  go (docs 03: humans apply).
- Cross-pack handoffs: when switching an in-progress worktree from one agent CLI
  to another, ensure `HANDOFF.md` (from `templates/HANDOFF.md`) is written in the
  worktree so the receiving agent picks up the state cleanly.
