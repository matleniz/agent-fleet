# agent-fleet

A workflow for running several coding-agent sessions (Claude Code, Gemini CLI,
...) on one machine without them fighting each other, tuned to spend as few
tokens as possible for the same quality of work. The core is agent-agnostic;
each CLI is an **agent pack** (`packs/<name>/`) and a project enables one or
several. Built around one idea:

> **The boundary of an agent is a context, not a task.**

You draw the line where the *context* changes, not where the *task* changes. That
one rule explains the roles, the queue, the routines, and why the posture adapts
to how mature your docs are.

This repo is the generic pattern plus the scripts and templates to stand it up.
It is meant to be readable by a human in fifteen minutes and reproducible on a
fresh machine in under an hour.

## The idea in one screen

```
                     ┌───────────────────────────┐
                     │        DOCS HUB             │   one writer
                     │   distilled shared context   │
                     └───────────────────────────┘
                                  ▲ writes docs
                      ┌───────────┴───────────┐
                      │   COORDINATOR (in hub)   │  triages the queue,
                      └───────────┬─────────────┘  briefs from the vista
                                  │ read-only (hook barrier)
                  ┌───────────────┼───────────────┐
             ┌────▼────┐     ┌────▼────┐     ┌────▼────┐
             │ WORKER  │     │ WORKER  │     │ WORKER  │  each in a worktree,
             │  code   │     │  code   │     │  code   │  writes code → PR
             └─────────┘     └─────────┘     └─────────┘
                              ▲
                    ┌─────────┴──────────┐
                    │  THE QUEUE (tracker) │  one inbox; agents propose,
                    │  labeled, deduped    │  a human applies. Report-only
                    └────────────────────┘  routines file findings here.
```

- **Coordinator**: one session, started in the docs hub, the only writer of docs.
- **Workers**: parallel sessions in git worktrees of the code repo, read-only on
  the hub, one coherent change each, ending in a PR.
- **Queue**: a single tracker project as the inbox. Structured handoffs, not live
  agent chatter. Agents propose, a human applies.
- **Routines**: scheduled read-only reviews (security, refactor, feature, retro)
  that file findings into the queue.

## Why it saves tokens

Short version (numbers and sources in [docs/06](docs/06-token-economy.md)):

- Reads are ~76% of tokens. Building context is the expensive part; changing code
  is cheap. So the levers are all about context, not about talking less.
- **More agents does not save tokens.** Multi-agent is ~15x a chat; it buys
  wall-clock and quality, not frugality. Frugality comes from *smaller context
  per agent* and *reusing warm context*.
- **Batch tasks by shared context.** Load the context once in a warm worker,
  reuse it from cache (cache reads bill at ~1/10) across many tasks, reset when
  the context changes. This beats a fresh agent per task, which repays context
  every time.
- **Read cheaply.** An index router (read index → open one file → grep) can cut
  initial context ~90%.

## Quickstart

1. Read [docs/01-mental-model.md](docs/01-mental-model.md). Ten minutes, and the
   rest follows from it.
2. Put the tools on your PATH (symlink, so edits to the repo take effect live):
   ```bash
   for t in fleet fleet-init new-worker fleet-assess fleet-queue fleet-migrate; do
     ln -sf "$PWD/bin/$t" ~/.local/bin/$t
   done
   ```
