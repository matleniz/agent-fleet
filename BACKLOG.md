# BACKLOG — vetted ideas, not (yet) implemented

Surveyed 2026-07-12 against the multi-agent-fleet ecosystem. Each entry: what /
proof it works elsewhere / how it would fit here / source. Implemented that day
instead: ntfy notifications (claude pack hooks + `bin/fleet-notify`) and
`fleet r broadcast` — the two highest value-per-effort items.

## Bugs to fix

- **`fleet doctor --write-probe` ignores `--machine`** (found 2026-07-16). In
  `bin/fleet`, `cmd_doctor()` hardcodes `target_machine local` on the
  `--write-probe` path, so `fleet doctor --write-probe --machine X` always
  probes `local`. The only route to a VM is `fleet --machine X doctor
  --write-probe` (top-level flag), and even then the remote engine must be
  >= 1368968 or the container's older `cmd_doctor` drops the flag and prints a
  plain doctor report with no PASS/FAIL line. Fix: forward the selected machine
  into the probe path, and detect+warn when the remote engine predates the
  write-probe subcommand.

## Try as-is (no code to write)

- **tmux agent dashboard** — a TUI over all tmux panes showing each agent's
  state (idle / processing / awaiting approval) with one-key approve. Supports
  Claude Code, opencode, Codex, Gemini — nearly our roster. Try on the VM tmux.
  https://github.com/nyanko3141592/tmuxcc (alt: hiroppy/tmux-agent-sidebar)
- **Claude Code statusline per worker** — script the statusline (worker name,
  branch, remaining context, plan usage) + `/color` per session to tell panes
  apart. https://support.claude.com/en/articles/14554000-claude-code-power-user-tips

## Small builds (one session each)

- **`fleet race <task>`** — same task fanned to N worktrees (optionally N
  different packs), then a judge session compares and recommends; human
  decides (LLM judges have a documented selection gap, arxiv 2603.12520).
  Proof: Cursor 2.2 multi-agent judging; DIY worktree fan-outs.
  https://forum.cursor.com/t/cursor-2-2-multi-agent-judging/145826
- **Quality gates at merge time** — a per-pack hook that blocks PR/merge until
  tests pass (the barrier protects the hub; this protects main). Proof:
  agent-dashboard's commit-lint/test gates; Claude agent-teams TaskCompleted
  hooks (exit 2 blocks). https://github.com/bjornjee/agent-dashboard
- **HANDOFF.md convention** — cross-CLI session portability does not exist
  (no standard, mid-2026); the community fallback is a state/handoff markdown
  in the worktree when switching agents. Cheap to standardize in the worker
  skills. https://wal.sh/research/2026-q2-cli-coding-agents/

- **Lean worker MCP profile** — SHIPPED. `WORKER_MCP` allowlist in a project
  `.env`, applied per worktree via the optional `pack_mcp_profile` (wired by
  `fleet_setup_worktree`, so it survives a refresh). Done: **gemini** (full —
  `mcp.allowed` gates every scope) and **opencode** (full — no allowlist key, so
  it disables the non-allowed servers it enumerates from the global config;
  verified live). **claude** partial — `enabledMcpjsonServers` gates the project
  `.mcp.json`, NOT user-scope `~/.claude.json`; full isolation needs
  `--strict-mcp-config` + a generated config from `~/.claude.json` (deferred, the
  one remaining sub-item). Confirmed NOT possible (verified empirically):
  **cursor** and **copilot** — their project MCP config only adds to / overrides
  the user-scope servers, cannot suppress them, and their disable is global not
  per-worktree; **antigravity** has no per-workspace MCP config. See docs/06.

## Bigger bets (wait for a real need)

- **Generic (CLI-agnostic) MCP loader via mount namespace** — make `WORKER_MCP`
  work for the CLIs with no native per-project MCP scoping (cursor, copilot,
  antigravity) by generalizing the hub barrier's mechanism (`packs/hub-mount-ns.sh`,
  `_fleet_hub_ro_exec`: `unshare --user --mount` + `mount --bind`). At launch, read
  the CLI's real global MCP config, write a per-worker filtered copy (only the
  allowlisted `mcpServers`; all three use that key), and `mount --bind` it
  read-only OVER the real path inside the worker's private namespace — so the
  worker sees only the allowed servers, the host + other workers are untouched, and
  auth is preserved (only the MCP file is overlaid, not the whole config home).
  Concurrency-safe (per-worker namespace + temp file); no global mutation (unlike
  `agent mcp disable`, which is why cursor was ruled out natively). Contract: an
  optional `pack_mcp_config_path` per pack echoing the file the CLI reads MCP from
  (cursor `~/.cursor/mcp.json`, copilot `${COPILOT_HOME:-~/.copilot}/mcp-config.json`,
  antigravity `~/.gemini/config/mcp_config.json`). Mirrors the barrier split:
  native where the CLI supports it (gemini/opencode/claude), mount-ns loader as
  the fallback. Two design rules: **fail-OPEN** (it's a token optimization, not
  security — launch unfiltered if userns is unavailable, never block a worker), and
  it applies at LAUNCH (pack_launch), not pack_worker_setup. Needs unprivileged
  userns (copilot/antigravity already require it; cursor would newly need mount-ns).

- **State from transcripts + mobile approvals** — parse Claude Code JSONL
  transcripts for blocked/waiting/done + a PWA to approve from the phone
  (Tailscale). Overlaps with ntfy for less effort today.
  https://github.com/bjornjee/agent-dashboard
- **srt (Anthropic sandbox-runtime)** — OS-level confinement (bubblewrap +
  network allowlist) for running NON-claude CLIs in bypass mode on the laptop
  without container weight. Known /proc escape (2026-04) → defense in depth,
  not a boundary. https://github.com/anthropic-experimental/sandbox-runtime
- **Container-per-worker (Docker Sandboxes / sbx)** — YOLO-inside-a-sandbox
  per agent, 9 CLIs supported. Our VM already isolates at container level;
  reconsider if workers ever run untrusted code locally.
  https://www.innoq.com/en/blog/2026/07/trust-but-sandbox/
- **Queue as MCP server** — expose the proposal queue through one MCP so all
  five CLIs pull/update tasks the same way (vibe-kanban proves the shape).
  Today fleet-queue + per-CLI transports cover it.
  https://github.com/BloopAI/vibe-kanban
- **Claude agent teams (native)** — intra-task lead+teammates with shared task
  list and TeammateIdle/TaskCompleted hooks; complements the fleet (inter-task)
  rather than replacing it. Experimental, no teammate resume.
  https://code.claude.com/docs/en/agent-teams

## Watchlist

- AGENTS.md is now under the Linux Foundation (Agentic AI Foundation); if
  Claude Code adopts it natively, drop the CLAUDE.md bridge files.
- Copilot standalone CLI shipped as its own pack (`packs/copilot`, OS
  mount-namespace barrier, live-proven). The separate "Copilot routed through
  opencode" idea (issue 19338, `ghu_` token staged in auth.json) is still open.
- Gemini-CLI auth: revisit the gemini E2E after upstream OAuth fixes.
