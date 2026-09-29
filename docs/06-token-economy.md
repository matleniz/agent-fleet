# 06 — Token economy: the numbers and the sources

This doc backs the claims the rest of the repo rests on.

> **Scope note.** The figures below were measured on Claude/Anthropic pricing
> and mechanisms (prompt-cache reads at ~1/10, progressive-disclosure skills).
> The *principles* — reads dominate, cache reuse, index routing, context per
> agent — apply to any provider; the constants differ. Re-derive them for the
> pack you run before betting a budget on them.

If you only remember one
thing: **parallelism buys wall-clock, not tokens.** More agents is a
spend-tokens-for-speed-or-quality move, not a save-tokens move. Save tokens by
shrinking context per agent and reusing warm context, not by talking less between
agents. And more agents costs RAM and disk, not just tokens: the per-machine
resource guard ([07](07-machine-and-solo.md#resource-guard-rails-dont-oom-the-box))
caps how wide one box goes before it OOMs.

## Where the tokens actually go

- Tool observations (file contents, command outputs) fill **70-80%** of the
  context window in agentic coding.
- **Read** operations alone are **~76%** of tokens spent, vs execute ~12% and
  edit ~12%. Understanding the code costs far more than changing it.

Implication: the biggest lever is reading less and reusing reads, not compressing
the messages agents send each other.

## What multi-agent costs

- A multi-agent system uses about **15x** the tokens of a plain chat.
- A single agent uses about **4x** a chat.
- Subagent-heavy workflows: roughly **7x** a single-thread session, because each
  subagent maintains its own context.
- Live "agent teams": roughly **3-4x** for 3 teammates, since every inter-agent
  message is a round trip through the model.

So multi-agent is worth it only when the task value justifies the multiplier.
Anthropic's own result: a multi-agent setup (strong-model lead + cheaper-model
subagents) beat a single strong agent by ~90% **on research**, an exploratory,
read-heavy, parallelizable task. That is the regime where extra agents pay.

## Research vs coding (the Anthropic / Cognition split)

The two well-known positions look opposed but agree on the axis:

- **Anthropic** (pro multi-agent) built a multi-agent *research* system. Research
  is exploratory and non-linear; parallel agents exploring different paths, each
  in its own context, genuinely help.
- **Cognition** ("Don't build multi-agents") argues against splitting *coding*
  work. Coding is write-heavy and needs one consistent context; split it and
  critical context is lost in transmission, causing rework.

Reconciled: **read-heavy exploration → multi-agent; write-heavy coherent change →
single agent.** That is exactly why in this system the routines (audits,
research) fan out, while a single coherent code change stays with one worker.

## Why warm context wins (the caching mechanism)

Cached input is billed at roughly **a tenth** of fresh input, split into cache
creation (a small premium) and cache read (the discount). Concretely, for N tasks
sharing context C:

- **One warm worker:** pay ~1.25·C once to build the cache, then ~0.1·C per task
  to reuse it. Total ≈ 1.25·C + 0.1·C·N.
- **A fresh subagent per task:** each has its own context and does not share the
  parent's cache, so each repays ~1.0·C. Total ≈ N·C.

For large C and many tasks, the warm worker wins by a wide margin. This is the
mechanism behind "batch tasks by shared context" ([01](01-mental-model.md)) and
the whole adaptive posture ([05](05-adaptive-posture.md)). Caveat: the cache is
warm only while the prefix is stable and within its TTL, which is another reason
to prefer a durable structured queue over live agent chatter that churns the
prefix.

## Progressive disclosure

Loading short discovery descriptions of installed skills instead of their full
bodies cut initial context by ~94% in one measurement (773 tokens for ten skill
descriptions vs ~13,900 to eagerly load all instructions). The same principle is
why the hub uses an index router: read the index, open the one file, grep the
section. Full-context agents have been measured at ~2.7x the tokens of
context-optimized ones on the same benchmark.

## On "caveman" / terse prompting

Prompt compression is real but the gains are inconsistent (measured anywhere from
~5% to ~27%) and concentrate on **output verbosity** and on **large stable prompt
bodies**, not on short handoff messages. Terse prose between agents also buys
ambiguity, and ambiguity causes rework, which is the most expensive outcome.
The productive version is a **structured contract** (a schema, a labeled issue):
the terseness of a fixed format without the ambiguity of compressed prose. Apply
terseness to output and to structured handoffs, not to inter-agent prose.

## The deterministic gate: fix mechanically, escalate the residual

A worker that runs its project's checks by hand pays model tokens three times:
deciding which checks to run, reading full tool output (most of it fixable
noise), and iterating fix-by-fix. `fleet gate` collapses that into one tool
call. The project declares its checks once (`GATE_CMDS` in its fleet config,
one command per line, auto-fix flags included — the fleet bundles no linter and
stays dep-free); the gate runs them all, lets the auto-fixes repair the fixable
noise at **zero** model cost, suppresses the output of everything that passes,
and prints back only the residual: which check failed and its own file:line
findings, capped so a failing test run cannot dump a full log into the window.
The model spends tokens only on what actually needs judgment. This is the same
schema-over-prose logic as the queue ([03](03-queue.md)): a fixed, mechanical
contract at the handoff instead of open-ended model work. A project that
declares no checks pays nothing — the gate is a no-op.

**Convention checks.** Besides `GATE_CMDS`, the gate can run a small set of
built-in, deterministic, opt-in checks (`bin/fleet_checks.py`, stdlib only),
enabled per project with `GATE_CHECKS` (nothing is enabled by default, so an
existing project is unchanged): `no-tracker-ids` (no tracker ids in code/test
files), `docs-with-bin` (when `bin/` — `GATE_CODE_DIRS` — changes, a doc and a
test change in the same branch), `tests-listed-in-ci` (every `test/*.sh` —
`GATE_TEST_GLOB` — is named in `.github/workflows/ci.yml` — `GATE_CI_FILE`),
`paths-exist` (backticked paths cited in docs/config exist). Every finding is
one line `WARN|BLOCK <check> <file>:<line> <message>`; `name` is advisory
(reported, gate still passes), `name:blocking` fails the gate. The diff-based
checks look at the files this branch changed against `DEFAULT_BASE`. Together
they count as one check in the `PASS n/n` summary. The same runner enforces
the dispatch spec's scope allowlist ([07](07-machine-and-solo.md)) — one
mechanism, one report format.

When gate checks fail under `fleet gate --escalate` (or when `GATE_ESCALATE=1` or
`ROUTE_GATE_ESCALATE=1` is configured), the gate queries the router for the
escalation candidate (`fleet-route.py --escalate`, e.g. `claude:sonnet`), prints it as an
explicit recommendation (`gate: automatic escalation target -> <target>`), and records a
structured `gate-escalate` event in the project's `events.log`. The gate exits non-zero
(exit 1) so the worker or coordinator can review residual findings and decide whether
to re-dispatch or hand off — it does not silently spawn unapproved workers behind the
scenes.

## Headless review passes: judge, race, fan-in

Three opt-in features share ONE primitive, `fleet_pass` (`bin/fleet-pass.sh`): a
fresh, non-interactive model run launched through the pack's existing
`pack_launch_headless <prompt> <model>` — the same entry point `fleet dispatch`
and the conversation-feedback distill use, so there is no new pack contract. The
primitive picks pack:model through the router (`fleet route --difficulty hard
--kind <kind>`: `ROUTE_KIND_JUDGE` / `ROUTE_KIND_RACE_JUDGE` / `ROUTE_KIND_FANIN`
override `ROUTE_HARD`; quota fall-through and `ROUTE_CLAUDE` apply, so a pass
never defaults to claude), bounds the run (`PASS_TIMEOUT`, default 900 s), records
a quota-exhausted pack in the quota ledger, and flags a pass that touched the
worktree (the prompt tells it not to; the check makes a violation visible).
`--with <pack[:model]>` overrides the router for one call. A pass skips the
admission guard (it is short-lived and read-only) and ignores the dispatch depth
limit (it dispatches nothing).

- **`fleet judge`** (also `fleet gate --review`, or `GATE_REVIEW=1`): after the
  deterministic checks pass, one fresh pass — no shared context with the author —
  reads the diff against the task (recorded dispatch task, `--task`, or commit
  subjects) and prints findings plus `VERDICT: APPROVE|CONCERNS`. **Advisory**: it
  never changes the gate's exit code and never files anything (a false positive
  must not silently block a PR); a pass that cannot run is reported as "not
  judged". Notes are kept in the dispatch state dir as `<worker>.judge.md`.
