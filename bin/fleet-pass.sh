# shellcheck shell=bash
# shellcheck disable=SC2154  # CONF/SELF_DIR/PROJ_NAME/FLEET_ROOT/WT_HOME/agent/... are set by bin/fleet, which sources this file
# fleet-pass.sh — the headless "review / aggregation pass" primitive and the
# three commands built on it (sourced by bin/fleet, never run directly):
#
#   fleet_pass   the ONE primitive: route (or take) a pack:model, run
#                pack_launch_headless once in a directory, capture its output.
#   fleet judge  (+ `fleet gate --review` / GATE_REVIEW=1) advisory post-gate
#                diff review by a fresh model.
#   fleet race   one task fanned to N worktrees, a judge pass compares, markdown
#                review comments are re-dispatched to the losing worktrees.
#   fleet fanin  optional hierarchical fan-in: a lead pass folds K workers'
#                results into one structured report (docs/06).
#
# Nothing here adds a pack contract: every pass goes through the same
# pack_launch_headless <prompt> <model> that `fleet dispatch` and the
# conversation-feedback routine already use. Nothing is default-on.

# ---------- the primitive ----------

# fleet_pass <kind> <workdir> <prompt> <outfile> [pack[:model]]
# Run ONE non-interactive pass and write its stdout+stderr to <outfile>.
#   - target: the explicit pack[:model] when given, else the router
#     (`fleet route --difficulty hard --kind <kind>`, so ROUTE_KIND_<KIND>,
#     quota fall-through and the ROUTE_CLAUDE policy all apply — a pass never
#     defaults to claude). Depth is pinned to 0: a pass dispatches nothing, so
#     the dispatch-recursion bound must not stop a worker from reviewing.
#   - a fresh process per pass: no shared context with the author.
#   - bounded by PASS_TIMEOUT seconds; a quota-exhausted pack is recorded in the
#     quota ledger exactly like a dead worker's.
#   - read-only by contract: the prompt forbids edits and the pass is flagged if
#     it left the worktree different.
# Sets PASS_TARGET (what ran). rc: 0 ok · 1 the pass failed/timed out · 3 no target.
fleet_pass() {
  local kind="$1" wd="$2" prompt="$3" outfile="$4" target="${5:-}" pack model=""
  PASS_TARGET=""
  if [ -z "$target" ]; then
    target="$(python3 "$SELF_DIR/fleet-route.py" --depth 0 --difficulty hard --kind "$kind" 2>/dev/null)" || {
      echo "pass($kind): no eligible pack from the router — see 'fleet route --difficulty hard --kind $kind --explain', or pass --with <pack[:model]>" >&2
      return 3
    }
  fi
  pack="${target%%:*}"
  case "$target" in *:*) model="${target#*:}" ;; esac
  fleet_agent_enabled "$pack" || {
    echo "pass($kind): pack '$pack' is not enabled for this project (AGENTS=\"$(fleet_agents)\")" >&2
    return 3
  }
  [ -f "$FLEET_PACKS_DIR/$pack/pack.sh" ] || { echo "pass($kind): unknown pack '$pack'" >&2; return 3; }
  PASS_TARGET="$target"
  echo "pass($kind): headless run via $target" >&2
  ( fleet_load_pack "$pack"; fleet_warn_model_ignored "$pack" "$model" )

  local timeout_s="${PASS_TIMEOUT:-${FLEET_DEF_PASS_TIMEOUT:-900}}"
  local before after rc=0 pid ticks=0
  before="$(git -C "$wd" status --porcelain 2>/dev/null || true)"
  : > "$outfile"
  ( fleet_load_pack "$pack"; cd "$wd" || exit 1; pack_launch_headless "$prompt" "$model" ) \
    </dev/null >"$outfile" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    ticks=$((ticks + 1))
    if [ "$ticks" -ge $((timeout_s * 5)) ]; then
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
      echo "pass($kind): timed out after ${timeout_s}s" >&2
      break
    fi
    sleep 0.2
  done
  wait "$pid" 2>/dev/null || rc=$?
  after="$(git -C "$wd" status --porcelain 2>/dev/null || true)"
  [ "$before" = "$after" ] || echo "pass($kind): WARNING — the pass changed files in $wd (it was told not to); inspect 'git status'" >&2
  if [ "$rc" -ne 0 ]; then
    ( worker_has_quota_error "_pass-$kind" "$pack" "$outfile" ) >/dev/null 2>&1 || true
    echo "pass($kind): failed (rc=$rc)" >&2
    return 1
  fi
  return 0
}

