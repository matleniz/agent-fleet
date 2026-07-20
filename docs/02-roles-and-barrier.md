# 02 — Roles and the barrier

Two roles. One writes docs, the other writes code. They never write the same
files, and the split is enforced mechanically, not by good intentions.

```
                     ┌───────────────────────────┐
                     │        DOCS HUB             │
                     │     the single writer        │
                     └───────────────────────────┘
                                  ▲  writes docs
                                  │
                      ┌───────────┴───────────┐
                      │   COORDINATOR session   │
                      │   started in the hub     │
                      │   • owns the docs         │
                      │   • triages the queue     │
                      │   • briefs from the vista  │
                      └───────────┬─────────────┘
                                  │ read-only
                  ┌───────────────┼───────────────┐
                  │ Read          │ Read          │ Read
      ┌───────────▼──┐   ┌────────▼─────┐   ┌─────▼────────┐
      │  WORKER A     │   │  WORKER B     │   │  WORKER C     │
      │ worktree      │   │ worktree      │   │ worktree      │
      │ writes CODE   │   │ writes CODE   │   │ writes CODE   │
      │ → branch → PR │   │ → branch → PR │   │ → branch → PR │
      └───────────────┘   └───────────────┘   └───────────────┘
             worktrees of the code repo (single clone)
```

## Coordinator

An agent session started **from the docs hub**. It is the only session allowed
to write the docs. It reads the code repo when needed, triages the queue,
integrates accepted changes into the hub, and briefs workers from the docs vista.
When it has a piece of work bigger than one coherent change, it decomposes it
before dispatching — by **file ownership, not pipeline phase**, so the resulting
PRs do not collide (the `dispatch-work` skill and [03](03-queue.md) carry the
playbook).

Key discipline: the coordinator **does not explore or fix the real code itself**.
That is each worker's job in its own worktree. The coordinator works from the
distilled vista (the hub) and dispatches. This keeps its context small and its
cache warm.

## Worker

An agent session in a **git worktree** of the code repo. It writes code and opens
PRs. It is **read-only on the hub**. A worker that wants to change a shared doc
does not edit it: it posts a proposal to the queue (skill `propose-doc-change`)
for the coordinator to review.

Spawn a worker with one command:

```bash
new-worker <name> [base]      # creates a worktree + injects the per-pack barriers
fleet w <name>                # launches the project's default agent in it
fleet -a gemini w <name>      # or any other pack enabled for the project
```

`fleet w` is **interactive**: it opens the agent in a tmux window on the target
machine and attaches you, for a human at a keyboard. It stays observable and
controllable after you detach (`fleet peek`/`send`, `fleet attach`). When the
coordinator is itself an agent (no human to drive a TUI), it dispatches
**headless** instead:

```bash
fleet dispatch <name> "<task>"   # worktree + detached tmux window, task run non-
                                 # interactively with the pack's bypass posture
fleet attach                     # attach the machine's tmux; fleet ls for status
```