- **`fleet race`**: `fleet race run --packs "cursor copilot" <race> "<task>"` fans one
  task to N (2–6) worktrees `<race>-a`, `<race>-b`, … through `fleet dispatch`.
  Once they finish (`fleet wait`), `fleet race judge <race>` runs a judge pass that
  recommends a winner and drafts markdown review comments for each loser (files in
  `dispatch/<project>/race/<race>/comments/`). LLM judges have a documented
  selection gap, so it is a recommendation — you decide. Add or edit comments with
  `fleet race comment <race> <worktree> [file|-]`, then `fleet race steer <race>
  --all [--toward <winner>]` re-sends each worktree's comments as a follow-up
  prompt through the same dispatch path to that worktree's own pack (the branch
  already holds its earlier commits; `--toward` also shows the winner's diff).
  Iterate: `wait` → `judge` → `steer`. Sent comments are archived
  (`<worktree>.sent-<round>.md`) and each round is logged in `events.log`.
- **`fleet fanin`** (optional, never default): a lead pass folds K finished
  workers (`--group K`, default 4) into one structured line each plus a
  `NEEDS-HUMAN:` list, so the coordinator reads one report
  (`dispatch/<project>/fanin/latest.md`) instead of N. A lead pass that fails
  degrades to that group's raw digests — nothing is lost. `--dry-run` plans without
  calling a model. Each run appends a measurement row to `fanin/measure.tsv`.

