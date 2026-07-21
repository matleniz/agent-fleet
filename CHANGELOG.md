# Changelog

Notable changes to agent-fleet. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

This project is **pre-1.0**: it works and is used daily, but subcommand names,
config keys, and the pack contract can still change between versions without a
deprecation cycle. There are no tagged releases yet; everything lands under
Unreleased until the first one.

## [Unreleased]

### Added
- `fleet gate` — the project-declared pre-PR validation gate. A project lists
  its checks in `GATE_CMDS` (its .env, one shell command per line, auto-fix
  flags included); a worker runs them all in one shot before opening a PR
  (`resolve-finding` step 5). Auto-fixes apply mechanically at zero model cost;
  passing checks print nothing; only residual failures (the failing command +
  its own output, capped at 200 lines) escalate to the model. Dep-free: the
  fleet bundles no linter, and a project with no `GATE_CMDS` gets a no-op.
  E2E: `test/gate.sh` (no-op / pass / fail / auto-fix note / truncation).
- Conversation-feedback is now a 3-stage pipeline (docs/04 "The conversation-feedback
  pipeline"): A extract (deterministic), B compress (new `conversation-compress`
  skill — cheap model, frequent, LOCAL; one session note per transcript under
  `$FLEET_HOME/feedback-notes/`), C distill + finalize (the `conversation-feedback`
  skill — reasoning runs local or off-box via `FEEDBACK_RUNNER`, but dedup/filing/
  digest always local). Splits cheap-frequent from expensive-rare and keeps private
  transcripts on the box while only compressed notes can travel.
- `fleet feedback config` reports the routine's model/runner knobs
  (`FEEDBACK_MODEL_COMPRESS` / `FEEDBACK_MODEL_DISTILL` / `FEEDBACK_RUNNER`,
  defaults in `default.env`; built-ins haiku/sonnet/local). No `bin/` script calls
  a model — the model rides the existing `pack_launch_headless` path.
- `fleet chats --scan --since <ISO>` drops transcripts untouched since a date, so
  the frequent compress pass skips already-compressed ones.
- `fleet chats --scan --history` (the retro's real stage-A input): one entry per
  transcript file over the window, **including finished workers whose worktree was
  deleted** (their `~/.claude` history survives `del`/`prune`). The default scan
  returns only the latest pointer per live worktree, so a fleet that deletes
  finished workers would expose almost none of its history — validated on a real
  fleet where the scoped default scan saw 1 conversation and `--history` saw 45.
  Claude-first via a new optional `pack_chat_history`; packs without it fall back to
  the default per-location scan.
- Cursor transcript coverage for the feedback retro: `fleet_chat_parse` now parses
  the Cursor CLI's JSONL (a `_parse_cursor` beside `_parse_claude`, dispatched by a
  format-tagging `detect_format`), and `packs/cursor/pack.sh` gains a
  `pack_chat_history` over `~/.cursor/projects/<slug>/agent-transcripts/`. Unwraps
  the `<timestamp>`/`<user_query>` envelope and filters the headless auto-continue
  nudge; `session_id` comes from the transcript filename. Cursor has no per-turn
  timestamp or `tool_result`, so it yields prompts + tool histogram but no
  `tool_errors` (started/ended stay null; the scanner carries the file mtime). This
  unblocks a claude-banned fleet (e.g. one running `AGENTS="cursor ..."`) that the
  retro was otherwise blind to.
- Lesson targets: a distilled lesson is `project` (per-project queue, unchanged),
  `global` (fleet-wide, → digest section for the user to apply by hand), or
  `upstream` (a generic tooling lesson for the public agent-fleet repo, → digest
  candidates section, never auto-filed).
- `test/test-feedback-pipeline.sh` (note dedup by session_id, `feedback config`,
  finalize routing), wired into CI.
- Public baseline: agent-agnostic fleet with packs for claude, gemini, opencode,
  cursor, antigravity, and copilot; coordinator/worker roles with a per-pack
  read-only-hub barrier; the proposal queue; scheduled routines; the resource
  guard rails; and the always-on VM deploy.
- CI check that every `fleet` subcommand is documented in the README or `docs/`
  (`test/docs-sync.sh`), so a new or renamed command cannot ship without a doc.
- E2E test for the shared read-only-hub guard behind the claude and gemini packs
  (`test/barrier-guard.sh`); previously the flagship barrier had no dedicated
  test.

### Changed
- README now states the barrier's guarantee level per pack: the hook/rule packs
  block the edit tools but not a shell redirect; the mount-namespace packs are
  write-proof.
- Removed instance-specific machine details (RAM figures, a personal worktree
  name, personal framing) from `ROADMAP.md` and `BACKLOG.md`, so the docs read
  as a generic pattern rather than one operator's setup.
