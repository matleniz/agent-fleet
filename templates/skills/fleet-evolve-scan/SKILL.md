---
name: fleet-evolve-scan
description: Weekly strategic scan for agent-fleet (docs/04 feature-scan style). Takes a step back, reads ROADMAP/BACKLOG/recent digests, researches the web for deep evolution ideas (orchestrators, multi-agent fleets, Claude Code / Cursor / OSS peers), then writes a dated evolve digest and optionally files a few high-value type:feature issues to the personal Linear queue. Report-only. Trigger on the weekly evolve schedule, or when asked for a deep / strategic / ecosystem scan of agent-fleet.
---

# Fleet evolve scan (weekly, judgment + web, report-only)

You look **outward and deep**, not at today's bugfixes. Goal: surface
non-obvious ways to evolve **agent-fleet** (the engine under
`CODE_REPO` / `~/agent-fleet`), grounded in what peers ship and what research
says — then propose, never apply.

This complements `conversation-feedback` (inward method lessons from your own
sessions). Here the signal is **external**: other tools, papers, product
moves, patterns that would change architecture or the product surface.

## Contract

- **Model:** strong (sonnet by default). Judgment-heavy.
- **Report-only:** write a digest; optionally file queue issues. Never edit
  code, hubs, ROADMAP/BACKLOG in-repo, never `git push`, never touch prod.
- **Sources mandatory** for every recommendation (URL + what you took from it).
- **Tracker language:** English for any Linear title/body (personal workspace).

## 0. Orient

```
fleet-queue --project agent-fleet
fleet feedback config
```

Read (skim, do not dump):

1. `$CODE_REPO/ROADMAP.md`, `$CODE_REPO/BACKLOG.md`, `$CODE_REPO/CHANGELOG.md`
   (recent entries), `$CODE_REPO/AGENTS.md` or `CLAUDE.md`
2. Latest files under `$FLEET_HOME/feedback-digests/` and
   `$FLEET_HOME/evolve-digests/` (if any) — skip ideas already proposed
3. Open Linear issues on project **Agent Fleet** (Linear MCP) with label
   `type:feature` if present — do not duplicate

Note what the product already claims (packs, queue backends, feedback pipeline,
gates, remote machines) so you do not "rediscover" shipped work.

## 1. Research (web required)

Search and read enough to form a **current** picture (not a 2024 blog roundup).
Cover at least three of these lenses:

- Multi-agent / fleet orchestrators (open-source and product)
- IDE / CLI agent workflows (Claude Code, Cursor, Codex, Gemini CLI, peers)
- Eval, memory, skill, and routine patterns that change how agents improve
- Safety / isolation / permission models relevant to a multi-worker laptop fleet
- Academic or industrial write-ups on agent teams, judging, handoffs

Prefer primary sources (repos, docs, papers, changelogs) over listicles.
Discard hype with no transferable mechanism.

## 2. Distill (depth over volume)

Produce **3–7** candidate directions. Each must answer:

- **What** — one concrete capability or architectural move
- **Why now** — what changed externally or in this repo's gaps
- **Fit** — how it maps onto agent-fleet (pack, `bin/`, docs/04 routine,
  queue type, etc.) without renaming the product into something else
- **Depth** — prefer structural bets (new routine class, new isolation model,
  race/judge loop, memory boundary) over tip-sized UX nits already in BACKLOG
- **Evidence** — sources + what you reused
- **Cost / risk** — tokens, ops load, safety classifier gotchas, maintenance

Rank by expected leverage for a **solo / small-fleet** dogfood setup (this
instance), not for a 100-engineer platform team.

Drop anything already in BACKLOG/ROADMAP unless you have a **materially
stronger** approach or proof point — then say what supersedes what.

## 3. Write the evolve digest

Create `$FLEET_HOME/evolve-digests/<YYYY-MM-DD>.md` (derive the date; never
hardcode the year). Structure:

```
# Fleet evolve scan — <YYYY-MM-DD>

## Snapshot
<2–4 lines: where agent-fleet stands vs the research window>

## Ranked directions
### 1. <title>
- What / why now / fit / evidence / cost

### 2. …

## Explicitly not recommending
<ideas you considered and rejected, with one-line why>

## Sources
- <url> — <one-line takeaway>
```

## 4. File sparingly to the queue

Only if `QUEUE_KIND=linear` (or github) for agent-fleet:

- File **at most 3** issues, only for top directions that are actionable and
  not already queued/BACKLOG-covered
- Label intent: **`type:feature`** (+ umbrella `agent` if that label exists).
  Never invent labels if create is restricted — put the type in the title
  prefix instead: `[type:feature] …`
- Body:

```
## Source
fleet-evolve-scan routine, run <YYYY-MM-DD>

## Direction
<what + why now>

## Fit for agent-fleet
<where it would land>

## Evidence
<urls + takeaways>

## Suggested next step
<smallest validating experiment a worker could run — no implementation here>
```

- Default state; do not close your own issues; English only on the tracker
- Prefer Linear MCP when available; do not require `LINEAR_API_KEY`

Everything else stays **digest-only** (including vague or upstream-public ideas
you are unsure about).

## Rules

- Outward research + digest (+ rare queue filing). Nothing else.
- No code/hub edits, no push, no prod, no auto-PR to the public repo.
- Prefer depth and falsifiable next steps over a long idea dump.
- End with: digest path, issues filed (ids), directions kept digest-only.
