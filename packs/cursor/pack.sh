# shellcheck shell=bash
# cursor pack — Cursor CLI (`agent`, install: curl https://cursor.com/install | bash).
# Sourced by fleet_load_pack; must define the six required pack_* functions
# (pack_doctor is optional, used by `fleet doctor`).
# Verified against agent 2026.07.09 (docs + empirical checks).

# Launch the Cursor agent in the CURRENT directory (caller cd's first).
# --force = auto-approve everything not explicitly denied — the hub deny rules
# in .cursor/cli.json are explicit denies, so the barrier holds under it
# (help text: "Force allow commands unless explicitly denied").
pack_launch() {
  local resume=()
  [ "${1:-}" = "--resume" ] && resume=(--continue)
  exec agent --force "${resume[@]}"
}

# Headless launch for `fleet dispatch`: run one task non-interactively. --force
# ("force allow unless explicitly denied", headless-only per its help) grants
# tool/shell access while the .cursor/cli.json hub deny still holds. Note it is
# `--force`/`--yolo`, NOT `--trust` (not a real flag): hand-rolling `agent -p
# --trust` leaves the worker with no shell.
pack_launch_headless() { exec agent -p --force "$1"; }

# Cursor stores chats in ~/.cursor/chats/<md5(cwd)>/<chat-uuid>/ (meta.json
# carries the cwd — verified). One md5 dir per working directory.
pack_has_sessions() {
  local dir="$1" h
  h="$(printf '%s' "$dir" | md5sum | cut -d' ' -f1)"
  [ -d "$HOME/.cursor/chats/$h" ] && ls "$HOME/.cursor/chats/$h"/* >/dev/null 2>&1
}

# Optional: readable pointer to the recorded conversation for <dir> (fleet chats).
pack_chat_pointer() {
  local h; h="$(printf '%s' "$1" | md5sum | cut -d' ' -f1)"
  local d="$HOME/.cursor/chats/$h"
  [ -d "$d" ] && ls "$d"/* >/dev/null 2>&1 && echo "$d"
}

# Cursor also records a parseable JSONL transcript per run under
# ~/.cursor/projects/<slug>/agent-transcripts/<uuid>/<uuid>.jsonl, where <slug> is
# the absolute cwd with every non-alnum char turned into '-' and no leading dash
# (claude keeps the leading dash; cursor drops it — verified against agent
# 2026.07.09). This is what the conversation-feedback retro reads, not the
# ~/.cursor/chats/<md5> metadata dir pack_chat_pointer returns.
_cursor_proj_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g; s/^-*//'; }

# Emit one TSV line per transcript under <dir>/agent-transcripts newer than
# <since_epoch> ("" = no floor): <role>\t<worktree>\t<cwd>\t<path>\t<mtime>.
_cursor_emit_transcripts() {  # <role> <worktree> <cwd> <dir> <since_epoch>
  local role="$1" wtn="$2" cwd="$3" dir="$4" since="${5%.*}" f m
  [ -d "$dir/agent-transcripts" ] || return 0
  for f in "$dir"/agent-transcripts/*/*.jsonl; do
    [ -e "$f" ] || continue
    m="$(stat -c %Y "$f" 2>/dev/null)" || continue
    { [ -z "$since" ] || [ "$m" -ge "$since" ]; } || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$role" "$wtn" "$cwd" "$f" "$m"
  done
}

# Optional: enumerate ALL recorded transcripts for a PROJECT over a window — the
# retro's history (docs/04), not just the latest pointer per live worktree. One
# line per session file for the hub (coordinator) AND every cwd under WT_HOME,
# INCLUDING finished workers whose worktree was deleted (their ~/.cursor/projects
# history survives del/prune). Args: <hub_dir> <wt_home_dir> <since_epoch|"">.
pack_chat_history() {  # <hub_dir> <wt_home_dir> <since_epoch>
  local hub="$1" wt_home="$2" since="${3:-}" root="$HOME/.cursor/projects"
  local slug wt_slug d name
  if [ -n "$hub" ]; then
    slug="$(_cursor_proj_slug "$hub")"
    _cursor_emit_transcripts coordinator - "$hub" "$root/$slug" "$since"
  fi
  if [ -n "$wt_home" ]; then
    wt_slug="$(_cursor_proj_slug "$wt_home")"
    for d in "$root/$wt_slug"-*/; do
      [ -d "$d" ] || continue
      name="$(basename "$d")"; name="${name#"$wt_slug"-}"
      _cursor_emit_transcripts worker "$name" "$wt_home/$name" "$d" "$since"
    done
  fi
}

# Worktree-relative files pack_worker_setup writes (the core ignores them
# when judging a worktree dirty for del/prune).
pack_barrier_files() { echo ".cursor/cli.json"; echo ".cursor/rules/00-fleet-user.mdc"; }

# Per-worktree setup: (1) the read-only-hub barrier — declarative in
# .cursor/cli.json: Read(hub/**) allowed, Write(hub/**) denied, denies hold
# under --force; (2) the per-user global-instructions fallback (see below).
pack_worker_setup() {
  local dest="$1"
  mkdir -p "$dest/.cursor"
  if [ -n "${HUB:-}" ]; then
    # json.dump, not a heredoc: an interpolated $HUB with JSON-special chars
    # would produce a deny pattern that silently never matches (fail-open).
    HUB="$HUB" python3 - "$dest/.cursor/cli.json" <<'PY'
import json, os, sys
hub = os.environ["HUB"]
cfg = {"permissions": {"allow": [f"Read({hub}/**)"], "deny": [f"Write({hub}/**)"]}}
json.dump(cfg, open(sys.argv[1], "w"), indent=2)
PY
  fi
  pack_global_inject "$dest"
}

# TEMPORARY BRIDGE (optional pack fn): the cursor CLI has no user-level
# global-instructions file (verified against its docs — only project
# .cursor/rules + AGENTS.md, and UI-only User Rules). So inject the canonical
# per-user instructions into <dir> as an always-apply PROJECT rule, regenerated
# on setup / `fleet refresh` and at coordinator launch (the hub). Git-exclude it
# (never commit personal instructions into the repo). The core calls this for
# worktrees (pack_worker_setup) and for the hub (cmd_hub). Drop it once the
# cursor CLI grows a real global file. Generic pattern for any no-global CLI.
pack_global_inject() {
  local dest="$1" rel=".cursor/rules/00-fleet-user.mdc" canon
  # global_canon() comes from fleet-config.sh on the real path; resolve the same
  # default inline so the pack is usable even when sourced standalone (tests).
  if declare -F global_canon >/dev/null 2>&1; then canon="$(global_canon)"
  else canon="${FLEET_GLOBAL_AGENTS:-$HOME/.agents/AGENTS.md}"; fi
  [ -f "$canon" ] || return 0
  mkdir -p "$dest/.cursor/rules"
  { printf -- '---\ndescription: per-user global instructions (fleet-managed; do not commit)\nalwaysApply: true\n---\n\n'
    cat "$canon"; } > "$dest/$rel"
  # keep it out of the project's git: append to the repo's shared info/exclude
  local common; common="$(git -C "$dest" rev-parse --git-common-dir 2>/dev/null)" || return 0
  case "$common" in /*) ;; *) common="$dest/$common";; esac
  local excl="$common/info/exclude"
  # `if`, not a trailing `[ ] && ...`: under the caller's set -e the && form
  # fails this function (and with it the whole worker setup) when .git/info is
  # absent, instead of just skipping the exclude.
  if [ -d "$common/info" ]; then
    grep -qxF "$rel" "$excl" 2>/dev/null || printf '%s\n' "$rel" >> "$excl"
  fi
}

# fleet global: the cursor CLI has no machine-wide global file to wire, so this
# only reports; the canonical is injected per worktree by pack_worker_setup /
# `fleet refresh` (see _cursor_global_rule).
pack_global_setup() {
  command -v agent >/dev/null || { echo "skipped:not-installed"; return 0; }
  echo "project rule (no CLI global file; injected at worker setup, fleet refresh, and hub launch)"
}

# Install line for the VM image / a fresh machine (auth: `agent login`, OAuth).
pack_install() { echo "curl -fsS https://cursor.com/install | bash"; }

# Optional: fleet doctor status line.
pack_doctor() {
  fleet_doctor_preamble agent "curl -fsS https://cursor.com/install | bash" "${1:-}" || return
  local v s; v="$(agent --version 2>/dev/null | head -1)"
  s="$(timeout 10 agent status 2>/dev/null | head -1 || true)"
  echo "installed ($v) — ${s:-status unavailable}"
}
