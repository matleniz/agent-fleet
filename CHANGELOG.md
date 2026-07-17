# Changelog

Notable changes to agent-fleet. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

This project is **pre-1.0**: it works and is used daily, but subcommand names,
config keys, and the pack contract can still change between versions without a
deprecation cycle. There are no tagged releases yet; everything lands under
Unreleased until the first one.

## [Unreleased]

### Added
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
