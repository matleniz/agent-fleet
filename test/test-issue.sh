#!/usr/bin/env bash
# test-issue.sh — `fleet issue` (bin/fleet-issue.py) drives a GitHub issue queue
# through the gh CLI. A stub `gh` records every call and answers with canned
# JSON, so no network and no real repo is touched.
#
#   new        labels (type/priority/area/agent/needs) + board Backlog + sub-issue link
#   start      board "In progress" + status:in-progress (others removed) + "Started by <wt>"
#   review     "In review" + status:in-review
#   block      needs --note; "Blocked" + status:blocked + "Blocked: ..." comment
#   done       open issue: needs --note, closes with it; closed issue: board only
#   guards     QUEUE_KIND!=github refused; bad --type/--priority refused;
#              no QUEUE_GITHUB_PROJECT = labels only (warning)
#   bootstrap  labels + README/forms (contents API) + board columns + .env lines
#
#   test/test-issue.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
FLEET="$REPO/bin/fleet"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-issue.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export FLEET_HOME="$TMP/config"
mkdir -p "$FLEET_HOME/projects" "$TMP/code" "$TMP/wt/my-worker" "$TMP/bin"
git init -q "$TMP/wt/my-worker"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
has() { if grep -qF -- "$2" "$REC"; then ok "$1"; else bad "$1: no call matching '$2'"; sed 's/^/       /' "$REC"; fi; }
hasnt() { if grep -qF -- "$2" "$REC"; then bad "$1: unexpected call '$2'"; else ok "$1"; fi; }

conf() {  # <kind> [project]
  cat > "$FLEET_HOME/projects/proj.env" <<EOF
CODE_REPO="$TMP/code"
WT_HOME="$TMP/wt"
HUB=""
AGENTS="claude"
QUEUE_KIND="$1"
QUEUE_GITHUB_REPO="acme/widget-issues"
QUEUE_GITHUB_PROJECT="${2:-}"
QUEUE_NEEDS_LABEL="needs:owner"
EOF
}

export REC="$TMP/rec" STATE_FILE="$TMP/state"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# One line per call: argv joined by spaces (a body passed on stdin is appended).
line="$*"
case "$*" in *"--input -"*) line="$line STDIN:$(cat)";; esac
printf '%s\n' "$line" >> "$REC"
case "$1 $2" in
  "issue create")  echo "https://github.com/acme/widget-issues/issues/7" ;;
  "issue view")    cat "$STATE_FILE" ;;
  "project item-add") echo '{"id":"ITEM7"}' ;;
  "project view")  echo '{"id":"PROJ1","number":4}' ;;
  "project field-list")
    if [ -f "$STATE_FILE.cols" ]; then cat "$STATE_FILE.cols"; else
    echo '{"fields":[{"name":"Title","id":"F0"},{"name":"Status","id":"FST","options":[{"name":"Backlog","id":"o1"},{"name":"In progress","id":"o2"},{"name":"In review","id":"o3"},{"name":"Blocked","id":"o4"},{"name":"Done","id":"o5"}]}]}'; fi ;;
  "project list")  echo '{"projects":[]}' ;;
  "project create") echo '{"number":4,"id":"PROJ1"}' ;;
  "repo view")     exit 1 ;;   # bootstrap: the repo does not exist yet
  "api repos/acme/widget-issues/issues/7") echo "90007" ;;
  "api repos/acme/widget-issues/contents/README.md") exit 1 ;;   # 404
  "api repos/acme/widget-issues/contents/.github/ISSUE_TEMPLATE/bug.yml") exit 1 ;;
  "api repos/acme/widget-issues/contents/"*) echo '{"sha":"abc"}' ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

run() {  # run fleet issue from inside the worker worktree; sets out, rc
  : > "$REC"; rc=0
  out="$(cd "$TMP/wt/my-worker" && "$FLEET" --project proj issue "$@" 2>&1)" || rc=$?
}

conf github 4
echo "== new"
printf '## Context\nx\n' > "$TMP/body.md"
run new --type feature --priority p2 --area cli --parent 3 "A title" "$TMP/body.md"
[ "$rc" = 0 ] && ok "new rc=0" || bad "new rc=$rc: $out"
has "new: labels"        "issue create -R acme/widget-issues --title A title --body-file"
has "new: type label"    "--label type:feature --label priority:p2-high --label area:cli --label agent"
has "new: board add"     "project item-add 4 --owner acme --url https://github.com/acme/widget-issues/issues/7"
has "new: Backlog"       "--single-select-option-id o1"
has "new: sub-issue"     "api -X POST repos/acme/widget-issues/issues/3/sub_issues -F sub_issue_id=90007"
case "$out" in *"https://github.com/acme/widget-issues/issues/7"*) ok "new prints the url";; *) bad "new output: $out";; esac

run new --type feature --priority p3 --needs-human "T" - <<< "## Context
### Decision needed
a or b"
has "new: needs label from QUEUE_NEEDS_LABEL" "--label needs:owner"
hasnt "new: no parent, no sub-issue call" "sub_issues"

run new --type nope --priority p2 "T" "$TMP/body.md"
[ "$rc" = 2 ] && ok "bad --type refused" || bad "bad --type rc=$rc"
run new --type bug --priority p9 "T" "$TMP/body.md"
[ "$rc" = 2 ] && ok "bad --priority refused" || bad "bad --priority rc=$rc"

