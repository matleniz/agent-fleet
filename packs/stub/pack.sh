# shellcheck shell=bash
# stub pack — no network, no real agent CLI. For CI / sandbox dogfood and for
# `fleet dispatch` plumbing tests. Writes markers instead of calling a model.
# Enable with AGENTS="stub" (or include stub in the list). Not a production pack.

pack_launch() { : ; }

# Headless: record the prompt (+ optional model) then exit 0. Tests and
# write-probe look for .fleet-witness / .dispatch-marker.
pack_launch_headless() {
  printf '%s' "$1" > "$PWD/.dispatch-marker"
  printf '%s' "${2:-}" > "$PWD/.model-marker"
  # write-probe asks for .fleet-witness — honor that so doctor --write-probe PASS.
  case "$1" in
    *.fleet-witness*|*"fleet-witness"*) printf 'OK\n' > "$PWD/.fleet-witness" ;;
  esac
}

pack_has_sessions() { return 1; }

pack_worker_setup() { return 0; }

pack_barrier_files() {
  echo ".dispatch-marker"
  echo ".model-marker"
  echo ".fleet-witness"
}

pack_global_setup() { echo "skipped:stub"; }

pack_install() { echo "(stub — no install)"; }

pack_doctor() {
  if [ "${1:-}" = probe ]; then
    pack_launch_headless 'Create a file named .fleet-witness containing the text OK in the current directory, then stop. Do nothing else.'
    if [ -f .fleet-witness ]; then
      echo "write-probe: PASS (stub wrote the witness)"
    else
      echo "write-probe: FAIL (stub)"
    fi
    return
  fi
  echo "stub (no CLI — offline dogfood / CI)"
}
