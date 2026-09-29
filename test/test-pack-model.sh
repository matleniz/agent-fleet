#!/usr/bin/env bash
# test-pack-model.sh — the per-launch model convention (PACK_MODEL_FLAG), with
# fake CLI binaries only (no real model, no tmux, no global state).
#   1. every bundled pack that declares PACK_MODEL_FLAG puts `<flag> <model>` in
#      the CLI's argv when pack_launch_headless gets a model, and nothing when not;
#   2. fleet_warn_model_ignored is silent for a pack that honors the model, and
#      warns (stderr + events log) for a pack that leaves PACK_MODEL_FLAG unset.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENGINE="$(cd "$SELF_DIR/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

work="$(mktemp -d)"; export REC="$work/rec"
trap 'rm -rf "$work"' EXIT
stub="$work/bin"; mkdir -p "$stub" "$work/hub" "$work/home"

# pack:cli:expected flag
CASES=(
  "claude:claude:--model"
  "gemini:gemini:--model"
  "opencode:opencode:-m"
  "cursor:agent:--model"
  "antigravity:agy:--model"
  "copilot:copilot:--model"
)

run_pack() {  # <pack> [model] — run pack_launch_headless against the stub CLI
  (
    export HOME="$work/home" HUB="$work/hub" PATH="$stub:$PATH"
    unset XDG_CONFIG_HOME OPENCODE_CONFIG FLEET_MODEL
    # shellcheck source=/dev/null
    source "$ENGINE/bin/fleet-config.sh"
    # shellcheck source=/dev/null
    source "$ENGINE/packs/$1/pack.sh"
    pack_launch_headless "TASK_$1" ${2:+"$2"}
  ) >/dev/null 2>&1 || true
}

for c in "${CASES[@]}"; do
  IFS=':' read -r pack cli flag <<<"$c"
  case "$pack" in
    antigravity|copilot)   # mount-namespace jail: skip where userns is unavailable
      ( HUB=""; source "$ENGINE/packs/$pack/pack.sh"; _fleet_userns_ro_ok ) \
        || { echo "  $pack: SKIP (no unprivileged userns)"; continue; } ;;
  esac
  printf '#!/usr/bin/env bash\nprintf "%%s" "$*" > "$REC"\n' > "$stub/$cli"
  chmod +x "$stub/$cli"
  ( source "$ENGINE/packs/$pack/pack.sh"; [ "${PACK_MODEL_FLAG:-}" = "$flag" ] ) \
    || fail "$pack: PACK_MODEL_FLAG is not '$flag'"
  : > "$REC"; run_pack "$pack" some/model-x
  got="$(cat "$REC")"
  case "$got" in *"$flag some/model-x"*) ;; *) fail "$pack: '$flag some/model-x' not in argv (got: $got)";; esac
  case "$got" in *"TASK_$pack"*) ;; *) fail "$pack: task missing from argv (got: $got)";; esac
  : > "$REC"; run_pack "$pack"
  got="$(cat "$REC")"
  case "$got" in *"$flag"*) fail "$pack: '$flag' leaked without a model (got: $got)";; esac
  case "$got" in *"TASK_$pack"*) ;; *) fail "$pack: task missing without model (got: $got)";; esac
  rm -f "$stub/$cli"
  echo "  $pack: OK ($flag)"
done

# ---- warning: a pack that ignores the model vs one that honors it ----
source "$ENGINE/bin/fleet-config.sh"
log="$work/events.log"

PACK_MODEL_FLAG="" ; : > "$log"
err="$(fleet_warn_model_ignored fakepack some-model "$log" 2>&1 >/dev/null)"
case "$err" in *"pack 'fakepack' ignores --model (asked: some-model)"*) ;; *) fail "no stderr warning for an ignoring pack (got: $err)";; esac
grep -q "model-ignored: pack 'fakepack' ignores --model" "$log" || fail "warning not recorded in events log"

: > "$log"
err="$(fleet_warn_model_ignored fakepack "" "$log" 2>&1)"
[ -z "$err" ] && [ ! -s "$log" ] || fail "warned with no model requested (got: $err)"

PACK_MODEL_FLAG=--model
err="$(fleet_warn_model_ignored fakepack some-model "$log" 2>&1)"
[ -z "$err" ] && [ ! -s "$log" ] || fail "warned for a pack that honors the model (got: $err)"
echo "PASS: model reaches argv where supported; ignored model warns loudly"
