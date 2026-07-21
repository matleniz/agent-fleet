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

## The conversation-feedback pipeline (stages A/B/C)

The fleet retro is not one pass — it is a **3-stage pipeline**, split so the cheap
work runs often and the expensive work runs rarely, and so the private data never
has to leave the box. The split is what makes an off-box (cloud/ssh) distill pass
possible at all.

```
  A extract   local, deterministic, no model   transcripts -> scan JSON
       |        (fleet chats --scan --parse)
       v
  B compress  local, cheap model, FREQUENT     scan JSON  -> session notes
       |        (skill: conversation-compress)  ($FLEET_HOME/feedback-notes/)
       v
  C distill   local OR ssh/cloud, strong, RARE  notes      -> candidate lessons
       |        (skill: conversation-feedback)
       v
  finalize    local, ALWAYS, no model           candidates -> dedup + file + digest
```

**Why B is local.** Transcripts are local and private (the scanner is local-only).
B is the confidentiality *and* compression boundary: it reads the private
transcripts and emits small notes carrying only a grounded lesson — no transcript
contents, and its `transcript` path is stripped before any payload leaves the box.
So B must run local; only its output is shippable.

**Why C can move but finalize cannot.** C's reasoning (notes -> candidate lessons)
is pure and needs no local state, so it can run local, over ssh, or in a cloud
routine — selected by `FEEDBACK_RUNNER`. But the seen-ledger (machine-wide dedup)
and the queue backend's credentials stay local, so **dedup, filing, and the digest
always run local**, from the candidates C returns. A cloud runner only ever
reasons; it never files and never sees a credential (matches the cloud-vs-local
rule above: cloud has no prod keys).

**The contract between stages** (stable, so the runner is swappable):

- A -> B: the scan JSON in **history mode** (`fleet chats --scan --all --parse
  --history --since <ISO>`). `--history` is what makes this a retro: the default
  scan returns only the latest pointer per live worktree, so a fleet that deletes
  finished workers would expose almost none of its history; `--history` emits one
  entry per transcript file over the window, finished/deleted workers included
  (their recorded history survives `del`/`prune`). Claude and cursor today (via the
  pack's `pack_chat_history`); packs without it fall back to the per-location scan.
- B -> notes: one file per transcript at `$FLEET_HOME/feedback-notes/<session_id>.json`;
  the file's existence is the dedup (B skips a transcript whose note exists).
- notes -> C: the notes, transcript paths stripped. No ledger, no creds.
- C -> candidates: `{lessons:[{fingerprint, project, pattern, evidence,
  proposed_change, target, label}]}`, where `target` is `project` | `global` |
  `upstream`.
- finalize: `project` -> that project's queue (`fleet-queue`/`QUEUE_KIND`);
  `global` -> the digest's global-lessons section; `upstream` -> the digest's
  upstream-candidates section (never auto-filed to the public repo). Dedup via
  `fleet feedback seen/record`; write the dated digest.

**Model + runner are knobs**, reported by `fleet feedback config` and set in
`default.env` (feedback is machine-wide): `FEEDBACK_MODEL_COMPRESS` (B, cheap),
`FEEDBACK_MODEL_DISTILL` (C, strong), `FEEDBACK_RUNNER` (local | ssh | cloud). No
`bin/` script calls a model — the model is passed on the existing
`pack_launch_headless <prompt> <model>` path. Built-ins: `haiku` / `sonnet` /
`local`.

**Scheduling is two jobs, both instance-side** (not repo code): B frequent (its
value is only realized if C is notably rarer), C rarer. Install each as a local
job (SessionStart hook on claude/gemini, else OS cron), throttled; a human launches
the first validation run and installs the hook (the classifier gotcha below). The
cloud runner for C — shipping notes to a cloud agent and getting candidates back —
is also instance-side wiring; the repo ships the contract and the local default,
not a named cloud CLI.

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
- **Conversation-feedback** (local, weekly for distill; more frequent for
  compress): the shipped workflow-retro routine, run as the 3-stage pipeline
  described above (**The conversation-feedback pipeline**). It reads how the work
  actually went across **every** project and worker on the machine and turns
  recurring method mistakes into durable fixes, not a one-off report. Stage B
  (`conversation-compress`) compresses each new transcript into a session note;
  stage C (`conversation-feedback`) distills the notes into lessons, dedups them
  against the machine-wide seen ledger (`fleet feedback seen/record`,
  `$FLEET_HOME/feedback-seen.json` — recurrence count is itself signal), and
  routes each: a `project` lesson to that project's queue (`type:doc-proposal` for
  a doc/skill/AGENTS.md edit, `type:workflow` for a how-we-work item, via the
  `propose-doc-change` backend), a `global` or `upstream` lesson to the dated
  digest (`$FLEET_HOME/feedback-digests/<date>.md`). Report-only and mechanical:
  the skills only read, file issues, and write the digest — never push or edit the
  hub. Both skills load from the hub; schedule both as local jobs (SessionStart
  hook on claude/gemini, else OS cron), throttled, a human launching the first
  validation run and installing the hook (the classifier gotcha above). Below, the
  older workflow-retro framing it generalizes:
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
