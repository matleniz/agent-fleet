# shellcheck shell=bash
# shellcheck disable=SC2154  # set by bin/fleet, which sources this file
# fleet-race.sh — `fleet race` (sourced by bin/fleet): one task fanned to N worktrees,
# a judge pass (fleet_pass, see fleet-pass.sh) compares, markdown review comments
# are re-dispatched to the losers through cmd_dispatch.

# ---------- fleet race ----------

race_dir() { echo "$(pass_sdir)/race/$1"; }

race_usage() {
  cat >&2 <<'EOF'
usage: fleet race run [--packs "p1 p2 .."] [--n N] [--model M] <race> "<task>" [base]
       fleet race ls <race>
       fleet race judge [--with pack[:model]] [--base REF] <race>
       fleet race comment <race> <worktree> [file|-]      (markdown, from file or stdin)
       fleet race steer [--toward <worktree>] [--all] <race> [<worktree>]
EOF
  return 2
}

race_members() { grep -v '^$' "$1/members" 2>/dev/null || true; }   # "<worktree> <pack> <model|->"

cmd_race() {
  local verb="${1:-}"; shift || true
  case "$verb" in
    run)     race_run "$@" ;;
    ls|status) race_ls "$@" ;;
    judge)   race_judge "$@" ;;
    comment) race_comment "$@" ;;
    steer)   race_steer "$@" ;;
    *)       race_usage ;;
  esac
}

race_run() {
  local packs="" n="" model=""
  while :; do
    case "${1:-}" in
      --packs) [ $# -ge 2 ] || { echo "error: --packs needs a value" >&2; return 2; }; packs="$2"; shift 2 ;;
      --n)     [ $# -ge 2 ] || { echo "error: --n needs a value" >&2; return 2; }; n="$2"; shift 2 ;;
      --model) [ $# -ge 2 ] || { echo "error: --model needs a value" >&2; return 2; }; model="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  local race="${1:-}" task="${2:-}" base="${3:-}"
  [ -n "$race" ] && [ -n "$task" ] || race_usage
  fleet_valid_name "$race" "race name" || return 2
  need_code_repo
  [ -n "$packs" ] || packs="${agent:-$(fleet_default_agent)}"
  local plist; read -r -a plist <<< "$packs"
  [ -n "$n" ] || n="${#plist[@]}"
  { [ "$n" -ge 2 ] && [ "$n" -le 6 ]; } 2>/dev/null || { echo "error: a race takes 2 to 6 worktrees (--n / --packs)" >&2; return 2; }
  local rdir; rdir="$(race_dir "$race")"
  [ ! -f "$rdir/members" ] || { echo "error: race '$race' already exists ($rdir) — pick another name" >&2; return 2; }
  mkdir -p "$rdir/comments"
  printf '%s\n' "$task" > "$rdir/task"
  printf '%s\n' "${base:-${DEFAULT_BASE:-origin/main}}" > "$rdir/base"
  local i letters=(a b c d e f) w p started=0 margs=()
  [ -z "$model" ] || margs=(--model "$model")
  for ((i = 0; i < n; i++)); do
    w="$race-${letters[$i]}"
    p="${plist[$((i % ${#plist[@]}))]}"
    fleet_valid_name "$w" "worktree name" || return 2
    if ( agent="$p"; cmd_dispatch "${margs[@]}" "$w" "$task" ${base:+"$base"} ); then
      printf '%s %s %s\n' "$w" "$p" "${model:--}" >> "$rdir/members"
      started=$((started + 1))
    else
      echo "race: could not start '$w' ($p) — continuing with the others" >&2
    fi
  done
  [ "$started" -ge 2 ] || { echo "race: fewer than 2 worktrees started; a race needs at least 2" >&2; return 1; }
  printf '%s %s race-run %s\n' "$(date -u +%FT%TZ 2>/dev/null)" "$race" "$started" >> "$(pass_sdir)/events.log"
  echo "race '$race': $started worktree(s) started. When they finish ('fleet wait'):"
  echo "  fleet race judge $race        # a fresh pass compares the diffs and drafts per-loser comments"
  echo "  fleet race steer $race --all  # re-dispatch the comments to the losers"
}