# Truncate stdin to N bytes with a visible marker (a pass prompt stays bounded).
pass_clip() {  # <max-bytes>
  local max="$1" data
  data="$(cat)"
  if [ "${#data}" -gt "$max" ]; then
    printf '%s\n[... truncated at %s bytes; run the git command yourself for the rest]\n' "${data:0:$max}" "$max"
  else
    printf '%s\n' "$data"
  fi
}

# Resolve the base a worker branch diverged from: --base, DEFAULT_BASE, origin/main, main.
pass_base_ref() {  # <workdir> [explicit]
  local wd="$1" cand
  for cand in "${2:-}" "${DEFAULT_BASE:-}" origin/main main; do
    [ -n "$cand" ] || continue
    git -C "$wd" rev-parse --verify -q "$cand^{commit}" >/dev/null 2>&1 && { echo "$cand"; return 0; }
  done
  return 1
}

# Everything the branch changed since it left the base (commits + working tree).
pass_branch_diff() {  # <workdir> <base>
  local mb
  mb="$(git -C "$1" merge-base "$2" HEAD 2>/dev/null)" || return 1
  git -C "$1" diff "$mb" 2>/dev/null
}

pass_tokens() { echo $(( ($(wc -c < "$1") + 3) / 4 )); }   # rough: 1 token ~ 4 bytes

pass_sdir() { local d; d="$(dispatch_state_dir)"; mkdir -p "$d"; echo "$d"; }

# ---------- fleet judge / gate --review ----------

# fleet judge [--base REF] [--task "<text>"] [--with pack[:model]]
# Advisory: prints the verdict and notes, never blocks, never files anything.
cmd_judge() {
  local base="" task="" target=""
  while :; do
    case "${1:-}" in
      --base) [ $# -ge 2 ] || { echo "error: --base needs a value" >&2; return 2; }; base="$2"; shift 2 ;;
      --task) [ $# -ge 2 ] || { echo "error: --task needs a value" >&2; return 2; }; task="$2"; shift 2 ;;
      --with) [ $# -ge 2 ] || { echo "error: --with needs a value" >&2; return 2; }; target="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "judge: not inside a git worktree" >&2; return 2; }
  local wname; wname="$(basename "$root")"
  base="$(pass_base_ref "$root" "$base")" || { echo "judge: cannot resolve a base ref (use --base <ref>)" >&2; return 2; }
  local sdir; sdir="$(pass_sdir)"
  if [ -z "$task" ] && [ -f "$sdir/$wname.task" ]; then task="$(cat "$sdir/$wname.task")"; fi
  if [ -z "$task" ]; then task="(no task text recorded; commit subjects follow)
$(git -C "$root" log --format='- %s' "$base..HEAD" 2>/dev/null | head -20)"; fi

  local diff; diff="$(pass_branch_diff "$root" "$base")" || diff=""
  if [ -z "$diff" ]; then echo "judge: no changes against $base — nothing to review"; return 0; fi
  local nfiles; nfiles="$(printf '%s\n' "$diff" | grep -c '^diff --git' || true)"
  local prompt
  prompt="[fleet-pass:judge]
You are an independent code reviewer. You did not write this change and share no context with its author. Do NOT modify, create, delete or commit any file; read only.

TASK the author was given:
$task

Review the diff below against the task: correctness bugs, requirements not met, missing tests, unintended scope. Be concrete (file:line). Skip style nits. You may read the repository for context.

Reply in markdown: a findings list (or 'No findings.'), then a FINAL line that is exactly 'VERDICT: APPROVE' or 'VERDICT: CONCERNS'.

--- DIFF vs $base ---
$(printf '%s\n' "$diff" | pass_clip "${JUDGE_MAX_DIFF_BYTES:-${FLEET_DEF_JUDGE_MAX_DIFF_BYTES:-60000}}")"

  local out; out="$(mktemp "${TMPDIR:-/tmp}/fleet-judge.XXXXXX")"
  echo "judge: reviewing $nfiles changed file(s) against $base (advisory — never blocks)"
  local rc=0
  fleet_pass judge "$root" "$prompt" "$out" "$target" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "judge: no verdict (review pass did not run; the change is NOT judged)"
    rm -f "$out"; return 1
  fi
  local verdict
  verdict="$(sed -n 's/^[[:space:]*]*VERDICT:[[:space:]]*\(APPROVE\|CONCERNS\).*/\1/p' "$out" | tail -1)"
  cat "$out"
  cp "$out" "$sdir/$wname.judge.md" 2>/dev/null || true
  rm -f "$out"
  echo "judge: verdict ${verdict:-UNPARSED} via $PASS_TARGET (advisory; notes kept in $sdir/$wname.judge.md)"
  return 0
}
