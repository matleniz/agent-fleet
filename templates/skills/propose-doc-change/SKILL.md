---
name: propose-doc-change
description: For a worker in a code-repo worktree (read-only on the docs hub) — when you would change a shared hub doc, or you notice the hub contradicts the code you are touching, file a proposal to the project's agent queue instead of editing the hub. Trigger whenever you are about to edit a hub file, or on spotting doc drift, from a worktree session.
---

# Propose a doc change (worktree worker role)

You are in a code-repo worktree, read-only on the docs hub. You never write the
hub. When a shared hub doc should change, you file a proposal and move on; the
coordinator integrates it.

## When this applies

- You would otherwise edit a roadmap / infra / architecture / decisions file that
  lives in the docs hub (not in your worktree's own source tree).
- **Freshness trigger:** you are touching code and notice the hub is wrong or
  silent about it (a stale endpoint / flag / schema / architecture / security
  fact). Flag it rather than let a session assert the stale fact. Cite the code
  (file:line) that proves the drift, and target trusted-fact docs (dated journals
  like ROADMAP/AUDIT stay historical, do not "correct" them).
- Editing your own worktree's code and local files needs none of this.

## Where to file (project-configured, do not hardcode)

Run `fleet-queue` to get this project's queue backend and coordinates, then:

- **QUEUE_KIND=linear** → create ONE Linear issue in team `QUEUE_LINEAR_TEAM`,
  project `QUEUE_LINEAR_PROJECT_ID`. Add label `agent` and `type:doc-proposal` if
  they exist (do not create labels here). State: leave the default
  (Backlog/Triage), never Done. Two transports, pick what your session has:
  - a Linear MCP (`save_issue`) if connected. Caution: some Linear MCPs wrap the
    payload in a nested text field needing a second `json.loads()`.
  - otherwise the Linear GraphQL API with `$LINEAR_API_KEY`:
    `curl -s https://api.linear.app/graphql -H "Authorization: $LINEAR_API_KEY" -H "Content-Type: application/json" -d '{"query": "mutation { issueCreate(input: {teamId: \"...\", projectId: \"...\", title: \"...\", description: \"...\"}) { issue { identifier } } }"}'`
    (resolve the team UUID first via a `teams` query if you only have the key).
  If neither is available, fall back to the `none` behavior below and say so.
- **QUEUE_KIND=github** → `gh issue create` in `QUEUE_GITHUB_REPO` with labels
  `agent`, `type:doc-proposal`.
- **QUEUE_KIND=none** → this project has NO queue. Do not try to file. Surface the
  drift to the user directly: the hub file/section, the code file:line that proves
  it, and the proposed change. Let them decide. Do not block your task.

## Proposal content (all backends)

Title: `[<worktree-name>] <short description>`

Body (markdown), always these sections:

```
## Branch
<the branch you are on>

## Target file(s)
<path(s) in the hub you want changed>

## Proposed change
<what to change, concretely>

## Why
<one or two lines of rationale, with the code file:line if it is a drift fix>

## Suggested content
<optional: the exact text/snippet or diff. The more precise, the faster the
 coordinator integrates without guessing.>
```

## Rules

- **Tracker language.** Title, body, and any comment go to the tracker in its
  fixed language from your global context file, regardless of the conversation
  language — even when the hub doc you propose to change is in another language.
  Quote the target doc verbatim where needed; the proposal's own prose stays in
  the tracker language.
- One issue = one proposal. Do not batch unrelated changes.
- Never edit the hub yourself, even "just a little".
- Do not close your own issue. Do not assume it has been integrated.
- Keep it self-contained (branch + file paths explicit): the coordinator reads it
  without your session context.
- After filing (or surfacing, for `none`), continue your task and tell the user
  the issue identifier.
