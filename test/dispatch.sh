#!/usr/bin/env bash
# dispatch.sh — prove `fleet dispatch` (headless worker in a detached tmux
# window) and each pack's pack_launch_headless, WITHOUT launching a real agent.
#
# Layer 1 (always): for every bundled pack, stub its CLI on PATH and call
#   pack_launch_headless "<task>" — assert the CLI is invoked in headless mode
#   with the bypass flag and the task. This is the fix for the no-shell failure
#   mode (a worker launched with the wrong flag, so approvals stayed on).
# Layer 2 (needs tmux): a stub PACK + `fleet dispatch` on the sandbox — assert
#   the worktree is created and the detached window actually runs the worker
#   (pack_launch_headless writes a marker in the worktree). No real agent, so no
#   API and no auto-mode classifier in the way.
#
# Exits non-zero on failure. Layer 2 skips (not fails) without tmux.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENGINE="$(cd "$SELF_DIR/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------- Layer 1: per-pack headless command ----------
# pack -> the CLI binary it execs, and the flags the stub must observe.
#   pack:cli:needle1|needle2|...
CASES=(
  "claude:claude:-p|--permission-mode auto"
  "gemini:gemini:-p|--approval-mode yolo"
  "opencode:opencode:run|--auto|--format json"
  "cursor:agent:-p|--force"
  "antigravity:agy:-p|--dangerously-skip-permissions"
  "copilot:copilot:-p|--allow-all-tools"
)
stub="$(mktemp -d)"; export REC="$stub/rec"
trap 'rm -rf "$stub"' EXIT
rohub="$(mktemp -d)"    # for the antigravity/copilot jails (a real dir to mount ro)

for c in "${CASES[@]}"; do
  IFS=':' read -r pack cli needles <<<"$c"
  # antigravity + copilot route headless through the mount-namespace jail; skip
  # if userns is unavailable here (the packs themselves fail closed in that case).
  case "$pack" in
    antigravity|copilot)
      ( HUB=""; source "$ENGINE/packs/$pack/pack.sh"
        _fleet_userns_ro_ok ) \
        || { echo "  $pack: SKIP (no unprivileged userns)"; continue; }
      ;;
  esac
  printf '#!/usr/bin/env bash\nprintf "%%s" "$*" > "$REC"\n' > "$stub/$cli"
  chmod +x "$stub/$cli"
  : > "$REC"
  (
    PATH="$stub:$PATH"
    case "$pack" in antigravity|copilot) export HUB="$rohub";; esac
    source "$ENGINE/bin/fleet-config.sh"   # defines fleet_node_heap_guard (packs call it), as in production
    source "$ENGINE/packs/$pack/pack.sh"
    pack_launch_headless "TASK_$pack here"
  ) || true
  got="$(cat "$REC" 2>/dev/null || true)"
  IFS='|' read -ra needarr <<<"$needles"
  for n in "${needarr[@]}"; do
    case "$got" in *"$n"*) ;; *) fail "$pack: headless cmd missing '$n' (got: $got)";; esac
  done
  case "$got" in *"TASK_$pack here"*) ;; *) fail "$pack: task not passed (got: $got)";; esac
  # MAT-14: agy's `-p` takes the next argv as the prompt (unlike cursor's boolean
  # `-p`). Assert adjacency so `--dangerously-skip-permissions` cannot be eaten.
  if [ "$pack" = antigravity ]; then
    case "$got" in
      *"-p TASK_$pack here"*) ;;
      *) fail "$pack: expected -p <task> adjacency (got: $got)";;
    esac
  fi
  rm -f "$stub/$cli"
  echo "  $pack: OK ($got)"
done
echo "PASS (layer 1): every pack launches headless with bypass + task"

