# agent-fleet — repo context

This repo IS the fleet pattern and its tooling, generic (no project-specific
names). Overview: `README.md`. Mental model: `docs/01-mental-model.md`.

## Layout
- `bin/` — the canonical tools (`fleet`, `fleet-init`, `new-worker`,
  `fleet-assess`, `fleet-queue`, `fleet-config.sh`, `hub-readonly-guard.py`,
  `fleet-notify`, `fleet-migrate`, `fleet-status.py`, `fleet-context.py`,
  `fleet_common.py`). Single source of truth; every project uses these via
  `~/.local/bin` symlinks (`fleet-status.py` / `fleet-context.py` are invoked by
  `fleet status` / `fleet context`, no symlink, like `hub-readonly-guard.py`;
  `fleet_common.py` is a shared import of those two, not run directly).
- `packs/` — one dir per agent CLI (`claude`, `gemini`, `opencode`, `cursor`,
  `antigravity`, `copilot`), each a `pack.sh` defining six required functions
  (`pack_launch`, `pack_launch_headless`, `pack_has_sessions`,
  `pack_worker_setup`, `pack_barrier_files`, `pack_install`) plus optional
  `pack_doctor` and optional `pack_global_setup` (wire this CLI's per-user
  global-instructions file for `fleet global`; packs whose CLI has no global
  mechanism omit it). `pack_launch_headless <prompt>` is the non-interactive
  launch behind `fleet dispatch` (same barrier + bypass posture as
  `pack_launch`). The core never names a CLI; projects enable packs via
  `AGENTS="..."` in their .env. `packs/hub-mount-ns.sh` is a shared helper
  (`_fleet_hub_ro_exec`) sourced by the antigravity + copilot packs for their OS
  mount-namespace barrier.
- Context files: `AGENTS.md` is the source everywhere (this repo included);
  `CLAUDE.md` is a one-line `@AGENTS.md` bridge. Skills live in
  `.agents/skills/` (the agentskills.io standard), `.claude/skills` symlinks
  to it for Claude Code.
- `templates/` — per-project config + skill skeletons that `fleet-init` installs.
- `test/` — `make-sandbox.sh` builds a throwaway project to exercise the tools;
  `dispatch.sh` (headless dispatch + per-pack flags + write-probe), `global.sh`
  (`fleet global` wiring), `barrier-{cursor,antigravity,copilot}.sh` (per-pack
  read-only-hub barrier), `test-guard.sh` (resource guard), `test-context.sh`
  (context reporter).
- `docs/` — the model (`01`-`07`). `BOOTSTRAP.md` — the setup prompt.

## Provenance and isolation (transition period)
Forked from `claude-fleet` (history preserved). The legacy fleet keeps running
from `~/claude-fleet` + `~/.config/claude-fleet` while this repo evolves; this
one uses `FLEET_*` env vars + `~/.config/fleet`. NEVER add a fallback that reads
the legacy config dir — the new tools must not be able to resolve the legacy
fleet's real projects. `fleet-config.sh` enforces this: it refuses to run if
`FLEET_HOME` resolves to a `claude-fleet` path. Cutover is explicit:
`fleet-migrate`. Test only against the sandbox (`test/make-sandbox.sh`), never a
real repo.

## Keep docs in sync with the tools (this repo's one real risk)
The docs describe the tools. When you change `bin/` (flags, commands, resolution
order, config schema), update `README.md`, the relevant `docs/`, `BOOTSTRAP.md`,
and the `templates/` in the SAME pass. Docs = part of "done". Drift between
`bin/` and the docs is exactly the failure the freshness model (`docs/03`) warns
about, so do not ship it. There is no separate hub here: the docs live with the
code, so the fix is to keep them in one pass, not to file a proposal.

## Conventions
- Bash + Python 3, no external deps. Scripts run via `~/.local/bin` symlinks, so
  they resolve their own dir with `readlink -f` before sourcing siblings.
- CI (`.github/workflows/ci.yml`) runs shellcheck (`.shellcheckrc`, severity
  warning), ruff (`ruff.toml`), and the whole `test/*.sh` suite on push/PR. These
  are dev/CI-only — nothing at runtime depends on them; keep the repo dep-free.
  A deliberate shellcheck exception goes in a `# shellcheck disable=` with a why.
- The read-only barrier is per pack (claude: PreToolUse hook; gemini:
  BeforeTool hook, both sharing `hub-readonly-guard.py`; opencode: declarative
  permission rules — with the edit patterns in worktree-RELATIVE form;
  antigravity + copilot: an OS mount namespace with the hub bind-mounted
  read-only, since their CLIs have no in-CLI per-path deny; see `docs/02`). Verify a CLI's flags/paths against its installed version (its
  bundled docs or source) before coding a pack, not against memory or blog
  posts. A pack's barrier is not done until the sandbox E2E shows the hub
  write actually denied — a wrong pattern fails silently open.
- Stay generic: zero project-specific names (no company / repo / tracker ids).
  Any instance lives in its own config and skills, never in this repo.
- This repo is THIN and single-writer by design: no hub, no queue, no fleet
  machinery for itself. Work solo here. Dogfood the principle, not the apparatus.
