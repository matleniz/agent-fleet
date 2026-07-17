# 05 — Adaptive posture: the tipping point moves

The fleet does not have one fixed posture. The right posture depends on how much
**distilled shared context** (call it C) already exists in the hub. This doc is
the model; `bin/fleet-assess` is the tool that reads your hub and prints the
recommendation.

## The single variable that moves everything

C is the cheap, reusable context an agent can load instead of reading raw code:
an index, a subsystem doc, a map. The key ratio that decides every posture choice
is:

```
              cost to (re)build the context a task needs
   ratio  =  ─────────────────────────────────────────────
              cost to carry accumulated transcript instead
```

- **cost to build C is HIGH** when there is no distilled doc, so building context
  means raw code reads. This is a THIN hub.
- **cost to build C is LOW** when a good index + docs exist, so context is
  index → one file → grep. This is a MATURE hub.

As the hub matures, the numerator falls. That single change flips the optimal
posture from "manufacture context" to "exploit context". The tipping point is not
fixed; it slides as your hub fills in.

## Three regimes

### THIN hub (little or no distilled C)

Early project. No index, few docs, no coverage. There is nothing cheap to reuse,
so every task pays raw code reads.

Posture:
- **Fleet: narrow (1-2 workers).** Parallelism has little to amortize against and
  high rework risk: with no shared doc, parallel workers drift apart.
- **Spend tokens MANUFACTURING context.** The expensive reads a worker does are
  an asset, not waste. Distill them into the hub before the worker resets, so the
  cost is paid once, forever. Early on, the coordinator's main job is to build
  the map.
- **Warm workers: yes**, across tasks in the same subsystem. But close each batch
  by writing a hub note, so the next worker inherits cheap C instead of re-reading.
- **Subagent offload: low value.** Do not send the big dig to a subagent that
  discards it; here the dig IS the deliverable, capture it.

The counterintuitive part: in a thin hub, spending *more* tokens now (to distill)
is the token-frugal move, because it lowers every future task's cost.

### GROWING hub (partial C, index exists, some subsystems documented)

Mixed. Some zones are documented (cheap C), some are not (raw reads).

Posture:
- **Fleet: medium.** Route workers by **zone maturity**, not evenly.
- **Documented zones → exploit:** batch small tasks on a warm worker, offload
  throwaway exploration to subagents with a compact brief.
- **Undocumented zones → treat as THIN:** distill what you learn into the hub.
- The tipping point is now **per zone**. Re-run `fleet-assess` as coverage grows;
  the cheapest future token win is one index entry per subsystem.

### MATURE hub (rich C, index, good coverage, skills, queue history)

C is a cheap artifact. Loading context is index → one file → grep.

Posture:
- **Fleet: wide** across independent workstreams (never inside one coherent
  change, see [01](01-mental-model.md)). Independence is by **file ownership, not
  pipeline phase**: streams that write the same file collide at PR time, so they
  are one stream (or a dependency chain), not parallel work. The `dispatch-work`
  skill is this partition-and-dispatch playbook. "Wide" is bounded by the box:
  the per-machine resource guard ([07](07-machine-and-solo.md#resource-guard-rails-dont-oom-the-box))
  refuses a launch once RAM/disk/worker limits are hit, so fan out across machines
  rather than piling workers onto one.
- **Warm workers, aggressive batching:** load C once, reuse from cache across the
  whole batch, reset at the next context boundary.
- **Subagent offload: high value.** Throwaway exploration goes to a subagent that
  returns only the distillate; the warm worker accumulates results, not raw digs.
- **Spend tokens EXPLOITING cheap C.** The constraint is no longer "C is
  expensive" but "do not let transcript accumulate". That is the trap from
  [01](01-mental-model.md), and offload is the tool against it.

## Summary table

| | THIN | GROWING | MATURE |
|---|---|---|---|
| cost of C | high (raw reads) | mixed, per zone | low (index → file) |
| fleet width | narrow (1-2) | medium, by zone | wide, independent streams |
| where tokens go | manufacture C | both, by zone | exploit C |
| warm workers | yes, then distill | yes in doc'd zones | yes, batch hard |
| subagent offload | low value | in doc'd zones | high value |
| main risk | drift, lost reads | uneven coverage | transcript bloat |

## Using the tool

```bash
fleet-assess --hub /path/to/hub --code /path/to/code
```

It scores observable signals (index present, doc count and size, doc/code ratio,
skills, git history), maps them to THIN / GROWING / MATURE, and prints the
posture above. Run it at the start of a work session and again whenever the hub
has grown noticeably. It reads only; it changes nothing.

The score is a heuristic, not a law. It exists to make you ask the right
question at the start of a batch: *is my next token better spent building context
or exploiting it?*