# ---------- Layer 1b: claude honors an optional per-launch model ($2) ----------
printf '#!/usr/bin/env bash\nprintf "%%s" "$*" > "$REC"\n' > "$stub/claude"; chmod +x "$stub/claude"
: > "$REC"
( PATH="$stub:$PATH"; source "$ENGINE/bin/fleet-config.sh"; source "$ENGINE/packs/claude/pack.sh"; pack_launch_headless "task" "opus" ) || true
got="$(cat "$REC" 2>/dev/null || true)"
case "$got" in *"--model opus"*) ;; *) fail "claude: --model not passed with \$2 (got: $got)";; esac
: > "$REC"
( PATH="$stub:$PATH"; source "$ENGINE/bin/fleet-config.sh"; source "$ENGINE/packs/claude/pack.sh"; pack_launch_headless "task" ) || true
got="$(cat "$REC" 2>/dev/null || true)"
case "$got" in *"--model"*) fail "claude: --model leaked with no \$2 (got: $got)";; *) ;; esac
rm -f "$stub/claude"
echo "PASS (layer 1b): claude adds --model only when a model is given"

# ---------- Layer 1c: claude INTERACTIVE launch posture (workers + coordinator) ----------
# pack_launch must carry auto mode too — the org's managed settings silently
# downgrade --dangerously-skip-permissions to prompting (every write denied), so
# that flag must never come back on ANY launch path. --continue / --resume resolve
# the last REAL session by id (see test-claude-resume.sh); with NO prior session
# they fall back to CLI --continue. --pick hands off to the bare --resume picker.
# The empty-HOME below pins the deterministic continue-last fallback.
printf '#!/usr/bin/env bash\nprintf "%%s" "$*" > "$REC"\n' > "$stub/claude"; chmod +x "$stub/claude"
: > "$REC"
( PATH="$stub:$PATH"; source "$ENGINE/bin/fleet-config.sh"; source "$ENGINE/packs/claude/pack.sh"; pack_launch ) || true
got="$(cat "$REC" 2>/dev/null || true)"
case "$got" in *"--permission-mode auto"*) ;; *) fail "claude interactive: missing '--permission-mode auto' (got: $got)";; esac
case "$got" in *"dangerously"*) fail "claude interactive: bypass flag is back (got: $got)";; *) ;; esac
: > "$REC"
emptyhome="$(mktemp -d)"   # no ~/.claude sessions here -> --continue falls back to CLI --continue
( HOME="$emptyhome"; PATH="$stub:$PATH"; source "$ENGINE/bin/fleet-config.sh"; source "$ENGINE/packs/claude/pack.sh"; pack_launch --continue ) || true
got="$(cat "$REC" 2>/dev/null || true)"
case "$got" in *"--permission-mode auto"*"--continue"*|*"--continue"*"--permission-mode auto"*) ;; \
  *) fail "claude interactive --continue: expected auto mode + --continue fallback (got: $got)";; esac
: > "$REC"
( HOME="$emptyhome"; PATH="$stub:$PATH"; source "$ENGINE/bin/fleet-config.sh"; source "$ENGINE/packs/claude/pack.sh"; pack_launch --resume ) || true
got="$(cat "$REC" 2>/dev/null || true)"; rm -rf "$emptyhome"
case "$got" in *"--permission-mode auto"*"--continue"*|*"--continue"*"--permission-mode auto"*) ;; \
  *) fail "claude interactive --resume (synonym): expected auto mode + --continue fallback (got: $got)";; esac
: > "$REC"
( PATH="$stub:$PATH"; source "$ENGINE/bin/fleet-config.sh"; source "$ENGINE/packs/claude/pack.sh"; pack_launch --pick ) || true
got="$(cat "$REC" 2>/dev/null || true)"
# Picker = bare --resume (no session id). Stub records "$*".
case "$got" in *"--permission-mode auto"*"--resume"|*"--resume"*"--permission-mode auto"*) ;; \
  *) fail "claude interactive --pick: expected auto mode + bare --resume picker (got: $got)";; esac
