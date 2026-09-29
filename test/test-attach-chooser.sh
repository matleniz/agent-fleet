#!/usr/bin/env bash
# test-attach-chooser.sh — the grouped view that `fleet attach` opens (the REAL
# view_snippet from bin/fleet, extracted not copied) must receive Ctrl-b w and
# show the window chooser. Runs a client in a pty on a private tmux socket (-L),
# so it never touches the caller's tmux. Skips cleanly without tmux or a pty.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENGINE="$(cd "$SELF_DIR/.." && pwd)"
command -v tmux >/dev/null || { echo "SKIP: tmux not installed"; exit 0; }
python3 -c 'import pty, os; os.close(pty.openpty()[0])' 2>/dev/null \
  || { echo "SKIP: no pty available"; exit 0; }

TMP="$(mktemp -d)"
SOCK="fleet-chooser-$$"
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

# The real view_snippet, rendered for session fleet-x (window list only).
eval "$(sed -n '/^view_snippet() {/,/^}/p' "$ENGINE/bin/fleet")"
[ "$(type -t view_snippet)" = function ] || { echo "FAIL: could not extract view_snippet" >&2; exit 1; }
view_snippet fleet-x "" > "$TMP/snippet.sh"

# The snippet calls bare `tmux`: shim it onto the private socket.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexec %s -L %s "$@"\n' "$(command -v tmux)" "$SOCK" > "$TMP/bin/tmux"
chmod +x "$TMP/bin/tmux"

tmux -L "$SOCK" new-session -d -s fleet-x -n _home
for n in w1 w2 w3; do tmux -L "$SOCK" new-window -t fleet-x -n "$n"; done

SNIPPET="$TMP/snippet.sh" SOCK="$SOCK" PATH="$TMP/bin:$PATH" env -u TMUX python3 - <<'PY'
import fcntl, os, pty, select, struct, subprocess, sys, termios, time

sock = os.environ["SOCK"]

def tmux(*a):
    return subprocess.run(["tmux", "-L", sock, *a], capture_output=True, text=True, timeout=10)

pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execvp("bash", ["bash", os.environ["SNIPPET"]])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))

def pump(deadline):
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                os.read(fd, 65536)
            except OSError:
                return

def view():
    out = tmux("list-sessions", "-F", "#{session_name}").stdout.split()
    return next((s for s in out if s.startswith("fv-")), None)

def wait(cond, secs=10):
    end = time.time() + secs
    while time.time() < end:
        pump(time.time() + 0.1)
        if cond():
            return True
    return False

def fail(msg):
    print("FAIL: " + msg, file=sys.stderr)
    tmux("kill-server")
    sys.exit(1)

if not wait(lambda: view() and tmux("list-clients", "-t", view()).stdout.strip()):
    fail("no client attached to the fv-* view")
v = view()
os.write(fd, b"\x02w")   # prefix + w
if not wait(lambda: tmux("display-message", "-p", "-t", v, "#{pane_mode}").stdout.strip() == "tree-mode"):
    fail("Ctrl-b w did not open the window chooser (pane_mode != tree-mode)")
print("ok   Ctrl-b w opens the window chooser in the fleet view")
PY
