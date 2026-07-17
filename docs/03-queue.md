# 03 — The queue: one inbox, humans apply

Every proposal from any agent lands in **one** place: a single tracker project
used as an agent queue (Linear, GitHub Issues, whatever you use). Issues are
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

## Label convention

Pick a small set of `type:` labels so triage is a glance. A starting set:

| Label | Meaning | Who resolves it |
|---|---|---|
| `type:security` | security finding | worker + PR |
| `type:refacto` | refactor / dead code | worker + PR |
| `type:doc-proposal` | doc change from a worker | coordinator |
| `type:workflow` | how-we-work retro item | coordinator / human |
| `type:feature` | product idea vs state of the art | human decides |

Plus one umbrella label (e.g. `agent`) so you can find everything agents filed.

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
  branch, fix, test with a regression, open a PR, update the issue. Out-of-scope
  work (someone else's area, an infra repo) is handed back, not forced.

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
