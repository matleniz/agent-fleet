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
