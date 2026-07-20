# Bootstrap prompt

Paste this into a fresh session of your agent CLI (Claude Code, opencode, Gemini
CLI, …) on the machine where you want to set up the fleet workflow. It reads the
state first, then proposes before building.

```
I want to set up the multi-session "fleet" workflow described in the agent-fleet
repo on this machine. Read the repo's docs first (docs/01 through docs/07), then
help me stand it up for MY project. The core rule is: the boundary of an agent is
a context, not a task.

Context to gather before proposing anything:
- Read my global context file (~/.claude/CLAUDE.md, ~/.codex/AGENTS.md,
  ~/.config/opencode/AGENTS.md, or ~/.gemini/GEMINI.md — whichever this CLI
  reads) and my memory index if present. If those global files disagree across
  CLIs, offer `fleet global`: it installs one canonical `~/.agents/AGENTS.md` and
  wires every installed CLI to it (migrating an existing `~/.claude/CLAUDE.md`).
- List my repos under $HOME and tell me which is the code repo and which (if any)
  is a docs hub. If there is no hub, `fleet-init` can seed one.
- Check whether the tools are on PATH (fleet, fleet-init, new-worker,
  fleet-assess, fleet-queue, fleet-migrate) and whether ~/.config/fleet/projects/
  exists.

Then propose, and wait for my approval before touching anything:
1. Put bin/ on PATH if not already (symlink fleet, fleet-init, new-worker,
   fleet-assess, fleet-queue, fleet-migrate into ~/.local/bin).
2. Register my project with ONE command:
     fleet-init <name> [--code <repo>] [--hub <hub>] [--agents claude,opencode]
                --queue <linear|github|none>
   --agents lists the agent packs to enable (first = default at launch). With
   --queue linear|github, pass the tracker coordinates; with none, workers
   surface findings to me directly. With a non-existent --hub, it seeds the hub
   (INDEX + AGENTS.md with a CLAUDE.md bridge + coordinator skills in
   .agents/skills/). OMIT --code to scaffold from scratch: a base-commit repo
   ~/<name> pushed to a new private GitHub repo, a seeded+committed hub
   ~/<name>-hub pushed to a private <owner>/<name>-hub, and queue defaulting to
   github (needs the gh CLI). Optionally declare the project's pre-PR checks in
   its .env (GATE_CMDS, one command per line, auto-fix flags included): workers
   then run `fleet gate` before opening a PR, and only residual failures reach
   the model.
3. Confirm the config-driven skills are installed globally once (propose-doc-change,
   resolve-finding, and dispatch-work in ~/.agents/skills/, with per-skill symlinks
   in ~/.claude/skills/ for Claude Code); they are generic and read my project's
   queue via `fleet-queue`, so they are NOT edited per project.
4. Run fleet-assess for the project to pick the starting posture (THIN → work
   solo and manufacture context; MATURE → batch and exploit it).
5. Which standing reviews should be cloud routines vs local hooks, given what
   needs local files or prod. All routines report only; I apply.

Rules to follow throughout:
- Report and propose, never auto-apply. I approve before you build.
- Never push code or touch prod from a routine. Never materialize prod secrets.
- Verify facts against the actual files before asserting. Say when you are unsure.
- Keep the global context file short; project detail lives at the repo/config level.
- Adding a project must not edit the fleet: it is fleet-init + config only.
- Docs have one writer (the coordinator). Workers are read-only on the hub, and
  the barrier is mechanical, installed per agent pack (hooks or permission
  rules — see docs/02), never a plain instruction.
- One coherent change stays in one worker. Batch unrelated tasks that share a
  context into one warm worker; reset at the context boundary.

Start by reading the state and giving me a numbered plan. Do not build yet.
```