3. Register a project in one command (writes the config, optionally seeds a hub):
   ```bash
   fleet-init myproj --code ~/my-code-repo --queue none        # solo / no tracker
   # or with a hub, two agent packs and a Linear queue:
   fleet-init myproj --code ~/my-code-repo --hub ~/my-hub --agents claude,gemini \
     --queue linear --linear-team TEAM --linear-project-id <uuid> \
     --linear-project-name "Agent Queue"
   # or FROM SCRATCH (no --code): scaffold everything and start working fast —
   # a base-commit repo ~/myproj pushed to a new PRIVATE github.com/<you>/myproj,
   # a seeded+committed hub ~/myproj-hub pushed to <you>/myproj-hub, queue
   # defaulting to github. Needs gh.
   fleet-init myproj
   ```
   `--queue` is `linear` | `github` | `none`. `--agents` lists the enabled agent
   packs (default `claude`; first = the default at launch). Workers branch off an
   auto-detected base ref (`--base` overrides). `--ntfy TOPIC` wires attention
   notifications (agent waiting / turn done) to [ntfy.sh](https://ntfy.sh) via
   `bin/fleet-notify` — subscribe to the topic on your phone. With `--hub` and a
   non-existent path, it seeds the hub: INDEX, `AGENTS.md` (single context
   source; `CLAUDE.md` is a one-line `@AGENTS.md` bridge), and the coordinator
   skills in `.agents/skills/` (the [agentskills.io](https://agentskills.io)
   standard, `.claude/skills` symlinked for Claude Code). You never edit the
   fleet to add a project. (Manual equivalent: copy `templates/fleet.env` to
   `~/.config/fleet/projects/myproj.env` and edit it.)
4. Install the config-driven skills once, globally (generic, shared by every
   project; they read each project's queue via `fleet-queue`, so you never edit
   them per project). These are the two worker skills plus `dispatch-work` (the
   coordinator's forward-dispatch playbook — not hub-coupled, so it covers hub-less
   projects too). They go to `~/.agents/skills/` — the cross-CLI standard dir —
   with per-skill symlinks in `~/.claude/skills/` for Claude Code:
   ```bash
   mkdir -p ~/.agents/skills ~/.claude/skills
   for s in propose-doc-change resolve-finding dispatch-work; do
     cp -r "templates/skills/$s" ~/.agents/skills/
     ln -sfn ~/.agents/skills/$s ~/.claude/skills/$s
   done
   ```
   The hub-coupled coordinator skills (`doc-nav`, `process-agent-queue`) are seeded
   into each hub by `fleet-init --hub` instead; if you made a hub by hand, copy them
   from `templates/skills/` into `<hub>/.agents/skills/` the same way.

   Same idea for your per-user *instructions* (identity, machine facts,
   cross-project rules): `fleet global` installs one canonical `~/.agents/AGENTS.md`
   and wires every installed CLI to it (Claude `@import`, opencode symlink, Gemini
   + Antigravity `~/.gemini/GEMINI.md`; an existing `~/.claude/CLAUDE.md` is
   migrated in). Cursor has no CLI global file, so the canonical is injected per
   worktree as an always-apply rule (git-excluded) — a temporary bridge. Copilot
   reads a repo's `AGENTS.md` natively, so nothing per-user is wired for it. Write
   it once, every agent reads it. `fleet global status` shows what is wired.
5. Check your posture:
   ```bash
   fleet-assess           # THIN / GROWING / MATURE + what to do about it
   ```
6. Launch a working session (creates or reopens a worktree and starts the agent):
   ```bash
   fleet                  # the COORDINATOR: launch/resume the agent in the hub
   fleet w my-task        # a WORKER (interactive, for a human): worktree + agent
   fleet -a gemini w my-task  # same worktree, another enabled agent
   fleet dispatch my-task "<task>"  # a WORKER headless (for an agent-coordinator):
                          #   detached tmux window; watch: fleet attach
   fleet dispatch --model opus big "<task>"   # pick the worker's model (claude)
   fleet --machine vm dispatch my-task "<task>"  # headless worker ON the VM
   fleet wait my-task     # block until a dispatched worker finishes (rc)
   fleet ls               # worktrees (session markers + [dispatch: done rc=N])
   fleet status           # the whole tree (machines/coordinator/workers/queue)
   fleet status --json    # same, machine-readable (what a dashboard/UI consumes)
   fleet status --remote  # also gather VM sessions over ssh (default: local only)
   fleet context          # what an agent auto-reads at launch, per role + ~tokens
   fleet context --json --budget 3000  # machine-readable; exit non-zero if over budget
   fleet peek local hub   # dump a session's terminal   ·   fleet send local hub "y"
   fleet del my-task      # remove one (guarded)  ·  fleet prune  = all merged ones
   fleet agents / doctor  # enabled packs / installed+logged status per pack
   fleet chats [<worker>] # per-pack pointer to the recorded conversation (read
                          #   to reprise a dead/other agent's session; not portable)
   fleet doctor --write-probe   # prove auto mode can actually write (witness file)
   fleet machines         # the project's machines (selected + registry pool)
   fleet add-agent PACK   # enable another pack (then refreshes every worktree)
   fleet refresh          # re-run the enabled packs' worker setup (all, or one name)
   fleet global           # install ONE per-user instructions file into every CLI
   ```
   Every session runs inside tmux (local mirrors the VM), so it survives a
   disconnect and stays observable/controllable — `fleet peek`/`send` from a
   laptop or phone, `fleet attach` to jump in. A worktree is agnostic: every
   enabled pack sets it up, so any enabled agent can open it. Sessions never
   transfer between agents; what crosses over is the branch, the commits, and
   the written context.
7. Machines are a global pool (`~/.config/fleet/machines/<name>.env`, or
   `fleet machines add <name> <ssh-host>`); a project picks which it runs on with
   `MACHINES="local vm-gpu"` in its .env (`fleet-init --machine`). `local` is
   this box. Run a session on any of them with `--machine`, and `fleet r` is
   shorthand for the project's first non-local machine:
   ```bash
   fleet --machine vm-gpu w my-task   # worker ON vm-gpu (worktree lives there)
   fleet --machine vm-gpu             # the coordinator, on vm-gpu
   fleet r                # attach the remote machine's tmux (survives your laptop)
   fleet r w my-task      # create/reopen the worker there, then attach
   fleet r hub            # the coordinator, there
   fleet r del my-task    # delete a remote worker (window + worktree)
   fleet r broadcast "m"  # type m+Enter in every remote tmux window
   fleet sync-remote [M]  # ship this engine to the project's VM(s) + rebuild (stamps its SHA)
   ```
   `--machine vm` also works with `dispatch` (headless worker on the VM,
   delegated to its container). A work command against a VM warns when its baked
   engine SHA lags your local one; `fleet sync-remote` clears it.
   A single legacy `REMOTE_HOST` (`fleet-init --remote HOST`) still works,
   treated as a machine named `remote`. `alias fr='fleet r'` if you want it
   shorter; the repo installs nothing outside the project config.

8. Resource guard rails keep a fan-out from crashing a box. `fleet dispatch`/`w`
   refuse to launch when the target machine is at a worker/RAM/disk limit
   (`MAX_WORKERS` / `MIN_FREE_MB` / `MIN_FREE_DISK_MB`, per-machine in
   `machines/<name>.env`, global in `default.env`; built-ins 6/2048/5120, `0`
   = off). Fail-fast: wait for a slot (`fleet wait`) and retry, or override with
   `fleet --force dispatch …` / `FLEET_NO_GUARD=1`. The admission gate has no
   runtime re-check, so on a constrained box also set `WORKER_NODE_MAX_MB` (a V8
   heap cap that OOM-kills a leaking node worker cleanly), and note `fleet
   del`/`prune` now reap the worker's tmux window so dead windows stop inflating
   the count. See
   [docs/07](docs/07-machine-and-solo.md#resource-guard-rails-dont-oom-the-box).

**Working solo is fine.** You do not need workers, a queue, or routines to
benefit. One repo + one agent session + a hub adapted to your work already gives
you the biggest token win (cheap, indexed context). The fleet is a scale-up you
add as the hub matures. See [docs/07](docs/07-machine-and-solo.md).

Or skip the manual steps: paste [BOOTSTRAP.md](BOOTSTRAP.md) into a fresh session
of your agent CLI and let it set this up for your project, proposing before it
builds.

## Repo layout

```
agent-fleet/
├── README.md                 you are here
├── AGENTS.md                 repo context (keep bin/ and docs in sync); CLAUDE.md = @AGENTS.md bridge
├── BOOTSTRAP.md              prompt to paste into your agent CLI to set this up
├── docs/
│   ├── 01-mental-model.md    context-boundary = agent boundary (start here)
│   ├── 02-roles-and-barrier.md   coordinator vs worker, the hook barrier
│   ├── 03-queue.md           one inbox, structured handoffs, report-only
│   ├── 04-routines.md        scheduled reviews, cloud vs local
│   ├── 05-adaptive-posture.md    the tipping point that moves with hub maturity
│   ├── 06-token-economy.md   the numbers and the sources
│   └── 07-machine-and-solo.md    machine-wide multi-project setup + working solo
├── bin/                      agent-agnostic core
│   ├── fleet                 launcher: create/reopen/list/delete + launch the agent
│   ├── fleet-init            register a new project (config + optional hub seed)
│   ├── new-worker            low-level: worktree + per-pack read-only-hub barrier
│   ├── fleet-config.sh       project resolver + pack loader (sourced by the above)
│   ├── fleet-queue           print the active project's queue config (skills read it)
│   ├── hub-readonly-guard.py the barrier hook (shared: claude PreToolUse, gemini BeforeTool)
│   ├── fleet-notify          ntfy.sh notifier wired into worker hooks (NTFY_TOPIC in the .env)
│   ├── fleet-migrate         explicit one-shot migration from the legacy claude-fleet config
│   ├── fleet-status.py       the whole tree as JSON/text (fleet status), for a UI
│   ├── fleet-context.py      front-loaded context per role as JSON/text (fleet context)
│   ├── fleet_common.py       shared .env parser + barrier-file set (imported by the two .py above)
│   └── fleet-assess          score hub maturity → recommend a posture
├── packs/                    one dir per agent CLI: 6 required pack_* functions + optional pack_doctor
│   ├── claude/pack.sh        Claude Code: launch/resume flags, sessions, barrier settings
│   ├── gemini/pack.sh        Gemini CLI: same contract via BeforeTool hook
│   ├── opencode/pack.sh      opencode: declarative barrier, per-worktree session filter
│   ├── cursor/pack.sh        Cursor CLI: declarative barrier (.cursor/cli.json), md5-cwd sessions
│   ├── antigravity/pack.sh   Antigravity: OS mount-namespace barrier (hub ro), no in-CLI deny; fails closed w/o userns
│   └── copilot/pack.sh       GitHub Copilot CLI: OS mount-namespace barrier (hub ro) like antigravity; reads AGENTS.md natively
├── templates/
│   ├── fleet.env             per-project config (projects/<name>.env)
│   ├── default.env           cross-project defaults (default.env: MACHINES_DEFAULT, resource limits)
│   ├── machine.env           machine registry entry (machines/<name>.env)
│   ├── global-AGENTS.md      per-user instructions seed, installed by `fleet global`
│   ├── hub-INDEX.md          index router skeleton
│   ├── hub-AGENTS.md         hub project instructions skeleton
│   ├── worker-settings.local.json   the claude barrier settings (reference)
│   └── skills/               dispatch-work, doc-nav, process-agent-queue, propose-doc-change, resolve-finding
├── test/
│   ├── make-sandbox.sh       throwaway sandbox project to exercise the tools
│   ├── test-guard.sh         unit + isolated-E2E tests for the resource guard rail
│   ├── test-context.sh       isolated-fixture tests for the context reporter
│   ├── dispatch.sh           headless dispatch: per-pack flags, tmux worker, remote, write-probe
│   ├── global.sh             fleet global wiring across the packs
│   ├── barrier-cursor.sh     cursor read-only-hub barrier (structural + opt-in live)
│   ├── barrier-antigravity.sh  antigravity mount-namespace barrier E2E
│   └── barrier-copilot.sh    copilot mount-namespace barrier E2E
└── deploy/                  run the fleet on an always-on VM (Docker), see deploy/README.md
```

## The adaptive part

There is no single fixed posture. When your hub is thin (early project, little
doc), context is expensive to build, so you run a narrow fleet and spend tokens
*manufacturing* context (write what you learn into the hub). When the hub is
mature, context is a cheap lookup, so you batch hard, offload throwaway
exploration to subagents, and scale wide. `fleet-assess` reads your hub and tells
you which regime you are in and what posture fits. The full model is
[docs/05-adaptive-posture.md](docs/05-adaptive-posture.md).

## Running on a VM

tmux keeps a session alive across disconnects, but only while the machine is on.
To keep the fleet running when your laptop is off, run it on an always-on VM in a
dedicated Docker container (isolation matters: workers run with skipped
permissions). The generic tools bake into the image; repos, config, and your login
live on a persistent volume. One-time setup and daily use are in
[deploy/README.md](deploy/README.md). Day to day you rarely ssh by hand:
`fleet r` from the laptop attaches the VM's tmux, `fleet r w <name>` opens a
worker there (the VM is a machine in the project's `MACHINES`, or a legacy
`REMOTE_HOST`). Several containers can share one host via `FLEET_CONTAINER` /
`FLEET_TMUX` in `deploy/.env`.

## License

MIT. See [LICENSE](LICENSE).
