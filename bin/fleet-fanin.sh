# shellcheck shell=bash
# shellcheck disable=SC2154  # set by bin/fleet, which sources this file
# fleet-fanin.sh — `fleet fanin` (sourced by bin/fleet): OPTIONAL hierarchical fan-in;
# a lead pass (fleet_pass, see fleet-pass.sh) folds K workers into one report.

# ---------- fleet fanin ----------

# One worker's compact result: the SAME text a coordinator would read directly
# (status, task head, commits, diffstat, optional worker-written summary).
fanin_digest() {  # <worker-name>
  local name="$1" sdir wt base pack
  sdir="$(dispatch_state_dir)"; wt="$WT_HOME/$name"
  pack="$(sed -n 's/^pack=//p' "$sdir/$name.meta" 2>/dev/null | head -1)" || true
  printf '### %s\nstatus: %s  pack: %s\n' "$name" "$(cat "$sdir/$name.status" 2>/dev/null || echo '?')" "${pack:-?}"
  printf 'task: %s\n' "$( (tr '\n' ' ' < "$sdir/$name.task" 2>/dev/null | cut -c1-300) || true)"
  if [ -d "$wt" ] && base="$(pass_base_ref "$wt" "")"; then
    printf 'commits:\n'; git -C "$wt" log --format='  %h %s' "$base..HEAD" 2>/dev/null | head -8
    printf 'diffstat:\n'; git -C "$wt" diff --stat "$(git -C "$wt" merge-base "$base" HEAD 2>/dev/null || echo "$base")" 2>/dev/null | tail -16
  fi
  if [ -f "$wt/.fleet-summary" ]; then printf 'summary:\n'; head -40 "$wt/.fleet-summary"; fi
  return 0
}

cmd_fanin() {
  local k="${FANIN_GROUP:-${FLEET_DEF_FANIN_GROUP:-4}}" target="" dry=0 names=()
  while :; do
    case "${1:-}" in
      --group) [ $# -ge 2 ] || { echo "error: --group needs a value" >&2; return 2; }; k="$2"; shift 2 ;;
      --with)  [ $# -ge 2 ] || { echo "error: --with needs a value" >&2; return 2; }; target="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      -*) echo "usage: fleet fanin [--group K] [--with pack[:model]] [--dry-run] [<worker>...]" >&2; return 2 ;;
      *) break ;;
    esac
  done
  [ "$k" -ge 1 ] 2>/dev/null || { echo "error: --group must be a positive integer" >&2; return 2; }
  need_code_repo
  local sdir f n
  sdir="$(pass_sdir)"
  if [ $# -gt 0 ]; then names=("$@")
  else
    for f in "$sdir"/*.status; do
      [ -e "$f" ] || continue
      n="$(basename "$f" .status)"
      case "$(cat "$f")" in done*) names+=("$n") ;; esac
    done
  fi
  [ "${#names[@]}" -gt 0 ] || { echo "fanin: no finished dispatched workers for '$PROJ_NAME'." >&2; return 0; }

  local work; work="$(mktemp -d "${TMPDIR:-/tmp}/fleet-fanin.XXXXXX")"
  local i=0 g=0 raw_tok=0 lead_in=0 lead_out=0 report="" t
  local batch
  # raw = what the hub would read with no fan-in.
  for n in "${names[@]}"; do fanin_digest "$n" > "$work/d.$n"; done
  : > "$work/raw"
  for n in "${names[@]}"; do cat "$work/d.$n" >> "$work/raw"; done
  raw_tok="$(pass_tokens "$work/raw")"
  if [ "$dry" = 1 ]; then
    echo "fanin (dry run): ${#names[@]} worker(s) in $(( (${#names[@]} + k - 1) / k )) group(s) of <=$k; direct read = ~$raw_tok hub tokens"
    rm -rf "$work"; return 0
  fi
  while [ "$i" -lt "${#names[@]}" ]; do
    g=$((g + 1)); batch=("${names[@]:$i:$k}"); i=$((i + k))
    local digests="" gout="$work/g.$g" prompt
    for n in "${batch[@]}"; do digests="$digests
$(cat "$work/d.$n")
"; done
    prompt="[fleet-pass:fanin]
You are a lead summarizing the results of ${#batch[@]} parallel workers for a coordinator who will NOT read the raw material. Do NOT modify, create, delete or commit any file.

For EACH worker output exactly one line, no prose around it:
- <worker> | <ok|failed|needs-human> | <outcome in at most 25 words> | files: <n> | risk: <at most 15 words, or none>
Then one last line: 'NEEDS-HUMAN: <comma-separated workers, or none>'. Treat a non-'done rc=0' status, a missing deliverable, or an empty diff as needs-human.

$digests"
    printf '%s' "$prompt" > "$work/p.$g"
    if fleet_pass fanin "$WT_HOME/${batch[0]}" "$prompt" "$gout" "$target" \
       && grep -q '^NEEDS-HUMAN:' "$gout"; then
      lead_in=$((lead_in + $(pass_tokens "$work/p.$g"))); lead_out=$((lead_out + $(pass_tokens "$gout")))
      report="$report
## group $g
$(cat "$gout")
"
    else
      # Never lose data: an unusable lead pass degrades to the raw digests for that group.
      echo "fanin: group $g lead pass unusable — including its raw digests instead" >&2
      report="$report
## group $g (raw: lead pass unavailable)
$digests
"
    fi
  done
  mkdir -p "$sdir/fanin"
  t="$(date -u +%Y%m%dT%H%M%SZ)"
  printf '# fan-in report — %s workers, groups of %s (%s)\n%s\n' "${#names[@]}" "$k" "$t" "$report" > "$sdir/fanin/$t.md"
  cp "$sdir/fanin/$t.md" "$sdir/fanin/latest.md"
  local rep_tok; rep_tok="$(pass_tokens "$sdir/fanin/$t.md")"
  cat "$sdir/fanin/$t.md"
  printf '%s\tn=%s\tk=%s\thub_direct=%s\thub_fanin=%s\tlead_in=%s\tlead_out=%s\n' \
    "$t" "${#names[@]}" "$k" "$raw_tok" "$rep_tok" "$lead_in" "$lead_out" >> "$sdir/fanin/measure.tsv"
  echo "fanin: hub reads ~$rep_tok tokens instead of ~$raw_tok (estimate, 1 token ~ 4 bytes); the lead passes spent ~$lead_in in / ~$lead_out out extra. report: $sdir/fanin/$t.md  (log: $sdir/fanin/measure.tsv)" >&2
  rm -rf "$work"
}
