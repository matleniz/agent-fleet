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
  "opencode:opencode:run|--auto"
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
    source "$ENGINE/packs/$pack/pack.sh"
    pack_launch_headless "TASK_$pack here"
  ) || true
  got="$(cat "$REC" 2>/dev/null || true)"
  IFS='|' read -ra needarr <<<"$needles"
  for n in "${needarr[@]}"; do
    case "$got" in *"$n"*) ;; *) fail "$pack: headless cmd missing '$n' (got: $got)";; esac
  done
  case "$got" in *"TASK_$pack here"*) ;; *) fail "$pack: task not passed (got: $got)";; esac
  rm -f "$stub/$cli"
  echo "  $pack: OK ($got)"
done
echo "PASS (layer 1): every pack launches headless with bypass + task"

# ---------- Layer 1b: claude honors an optional per-launch model ($2) ----------
printf '#!/usr/bin/env bash\nprintf "%%s" "$*" > "$REC"\n' > "$stub/claude"; chmod +x "$stub/claude"
: > "$REC"
( PATH="$stub:$PATH"; source "$ENGINE/packs/claude/pack.sh"; pack_launch_headless "task" "opus" ) || true
got="$(cat "$REC" 2>/dev/null || true)"
case "$got" in *"--model opus"*) ;; *) fail "claude: --model not passed with \$2 (got: $got)";; esac
: > "$REC"
( PATH="$stub:$PATH"; source "$ENGINE/packs/claude/pack.sh"; pack_launch_headless "task" ) || true
got="$(cat "$REC" 2>/dev/null || true)"
case "$got" in *"--model"*) fail "claude: --model leaked with no \$2 (got: $got)";; *) ;; esac
rm -f "$stub/claude"
echo "PASS (layer 1b): claude adds --model only when a model is given"

# ---------- Layer 2: fleet dispatch plumbing (stub pack + tmux) ----------
if ! command -v tmux >/dev/null; then
  echo "SKIP (layer 2): tmux not installed"; exit 0
fi

ROOT="$HOME/fleet-sandbox"
export FLEET_HOME="${FLEET_HOME:-$HOME/.config/fleet}"
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
rm -rf "$FLEET_HOME/dispatch/sandbox"
echo "PASS (layer 2): dispatch ran the detached worker (task + preamble) and recorded completion (status + fleet ls + fleet wait)"

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
