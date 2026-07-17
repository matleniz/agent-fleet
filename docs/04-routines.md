# 04 — Scheduled reviews (routines)

Standing reviews run on a schedule and file findings into the queue. This is
where extra agents genuinely pay off: reviews are read-heavy and exploratory, the
regime where context isolation across agents saves more than it costs (see
[06](06-token-economy.md) on the research vs coding split).

## The design principles

- **Event first, cron second.** Review at the PR when a natural trigger exists.
  Reserve cron for standing work with no trigger (a periodic security audit, a
  retro).
- **Report, never apply.** A routine proposes into the queue. A human applies.
  No routine pushes code or touches production. Make this *mechanical*: scope the
  routine's allowed tools so it physically cannot post code or write prod, not
  just so it is told not to.
- **Cadence tracks churn**, not "one per day". More frequent than the code
  changes is pure noise and wasted tokens. Rotate (e.g. security one day,
  refactor another, retro weekly).
- **Load the method from the hub.** A routine should load its skill from the
  versioned hub, not freeze a prompt in the cron config. Then improving the skill
  improves every future run.

## Cloud vs local

```
  ┌──────────────── CLOUD (scheduled agents, report-only) ─────────────┐
  │  Clones the repos from the remote. Has NO local uncommitted state,   │
  │  NO prod SSH keys, NO local-only repos.                              │
  │  Good for: reviews of committed code (security, refactor, feature).  │
  └────────────────────────────────────────────────────────────────────┘
  ┌────────────── LOCAL (session-start hook, detached) ─────────────────┐
  │  Runs on your machine when it is up. Has local files and prod access.│
  │  Needed for: anything reading local-only data (session transcripts,  │
  │  a local infra repo) or touching prod.                               │
  └────────────────────────────────────────────────────────────────────┘
```

Route each routine by what it needs to read. If it only needs committed code,
cloud. If it needs local files or prod, local via a session-start hook that
fires a detached job (throttled so it does not run every session). Not every
pack's CLI has one: Claude Code and Gemini expose `SessionStart`, opencode has
plugins; the Cursor CLI and Antigravity expose no such hook, and Copilot's fires
only from user/system-global config (its repo-level hooks are deferred and never
run in headless mode) — verified on the installed versions. With those packs,
schedule the local job outside the CLI (cron) instead.

## Model choice per routine

Use a stronger model for judgment-heavy passes (refactor proposals, feature
scans against the state of the art) and a cheaper one for the rest (a proven
security checklist, a digest). This mirrors the general tiering: strong model for
the orchestrator and for judgment, cheap model for mechanical work.

## Two gotchas (learned the hard way)

- A permission classifier (Claude Code's auto mode, and any CLI that vets tool
  calls) **blocks a routine that writes to an external system** if you meant it
  to be report-only. Keep report-only routines mechanically report-only (scope
  the tools so they *cannot* post) and it passes.
- Such a classifier also **refuses to let the agent itself wire up a
  permissions-bypassing agent**. A human launches that validation run and
  installs the hook. In production the hook spawns the worker as a detached
  process, out of the classifier's reach.

## A starter set of routines

- **Security audit** (cloud, weekly): clone repos → security skill → findings to
  queue as `type:security`.
- **Refactor audit** (cloud, weekly): static tools (linters, dead-code,
  complexity, duplication) → synthesized proposals as `type:refacto`.
- **Feature scan** (cloud, monthly): repo direction vs the state of the art found
  by web research, sources mandatory → `type:feature`.
- **Conversation-feedback** (local, weekly): the shipped workflow-retro routine.
  Reads how the work actually went across **every** project and worker on the
  machine and turns recurring method mistakes into durable fixes, not a one-off
  report. Skill: `conversation-feedback` (in `templates/skills/`, load it from the
  hub). Input: `fleet chats --scan --all --parse --json` — a fleet-wide inventory
  of every pack's recorded conversation plus, for each Claude transcript, a parsed
  method signal (user corrections, tool errors, tool histogram; claude-first,
  other packs are inventory-only until their parser lands). Dedup: a machine-wide
  "seen ledger" (`fleet feedback seen/record`, stored at
  `$FLEET_HOME/feedback-seen.json`) so the same lesson is not re-filed every run —
  a lesson's recurrence count is itself signal. Output is **hybrid**: one queue
  proposal per new lesson against the project it came from (`type:doc-proposal`
  for a concrete doc/skill/AGENTS.md edit, `type:workflow` for a how-we-work item,
  via the same `propose-doc-change` backend path), **plus** a dated global digest
  under `$FLEET_HOME/feedback-digests/<date>.md` for the whole-fleet view the
  per-project issues cannot give. Report-only and mechanical: the skill only reads
  transcripts, files issues, and writes the digest file — it cannot push or edit
  the hub. Local because transcripts are local and private; schedule it as a
  local job (SessionStart hook on claude/gemini, else OS cron), throttled, with a
  human launching the first validation run and installing the hook (a permission
  classifier refuses to let an agent wire up its own bypassing agent — see the
  gotchas above). Below, the older workflow-retro framing it generalizes:
- **Workflow retro** (local, weekly): read how the work actually went (queue
  health, hub structure, skills freshness, session transcripts if local) → a
  dated report. Local because transcripts are local and private. Once the fleet
  engine lives in its own repo (this one, shared by every project) separately from
  a project's hub instance, add it as a signal source: the engine repo's freshness
  and, above all, **drift between the canonical engine (`bin/`, `docs/`, the
  `templates/skills/`) and what a project seeded into its hub** (coordinator
  skills, workflow docs). That drift is invisible to a hub-only or transcript-only
  scan, and it is exactly what [03](03-queue.md)'s freshness model warns about.
  A low-frequency variant (monthly/quarterly, web-enabled) can also compare the
  workflow *itself* against the current external state of the art — the methods
  analogue of the feature scan. Derive the year from today's date; never hardcode
  it, since the routine runs indefinitely.
