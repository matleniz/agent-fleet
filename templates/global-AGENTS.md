# Template: global context file (keep it SHORT and stable)

Global instructions apply to every project on this machine. Keep this file small.
Project detail belongs in the repo's `AGENTS.md`, not here.

`fleet global` installs THIS file as your canonical per-user instructions at
`~/.agents/AGENTS.md` (override: `FLEET_GLOBAL_AGENTS`) and wires every installed
CLI to it — write it once, all agents read it. Re-run `fleet global` after
enabling a new pack; `fleet global status` shows what is wired.

How each CLI is pointed at the one canonical file:

| CLI | Wiring `fleet global` applies |
|---|---|
| Claude Code | `~/.claude/CLAUDE.md` gets a one-line `@<canonical>` import (an existing CLAUDE.md is migrated into the canonical, backup kept) |
| opencode | `~/.config/opencode/AGENTS.md` symlinked to the canonical (opencode also reads `~/.claude/CLAUDE.md` natively) |
| Gemini CLI + Antigravity | `~/.gemini/GEMINI.md` symlinked to the canonical (both read it every session; agy reuses `~/.gemini/`) |
| Cursor | no user-level global file exists in the CLI, so the canonical is injected per worktree as an always-apply `.cursor/rules/00-fleet-user.mdc` (git-excluded, regenerated on `fleet refresh`) — a temporary bridge until the CLI grows one |
| GitHub Copilot CLI | `~/.copilot/copilot-instructions.md` symlinked to the canonical (relocated by `$COPILOT_HOME`; Copilot also reads a repo's `AGENTS.md` natively for project context) |
| Codex CLI | `~/.codex/AGENTS.md` (no Codex pack in this repo yet) |

Fill in and trim:

```markdown
# <your name> — global context

<one line on who you are / your role>.

## Machine
- <OS / shell notes, e.g. WSL2>. Code lives under `$HOME`, not on mounted drives.
- <anything about paths that has bitten you before>

## How to work
- Answers in <language>. Code, commits, docstrings in <language>.
- Tracker/queue writes (Linear/GitHub issues, titles, descriptions, comments):
  always in <tracker language, e.g. English>, regardless of the conversation
  language. Repo docs follow that repo's own language (repo scale), not the tracker.
- Verify APIs / versions / flags against the code or docs before asserting. Do
  not guess.
- Project context lives at the repo level (`<repo>/AGENTS.md`), not here.
- Skills: personal (all projects) in `~/.agents/skills/`; repo/team skills
  committed under `<repo>/.agents/skills/`. (Claude Code still reads
  `~/.claude/skills/` — keep per-skill symlinks there.)
```

If your agent has durable memory, turn it on (facts one per file) so
cross-session state does not live in this file. Keep this file to identity,
machine facts, and cross-project rules.
