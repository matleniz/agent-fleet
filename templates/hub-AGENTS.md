# Template: <hub>/AGENTS.md (project-level, read at session start)

> This folder is opened as a working directory but it is NOT the code: it is the
> documentation hub. The code lives in `<code-repo>`.
>
> AGENTS.md is the single source: Codex, opencode, and GitHub Copilot read it
> natively, Gemini via `.gemini/settings.json` (`context.fileName`), and Claude
> Code through the one-line bridge `CLAUDE.md` containing `@AGENTS.md` (both
> seeded by fleet-init).

Fill in and trim:

```markdown
# Repo context — <hub name>

## What this is
<hub> is the reference documentation for <system>. It is the source of truth for
the architecture. See INDEX.md to navigate and README.md for the full plan.

## Where the code lives (not here)
The application code is in `<code-repo>` (path). All code changes happen there,
not here.

## Architecture in brief
<a few lines: the main components and how they talk>

## Your fleet — dispatching workers
You are the COORDINATOR: you write the docs and dispatch code work; you do not
edit the real code yourself. From this hub:
- `fleet-queue` — this project's work queue (backend + coordinates). Run it FIRST
  to see where issues go; it is whatever `fleet-queue` reports (Linear, GitHub
  Issues, or none), not what another project uses.
- `fleet w <name>` — spawn/reopen a worker worktree (one coherent task = one
  worker; batch small tasks that share a context into one warm worker).
- `fleet dispatch <name> "<task>"` — headless worker (worktree + detached run)
  when you are an agent, not a human at a keyboard.
- `fleet -a <pack> w <name>` — pick the agent CLI for that worker. `fleet
  agents` lists the packs enabled for this project; `fleet doctor` shows which
  are installed and logged in.
- `fleet r w <name>` — same, on the project's always-on VM (if configured).
- `fleet ls` — worktrees + per-pack session markers; `fleet status` for the
  worker tree, commits, and queue; `fleet prune` at checkpoints to drop merged
  worktrees.
- `fleet chats [<worker>]` — per-pack pointer to the conversation recorded in a
  worktree (bare = this hub, i.e. your own session). When you switch a worker's
  agent, or one dies mid-task (crash, credit limit), read the prior transcript to
  reprise what never made it into the hub. Sessions are NOT portable between CLIs,
  so READ the pointer, do not resume it — and fold anything worth keeping back
  into the hub, the durable handoff.

Building something across several workers? Use the `dispatch-work` skill: it
partitions the work by **file ownership, not pipeline phase** (streams that share
a file are not independent and their PRs collide), files one issue per stream,
dispatches one worker/branch/PR each, and sequences the merges. A single coherent
change stays in ONE worker; parallelize only across streams that touch disjoint
files.

## Conventions
- Verify facts against the code (`grep`/`ls` in <code-repo>) before asserting.
  Do not guess endpoints/flags/names.
- Docs have one writer (the coordinator). Workers are read-only here.
- Navigate cheaply: INDEX first, one file, grep sections. Do not load everything.
- Hub freshness: detect and flag drift, do not rewrite the whole hub. When you
  touch code and find the hub wrong or silent, flag it (worker → propose-doc-change
  queue with the file:line proof; coordinator → fix at a checkpoint). Never assert
  a hub fact you just saw contradicted. Target trusted-fact docs (index,
  architecture, schemas, endpoints); dated journals stay historical. No systematic
  or real-time updating: drift is merge-driven, so the update rides the PR.
```
