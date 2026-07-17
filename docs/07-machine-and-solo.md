# 07 — Machine-wide setup, and working solo

Two things this doc covers: how the tooling lives at the **machine** level so one
improvement reaches all your projects, and how the same setup lets you work the
**old way** (one repo, one agent session) while still getting the main benefit.

## Machine-wide, not per-project

The scripts are generic and canonical in one place; each project just declares
its paths. Improve a script once, every project gets it.

```
   ~/agent-fleet/bin/                canonical tools (edit HERE)
     ├── fleet            launcher: create/reopen/list/delete + launch the agent
     ├── new-worker       low-level: worktree + read-only-hub barrier
     ├── fleet-assess     score hub maturity → posture
     ├── fleet-config.sh  shared project resolver (sourced by fleet + new-worker)
     ├── hub-readonly-guard.py   the shared barrier hook (per-pack wiring)
     ├── fleet-init / fleet-queue / fleet-notify / fleet-migrate   (see README)
     └── packs/…          one dir per agent CLI (claude, gemini, opencode, cursor, antigravity, copilot)
        │  symlinked onto PATH
        ▼
   ~/.local/bin/          fleet, fleet-init, new-worker, fleet-assess, ...  (+ your aliases)

   ~/.config/fleet/projects/
     ├── <projectA>.env   CODE_REPO / HUB / WT_HOME / AGENTS / MACHINES ...
     └── <projectB>.env   (HUB optional: a project can have no hub yet)

   ~/.config/fleet/machines/
     ├── <vm-gpu>.env     MACHINE_HOST / MACHINE_CONTAINER / MACHINE_TMUX ...
     └── <vm-eu>.env      (a global pool; projects reference them by name)
```

### Machines are a global pool; projects select

A **machine** is a place a session runs: this box (`local`, implicit) or a VM
running the deploy/ container. Machines live in a global pool,
`~/.config/fleet/machines/<name>.env` (`MACHINE_HOST` + optional
`MACHINE_CONTAINER`/`MACHINE_TMUX`/`MACHINE_ENGINE_DIR`/`MACHINE_PROJECT`), added
by hand from `templates/machine.env` or with `fleet machines add <name>
<ssh-host>`. Any project can use any machine; a project picks which with
`MACHINES="local vm-gpu"` in its .env (`fleet-init --machine`). A machine listed
by one project is de facto dedicated; one listed by several is shared. Machines
common to *every* project go in `MACHINES_DEFAULT` in
`~/.config/fleet/default.env`, so you do not repeat them.