# Nothing after --resume except optional further flags (resume is last today).
rest="${got##*--resume}"; rest="${rest#"${rest%%[![:space:]]*}"}"  # trim leading space
case "$rest" in ""|--*) ;; *) fail "claude interactive --pick: must not pass a session id (got: $got)";; esac
rm -f "$stub/claude"
echo "PASS (layer 1c): claude interactive launch is auto mode; --continue/--resume fall back; --pick opens picker"

# ---------- Layer 1d: launch survives `set -e` WITHOUT an MCP profile ----------
# Production regression this pins down: bin/fleet runs `set -euo pipefail`, and
# _claude_mcp_flags ended in `[ -f fleet-mcp.json ] && ...` — rc 1 whenever the
# profile is absent (every hub, every worktree without WORKER_MCP), silently
# killing the launch right before the exec. The other layers CANNOT catch this
# class: they run pack_launch inside `( ... ) || true`, and `||` suppresses
# set -e inside the subshell. Here the subshell is a bare statement (outer set +e,
# rc read afterwards), so the inner set -e is genuinely active, like in fleet.
printf '#!/usr/bin/env bash\nprintf "%%s" "$*" > "$REC"\n' > "$stub/claude"; chmod +x "$stub/claude"
nomcp="$(mktemp -d)"   # cwd with NO .claude/fleet-mcp.json, like a hub
for launch_call in "pack_launch" "pack_launch_headless task"; do
  : > "$REC"
  set +e
  ( set -e; PATH="$stub:$PATH"; cd "$nomcp"
    source "$ENGINE/bin/fleet-config.sh"; source "$ENGINE/packs/claude/pack.sh"
    $launch_call )
  rc=$?
  set -e
  [ "$rc" = 0 ] || fail "claude $launch_call died under set -e without an MCP profile (rc=$rc — silent-launch-death regression)"
  [ -s "$REC" ] || fail "claude $launch_call never exec'd the CLI under set -e without an MCP profile"
done
rm -rf "$nomcp"; rm -f "$stub/claude"
echo "PASS (layer 1d): claude launches survive set -e with no MCP profile (hub / no-WORKER_MCP worktree)"

# ---------- Layer 2: fleet dispatch plumbing (stub pack + tmux) ----------
if ! command -v tmux >/dev/null; then
  echo "SKIP (layer 2): tmux not installed"; exit 0
fi

ROOT="$HOME/fleet-sandbox"
export FLEET_HOME="${FLEET_HOME:-$HOME/.config/fleet}"
# The dispatch/worker windows run a bare `fleet` (production assumes ~/.local/bin
# symlinks). Put the repo's bin/ on PATH so the detached window resolves it here
# too — otherwise the worker never starts on a box without the symlinks (e.g. CI).
export PATH="$ENGINE/bin:$PATH"
"$SELF_DIR/make-sandbox.sh" "$ROOT" >/dev/null 2>&1 || fail "sandbox build failed"

# A stub pack that writes a marker (the prompt it received) into the worktree
# instead of launching a real agent. pack_worker_setup is a no-op (test only).
packs="$(mktemp -d)"; mkdir -p "$packs/stub"
cat > "$packs/stub/pack.sh" <<'PACK'
pack_launch()          { : ; }
pack_launch_headless() { printf '%s' "$1" > "$PWD/.dispatch-marker"; printf '%s' "${2:-}" > "$PWD/.model-marker"; }
pack_has_sessions()    { return 1; }
pack_worker_setup()    { return 0; }
pack_barrier_files()   { echo ".dispatch-marker"; }
pack_install()         { echo "(stub)"; }
pack_doctor()          { if [ "${1:-}" = probe ]; then echo OK > .fleet-witness; echo "write-probe: PASS (stub wrote the witness)"; else echo "stub"; fi; }
PACK
conf="$FLEET_HOME/projects/sandbox.env"
sed -i 's/^AGENTS=.*/AGENTS="stub"/' "$conf"

