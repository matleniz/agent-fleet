---
name: process-agent-queue
description: Coordinator only. Process this project's agent queue — read open proposal/finding issues posted by worker sessions, integrate approved doc proposals into the versioned hub, commit, and close them. Invoke manually with /process-agent-queue.
disable-model-invocation: true
---

# Process the agent queue (coordinator role)

This session is the ONLY writer to the docs hub. Workers post proposals to the
queue; here you read them, decide, integrate, and close.

## Queue location (project-configured)

Run `fleet-queue` to get this project's backend and coordinates:
- **linear** → the Linear project `QUEUE_LINEAR_TEAM` / `QUEUE_LINEAR_PROJECT_ID`,
  via a Linear MCP if connected (caution: some wrap the payload in a nested text
  field needing a second `json.loads()`; parse it properly, do not eyeball the
  raw string) or via the Linear GraphQL API with `$LINEAR_API_KEY`.
- **github** → issues in `QUEUE_GITHUB_REPO` (`gh issue list`).
- **none** → there is no queue; workers surface proposals to the user directly.
  There is nothing to process here.

## Steps

1. **Read the queue.** List open issues (filter out completed/canceled).
2. **Digest each proposal.** Pull: branch, target file(s), proposed change,
   rationale, suggested content.
3. **Present grouped, with a recommendation.** Group by target file. One-line
   recommendation each: integrate as-is / with edits / reject (why). Wait for the
   user's decision on anything not trivial or purely additive.
4. **Integrate approved proposals** into the versioned hub doc. If two touch the
   same file/section, reconcile together and flag the overlap.
5. **Dispatch code findings to workers.** Issues that require a CODE change are
   not integrated here — spawn a worker per coherent finding:
   `fleet w <short-name>` (add `-a <pack>` to pick the agent — `fleet agents`
   lists what this project has; `fleet r w <name>` for the project's VM), and
   tell the worker to run `resolve-finding` on the issue id. Batch small
   findings that share a context into one worker; keep unrelated ones apart.
6. **Commit.** One commit per proposal (or coherent group), message referencing
   the issue id.
7. **Close the issue.** Doc proposals: state Done + a short comment saying where
   it landed (file + commit). Dispatched code findings: leave them open for the
   worker's PR flow — do not close what you did not integrate. Never delete
   issues.

## Hub freshness (checkpoint-driven, not systematic)

Drift is merge-driven, so freshness is queue-driven, not a clock and not a manual
"go check everything". Detection lives in the workers; you apply the results here.

- **Process the queue at checkpoints** (end of a batch, before relying heavily on
  the hub, before a release), not on demand.
- **No systematic full-hub rewrites.** Apply the accumulated proposals; do not
  re-audit the whole hub (that is a low-frequency backstop routine's job).
- **Target trusted-fact docs** (index, architecture, schemas, endpoints, security).
  Dated journals stay historical under a dated banner: do not "correct" them.

## Rules

- **Tracker language.** Anything you write to the tracker (comments, any edited
  title/description) is in the tracker's fixed language from your global context
  file, regardless of the conversation language. Do not mix languages in the queue.
- Never delete an issue; close it. Never force an integration the user hasn't OK'd.
- If a proposal is stale (target already changed, branch merged/gone), flag and ask.
- The hub is the source of truth; the queue is a proposal channel, not the record.