Run a session anywhere with `--machine`: `fleet --machine vm-gpu w <name>` opens
the worker on that VM (the worktree lives there), `fleet --machine vm-gpu` the
coordinator, and `fleet --machine vm-gpu dispatch <name> "<task>"` a **headless**
worker on the VM — delegated to the container's own `fleet dispatch`, so the
worktree, `.status`, and the resource guard all live and run there (same
ssh+docker transport as an interactive session; the task rides as base64 so
multi-line prompts survive the ssh→docker→bash quoting). `fleet r` is shorthand
for the project's first non-local machine: `fleet r` attaches its tmux, `fleet r
w <name>` opens a worker there. Inspect the selection and the pool with `fleet
machines`; see the whole live tree (machines, coordinator, workers, queue) with
`fleet status` (`--json` for a UI, `--remote` to also gather each VM's sessions
over ssh — it runs the container's own `fleet status --json` and grafts it in, so
the VM needs a synced engine). A project can be **remote-only**:
`MACHINES="vm-gpu"` with no local clone.

The engine baked in a VM's image is stamped with its git SHA (`fleet sync-remote`
sets it on rebuild). A work-spawning command against a VM (`fleet --machine X w`,
`... dispatch`) prints a **non-fatal** warning when that SHA lags your local
HEAD, so a stale VM does not silently run old dispatch/barrier code — `fleet
sync-remote X` ships the engine and rebuilds (stamping the new SHA). Read paths
(`fleet r` attach, `fleet status`) skip the check to avoid an extra ssh hop.

A coordinator is just the `hub` window in the machine's tmux session (`fleet`, or
`fleet --machine X`); it persists across SSH disconnects like every other window.
Do not hand-launch a CLI's own remote-control / headless mode inside a bare
detached tmux (`tmux new-session -d …`): with no client ever attached its stdin
hits EOF and it exits immediately. Let `fleet` own the window and attach through a
view (`fleet` / `fleet r`).

Every session runs inside tmux on its machine (local mirrors the VM), so it
survives disconnects and is observable from anywhere: `fleet peek <machine>
<window>` dumps a session's terminal and `fleet send <machine> <window> "<text>"`
types into it (answer a permission prompt from your phone). `fleet r broadcast
"<msg>"` types the same line into every window of a remote machine.

One tmux session per machine holds every window (the coordinator's `hub` plus
one per worker), but no terminal ever attaches to it directly. tmux shares a
single active window across all clients of a session, so a raw attach would yank
a coordinator already viewing one window onto whatever a new `fleet w` selects.
Instead each `fleet` / `fleet w` / `fleet attach` opens a private **view** — a
grouped tmux session (named `fv-*`) that shares the machine session's window
list, so new workers still appear, but keeps its own active window and
self-destructs when you detach. Launching a worker never drags another terminal.
The `fv-*` prefix is also why the worker count below (which scans `fleet*`
sessions) never double-counts a view's shared windows.

A single legacy `REMOTE_HOST` (`fleet-init --remote HOST`, optional
`REMOTE_CONTAINER`/`REMOTE_TMUX`/`REMOTE_PROJECT`/`REMOTE_ENGINE_DIR`) still
works, synthesized as a machine named `remote`. Prefer the registry for anything
new. Several containers can share one host via `FLEET_CONTAINER`/`FLEET_TMUX` in
`deploy/.env`, each matched by a registry entry's `MACHINE_CONTAINER`/
`MACHINE_TMUX`.

### Resource guard rails (don't OOM the box)

Every worker is a full agent process plus a git worktree, so an unbounded fan-out
(`dispatch-work` calling `fleet dispatch` in a loop) can exhaust a machine's RAM
or fill its disk and crash it. `fleet` refuses to launch a worker when the
**target machine** is at a limit — a fail-fast guard, not a queue. It applies to
both `fleet dispatch` (headless) and `fleet w` (interactive), on whichever machine
you target, each checked against that machine's own limits — a remote `dispatch`
runs the guard inside the container, where the worker actually spawns.

Three per-machine limits (a `0` turns that check off):

| key | what it caps | built-in default |
|-----|--------------|------------------|
| `MAX_WORKERS` | live workers on the machine | 6 |
| `MIN_FREE_MB` | free RAM (`MemAvailable`) floor, MB | 2048 |
| `MIN_FREE_DISK_MB` | free disk on `WT_HOME`'s filesystem, MB | 5120 |

Set them where they belong, **most-specific wins**:

1. Per machine — `MACHINE_MAX_WORKERS` / `MACHINE_MIN_FREE_MB` /
   `MACHINE_MIN_FREE_DISK_MB` in `~/.config/fleet/machines/<name>.env` (size to
   the box: a big VM tolerates far more than a laptop). The local box can carry
   its own via a `machines/local.env` with `MACHINE_HOST=local`.
2. Globally — `MAX_WORKERS` / `MIN_FREE_MB` / `MIN_FREE_DISK_MB` in
   `~/.config/fleet/default.env` (all projects) or a project `.env`.
3. Built-in defaults (above) when nothing is set.

The worker **count** is machine-wide: it sums the live windows across every
`fleet*` tmux session on the box (so it stays honest when several projects share
a machine), minus each session's `_home` and `hub` windows — the coordinator's
own memory is caught by the RAM floor instead of the count. The RAM and disk
floors read `/proc/meminfo` and `df` directly, so they already see everything on
the machine. On a remote machine the probe runs over the same ssh+docker
transport as the session; if it can't measure RAM/disk (probe failure) it skips
that floor rather than blocking (the count still applies).

When a limit trips, `fleet` prints what tripped and the current usage, then
exits non-zero — a coordinator should wait for a worker to finish
(`fleet wait` / `fleet ls`) and retry, which naturally throttles the fan-out.
Override a single launch with `--force` (a global option, before the subcommand:
`fleet --force dispatch big "…"`) or `FLEET_NO_GUARD=1 fleet dispatch big "…"`.

**Per-worker heap cap (the admission guard's blind spot).** The guard only checks
at launch; once workers run, nothing re-checks them, and node-based agent CLIs
leak unbounded — N of them in parallel can OOM the whole host, which the
admission gate never re-fires to stop. Set `WORKER_NODE_MAX_MB` (same precedence
as the floors: machine `.env` > project `.env` > `default.env` > built-in) and
the node packs (claude/gemini/opencode/copilot) launch with
`NODE_OPTIONS=--max-old-space-size=<MB>`, so a runaway worker is OOM-killed
cleanly (its window shows a non-zero rc via `fleet ls`) instead of dragging the
box down. Built-in default `0` (off): a shipped cap would surprise big-box users,
so a constrained box opts in. It respects a `NODE_OPTIONS` you already export and
is inherited by node the worker itself spawns (a task's `npm run build`), so size
it above a legitimate build; the knob is the escape hatch.

**Small-box preset.** On a constrained machine (e.g. WSL2 with ~8 GiB, where the
VM has no memory cap and node CLIs leak), put the tighter numbers in a
`machines/local.env` (`MACHINE_HOST=local`) so they stay machine-specific:
```sh
MACHINE_MAX_WORKERS=2
MACHINE_MIN_FREE_MB=3072
WORKER_NODE_MAX_MB=2048
```
The biggest single lever on WSL2 lives outside the repo: cap and reclaim the VM
itself in `%USERPROFILE%\.wslconfig` (`memory=`, `swap=`, `autoMemoryReclaim=gradual`),
then `wsl --shutdown`, so even a worker OOM cannot freeze Windows.

**Teardown reaper.** `fleet del` / `fleet prune` remove the worktree *and* kill
the worker's tmux window and GC its dispatch sidecars (`.status` / `.meta`) — a
finished dispatch window is otherwise kept "for inspection" and would keep
counting against `MAX_WORKERS`, causing false refusals. The dispatch `events.log`
is capped so it cannot grow without bound.

### How the active project is resolved

`fleet`, `new-worker`, and `fleet-assess` pick the project in this order:

1. `--project <name>`
2. `$FLEET_PROJECT`
3. **your current directory** (a project whose `CODE_REPO`, `HUB`, or `WT_HOME`
   contains it — so it also works from inside a worker's worktree)
4. otherwise an **error** listing known projects

So from inside a project's repo, `fleet w my-task` just works (and bare
`fleet` opens the coordinator in the hub). There is
deliberately **no implicit default project**: from an arbitrary directory you
must name the project. A silent fallback means a command aimed at project A
quietly lands on project B — worktrees created on the wrong repo, remote
workers opened on the wrong VM. Fail loud instead.

### Project-specific aliases

Keep a memorable per-project command as a thin wrapper that pins the project, so
muscle memory survives:

```bash
# ~/.local/bin/mycmd
#!/usr/bin/env bash
exec fleet --project myproject "$@"
```

### Adding a project

One command:

```bash
fleet-init newproj --code ~/newproj-repo --queue none
# or, with a hub + a tracker:
fleet-init newproj --code ~/newproj-repo --hub ~/newproj-hub --queue linear \
  --linear-team TEAM --linear-project-id <uuid> --linear-project-name "Agent Queue"
