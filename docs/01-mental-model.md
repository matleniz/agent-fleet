# 01 — Mental model

The whole system rests on one idea:

> **The boundary of an agent is a context, not a task.**

You draw the line where the *context* changes, not where the *task* changes.
Everything else (roles, the queue, the routines, the adaptive posture) follows
from that.

## Why context, not task

Two facts about how a coding agent spends tokens:

1. **Reads dominate.** File contents and command outputs fill 70-80% of the
   context window. Read-type operations alone are ~76% of tokens spent, far more
   than execute or edit. Understanding the code costs far more than changing it.
2. **The window is re-sent every turn.** Each step re-sends the whole
   conversation so far. Prompt caching makes the re-send cheap (cache reads bill
   at roughly a tenth of fresh input), but only while the prefix stays stable and
   the cache stays warm.

Put those together and the expensive thing is *building context*, and the cheap
thing is *reusing context you already built*. So:

- If several tasks need the **same** context, run them in **one** warm session.
  You build that context once and reuse it from cache across every task. Spinning
  a fresh agent per task repays the full context each time (a fresh agent does
  not share the parent's cache).
- If one coherent change needs a **single** consistent context, keep it in **one**
  agent. Splitting it across agents loses shared context and causes rework, and
  rework is the most expensive thing there is.

Same rule, two directions:

```
  BATCH by shared context            DON'T SPLIT one context
  (many unrelated small tasks,       (one coherent change,
   same context)                      one consistent context)

      task A ┐                             ┌ agent X ┐
      task B ┼─► one warm worker           │ agent Y │ ─► rework, drift
      task C ┘   (load C once)             └ agent Z ┘   (context lost)
                                        keep it in ONE worker instead
```

## The token levers, in order of impact

1. **Minimize context per agent.** Progressive disclosure: read an index, open
   the one relevant file, grep the section. Do not load everything. This is the
   single biggest lever (a router + on-demand docs can cut the initial context by
   ~90%).
2. **Reuse warm context.** Batch tasks that share a context into one session so
   the cache stays warm and the reads are paid once.
3. **Isolate throwaway exploration.** When a task needs a big one-off dig (read
   many files to change a few lines), send that dig to a subagent that returns
   only the distillate. The parent accumulates results, not raw reads. A native
   subagent inherits the parent's model unless told otherwise (Claude Code since
   v2.1.198), so a dig launched from an Opus session runs on Opus. The claude pack
   defaults `CLAUDE_CODE_SUBAGENT_MODEL` to a cheap model (sonnet) so exploration
   does not inherit the expensive driver; the driver still bumps a specific dig up
   per call when it needs the reasoning. Cheap by default, escalate on demand.
4. **Reset at context boundaries.** When the shared context is exhausted or the
   next batch needs a different context, clear or replace the worker. Do not let
   an old task's transcript ride along under an unrelated one.

## The trap in "just keep one worker forever"

A long warm worker is great for reusing C, but the transcript of finished tasks
keeps accumulating and gets re-sent every turn. Cached, so cheap, but the window
grows and eventually you pay in compaction or in degraded quality (context rot).
So: keep C warm, but do not let unrelated task noise pile up. The tool for that
is subagent offload (lever 3), not clearing (clearing would drop C too).

## What follows from this

- **Roles** ([02](02-roles-and-barrier.md)): docs have one writer; code workers
  are read-only on the docs. Each is a clean context boundary.
- **Queue** ([03](03-queue.md)): a durable structured handoff instead of live
  agent chatter. A structured artifact is cache-friendly and unambiguous; live
  inter-agent conversation is neither.
- **Routines** ([04](04-routines.md)): read-heavy exploratory work (audits,
  research) is where extra agents genuinely pay off; write-heavy coherent work is
  where they do not.
- **Adaptive posture** ([05](05-adaptive-posture.md)): how much cheap C exists
  changes where the tipping point sits, so the fleet posture adapts to hub
  maturity.
- **Token economy** ([06](06-token-economy.md)): the numbers and sources behind
  all of the above.