cleanup2() {
  tmux kill-session -t "fleet-sandbox" 2>/dev/null || true
  rm -rf "$packs"
}
trap 'rm -rf "$stub"; cleanup2' EXIT

FLEET_PACKS_DIR="$packs" "$ENGINE/bin/fleet" --project sandbox -a stub \
  dispatch dtest "please do the thing" >/dev/null 2>&1 || fail "fleet dispatch errored"

[ -d "$ROOT/wt/dtest" ] || fail "dispatch did not create the worktree"

marker="$ROOT/wt/dtest/.dispatch-marker"
for _ in $(seq 1 50); do [ -f "$marker" ] && break; sleep 0.2; done
[ -f "$marker" ] || fail "detached worker never ran (no marker after 10s)"
grep -q "please do the thing" "$marker" || fail "worker did not receive the task"
grep -q "READ-ONLY" "$marker" || fail "worker preamble missing the read-only-hub note"
tmux has-session -t "fleet-sandbox" 2>/dev/null || fail "dispatch tmux session not created"

# --- completion signal the coordinator observes ---
status="$FLEET_HOME/dispatch/sandbox/dtest.status"
for _ in $(seq 1 50); do [ "$(cat "$status" 2>/dev/null)" = "done rc=0" ] && break; sleep 0.2; done
[ "$(cat "$status" 2>/dev/null)" = "done rc=0" ] || fail "completion not recorded (status: $(cat "$status" 2>/dev/null))"
FLEET_PACKS_DIR="$packs" "$ENGINE/bin/fleet" --project sandbox ls 2>/dev/null \
  | grep -q "dispatch: done rc=0" || fail "fleet ls does not show the dispatch status"
FLEET_PACKS_DIR="$packs" FLEET_WAIT_POLL=1 "$ENGINE/bin/fleet" --project sandbox wait dtest >/dev/null 2>&1 \
  || fail "fleet wait did not return success for a done worker"
# Finished dispatch renames the pane to _done-<name> so it no longer burns a
# MAX_WORKERS slot (pack-interop dogfood 2026-09-25).
for _ in $(seq 1 50); do
  tmux list-windows -t fleet-sandbox -F '#{window_name}' 2>/dev/null | grep -Fxq -- '_done-dtest' && break
  sleep 0.2
done
tmux list-windows -t fleet-sandbox -F '#{window_name}' 2>/dev/null | grep -Fxq -- '_done-dtest' \
  || fail "finished dispatch did not rename window to _done-dtest"
# peek must still resolve the worker under its original name
FLEET_PACKS_DIR="$packs" "$ENGINE/bin/fleet" --project sandbox peek local dtest >/dev/null 2>&1 \
  || fail "fleet peek local dtest failed after _done- rename"
# fleet del must reap the renamed pane too — including a legacy duplicate
# _done-dtest (re-dispatch under one name used to leave two, making the name
# target ambiguous).
tmux new-window -d -t fleet-sandbox -n _done-dtest "exec sleep 600"
FLEET_PACKS_DIR="$packs" "$ENGINE/bin/fleet" --project sandbox del dtest >/dev/null 2>&1 \
  || fail "fleet del dtest failed"
if tmux list-windows -t fleet-sandbox -F '#{window_name}' 2>/dev/null | grep -Fxq -- '_done-dtest'; then
  fail "fleet del left a _done-dtest window behind"
fi
rm -rf "$FLEET_HOME/dispatch/sandbox"
echo "PASS (layer 2): dispatch ran the detached worker (task + preamble) and recorded completion (status + fleet ls + fleet wait + _done- rename + del reaps _done-)"