race_ls() {
  local race="${1:-}"; [ -n "$race" ] || race_usage
  local rdir; rdir="$(race_dir "$race")"
  [ -f "$rdir/members" ] || { echo "no race '$race' for '$PROJ_NAME'." >&2; return 2; }
  local sdir w p m rounds pending
  sdir="$(pass_sdir)"
  printf 'race %s — base %s\n' "$race" "$(cat "$rdir/base")"
  while read -r w p m; do
    rounds="$(cat "$rdir/rounds.$w" 2>/dev/null || echo 0)"
    pending="-"; [ -s "$rdir/comments/$w.md" ] && pending="comments-pending"
    printf '  %-24s %-12s %-22s rounds=%s %s\n' "$w" "$p" "$(cat "$sdir/$w.status" 2>/dev/null || echo '?')" "$rounds" "$pending"
  done < <(race_members "$rdir")
  [ -f "$rdir/judge.md" ] && echo "  judge notes: $rdir/judge.md (winner: $(cat "$rdir/winner" 2>/dev/null || echo '?'))"
  return 0
}

race_judge() {
  local target="" base=""
  while :; do
    case "${1:-}" in
      --with) [ $# -ge 2 ] || { echo "error: --with needs a value" >&2; return 2; }; target="$2"; shift 2 ;;
      --base) [ $# -ge 2 ] || { echo "error: --base needs a value" >&2; return 2; }; base="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  local race="${1:-}"; [ -n "$race" ] || race_usage
  need_code_repo
  local rdir; rdir="$(race_dir "$race")"
  [ -f "$rdir/members" ] || { echo "no race '$race' for '$PROJ_NAME'." >&2; return 2; }
  local sdir w p m names="" body="" ref
  sdir="$(pass_sdir)"
  ref="$(pass_base_ref "$WT_HOME/$(race_members "$rdir" | head -1 | cut -d' ' -f1)" "${base:-$(cat "$rdir/base")}")" \
    || { echo "race: cannot resolve a base ref (use --base <ref>)" >&2; return 2; }
  local max="${RACE_MAX_DIFF_BYTES:-${FLEET_DEF_RACE_MAX_DIFF_BYTES:-30000}}" d
  while read -r w p m; do
    case "$(cat "$sdir/$w.status" 2>/dev/null)" in
      running*) echo "race: '$w' is still running — 'fleet wait $w' first" >&2; return 2 ;;
    esac
    [ -d "$WT_HOME/$w" ] || { echo "race: worktree $WT_HOME/$w is gone" >&2; return 2; }
    d="$(pass_branch_diff "$WT_HOME/$w" "$ref" | pass_clip "$max")"
    names="$names $w"
    body="$body
=== WORKTREE $w (pack $p) ===
$d
"
  done < <(race_members "$rdir")
  local prompt
  prompt="[fleet-pass:race-judge]
You are an independent judge. Several agents solved the SAME task in separate worktrees. You did not write any of them. Do NOT modify, create, delete or commit any file.

TASK:
$(cat "$rdir/task")

Compare the diffs below for correctness, completeness against the task, tests and unintended scope. Then reply in markdown, in this exact shape:
WINNER: <worktree name>
REASON: <two sentences>
and, for EVERY other worktree, a section that starts with the exact heading '## Comments for <worktree name>' followed by concrete, actionable review comments (file:line where possible) that would bring that branch to the winner's level; say what the winner does better when it helps. Worktrees:$names

$body"
  local out; out="$(mktemp "${TMPDIR:-/tmp}/fleet-race-judge.XXXXXX")"
  local rc=0
  fleet_pass race_judge "$WT_HOME/$(echo "$names" | awk '{print $1}')" "$prompt" "$out" "$target" || rc=$?
  if [ "$rc" -ne 0 ]; then echo "race: judge pass did not run — nothing decided" >&2; rm -f "$out"; return 1; fi
  cp "$out" "$rdir/judge.md"
  local winner
  winner="$(sed -n 's/^[[:space:]*]*WINNER:[[:space:]]*\([A-Za-z0-9._-]*\).*/\1/p' "$out" | head -1)"
  case " $names " in *" $winner "*) ;; *) winner="" ;; esac
  # Split "## Comments for <w>" sections into per-worktree comment files (never for the winner).
  local cur="" line
  while IFS= read -r line; do
    case "$line" in
      "## Comments for "*)
        cur="$(printf '%s' "${line#\#\# Comments for }" | tr -d '[:space:]`*')"
        case " $names " in *" $cur "*) ;; *) cur="" ;; esac
        if [ "$cur" = "$winner" ]; then cur=""; fi
        if [ -n "$cur" ]; then : > "$rdir/comments/$cur.md"; fi
        ;;
      *) [ -z "$cur" ] || printf '%s\n' "$line" >> "$rdir/comments/$cur.md" ;;
    esac
  done < "$out"
  rm -f "$out"
  printf '%s\n' "$winner" > "$rdir/winner"
  cat "$rdir/judge.md"
  echo "race: judge recommends '${winner:-?}' via $PASS_TARGET — a recommendation only, YOU decide."
  echo "  comments drafted in $rdir/comments/ (edit them, add yours with 'fleet race comment'), then:"
  echo "  fleet race steer${winner:+ --toward $winner} $race --all"
}