### Fan-in: where it pays (measured, honestly)

What the hub would read without fan-in is the per-worker digest (status, task head
≤300 chars, commits, diffstat — `fanin_digest`). Measured on this repo's last 12
merged PRs (each one a worker's result): **~205 tokens per worker on average**
(range 132–299, 1 token ≈ 4 bytes). A lead line is capped at ~25 + 15 words:
~27 tokens for a typical line, ~61 at the cap (estimated from the format; the lead
model's real output was not measured). Hub tokens, N workers:

| N | direct read | fan-in report (typical / cap) |
|---|---|---|
| 6 (default cap) | ~1.2k | ~0.2k / ~0.4k |
| 16 | ~3.3k | ~0.5k / ~1.0k |
| 50 | ~10.3k | ~1.4k / ~3.1k |

Reading it: in *hub* tokens fan-in is ahead from N=2 on paper, but at N ≤ 6 it saves
about 1k tokens — less than one file read — and in *total* tokens it never wins: the
lead passes re-read every digest (≈ N × 205 in) and write ≈ N × 27–61 out, on top of
what the hub still reads. It also adds a serial hop of latency and a lossy summary a
tired reviewer may trust too much. The saving only becomes material (≳ 5k hub
tokens, ≈ 24+ workers) beyond the default cap of 6, i.e. for large-N runs
(`MAX_WORKERS` raised, or several batches). **Do not enable it below that**; the
crossover is a prediction from digest sizes, not a live-model measurement —
`measure.tsv` records `hub_direct` / `hub_fanin` / `lead_in` / `lead_out` per real
run so the number can be corrected. Prototype: one level of grouping only.

## Operational levers checklist

State-of-the-art practice (checked mid-2026) adds four levers the model above
does not cover. All four are usage discipline, not fleet code:

- **Tool-schema bloat / deferred loading.** MCP servers inject every tool
  schema at session start — a few servers can occupy half a 200K window before
  the first prompt. Keep workers lean: connect only the MCP servers the task
  needs, prefer a CLI command over an MCP tool when both exist, and turn on
  deferred tool loading where the CLI supports it (measured around -85% of
  tool-definition tokens). The fleet automates the first part: set
  `WORKER_MCP="name ..."` (or `none`) in a project `.env` and `pack_worker_setup`
  writes that allowlist into each worktree's config, so workers connect only those
  servers — not whatever the machine happens to have. Support is per CLI: the
  **gemini** pack applies it fully (`mcp.allowed` gates every scope); the
  **opencode** pack fully too (no allowlist key exists, so it disables the
  non-allowed servers it finds in the global config); the **claude** pack fully
  too — it gates the project `.mcp.json` via `enabledMcpjsonServers` AND generates
  a filtered `.claude/fleet-mcp.json` (allowlisted server defs distilled from the
  project `.mcp.json` and every `~/.claude.json` scope), then `pack_launch`
  launches with `--strict-mcp-config --mcp-config`, so claude ignores all other
  MCP config and connects only the allowlist (a claude.ai account connector, not
  present in `~/.claude.json`, cannot be fed this way and is dropped). **cursor**
  and **copilot** can't: their project MCP
  config only *adds to / overrides* the user-scope servers, it cannot suppress
  them, and their disable is global rather than per-worktree (both verified).
  **antigravity** has no per-workspace MCP config at all. Unset = inherit
  everything (no change).
- **Model tiering + effort caps.** Route mechanical work (renames, formatting,
  checklist passes) to a cheaper model and cap extended thinking; keep the
  strong model for judgment. The key mechanism: when a strong orchestrator
  directs cheap subagents, its intelligence reaches them through the briefs —
  precise targets, distilled context, falsification criteria — so a
  well-directed cheap model approaches strong-model quality on mechanical
  stages at a fraction of the cost (orchestration doing the work of
  distillation). The failure mode is fan-out that silently *inherits* the
  orchestrator's model: N strong-model subagents doing mechanical work is the
  most expensive way to run a fleet — set the model per stage explicitly.
  The packs launch each CLI at its default model; for interactive sessions
  tiering is a per-session choice (the CLI's own `/model`), and for headless
  workers `fleet dispatch --model M` sets it per dispatch (packs that support
  it, e.g. claude).
- **Task routing and escalation (`fleet route` / `dispatch --auto`).** Coordinators
  tag sub-tasks by difficulty (`easy` / `medium` / `hard`) or kind (`doc` / `code` /
  `read`). The router maps these to `pack:model` pairs according to configurable
  preference lists (`ROUTE_EASY`, `ROUTE_MEDIUM`, `ROUTE_HARD`, `ROUTE_KIND_*`).
  Working defaults (`antigravity cursor copilot`) prioritize reliable working packs
  (gemini and opencode are omitted from defaults due to client/provider dependencies
  and used only when explicitly listed).
  To protect rare frontier tokens, `ROUTE_CLAUDE=escalate-only` reserves Claude for the
  coordinator unless an explicit escalation path is taken (`ROUTE_ESCALATE`).
  If a candidate pack encounters a quota error (detected automatically by `_dispatch-run`
  when a non-zero exit matches `pack_quota_pattern` declared by the pack, or manually via
  `fleet route --quota-exceeded <pack>`), fleet writes an active ledger in
  `$FLEET_ROOT/quota/<pack>` with a configurable TTL (`ROUTE_QUOTA_TTL_SEC`, default 6h =
  21600s). The router skips any pack with an active ledger, logs the fallback, and routes
  to the next eligible candidate in the preference list. Recursive worker dispatch is bounded
  by `ROUTE_MAX_DEPTH`. `fleet route --exclude <pack>` skips a pack for one call without
  touching the ledger (used by supervision to pick the fallback after a failure).
- **Cache-prefix hygiene.** The ~1/10 cache read only holds while the prefix
  is byte-identical and within TTL: keep volatile content (timestamps,
  per-turn state) out of the always-loaded context files, and place
  fast-changing material after the stable blocks, not inside them.
- **Measure before optimizing.** Baseline a representative task (`/cost` in
  Claude Code), change one thing, re-run, compare. Guessed savings are
  usually wrong.

## Measuring fleet's own footprint

`/cost` measures a running session's total bill. To see just the part fleet
front-loads — what an agent auto-reads the instant it launches, before it does
any work — run **`fleet context`**. It lists, per role (coordinator in the hub,
worker in a worktree), the always-on files (global `AGENTS.md`, the hub/code
`AGENTS.md` + bridge, and skill *descriptions*) with byte sizes and a rough token
estimate, and separately shows what is pulled on demand (the INDEX router, skill
bodies, `docs/`, hub content). `fleet context --json` feeds a UI or an agent;
`fleet context --budget <tokens>` exits non-zero if a role's front-load exceeds a
ceiling (a guard for CI or a self-checking coordinator).

By default the skill-description line includes every machine-wide skill under
`~/.agents/skills` and `~/.claude/skills` (same dump most CLIs discover). That
is fine when every global skill is relevant; it pollutes the report — and the
`--budget` check — when a project-specific skill (e.g. a prod-access tunnel
helper) lives next to the generic worker skills. Set **`CONTEXT_GLOBAL_SKILLS`**
in the project `.env` to scope the measurement: unset / empty / `all` keeps the
old behaviour (retro-compatible); `none` counts only hub/code skills; a
space-separated name list keeps those machine-wide skills plus all hub/code
skills. This does not change what a CLI loads at launch — it keeps the
footprint report honest for the project. Hub and code-repo skills always count.

Two things it makes concrete. First, the framework is thin: a fresh coordinator's
fleet-authored front-load is on the order of ~1.5-2k tokens, most of it the hub
`AGENTS.md` template you are meant to trim — everything else is on demand. Second,
the resource guard rail ([07](07-machine-and-solo.md#resource-guard-rails-dont-oom-the-box))
adds **zero** context: it is a runtime bash check, invisible to the agent unless
it refuses (and then the agent never launches). `fleet context` measures the
*spend* side; `fleet-assess` measures the *supply* side (how much cheap distilled
context the hub offers). Keep the first small and the second growing.

Sources for this section: Anthropic, "Effective context engineering for AI
agents" (anthropic.com/engineering/effective-context-engineering-for-ai-agents);
Claude prompt-caching docs (platform.claude.com/docs → prompt caching).
Practitioner percentages are indicative, not constants.

## Sources

- Anthropic — How we built our multi-agent research system:
  https://www.anthropic.com/engineering/multi-agent-research-system
- Cognition — Don't Build Multi-Agents:
  https://cognition.com/blog/dont-build-multi-agents
- CloudZero — Claude Code Agents in 2026 (what parallel sessions cost):
  https://www.cloudzero.com/blog/claude-code-agents/
- How Do AI Agents Spend Your Money? Token consumption in agentic coding (arXiv):
  https://arxiv.org/pdf/2604.22750
- Less Context, Better Agents: Efficient Context Engineering (arXiv):
  https://arxiv.org/pdf/2606.10209
- Telegraph English: Semantic Prompt Compression (arXiv):
  https://arxiv.org/pdf/2605.04426
- Claude Code docs — Agent teams: https://code.claude.com/docs/en/agent-teams

Numbers are drawn from the sources above as of mid-2026; treat them as orders of
magnitude, not constants, and re-check as tooling and pricing change.