# ---------- Layer 2c: failing pack still records done rc=N (MAT-13) ----------
# Under `set -e`, a bare failing subshell used to abort _dispatch-run before the
# status write — forever "running", hung `fleet wait`. Stub exits 7.
cat > "$packs/stub/pack.sh" <<'PACK'
pack_launch()          { : ; }
pack_launch_headless() { return 7; }
pack_has_sessions()    { return 1; }
pack_worker_setup()    { return 0; }
pack_barrier_files()   { : ; }
pack_install()         { echo "(stub)"; }
pack_doctor()          { echo "stub"; }
PACK
FLEET_PACKS_DIR="$packs" "$ENGINE/bin/fleet" --project sandbox -a stub \
  dispatch failtest "should fail" >/dev/null 2>&1 || true
fstatus="$FLEET_HOME/dispatch/sandbox/failtest.status"
for _ in $(seq 1 50); do
  case "$(cat "$fstatus" 2>/dev/null)" in done\ rc=*) break ;; esac
  sleep 0.2
done
[ "$(cat "$fstatus" 2>/dev/null)" = "done rc=7" ] \
  || fail "failing dispatch did not record done rc=7 (got: $(cat "$fstatus" 2>/dev/null))"
rc=0
FLEET_PACKS_DIR="$packs" FLEET_WAIT_POLL=1 "$ENGINE/bin/fleet" --project sandbox wait failtest >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] || fail "fleet wait should be non-zero for done rc=7"
rm -rf "$FLEET_HOME/dispatch/sandbox"
# Restore writing stub for later layers
cat > "$packs/stub/pack.sh" <<'PACK'
pack_launch()          { : ; }
pack_launch_headless() { printf '%s' "$1" > "$PWD/.dispatch-marker"; printf '%s' "${2:-}" > "$PWD/.model-marker"; }
pack_has_sessions()    { return 1; }
pack_worker_setup()    { return 0; }
pack_barrier_files()   { echo ".dispatch-marker"; }
pack_install()         { echo "(stub)"; }
pack_doctor()          { if [ "${1:-}" = probe ]; then echo OK > .fleet-witness; echo "write-probe: PASS (stub wrote the witness)"; else echo "stub"; fi; }
PACK
echo "PASS (layer 2c): failing pack_launch_headless records done rc=N (set -e safe)"

# ---------- Layer 2b: dispatch --model plumbs the model to the pack ----------
FLEET_PACKS_DIR="$packs" "$ENGINE/bin/fleet" --project sandbox -a stub \
  dispatch --model my-model mtest "task two" >/dev/null 2>&1 || fail "dispatch --model errored"
mm="$ROOT/wt/mtest/.model-marker"
for _ in $(seq 1 50); do [ -f "$mm" ] && break; sleep 0.2; done
[ "$(cat "$mm" 2>/dev/null)" = "my-model" ] || fail "dispatch --model not propagated (got: $(cat "$mm" 2>/dev/null))"
rm -rf "$FLEET_HOME/dispatch/sandbox"
echo "PASS (layer 2b): dispatch --model reaches pack_launch_headless (\$2)"

# ---------- Layer 3: remote dispatch delegates to the container's fleet -------
# Stub ssh so no real VM is needed: it records the command the laptop would send.
# The sandbox already selects a placeholder machine 'vm'. version_preflight's
# probe returns empty (stub) so it stays silent; the dispatch ssh is what we assert.
export SSHLOG="$stub/sshlog"; : > "$SSHLOG"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$SSHLOG"\n' > "$stub/ssh"; chmod +x "$stub/ssh"
FLEET_PACKS_DIR="$packs" PATH="$stub:$PATH" "$ENGINE/bin/fleet" --project sandbox -a stub \
  --machine vm dispatch --model opus rtest "remote task" >/dev/null 2>&1 || fail "remote dispatch errored"