# or from scratch — no --code: scaffold ~/newproj (base commit, pushed to a new
# private GitHub repo) + a committed ~/newproj-hub (pushed to a private
# <owner>/newproj-hub), queue defaulting to github:
fleet-init newproj
```

No fleet edit. The scripts are generic and config-driven, and so are the skills:
you add a project, not a workflow.

### Why the skills do not need per-project editing

The worker skills (`propose-doc-change`, `resolve-finding`) and the coordinator's
queue skills (`process-agent-queue`, `dispatch-work`) are **generic and
config-driven**. They do not hardcode a tracker; they run `fleet-queue` to learn
the active project's queue backend and coordinates, then act accordingly:

- `QUEUE_KIND=linear` → file into the configured Linear team/project.
- `QUEUE_KIND=github` → `gh issue create` in the configured repo.
- `QUEUE_KIND=none` → there is no tracker; the worker surfaces the drift/finding
  to you directly. This is the solo / early-project case, and it just works.

So one copy of each skill covers every project. Improve a skill once, every
project gets it. Project-specific skills (deploy access, stack-specific audits)
stay with their project and are unaffected. Install home splits by whether a skill
touches the hub:

- **Not hub-coupled → user level** (`~/.agents/skills/`, symlinked into
  `~/.claude/skills/` for Claude Code): the worker skills and `dispatch-work`. They
  work off `fleet-queue` + `fleet dispatch` alone, so they cover any project,
  including a **hub-less** one (a code repo with a GitHub-Issues queue and no docs
  hub). User level also means a teammate cloning the code repo does not inherit your
  queue.
- **Hub-coupled → seeded into each hub** by `fleet-init` from the templates:
  `doc-nav` (navigates the hub docs) and `process-agent-queue` (integrates doc
  proposals into the versioned hub). They only make sense where a hub exists.

Your per-user *instructions* follow the same "one copy, machine-wide" shape.
Each CLI reads its own global file, which drifts if maintained by hand. `fleet
global` keeps one canonical `~/.agents/AGENTS.md` and wires every installed CLI
to it:

- **Claude Code** — `~/.claude/CLAUDE.md` gets a one-line `@import`; an existing
  CLAUDE.md is migrated into the canonical (backup kept).
- **opencode** — `~/.config/opencode/AGENTS.md` symlinked to it.
- **Gemini + Antigravity** — `~/.gemini/GEMINI.md` (the doc'd global file both
  read every session; agy reuses `~/.gemini/`) symlinked to it.
- **Cursor** — the CLI has *no* user-level global file (verified against its
  docs). Temporary bridge: `fleet` injects the canonical as an always-apply
  `.cursor/rules/00-fleet-user.mdc` (git-excluded so personal notes never land in
  the code repo) into each worktree (at setup / `fleet refresh`) **and into the
  hub at coordinator launch** — so both worker and coordinator cursor sessions
  see it. This is the generic pattern for any provider without a native global
  file: `pack_global_setup` wires the native file, else `pack_global_inject`
  drops it into the working dir. Drop it once the cursor CLI ships a global file.
- **GitHub Copilot** — nothing per-user is wired: Copilot reads a repo's
  `AGENTS.md` natively (the same file the hub and worktrees already carry), so
  `fleet global` leaves it alone.

Write your identity / machine facts / cross-project rules once; every agent reads
them. `fleet global status` shows what is wired. Keep this file small: project
detail belongs in the repo's `AGENTS.md`.

## Working solo (the old way, but with an adapted doc base)

You do not need the full fleet to get value here. The minimum viable version is
just **one repo, one agent session, and a docs hub adapted to your work**. That
is the classic way of working with a coding agent, plus the one thing that moves
the token bill: a distilled, greppable, indexed context tuned to *this* project.

What you get solo, with no workers, no queue, no routines:

- **Cheap, adapted context.** The hub's index router means the session reads the
  one relevant doc instead of spelunking the codebase every time. That is the
  single biggest token lever (see [06](06-token-economy.md)), and it works with a
  single session.
- **Continuity.** The hub is durable memory across sessions. You do not re-explain
  the architecture each morning; you point at the hub.
- **A ramp, not a wall.** A brand-new project has no hub, so `fleet-assess`
  reports THIN and you simply work in the repo directly, distilling what you learn
  into a growing hub. As the hub matures, the same setup lets you add workers,
  then a queue, then routines. Nothing to rebuild.

The fleet is a **scale-up**, not a prerequisite. The adaptive posture
([05](05-adaptive-posture.md)) is exactly this: THIN means "work solo and build
context", MATURE means "exploit context and parallelize". Same machine setup,
same commands, all the way along.

```
   SOLO                     GROWING                    FLEET
   one repo + one agent      hub covers key zones,      many workers on
   + a small hub you feed     a worker or two on the    independent streams,
   as you go                  documented parts          a queue, routines
   ───────────────────────────────────────────────────────────────────────►
                     you never change tools, only posture
```

So: use `fleet w <name>` to launch a single working session on a repo that has an
adapted hub, and you are already ahead of a plain agent-in-a-repo. Add the rest
when the work asks for it.
