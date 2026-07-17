---
name: resolve-finding
description: For a worker in a code-repo worktree — take ONE finding from the project's agent queue (or one given by the user if the project has no queue), verify it against the code, implement the fix on a branch, test, open a PR, and update the finding. Use when asked to resolve or fix a specific finding (e.g. "fix issue #123") or to work through the queue.
---

# Resolve a finding (worker role)

You are a worker in a code-repo worktree. Fix **one** finding at a time, cleanly
and safely. Never edit the docs hub from here — that is the coordinator's job (and
it is read-only for you).

## Get the finding (project-configured)

Run `fleet-queue` for this project's queue backend:

- **linear** → read the issue from the Linear project (`QUEUE_LINEAR_TEAM` /
  `QUEUE_LINEAR_PROJECT_ID`) — via a Linear MCP if connected (caution: some wrap
  the payload in a nested text field needing a second `json.loads()`), otherwise
  via the Linear GraphQL API with `$LINEAR_API_KEY` (`issue` / `issues` query).
- **github** → `gh issue view <n>` in `QUEUE_GITHUB_REPO`.
- **none** → there is no queue; the finding is given directly by the user.

## Steps

1. **Read the finding.** Pull: severity, location (file:line), impact, proposed
   fix, owner. If it is owned by someone else or lives in another repo (e.g. an
   IaC repo), **STOP** — it is not a code fix here. Tell the user.
2. **Verify against the code first.** Open the cited files and confirm the finding
   is real and still current (the code may have changed since it was filed). If it
   is a false positive or already fixed, do NOT force a change — say so, and
   comment the issue (if there is a queue) with that conclusion.
3. **Branch.** Work on your worktree's branch (created by `new-worker`). Do not
   touch unrelated code.
4. **Fix**, following the repo's conventions (its context file — `AGENTS.md` or
   `CLAUDE.md`: language, deps, where reusable code goes, no hardcoded config).
   Keep the change minimal and scoped to the finding.
5. **Test.** Run the relevant tests. For a security fix, add a **regression test**
   that proves the exploit is now blocked.
6. **Docs = part of "done".** If the fix changes a behavior the hub describes (an
   endpoint, flag, schema, architecture fact, or security posture), file a
   `type:doc-proposal` via `propose-doc-change` (it routes by QUEUE_KIND; for
   `none` it surfaces the drift to the user). Never edit the hub. A code-internal
   change the hub does not describe needs none.
7. **Commit + PR.** Message references the finding, e.g.
   `fix(security): block path traversal in the upload handler (#123)`. Push, open a PR.
8. **Update the finding** (if there is a queue): comment the PR link + a short
   summary; move it to In Progress / In Review. Do **not** close it yourself —
   leave the final close to review/merge.

## Rules

- **Tracker language.** Anything you write to the tracker (the issue comment, any
  edited title/description) is in the tracker's fixed language from your global
  context file, regardless of the conversation language. (Commit/PR/code language
  is the code repo's, per its context file — a separate rule.)
- One finding = one branch = one PR.
- Never fix a finding you could not verify in the code.
- Security: prefer a testable defense; ship the regression test with it.
- Out of scope (owned by someone else, or living in another repo like IaC) → hand
  it back, do not force it.
