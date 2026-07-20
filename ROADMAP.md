# Roadmap

Near-term priorities for agent-fleet, most urgent first. Longer-tail vetted ideas
live in `BACKLOG.md`.

## Next (most urgent)

### Relaunch the agent in a window whose process died  [bug] — DONE
Was: `fleet` / `fleet w <name>` only ever created OR selected their tmux window,
so a window whose agent had exited (surviving as the `exec bash` fallback shell)
was silently focused instead of relaunched, and the operator ran the CLI by hand
outside the fleet posture (auto mode, barrier, MCP profile).

Shipped: `ensure_window_snippet` in `bin/fleet` (used by `session_window`, so
`hub` + `w <name>`, local and remote) detects a dead pane and `respawn-pane`s the
original launch line into it — re-entering the in-window fleet, same resume offer
as first creation. Detection note (verified empirically): `#{pane_current_command}`
reports a shell for alive AND dead panes (the `-c` wrapper does no job control);
dead = the pane process is a childless shell — an agent, an in-window fleet at
its resume prompt, or a command running in the fallback shell all show as
children and are left alone. E2E: `test/relaunch.sh`.

### Fleet-wide conversation-feedback routine  [tooling shipped; scheduling is instance-side]
A scheduled routine (see `docs/04-routines.md`) that analyzes the recorded
conversations across **all** workers and sessions and turns them into method
improvements, not a one-off report, fed back as **proposed changes** to the
trusted context through the same freshness / `propose-doc-change` path a worker
uses — so a lesson lands where it will be front-loaded next time instead of being
lost in a log.

