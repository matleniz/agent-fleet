#!/usr/bin/env python3
"""fleet-route.py — route tasks to pack:model via configurable preferences.

Invoked by `fleet route [--difficulty D] [--kind K] [--escalate] [--task T]`.
Prints `pack:model` (or `pack` if model is empty) to stdout.

Resolves preference lists in order:
  - --escalate -> ROUTE_ESCALATE
  - --kind <K> -> ROUTE_KIND_<K> (if set)
  - --difficulty <easy|medium|hard> -> ROUTE_EASY / ROUTE_MEDIUM / ROUTE_HARD
  - default -> ROUTE_MEDIUM

Config precedence:
  1. CLI arguments and environment variables (ROUTE_*)
  2. Active project config (.env or $FLEET_CONF)
  3. Global ~/.config/fleet/routing.env
  4. Global ~/.config/fleet/default.env
  5. Built-in defaults

Enforces:
  - Only packs enabled in project AGENTS are eligible.
  - ROUTE_CLAUDE policy: escalate-only (default), allowed, never.
  - Quota fall-through: if a candidate pack has exceeded its quota, fall through
    to the next preference entry.
  - Hub barrier: if HUB is set, packs requiring unprivileged userns
    (antigravity, copilot) are filtered out if userns is unavailable.
  - ROUTE_MAX_DEPTH: refuses if current recursion depth reaches or exceeds max depth.
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from fleet_common import assert_not_legacy, parse_env  # noqa: E402

DEFAULT_ROUTE_CONF = {
    "ROUTE_EASY": "gemini opencode:haiku antigravity copilot",
    "ROUTE_MEDIUM": "gemini opencode antigravity copilot cursor",
    "ROUTE_HARD": "gemini opencode antigravity copilot cursor claude:sonnet",
    "ROUTE_ESCALATE": "claude:sonnet claude:opus",
    "ROUTE_CLAUDE": "escalate-only",
    "ROUTE_MAX_DEPTH": "2",
    "ROUTE_SCORER": "",
}


def check_userns_ok():
    """True iff unshare userns and mount namespace works."""
    try:
        p = subprocess.run(
            ["unshare", "--user", "--map-root-user", "--mount", "--", "true"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2,
        )
        return p.returncode == 0
    except Exception:
        return False


def is_copilot_quota_exceeded():
    """True iff recent Copilot logs indicate monthly quota exceeded."""
    logdir = os.path.expanduser("~/.copilot/logs")
    if not os.path.isdir(logdir):
        return False
    try:
        logs = sorted(
            glob.glob(os.path.join(logdir, "process-*.log")),
            key=os.path.getmtime,
            reverse=True,
        )
    except OSError:
        return False
    now = time.time()
    window = int(os.environ.get("COPILOT_QUOTA_WINDOW_SEC", "86400"))
    for log in logs[:10]:
        try:
            if now - os.path.getmtime(log) > window:
                break
            with open(log, errors="ignore") as f:
                c = f.read()
                if "exceeded your monthly quota" in c or "402 You have exceeded" in c:
                    return True
        except OSError:
            pass
    return False


def is_pack_quota_exceeded(pack, conf, manual_exceeded):
    """Check if a pack is out of quota."""
    if pack in manual_exceeded:
        return True
    pack_upper = pack.upper().replace("-", "_")
    if conf.get(f"FLEET_QUOTA_EXCEEDED_{pack_upper}") == "1":
        return True
    if conf.get(f"FLEET_QUOTA_{pack_upper}") == "0":
        return True
    if pack == "copilot" and is_copilot_quota_exceeded():
        return True
    if pack == "cursor" and os.path.exists(os.path.expanduser("~/.cursor/quota_exceeded")):
        return True
    return False


def resolve_conf(proj=None):
    root = os.environ.get("FLEET_HOME") or os.path.expanduser("~/.config/fleet")
    assert_not_legacy(root)
    conf = dict(DEFAULT_ROUTE_CONF)

    # Global configs
    for name in ("routing.env", "default.env"):
        p = os.path.join(root, name)
        if os.path.isfile(p):
            conf.update(parse_env(p))

    # Project config
    proj_file = os.environ.get("FLEET_CONF")
    if not proj_file and proj:
        cand = os.path.join(root, "projects", f"{proj}.env")
        if os.path.isfile(cand):
            proj_file = cand
    if not proj_file and os.environ.get("FLEET_PROJECT"):
        cand = os.path.join(root, "projects", f"{os.environ['FLEET_PROJECT']}.env")
        if os.path.isfile(cand):
            proj_file = cand

    if proj_file and os.path.isfile(proj_file):
        conf.update(parse_env(proj_file))

    # Environment overrides
    for k, v in os.environ.items():
        if k.startswith("ROUTE_") or k.startswith("FLEET_QUOTA_") or k in ("AGENTS", "HUB", "FLEET_DISPATCH_DEPTH"):
            conf[k] = v

    return conf, root


def parse_candidates(list_str):
    raw_entries = [item.strip() for item in re.split(r"[,\s]+", list_str) if item.strip()]
    candidates = []
    for entry in raw_entries:
        if ":" in entry:
            p, m = entry.split(":", 1)
            candidates.append((p.strip(), m.strip()))
        else:
            candidates.append((entry, ""))
    return candidates


def main():
    parser = argparse.ArgumentParser(
        description="Route coordinator tasks to pack+model via configurable preferences."
    )
    parser.add_argument("--project", help="Project name")
    parser.add_argument("--difficulty", "-d", choices=["easy", "medium", "hard"], help="Task difficulty")
    parser.add_argument("--kind", "-k", help="Task kind (e.g. read, code, doc)")
    parser.add_argument("--escalate", action="store_true", help="Select escalation candidate")
    parser.add_argument("--task", help="Task description string")
    parser.add_argument("--task-file", help="Path to file containing task description")
    parser.add_argument("--depth", type=int, help="Current dispatch recursion depth")
    parser.add_argument(
        "--quota-exceeded", "--exclude-pack",
        dest="quota_exceeded",
        action="append",
        default=[],
        help="Mark pack(s) as out of quota",
    )
    parser.add_argument("--explain", action="store_true", help="Explain routing decisions on stderr")
    parser.add_argument("--json", action="store_true", help="Output routing decision as JSON")

    args = parser.parse_args()

    conf, _ = resolve_conf(args.project)

    # Recursion depth check
    try:
        max_depth = int(conf.get("ROUTE_MAX_DEPTH", 2))
    except (ValueError, TypeError):
        max_depth = 2

    current_depth = args.depth if args.depth is not None else int(os.environ.get("FLEET_DISPATCH_DEPTH", 0))
    if current_depth >= max_depth:
        sys.stderr.write(f"error: max dispatch depth ({max_depth}) reached (current={current_depth})\n")
        sys.exit(2)

    # Determine candidate preference list
    difficulty = args.difficulty
    kind = args.kind

    if args.escalate:
        list_str = conf.get("ROUTE_ESCALATE", DEFAULT_ROUTE_CONF["ROUTE_ESCALATE"])
        route_reason = "escalate"
    elif kind and conf.get(f"ROUTE_KIND_{kind.upper()}"):
        list_str = conf.get(f"ROUTE_KIND_{kind.upper()}")
        route_reason = f"kind:{kind}"
    else:
        diff = (difficulty or "medium").lower()
        if diff == "easy":
            list_str = conf.get("ROUTE_EASY", DEFAULT_ROUTE_CONF["ROUTE_EASY"])
        elif diff == "hard":
            list_str = conf.get("ROUTE_HARD", DEFAULT_ROUTE_CONF["ROUTE_HARD"])
        else:
            diff = "medium"
            list_str = conf.get("ROUTE_MEDIUM", DEFAULT_ROUTE_CONF["ROUTE_MEDIUM"])
        route_reason = f"difficulty:{diff}"

    candidates = parse_candidates(list_str)

    # Enabled agents
    enabled_agents = set(conf.get("AGENTS", "claude").split())
    claude_policy = conf.get("ROUTE_CLAUDE", "escalate-only").strip().lower()

    # Quota exceeded packs
    manual_exceeded = set()
    for q in args.quota_exceeded:
        for item in re.split(r"[,\s]+", q):
            if item.strip():
                manual_exceeded.add(item.strip())
    for item in re.split(r"[,\s]+", conf.get("ROUTE_QUOTA_EXCEEDED", "")):
        if item.strip():
            manual_exceeded.add(item.strip())

    has_hub = bool(conf.get("HUB"))
    userns_ok = check_userns_ok() if has_hub else True

    selected = None
    for pack, model in candidates:
        if pack not in enabled_agents:
            if args.explain:
                sys.stderr.write(f"skip {pack}: not enabled in AGENTS ({', '.join(sorted(enabled_agents))})\n")
            continue

        if pack == "claude":
            if claude_policy == "never":
                if args.explain:
                    sys.stderr.write("skip claude: ROUTE_CLAUDE=never\n")
                continue
            if claude_policy == "escalate-only" and not args.escalate:
                if args.explain:
                    sys.stderr.write("skip claude: ROUTE_CLAUDE=escalate-only and not escalating\n")
                continue

        if has_hub and pack in ("antigravity", "copilot") and not userns_ok:
            if args.explain:
                sys.stderr.write(f"skip {pack}: userns mount namespace unavailable for hub project\n")
            continue

        if is_pack_quota_exceeded(pack, conf, manual_exceeded):
            if args.explain:
                sys.stderr.write(f"skip {pack}: quota exceeded, falling through\n")
            continue

        selected = (pack, model)
        break

    if selected:
        pack, model = selected
        target = f"{pack}:{model}" if model else pack
        if args.json:
            print(json.dumps({
                "pack": pack,
                "model": model,
                "target": target,
                "route": route_reason,
                "escalate": bool(args.escalate),
                "depth": current_depth,
            }))
        else:
            print(target)
        sys.exit(0)
    else:
        sys.stderr.write(f"error: no eligible worker pack found for route ({route_reason})\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