`dispatch` reuses each pack's `pack_launch_headless` (e.g. cursor `agent -p
--force`, claude `claude -p --permission-mode auto`), so the worker has
real shell/tool access **and** the read-only-hub barrier still holds. Hand-rolling
the launch instead (e.g. `agent -p --trust`, which is not a real cursor flag) is
what produces a worker with no shell; go through `dispatch`.

More generally: **the posture rides the launch**. Permission mode, barrier, MCP
profile, resource guard, heap cap all exist only because `fleet` applied them at
launch time — a CLI started by hand (or by a coordinator-generated script that
calls the CLI or raw `tmux new-window` directly) has none of them, and nothing
flags it afterwards. The seeded hub context and the `dispatch-work` skill make
this a hard rule for coordinators: every agent launch is a `fleet` command. The
same trap exists on the human side via a shell alias that injects launch flags
(an alias only fires in interactive shells, so pack launches are immune — but a
manual relaunch in a dead window gets poisoned; see the dead-window relaunch in
docs/07, which removes the reason to relaunch by hand at all).

The node packs (claude/gemini/opencode/copilot) also call `fleet_node_heap_guard`
in both launch paths, which exports `NODE_OPTIONS=--max-old-space-size` when
`WORKER_NODE_MAX_MB` is set — an anti-crash rail for constrained boxes, off by
default (see [docs/07](07-machine-and-solo.md#resource-guard-rails-dont-oom-the-box)).

The claude pack launches in **auto mode** rather than
`--dangerously-skip-permissions`: on an org account whose managed settings set
`permissions.disableBypassPermissionsMode: "disable"`, the bypass flag is
silently downgraded to prompting (so every write auto-denies in headless), while
auto mode — autonomous with a server-side classifier gating each action — is left
untouched by that policy. Headless auto mode aborts if the classifier blocks
repeatedly (no human to approve), so classifier-tripping work belongs in an
interactive `fleet w` session. See `packs/claude/pack.sh`.

That failure mode is silent — a wrongly-gated box accepts a dispatch, writes
nothing, and exits `rc=0`. To confirm a box (or a fresh VM) can actually write
before dispatching a fleet at it, `fleet doctor --write-probe [--machine M]`
runs one tiny headless turn per pack in a throwaway dir and checks it produced
the witness file: `PASS` means auto mode writes there, `FAIL` points at the
managed-permission / login problem. It costs a few tokens, so it is opt-in and
never part of a bare `fleet doctor`.

Knowing when a worker finished: the headless process exits when its conversation
ends, so `dispatch` records completion in `$FLEET_HOME/dispatch/<proj>/` (a
`<name>.status` of `running` / `done rc=N`, plus `events.log`). A coordinator is
an agent — it cannot receive an ntfy push — so it reads that state: `fleet ls`
shows `[dispatch: done rc=0]` per worker, and `fleet wait [<name>]` blocks until
the worker(s) finish and returns their rc. `NTFY_TOPIC` still gets the human's
phone ping. (This clean signal is for dispatched/headless workers; an interactive
`fleet w` session has no single "conversation ended" moment.)

`rc=0` means the process finished, **not** that it produced a correct deliverable:
a headless agent that crashes on an API error or wanders off-task still exits 0
with an empty branch. So check the deliverable, not just the rc. `fleet status`
does this for you: it reports each worker's commits above the base and flags a
finished worker that produced none (`[empty: finished, no commits]`), which is the
tell for an agent that failed its task rather than a fleet problem.

The coordinator has its own command — it IS the bare one: `fleet` launches (or
resumes) the default agent in the project's hub.

Worktrees (not fresh clones) because they share the repo's object store: cheap to
create, cheap on disk, and each has its own working tree and branch so workers do
not step on each other.

## The barrier (read this, it is subtle)

The barrier is **per agent pack**: each pack enabled for the project
(`AGENTS="claude gemini"`) installs its own read-only-hub mechanism into the
worktree via `pack_worker_setup`, using its CLI's native means. The principle
is always the same — expose the hub for *native reads* (the agent keeps its own
Read/Grep/ls tools on it), block writes mechanically — and one guard script
(`hub-readonly-guard.py`) is shared by all packs: both Claude Code and Gemini
CLI hand it the tool-call JSON on stdin (`tool_input.file_path`) and treat
exit 2 as "block, stderr is the reason".

If ANY enabled pack's `pack_worker_setup` fails, `new-worker` rolls the whole
worktree back (worktree + fresh branch) instead of leaving it half set up: a
persisted worktree missing one pack's barrier would be reopened later by
`fleet w` with no barrier at all — the silent fail-open this doc refuses.
Every pack also declares the files it writes (`pack_barrier_files`), which is
how `fleet del`/`fleet prune` know those untracked configs are not real
uncommitted work.

**Claude Code** (`packs/claude`): the obvious approach, "add a `deny` rule for
Write/Edit on the hub path", **does not work**. To let a worker *read* the hub
you must add it to `additionalDirectories`, and that grants read **and write**.
A `deny` rule does not override an `additionalDirectories` root: in
`acceptEdits` mode the write goes straight through. So the real barrier is a
**PreToolUse hook**, written into the worktree's `.claude/settings.local.json`
(the `allow: Read` line is cosmetic; the hook enforces the rule):

```json
{
  "permissions": {
    "allow": ["Read(/abs/path/to/hub/**)"],
    "additionalDirectories": ["/abs/path/to/hub"]
  },
  "hooks": {
    "PreToolUse": [{
      "matcher": "Write|Edit|MultiEdit|NotebookEdit",
      "hooks": [{ "type": "command", "command": "/path/to/hub-readonly-guard.py /abs/path/to/hub" }]
    }]
  }
}
```

**Gemini CLI** (`packs/gemini`): same shape with Gemini's native pieces, written
into the worktree's `.gemini/settings.json` — `context.includeDirectories`
grants native reads on the hub, and a **BeforeTool hook** on `write_file|replace`
runs the same guard (Gemini's hook contract mirrors Claude Code's: stdin JSON,
exit 2 blocks, stderr becomes the reason sent to the agent).

**opencode** (`packs/opencode`): no hook at all — the barrier is declarative in
the worktree's `opencode.json`: `permission.external_directory` allows native
reads on the hub, `permission.edit` denies edit/write/patch on it. One trap,
learned the hard way (the sandbox E2E let a hub write through before the fix):
opencode matches edit patterns against the path **relative to the worktree**
(`path.relative(worktree, file)` in `tool/edit.ts`), so an absolute-only deny
pattern silently never matches. The pack writes the deny in relative form
(computed per worktree) plus the absolute form as belt-and-braces. Explicit
denies hold under `--auto`.

**Cursor CLI** (`packs/cursor`): declarative like opencode, in the worktree's
`.cursor/cli.json` — `Read(hub/**)` allowed, `Write(hub/**)` denied. File-tool
rules take absolute-path globs, deny beats allow, and denies hold under
`--force` (its own help says "force allow **unless explicitly denied**").
E2E-verified: hub read OK, hub write refused, worktree write OK.

**Antigravity** (`packs/antigravity`): agy has **no per-path deny mechanism**
(no hooks, no permission rules — verified: in bypass mode it happily wrote to
the hub in the sandbox E2E; its own `--sandbox` is "terminal restrictions", not
a filesystem write jail). So the barrier is moved out of the CLI and into the
**OS**: `pack_launch` runs agy inside an unprivileged mount namespace where
`$HUB` is bind-mounted **read-only** (`unshare --user --map-root-user --mount`
+ `mount -o remount,bind,ro`), a kernel-enforced deny. `pack_worker_setup`
probes that user namespaces + a ro remount actually work and **fails closed**
if not (no userns → refuse the project; use it hub-less or drop it from
`AGENTS`). The jail exists only at launch, so the worker must be driven via
`fleet w`, not a bare `agy` in the worktree. The jail is applied by **role**,
read from the launch cwd: a **worker** (cwd = a worktree, hub external) is
jailed, but the **coordinator** (launched *in* the hub, cwd = the hub) runs
unconfined so it can write the hub it owns. So agy/copilot work as coordinators
too, not only as workers. E2E: `test/barrier-mount-ns.sh antigravity` (worker hub
write denied, hub read OK, worktree write OK, coordinator cwd=hub write OK).

**GitHub Copilot CLI** (`packs/copilot`): same story as antigravity, for the same
reason. Its `write` tool kind matches *all* writes with no path argument (verified
in `copilot help permissions`; per-path wildcards "will be extended in the very
near future"), its path grants are binary (a dir is reachable read+write via
`--add-dir`, or not at all — no read-only grant), and its hooks *could* deny per
path but repo-level hooks (`.github/copilot/settings.local.json`) are deferred and
**do not fire in headless mode** (verified: a sessionStart hook there never ran).
So the barrier is again the **OS**: `pack_launch` runs `copilot` inside the same
unprivileged mount namespace with `$HUB` bind-mounted read-only, and `--add-dir
"$HUB"` lets the worker still *read* the hub (Copilot restricts file access to the
cwd by default) while the ro mount stops writes. `pack_worker_setup` fails closed
without userns, same as antigravity. Same role rule as antigravity: only a worker
(cwd = worktree) is jailed; a coordinator launched in the hub runs unconfined and
can write it. E2E: `test/barrier-mount-ns.sh copilot`, plus a live proof — a jailed
`copilot -p` asked to overwrite a hub file reported `EROFS` and left it unchanged.

Residual hole in the hook/rule-based packs (claude/cursor/opencode/gemini):
their mechanisms match the *file-editing tools*, not the shell tool, so an agent
in bypass mode can still write to the hub through a shell redirect. The
guarantee there is "the standard edit paths are mechanically blocked + the
instruction is explicit", not "write-proof". The antigravity/copilot mount-namespace
jail has no such hole — the read-only mount blocks shell redirects too — so
where write-proofing matters (the VM), the same filesystem-level hardening
(read-only bind mount) is the answer for every pack.

Unrelated to the barrier, a pack may also define an optional `pack_global_setup`
— how that CLI is pointed at the one canonical per-user instructions file for
`fleet global` (Claude `@import`, opencode symlink, Gemini + Antigravity share
`~/.gemini/GEMINI.md`). A CLI with no user-level global file (cursor) instead
defines `pack_global_inject <dir>`; the core drops an always-apply
`.cursor/rules/*.mdc` (git-excluded) into each worktree (`pack_worker_setup`) and
the hub (`cmd_hub`). Copilot defines neither — it reads a repo's `AGENTS.md`
natively, so `fleet global` leaves it alone. Per-user and machine-wide, not a
barrier; see
[07](07-machine-and-solo.md).

## Why this shape

Before roles were split, several heavy diverging clones and several agents
overwriting each other in a shared "docs" folder. The fix: versioned docs with
exactly one writer, a mechanical barrier so a worker *cannot* corrupt the shared
truth, a proposal queue for changes across the boundary, one code clone, and
cheap worktrees. Each session is a clean context boundary (see
[01](01-mental-model.md)).
