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

- **github** (the default) → `gh issue view <n> -R <QUEUE_GITHUB_REPO> --comments`.
  Move it with `fleet issue` (board column + `status:*` label + comment in one
  call; never hand-roll `gh project` calls).
- **none** → there is no queue; the finding is given directly by the user.
- **linear** (legacy) → read the issue from the Linear project (`QUEUE_LINEAR_TEAM` /
  `QUEUE_LINEAR_PROJECT_ID`) — via a Linear MCP if connected (caution: some wrap
  the payload in a nested text field needing a second `json.loads()`), otherwise
  via the Linear GraphQL API with `$LINEAR_API_KEY` (`issue` / `issues` query).
  Set its states with the tracker's own tools (no `fleet issue`).

## Steps

1. **Read the finding.** Pull: severity, location (file:line), impact, proposed
   fix, owner. If it is owned by someone else or lives in another repo (e.g. an
   IaC repo), **STOP** — it is not a code fix here. Tell the user. Otherwise claim
   it: github → `fleet issue start <n>` (In progress + `status:in-progress` +
   `Started by <your worktree>`).
2. **Verify against the code first.** Open the cited files and confirm the finding
   is real and still current (the code may have changed since it was filed). If it
   is a false positive or already fixed, do NOT force a change — say so, and
   comment the issue (if there is a queue) with that conclusion. Stuck on
   something outside your reach → `fleet issue block <n> --note "<blocker>"`.
3. **Branch.** Work on your worktree's branch (created by `new-worker`). Do not
   touch unrelated code.
4. **Fix**, following the repo's conventions (its context file — `AGENTS.md` or
   `CLAUDE.md`: language, deps, where reusable code goes, no hardcoded config).
   Keep the change minimal and scoped to the finding.
5. **Test.** Run `fleet gate` first: it runs the project's declared checks
   (`GATE_CMDS` in its fleet config) in one shot — auto-fixes apply mechanically
   inside it, and it prints only the residual findings (the failing check +
   its file:line output). Fix those and re-run until it passes; commit any files
   the gate notes as auto-fixed. It is a no-op when the project declares no
   checks. Then run the tests relevant to your change. For a security fix, add a
   **regression test** that proves the exploit is now blocked.
6. **Docs = part of "done".** If the fix changes a behavior the hub describes (an
   endpoint, flag, schema, architecture fact, or security posture), file a
   `type:doc-proposal` via `propose-doc-change` (it routes by QUEUE_KIND; for
   `none` it surfaces the drift to the user). Never edit the hub. A code-internal
   change the hub does not describe needs none.
7. **Commit + PR.** Message describes the fix, e.g.
   `fix(security): block path traversal in the upload handler`. Push, open a PR
   whose body ends with `Closes <QUEUE_GITHUB_REPO>#<n>` (e.g. `Closes
   owner/product-issues#123`; the full `owner/repo#n` form is what closes an issue
   living in another repo than the code). The merge then closes the issue.
8. **Update the finding** (if there is a queue): github → `fleet issue review <n>
   --note "PR <url>: <one-line summary>"` (In review + `status:in-review`);
   linear (legacy) → comment the PR link + summary, move it to In Review. Do
   **not** close it yourself — leave the final close to review/merge.

## Rules

- **Tracker language.** Anything you write to the tracker or the code host (issue
  comments, PR title/body, any edited title/description) is in the tracker's fixed
  language from your global context file (English by default), regardless of the
  conversation language. (Code/doc language inside the repo follows its context
  file — a separate rule.)
- One finding = one branch = one PR.
- Never fix a finding you could not verify in the code.
- Security: prefer a testable defense; ship the regression test with it.
- Out of scope (owned by someone else, or living in another repo like IaC) → hand
  it back, do not force it.
- **Cross-CLI handoff.** If you switch agents or pause work before a PR, write
  `HANDOFF.md` at the worktree root using `templates/HANDOFF.md` (task,
  status/result, reason, constraints, next steps, files touched, how to
  verify). If starting in a worktree with an existing `HANDOFF.md`, read it first
  to resume immediately. `HANDOFF.md` is local working state only and must NOT
  be committed to the PR: delete it or exclude it via `.git/info/exclude` before
  opening the PR; the final summary belongs in the PR description.