echo "== start / review / block"
run start 12 --note "plan: x"
[ "$rc" = 0 ] && ok "start rc=0" || bad "start rc=$rc: $out"
has "start: In progress" "--single-select-option-id o2"
has "start: label swap"  "issue edit 12 -R acme/widget-issues --remove-label status:in-review --remove-label status:blocked --add-label status:in-progress"
has "start: comment names the worktree" "issue comment 12 -R acme/widget-issues --body Started by my-worker"
run start 12 --by lead-x
has "start --by" "--body Started by lead-x"

run review 12
has "review: In review" "--single-select-option-id o3"
has "review: label"     "--add-label status:in-review"
hasnt "review: no empty comment" "issue comment"

run block 12
[ "$rc" = 2 ] && ok "block without --note refused" || bad "block no-note rc=$rc"
run block 12 --note "waiting on #9"
has "block: Blocked" "--single-select-option-id o4"
has "block: comment" "--body Blocked: waiting on #9"

echo "== done"
echo OPEN > "$STATE_FILE"
run "done" 12
[ "$rc" = 2 ] && ok "done on an open issue needs --note" || bad "done open no-note rc=$rc"
hasnt "done refused before touching anything" "item-add"
run "done" 12 --note "superseded by #13"
has "done: Done column" "--single-select-option-id o5"
has "done: all status labels removed" "--remove-label status:in-progress --remove-label status:in-review --remove-label status:blocked"
has "done: closes with the note" "issue close 12 -R acme/widget-issues --comment superseded by #13"
echo CLOSED > "$STATE_FILE"
run "done" 12
[ "$rc" = 0 ] && ok "done on a closed issue: no note needed" || bad "done closed rc=$rc: $out"
hasnt "done on a closed issue does not re-close" "issue close"

echo "== guards"
conf github ""
run review 12
[ "$rc" = 0 ] && ok "no board: still rc=0" || bad "no board rc=$rc"
hasnt "no board: no project call" "project "
has "no board: labels still set" "--add-label status:in-review"
case "$out" in *"QUEUE_GITHUB_PROJECT unset"*) ok "no board: warned";; *) bad "no board warning: $out";; esac
conf linear
run start 1
[ "$rc" = 2 ] && ok "QUEUE_KIND=linear refused" || bad "linear rc=$rc"
case "$out" in *"QUEUE_KIND=linear"*) ok "refusal names the kind";; *) bad "refusal: $out";; esac

echo "== bootstrap"
conf github ""
run bootstrap --area "cli=bin/" --area "area:docs=docs/"
[ "$rc" = 2 ] && ok "missing repo without --create refused" || bad "bootstrap no --create rc=$rc: $out"
run bootstrap --create --area "cli=bin/" --area "area:docs=docs/" --product widget
[ "$rc" = 0 ] && ok "bootstrap rc=0" || bad "bootstrap rc=$rc: $out"
has "bootstrap: private repo"    "repo create acme/widget-issues --private"
has "bootstrap: type label"      "label create type:doc-proposal -R acme/widget-issues"
has "bootstrap: needs label"     "label create needs:owner"
has "bootstrap: area label"      "label create area:cli -R acme/widget-issues --color 006b75 --description bin/"
has "bootstrap: area prefix kept" "label create area:docs"
has "bootstrap: README created"  "api -X PUT repos/acme/widget-issues/contents/README.md --input -"
grep "contents/README.md --input" "$REC" | grep -q '"sha"' && bad "README create carried a sha" || ok "README created without sha"
hasnt "bootstrap: existing form kept" "contents/.github/ISSUE_TEMPLATE/feature.yml --input"
has "bootstrap: board created"   "project create --owner acme --title widget"
has "bootstrap: board linked"    "project link 4 --owner acme --repo acme/widget-issues"
hasnt "bootstrap: standard columns untouched" "api graphql"
case "$out" in *'QUEUE_GITHUB_PROJECT="4"'*) ok "bootstrap prints the .env lines";; *) bad "bootstrap output: $out";; esac
# README content: the template's placeholders all substituted
readme="$(grep 'contents/README.md --input' "$REC" | sed 's/.*STDIN://' \
  | python3 -c 'import sys,json,base64; print(base64.b64decode(json.load(sys.stdin)["content"]).decode())')"
case "$readme" in *__*) bad "README has an unsubstituted placeholder";; *) ok "README placeholders substituted";; esac
case "$readme" in *'Closes acme/widget-issues#<n>'*'`needs:owner`'*) ok "README names the slug + needs label";; *) bad "README content";; esac

# A board with non-standard columns is not rewritten without --reset-columns.
echo '{"fields":[{"name":"Status","id":"FST","options":[{"name":"Todo","id":"x"},{"name":"Done","id":"y"}]}]}' > "$STATE_FILE.cols"
run bootstrap --create
[ "$rc" = 1 ] && ok "non-standard columns refused" || bad "columns guard rc=$rc: $out"
run bootstrap --create --reset-columns
has "--reset-columns rewrites Status" "api graphql -f query=mutation"

echo
echo "test-issue: $pass passed, $fail failed"
[ "$fail" = 0 ]