[ ! -d "$ROOT/wt/rtest" ] || fail "remote dispatch created a LOCAL worktree (should delegate to the VM)"
b64="$(printf '%s' "remote task" | base64 | tr -d '\n')"
disp="$(grep 'dispatch' "$SSHLOG" || true)"
[ -n "$disp" ] || fail "remote dispatch sent no 'dispatch' command over ssh (log: $(cat "$SSHLOG"))"
for n in "docker exec" "bash -lc" "dispatch" "--task-file" "--model opus" "rtest" "$b64"; do
  case "$disp" in *"$n"*) ;; *) fail "remote dispatch cmd missing '$n' (got: $disp)";; esac
done
rm -f "$stub/ssh"
echo "PASS (layer 3): remote dispatch delegates to the container (ssh+docker, task base64, --model, no local worktree)"

# ---------- Layer 4: fleet doctor --write-probe (local) ----------------------
FLEET_PACKS_DIR="$packs" "$ENGINE/bin/fleet" --project sandbox doctor --write-probe 2>&1 \
  | grep -q "write-probe: PASS" || fail "doctor --write-probe did not report PASS for a writing pack"
echo "PASS (layer 4): fleet doctor --write-probe runs the witness write per pack"

# ---------- Layer 4b: --write-probe honors --machine AFTER the subcommand -----
# Regression: cmd_doctor used to inspect only $1, so a trailing --machine was
# dropped and it always probed local. With the ssh stub, targeting 'vm' must go
# remote (an ssh 'doctor --write-probe' to the container), not run locally.
: > "$SSHLOG"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$SSHLOG"\n' > "$stub/ssh"; chmod +x "$stub/ssh"
FLEET_PACKS_DIR="$packs" PATH="$stub:$PATH" "$ENGINE/bin/fleet" --project sandbox \
  doctor --write-probe --machine vm >/dev/null 2>&1 || true
grep -q "doctor --write-probe" "$SSHLOG" \
  || fail "doctor --write-probe --machine vm did not target the VM (trailing --machine dropped?)"
rm -f "$stub/ssh"
echo "PASS (layer 4b): doctor --write-probe honors --machine after the subcommand"

# ---------- Layer 5: input validation (names + flag values) -------------------
# 5a: worker/dispatch names with shell metacharacters are refused (they otherwise
# thread UNQUOTED through tmux/ssh). 5b: --model with no value must error, not
# busy-loop forever (the old `shift 2 || true` hang).
FLEET_PACKS_DIR="$packs" "$ENGINE/bin/fleet" --project sandbox -a stub \
  dispatch 'bad;name' "x" >/dev/null 2>&1 && fail "dispatch accepted an unsafe worker name"
[ ! -e "$ROOT/wt/bad;name" ] || fail "unsafe-named worktree was created"
FLEET_PACKS_DIR="$packs" "$ENGINE/bin/fleet" --project sandbox -a stub \
  w 'evil$(touch pwned)' >/dev/null 2>&1 && fail "fleet w accepted an unsafe worker name"
FLEET_PACKS_DIR="$packs" "$ENGINE/bin/fleet" --project sandbox -a stub \
  w --help >/dev/null 2>&1 && fail "fleet w accepted leading-dash name --help"
# add-agent available list must be pack dirs only (not packs/hub-mount-ns.sh).
add_out="$("$ENGINE/bin/fleet" --project sandbox add-agent nosuch 2>&1)" || true
case "$add_out" in *hub-mount-ns*) fail "add-agent available list includes hub-mount-ns.sh (not a pack)";; esac
echo "PASS (layer 5a): unsafe worker/dispatch names are refused"

guard=""; command -v timeout >/dev/null && guard="timeout 10"
rc=0
$guard env FLEET_PACKS_DIR="$packs" "$ENGINE/bin/fleet" --project sandbox -a stub \
  dispatch --model >/dev/null 2>&1 || rc=$?
[ "$rc" = 124 ] && fail "dispatch --model (no value) HUNG (busy-loop regression)"
[ "$rc" != 0 ] || fail "dispatch --model (no value) should error, not succeed"
echo "PASS (layer 5b): dispatch --model with no value errors instead of hanging"
