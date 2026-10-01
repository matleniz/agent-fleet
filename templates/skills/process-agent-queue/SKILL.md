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
- **github** (the default) → the private issues repo `QUEUE_GITHUB_REPO` and its
  board `QUEUE_GITHUB_PROJECT`. Read with `gh issue list -R <repo> --state open`
  (`--label type:doc-proposal`, `--label agent`, ... to filter) and `gh issue view
  <n> -R <repo> --comments`. Every state change goes through `fleet issue`
  (`new|start|review|block|done`): it moves the board column and the `status:*`
  label together and posts the comment — never hand-roll `gh project` calls. The
  conventions (labels, lifecycle, who does what) are the issues repo's README.
- **none** → there is no queue; workers surface proposals to the user directly.
  There is nothing to process here.
- **linear** (legacy) → the Linear project `QUEUE_LINEAR_TEAM` /
  `QUEUE_LINEAR_PROJECT_ID`, via a Linear MCP if connected (caution: some wrap the
  payload in a nested text field needing a second `json.loads()`; parse it
  properly, do not eyeball the raw string) or via the Linear GraphQL API with
  `$LINEAR_API_KEY`. No `fleet issue` here: set states with the tracker's tools.

## Steps

1. **Read the queue.** List open issues (filter out completed/canceled). Triage
   what lacks a label: exactly one `type:*`, one `priority:*`, an `area:*` when it
   applies (`gh issue edit <n> -R <repo> --add-label ...`). An issue labeled
   `needs:*` (`QUEUE_NEEDS_LABEL`) waits for the human's decision: do not act on
   it until they answered in a comment, then remove the label.
2. **Digest each proposal.** Pull: branch, target file(s), proposed change,
   rationale, suggested content.
3. **Present grouped, with a recommendation.** Group by target file. One-line
   recommendation each: integrate as-is / with edits / reject (why). Wait for the
   user's decision on anything not trivial or purely additive.
4. **Integrate approved proposals** into the versioned hub doc. If two touch the
   same file/section, reconcile together and flag the overlap.
5. **Dispatch code findings to workers.** Issues that require a CODE change are
   not integrated here — spawn a worker per coherent finding:
   `fleet w <short-name>` / `fleet dispatch <short-name> "<brief>"` (add `-a
   <pack>` to pick the agent — `fleet agents` lists what this project has; `fleet
   r w <name>` for the project's VM), and tell the worker to run `resolve-finding`
   on the issue number (it runs `fleet issue start <n>` itself). Batch small
   findings that share a context into one worker; keep unrelated ones apart.
6. **Commit.** One commit per proposal (or coherent group), message referencing
   the issue id.
7. **Close the issue.** Doc proposals: github → `fleet issue done <n> --note
   "Landed in <file> (<commit>)"` (closes it, board Done, status labels cleared);
   linear (legacy) → state Done + the same comment. Rejected proposals: the same
   command with the reason. Dispatched code findings: leave them open for the
   worker's PR flow — the merge of the PR carrying `Closes <QUEUE_GITHUB_REPO>#<n>`
   closes them. Do not close what you did not integrate. Never delete issues.

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

- **Tracker language.** Anything you write to the tracker (comments, labels, any
  edited title/description) is in the tracker's fixed language from your global
  context file (English by default), regardless of the conversation language. Do
  not mix languages in the queue.
- Never delete an issue; close it. Never force an integration the user hasn't OK'd.
- If a proposal is stale (target already changed, branch merged/gone), flag and ask.
- The hub is the source of truth; the queue is a proposal channel, not the record.
