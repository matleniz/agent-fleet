#!/usr/bin/env python3
"""PreToolUse hook: hard-block writes/edits to the docs hub from a worker.

Registered by `new-worker` in each worker's .claude/settings.local.json. Runs in
every permission mode (default/acceptEdits/bypass), unlike a `deny` rule, which
does NOT override an additionalDirectories root (a hub added to
additionalDirectories so it can be read is otherwise also writable, and
acceptEdits writes straight through a deny). This hook is the real barrier.

Reads the tool-call JSON on stdin; exits 2 (block) if the target path is inside
the hub, else 0 (allow). The hub path comes from argv[1], else $HUB.
"""
import sys
import json
import os

hub = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("HUB", "")
if not hub:
    sys.exit(0)  # no hub configured: nothing to protect
HUB = os.path.abspath(os.path.expanduser(hub))

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)  # fail open: never break unrelated tool calls

ti = data.get("tool_input", {}) or {}
paths = [ti[k] for k in ("file_path", "path", "notebook_path") if isinstance(ti.get(k), str)]

def under_hub(p):
    ap = os.path.abspath(os.path.expanduser(p))
    return ap == HUB or ap.startswith(HUB + os.sep)

if any(under_hub(p) for p in paths):
    sys.stderr.write(
        "The docs hub is read-only from a worker. Propose changes via the "
        "propose-doc-change skill (the queue); do not edit the hub directly.\n"
    )
    sys.exit(2)

sys.exit(0)