race_comment() {
  local race="${1:-}" w="${2:-}" src="${3:--}"
  [ -n "$race" ] && [ -n "$w" ] || race_usage
  local rdir; rdir="$(race_dir "$race")"
  race_members "$rdir" | cut -d' ' -f1 | grep -qx -- "$w" || { echo "race: '$w' is not a member of '$race'" >&2; return 2; }
  if [ "$src" = "-" ]; then cat >> "$rdir/comments/$w.md"; else cat "$src" >> "$rdir/comments/$w.md"; fi
  printf '\n' >> "$rdir/comments/$w.md"
  echo "race: comments for '$w' saved in $rdir/comments/$w.md"
}

race_steer() {
  local toward="" all=0 pos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --toward) [ $# -ge 2 ] || { echo "error: --toward needs a value" >&2; return 2; }; toward="$2"; shift ;;
      --all) all=1 ;;
      *) pos+=("$1") ;;
    esac
    shift
  done
  local race="${pos[0]:-}" only="${pos[1]:-}"
  [ -n "$race" ] || race_usage
  [ "$all" = 1 ] || [ -n "$only" ] || race_usage
  need_code_repo
  local rdir; rdir="$(race_dir "$race")"
  [ -f "$rdir/members" ] || { echo "no race '$race' for '$PROJ_NAME'." >&2; return 2; }
  [ -n "$toward" ] || toward="$(cat "$rdir/winner" 2>/dev/null || true)"
  local sdir w p m sent=0 round ref ref_diff="" followup margs
  sdir="$(pass_sdir)"
  if [ -n "$toward" ]; then
    ref="$(pass_base_ref "$WT_HOME/$toward" "$(cat "$rdir/base")")" || ref=""
    [ -z "$ref" ] || ref_diff="$(pass_branch_diff "$WT_HOME/$toward" "$ref" | pass_clip "${RACE_MAX_DIFF_BYTES:-${FLEET_DEF_RACE_MAX_DIFF_BYTES:-30000}}")"
  fi
  while read -r w p m; do
    [ "$all" = 1 ] || [ "$w" = "$only" ] || continue
    [ "$w" != "$toward" ] || continue
    if [ ! -s "$rdir/comments/$w.md" ]; then
      [ "$all" = 1 ] || echo "race: no comments for '$w' (fleet race comment $race $w <file>)" >&2
      continue
    fi
    case "$(cat "$sdir/$w.status" 2>/dev/null)" in
      running*) echo "race: '$w' is still running — not steering it now" >&2; continue ;;
    esac
    round=$(( $(cat "$rdir/rounds.$w" 2>/dev/null || echo 0) + 1 ))
    followup="FOLLOW-UP (review round $round). Your earlier work on this task is already committed on this branch; continue from it, do not start over.

ORIGINAL TASK:
$(cat "$rdir/task")

A reviewer left these markdown comments on your diff. Address each one, run the tests, and commit on this branch:

$(cat "$rdir/comments/$w.md")
${ref_diff:+
For reference, the preferred sibling solution (branch $toward) is:
$ref_diff
}"
    margs=(); [ "$m" = "-" ] || margs=(--model "$m")
    if ( agent="$p"; cmd_dispatch "${margs[@]}" "$w" "$followup" ); then
      mv "$rdir/comments/$w.md" "$rdir/comments/$w.sent-$round.md"
      echo "$round" > "$rdir/rounds.$w"
      printf '%s %s race-steer round=%s\n' "$(date -u +%FT%TZ 2>/dev/null)" "$w" "$round" >> "$sdir/events.log"
      sent=$((sent + 1))
    else
      echo "race: re-dispatch of '$w' failed; its comments are kept" >&2
    fi
  done < <(race_members "$rdir")
  [ "$sent" -gt 0 ] || { echo "race: nothing to steer"; return 0; }
  echo "race: $sent worktree(s) re-dispatched with their review comments ('fleet wait' then 'fleet race judge $race' to iterate)"
}