Shipped as a **3-stage pipeline** (A extract / B compress / C distill + finalize;
see `docs/04-routines.md` "The conversation-feedback pipeline"):
- **A extract** — `fleet chats --scan [--all] [--parse] [--history] [--since ISO]
  [--json]` (`bin/fleet-chats-scan.py`): fleet-wide inventory of every pack's
  recorded conversation, with `--parse` attaching a claude-first method signal via
  `bin/fleet_chat_parse.py` (user corrections, tool errors, tool histogram).
  `--history` (the retro's real input) emits one entry per transcript file over the
  `--since` window, **including finished workers whose worktree was deleted** — the
  default scan only gives the latest pointer per live worktree, which misses almost
  all history on a fleet that deletes workers. Claude-first via `pack_chat_history`;
  packs without it fall back to the default per-location scan. Deterministic, no
  model. Local machine only.
- **B compress** — the `conversation-compress` skill (`templates/skills/`): cheap
  model, frequent, LOCAL (the confidentiality + compression boundary). One session
  note per new transcript at `$FLEET_HOME/feedback-notes/<session_id>.json`; the
  note's existence is the dedup. Extractive only.
- **C distill + finalize** — the `conversation-feedback` skill: strong model,
  rarer; reasoning runs local OR off-box (`FEEDBACK_RUNNER`), but dedup + filing +
  digest always local. Routes each lesson by target: `project` → per-project queue
  (`type:doc-proposal` / `type:workflow`), `global` and `upstream` → the dated
  digest (`$FLEET_HOME/feedback-digests/`). Report-only and mechanical.
- **Dedup** — a machine-wide "seen ledger", `fleet feedback seen/record/list/prune`
  (`bin/fleet-feedback.py`, at `$FLEET_HOME/feedback-seen.json`), so a lesson is
  not re-filed every run; recurrence count is itself signal.
- **Knobs** — `fleet feedback config` reports `FEEDBACK_MODEL_COMPRESS` /
  `FEEDBACK_MODEL_DISTILL` / `FEEDBACK_RUNNER` (defaults in `default.env`; built-ins
  haiku/sonnet/local). No `bin/` script calls a model — the model rides the existing
  `pack_launch_headless <prompt> <model>` path.
- **Tests** — `test/test-chats-scan.sh` (scanner + parser + ledger),
  `test/test-feedback-pipeline.sh` (note dedup, `feedback config`, finalize routing).

Remaining:
- **Scheduling wiring is instance-side** (not repo code): install the two local
  jobs (B frequent, C rarer) as a SessionStart hook on claude/gemini, else OS cron,
  throttled; a human launches the first validation run and installs the hook
  (`docs/04` gotchas).
- **The cloud/ssh runner for C** is instance-side too: shipping the notes to a
  cloud agent and getting candidate lessons back. The repo ships the contract +
  the local default (`FEEDBACK_RUNNER=local`); a cloud plug is wired per instance,
  following the `fleet status --remote` ssh pattern for the ssh case.
- **Non-claude transcript parsers** (gemini `chats/`, antigravity SQLite, copilot
  session-state, cursor, opencode) — inventory-only today; each plugs in at the
  parser layer (`fleet_chat_parse.detect_format` + a sibling parser), no scanner
  change. Deferred until needed.

Why now: the fleet already scales *work* across many sessions but has no loop that
scales *learning* from them; every session repeats avoidable mistakes.

### MCP lean profile — finish the coverage
`WORKER_MCP` is native and FULL on gemini, opencode, and claude (claude now via a
generated `.claude/fleet-mcp.json` + `--strict-mcp-config` at launch — see
`packs/claude/pack.sh`, `test/test-mcp-profile.sh`, `docs/06`). Remaining: the
generic CLI-agnostic mount-namespace loader for cursor/copilot/antigravity
(designed in `BACKLOG.md`, a bigger bet — wait for a real need).

## Resource management (anti-crash)  [mostly shipped]

Context: on a memory-constrained host (e.g. WSL2 with a low RAM ceiling) the
fleet can freeze the machine. Root cause is **memory, not disk**.

Status: **B, C (repo side), D are implemented** (heap-cap knob, small-box preset
docs, teardown reaper). **A** is a manual host change (outside the repo) and **E**
(runtime watchdog) is deferred by design — A+B+C+D cover the crash.

## Diagnosis (confirmed)

The freeze is a memory chain, compounded by a launch-time-only guard:

1. **WSL2 has no cap and no reclaim.** A default `%USERPROFILE%\.wslconfig` only
   sets `defaultVhdSize=64GB`. No `memory=`, no `swap=`, no `autoMemoryReclaim`.
   WSL2 takes up to ~50% of host RAM and never returns freed/cached pages to
   Windows (`vmmem` balloons). On a small box this starves Windows itself → freeze.
   Refs: microsoft/WSL#4166, #6394.
2. **Node-based agent CLIs leak, natively.** Documented unbounded growth in
   Claude Code long sessions (heap to 90-120 GB before OOM-kill, V8
   `CheckIneffectiveMarkCompact`). The fleet runs N of them in parallel → N× the
   leak. Refs: anthropics/claude-code#4953, #56693, #22188, #24658.
3. **`fleet_guard` is admission-only.** `bin/fleet-config.sh:288-311`. Checks
   `MemAvailable` once, before launch. Defaults `MAX_WORKERS=6`,
   `MIN_FREE_MB=2048` (`fleet-config.sh:44-45`) are tuned for a big box. Once
   workers are running, nothing watches their growth: no per-process heap cap
   (no `NODE_OPTIONS` anywhere), no cgroup, no ulimit. The guard admits up to 6
   leaking node procs, they blow past the floor, `MemAvailable` → 0, guard never
   re-fires.
4. **No teardown-time reaper (subagent audit).** The fleet has a launch gate but
   never reaps. `cmd_del`/`cmd_prune` (`bin/fleet:483-527`) remove the git
   worktree but never `tmux kill-window` the local worker window (asymmetric with
   the remote path `bin/fleet:413`). Dispatch windows are kept open "for
   inspection" (`bin/fleet:776-778`). Dead windows accumulate and are counted by
   the guard (`guard_probe_snippet`, `fleet-config.sh:252-266`) → false blocks →
   operators reach for `--force`/`FLEET_NO_GUARD=1` → the only rail is disabled.
   `events.log` + `.status`/`.meta` are never GC'd (slow unbounded growth).

Not causes (verified clean): temp cleanup (traps + `rm`, `fleet:440/671`), mount
namespaces in antigravity/copilot packs (per-process `unshare`, 0 leaked), logs
(`events.log` stays tiny). Disk is secondary: the VHD/volume has ample headroom;
worktrees accumulate (a few GB each), `fleet prune` exists but is manual.

## Items (by leverage)

### A — WSL2 cap + reclaim  [OUTSIDE REPO, biggest lever]
Edit `%USERPROFILE%\.wslconfig`:
```ini
[wsl2]
memory=6GB
swap=8GB
autoMemoryReclaim=gradual
defaultVhdSize=64GB
```
Then from Windows: `wsl --shutdown` (kills all WSL sessions, do it when idle).
Effect: even if the VM OOMs, Windows survives; swap absorbs spikes; RAM is
returned. This alone stops the host freeze. Cannot be scripted from inside WSL
(the shutdown would kill the session doing it) — apply by hand.

### B — per-worker V8 heap cap  [IN REPO] — DONE
Implemented: `FLEET_DEF_WORKER_NODE_MAX_MB` (default 0 = off) + `fleet_node_heap_guard`
in `bin/fleet-config.sh`; the four node packs (claude/gemini/opencode/copilot)
call it before `exec` in both launch paths. Override with `WORKER_NODE_MAX_MB`
(project/global). Docs: docs/02, docs/07, README, templates/{fleet,default}.env.
Original design notes below.

Inject `NODE_OPTIONS=--max-old-space-size=<N>` at launch so a leaking CLI gets
OOM-killed cleanly (rc≠0, fleet sees it via `.status`) instead of dragging the
host down. A node hitting the cap self-terminates.
- Design: add `FLEET_DEF_WORKER_NODE_MAX_MB` (e.g. 2048; `0` disables) to the
  defaults block in `bin/fleet-config.sh:44`. Overridable per project/machine
  like the other guard knobs. Respect an env value already set (don't clobber).
- Apply point: node packs only (`opencode`, `copilot`, `claude`, `gemini` —
  those with `npm install` in `pack_install`). Prepend `NODE_OPTIONS` to the
  `exec <cli>` in both `pack_launch` and `pack_launch_headless`. Cheapest via a
  shared helper in `fleet-config.sh` that echoes the value, so each node pack is
  a one-liner. If you only run `AGENTS="claude"`, the claude pack is the
  must-have; wire the others for parity.
- Caveat to document: `NODE_OPTIONS` is inherited by child node the worker
  spawns (a task's `npm run build`), so a genuinely heap-hungry build could hit
  the cap. Acceptable default on a small box; the knob is the escape hatch.
- Docs to update in the same pass (repo rule: docs = done): `docs/02` (barrier /
  launch posture), `README.md` config table, `templates/` project .env comment.

### C — tune the guard for a memory-constrained host  [IN REPO / config] — DONE (repo side)
Repo side shipped: the small-box preset (`MACHINE_MAX_WORKERS=2`,
`MACHINE_MIN_FREE_MB=3072`, `WORKER_NODE_MAX_MB=2048`) is documented in docs/07.
Still per-box: create your own `~/.config/fleet/machines/local.env` (instance
config, never in the repo). Original notes below.

Create `~/.config/fleet/machines/local.env` (mechanism already supported,
`fleet-config.sh:211-218`):
```sh
MACHINE_MAX_WORKERS=2
MACHINE_MIN_FREE_MB=3072
```
Calibrates the admission gate for a small box. This is instance config, not repo
code — but consider lowering the shipped `FLEET_DEF_*` defaults too, or at least
documenting the small-box preset in `README.md` / `BOOTSTRAP.md`.

### D — teardown reaper  [IN REPO, from subagent audit] — DONE
Implemented in `bin/fleet`: `reap_worker_state` (called by `cmd_del`/`cmd_prune`)
kills the worker's tmux window via `dispatch_tmux` and GCs `.status`/`.meta`;
`rotate_events_log` caps `events.log`. Original notes below.

Close the launch-gate-without-reaper gap:
- `cmd_del`/`cmd_prune` (`bin/fleet:483-527`): add `tmux kill-window -t
  "$LT:$name"` alongside the `worktree remove`, mirroring the remote path
  (`bin/fleet:413`). Removes zombie windows that inflate the guard count.
- GC dispatch state: delete `dispatch/$PROJ_NAME/<name>.status`/`.meta` on
  `del`/`prune`; cap/rotate `events.log`.
- Consider a `fleet prune --windows` or auto-reap of finished dispatch windows.

### E — runtime watchdog  [BIGGER CHANTIER, scope later]
The structural fix for the admission-only guard: watch running workers' RAM (or
launch each worker in a cgroup with `memory.max`) and kill/alert before OOM,
instead of only gating at spawn. Needs design. Lowest priority; A+B+C+D cover
the crash.

## Suggested order
A (manual, unblocks the machine) → B (claude pack + config knob) → C (local.env)
→ D (reaper) → E (design only).
