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
import json
import os
import re
import shlex
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from fleet_common import assert_not_legacy, parse_env  # noqa: E402

DEFAULT_ROUTE_CONF = {
    "ROUTE_EASY": "antigravity cursor copilot",
    "ROUTE_MEDIUM": "antigravity cursor copilot",
    "ROUTE_HARD": "antigravity cursor copilot claude:sonnet",
    "ROUTE_ESCALATE": "claude:sonnet claude:opus",
    "ROUTE_CLAUDE": "escalate-only",
    "ROUTE_MAX_DEPTH": "2",
    "ROUTE_QUOTA_TTL_SEC": "21600",
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


def pack_requires_userns(pack, packs_dir):
    """True iff pack requires userns mount namespace for hub isolation."""
    pack_sh = os.path.join(packs_dir, pack, "pack.sh")
    if not os.path.isfile(pack_sh):
        return False
    try:
        with open(pack_sh, errors="ignore") as f:
            c = f.read()
            return "pack_requires_userns" in c or "hub-mount-ns.sh" in c
    except OSError:
        return False


def parse_expiry(raw):
    """Parse integer epoch or ISO timestamp string into epoch float."""
    raw = raw.strip()
    if not raw:
        return None
    try:
        return float(raw)
    except ValueError:
        pass
    try:
        import datetime
        if len(raw) == 10 and raw.count("-") == 2:
            raw += "T23:59:59Z"
        dt = datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
        return dt.timestamp()
    except Exception:
        return None


def get_pack_quota_expiry(pack, root):
    """Return active quota expiration epoch for pack from ledger, or None."""
    ledger = os.path.join(root, "quota", pack)
    if not os.path.isfile(ledger):
        return None
    try:
        with open(ledger) as f:
            content = f.read().strip()
        if not content:
            mtime = os.path.getmtime(ledger)
            return mtime + 21600
        return parse_expiry(content)
    except Exception:
        return None


def is_pack_quota_active(pack, root, conf, manual_exceeded, now=None):
    """Check if a pack is out of quota via ledger or config."""
    if pack in manual_exceeded:
        return True, "manual/cli"
    pack_upper = pack.upper().replace("-", "_")
    if conf.get(f"FLEET_QUOTA_EXCEEDED_{pack_upper}") == "1":
        return True, f"FLEET_QUOTA_EXCEEDED_{pack_upper}=1"
    if conf.get(f"FLEET_QUOTA_{pack_upper}") == "0":
        return True, f"FLEET_QUOTA_{pack_upper}=0"

    if now is None:
        now = time.time()
    exp = get_pack_quota_expiry(pack, root)
    if exp is not None:
        if exp > now:
            iso_str = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(exp))
            return True, f"ledger active until {iso_str}"
        else:
            try:
                os.remove(os.path.join(root, "quota", pack))
            except OSError:
                pass
    return False, None


def record_quota_exceeded(pack_arg, root, conf):
    """Write pack quota expiry to $root/quota/<pack>."""
    if ":" in pack_arg:
        pack, val = pack_arg.split(":", 1)
        exp = parse_expiry(val)
        if exp is None:
            try:
                ttl = int(val)
                exp = int(time.time() + ttl)
            except ValueError:
                exp = int(time.time() + int(conf.get("ROUTE_QUOTA_TTL_SEC", 21600)))
    else:
        pack = pack_arg
        ttl = int(conf.get("ROUTE_QUOTA_TTL_SEC", 21600))
        exp = int(time.time() + ttl)

    qdir = os.path.join(root, "quota")
    os.makedirs(qdir, exist_ok=True)
    ledger = os.path.join(qdir, pack)
    with open(ledger, "w") as f:
        f.write(f"{int(exp)}\n")
    return pack, exp


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

    proj_name = proj or os.environ.get("FLEET_PROJECT") or ""
    if not proj_name and proj_file:
        base = os.path.basename(proj_file)
        if base.endswith(".env"):
            proj_name = base[:-4]

    return conf, root, proj_name


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


def run_route_scorer(scorer_cmd, task_text, explain=False):
    """Run an external ROUTE_SCORER hook command with the task prompt.

    Returns a dict with optional keys: 'difficulty', 'kind', 'candidate'.
    Falls back gracefully on non-zero exit or error.
    """
    if not scorer_cmd:
        return {}
    try:
        cmd = f"{scorer_cmd} {shlex.quote(task_text)}"
        p = subprocess.run(
            cmd,
            input=task_text,
            text=True,
            capture_output=True,
            shell=True,
            timeout=15,
        )
        if p.returncode != 0:
            if explain:
                sys.stderr.write(f"scorer: ROUTE_SCORER exited with rc={p.returncode}: {p.stderr.strip()}\n")
            return {}
        raw = p.stdout.strip()
        if explain:
            sys.stderr.write(f"scorer: ROUTE_SCORER output: '{raw}'\n")
        return parse_scorer_output(raw)
    except Exception as exc:
        if explain:
            sys.stderr.write(f"scorer: failed to execute ROUTE_SCORER: {exc}\n")
        return {}


def parse_scorer_output(raw):
    """Parse scorer output into difficulty, kind, or candidate."""
    result = {}
    lines = [line.strip() for line in raw.splitlines() if line.strip()]
    if not lines:
        return result

    for line in lines:
        m_kind = re.search(r"\bkind\s*[:=]\s*([a-zA-Z0-9_-]+)", line, re.IGNORECASE)
        if m_kind:
            result["kind"] = m_kind.group(1).lower()

        m_diff = re.search(r"\b(?:difficulty\s*[:=]\s*)?(easy|medium|hard)\b", line, re.IGNORECASE)
        if m_diff and not result.get("difficulty"):
            result["difficulty"] = m_diff.group(1).lower()

        m_score = re.search(r"\b(?:score\s*[:=]\s*)?([0-9]+(?:\.[0-9]+)?)\b", line, re.IGNORECASE)
        if m_score and not result.get("difficulty"):
            try:
                val = float(m_score.group(1))
                if val <= 1.0:
                    result["difficulty"] = "easy" if val < 0.35 else ("medium" if val < 0.70 else "hard")
                else:
                    result["difficulty"] = "easy" if val < 35 else ("medium" if val < 70 else "hard")
            except ValueError:
                pass

        m_cand = re.search(r"\b(?:candidate\s*[:=]\s*)?([a-zA-Z0-9_-]+:[a-zA-Z0-9_.-]+)\b", line, re.IGNORECASE)
        if m_cand:
            result["candidate"] = m_cand.group(1)

    return result


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
        "--quota-exceeded",
        dest="quota_exceeded",
        action="append",
        default=[],
        help="Mark pack(s) as out of quota",
    )
    parser.add_argument(
        "--exclude", "--exclude-pack",
        dest="exclude",
        action="append",
        default=[],
        help="Exclude pack(s) from candidate selection",
    )
    parser.add_argument("--explain", action="store_true", help="Explain routing decisions on stderr")
    parser.add_argument("--json", action="store_true", help="Output routing decision as JSON")

    args = parser.parse_args()

    conf, root, proj_name = resolve_conf(args.project)

    # Recursion depth check
    try:
        max_depth = int(conf.get("ROUTE_MAX_DEPTH", 2))
    except (ValueError, TypeError):
        max_depth = 2

    current_depth = args.depth if args.depth is not None else int(os.environ.get("FLEET_DISPATCH_DEPTH", 0))
    if current_depth >= max_depth:
        sys.stderr.write(f"error: max dispatch depth ({max_depth}) reached (current={current_depth})\n")
        sys.exit(2)

    # Quota exceeded packs handling
    manual_exceeded = set()
    for q in args.quota_exceeded:
        for item in re.split(r"[,\s]+", q):
            if item.strip():
                p, exp = record_quota_exceeded(item.strip(), root, conf)
                manual_exceeded.add(p)
    for item in re.split(r"[,\s]+", conf.get("ROUTE_QUOTA_EXCEEDED", "")):
        if item.strip():
            manual_exceeded.add(item.strip())

    # Excluded packs (without writing to quota ledger)
    excluded_packs = set()
    for ex in args.exclude:
        for item in re.split(r"[,\s]+", ex):
            if item.strip():
                excluded_packs.add(item.strip())

    # Standalone --quota-exceeded invocation: mark ledger and exit
    if args.quota_exceeded and not (
        args.difficulty or args.kind or args.escalate or args.task or args.task_file
    ):
        for p in manual_exceeded:
            exp = get_pack_quota_expiry(p, root)
            exp_str = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(exp)) if exp else "active"
            print(f"[fleet] marked quota exceeded for pack '{p}' until {exp_str} ({os.path.join(root, 'quota', p)})")
        sys.exit(0)

    # Resolve task text if provided
    task_text = args.task or ""
    if not task_text and args.task_file and os.path.isfile(args.task_file):
        try:
            with open(args.task_file) as f:
                task_text = f.read()
        except OSError:
            task_text = ""

    # Determine candidate preference list
    difficulty = args.difficulty
    kind = args.kind

    # If difficulty is not set, query ROUTE_SCORER hook if configured
    scorer_cmd = conf.get("ROUTE_SCORER", "").strip()
    if not difficulty and scorer_cmd and (task_text or not args.task_file):
        scorer_res = run_route_scorer(scorer_cmd, task_text, explain=args.explain)
        if scorer_res.get("difficulty"):
            difficulty = scorer_res["difficulty"]
            if args.explain:
                sys.stderr.write(f"scorer: difficulty resolved to {difficulty}\n")
        if not kind and scorer_res.get("kind"):
            kind = scorer_res["kind"]
            if args.explain:
                sys.stderr.write(f"scorer: kind resolved to {kind}\n")

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

    packs_dir = os.environ.get("FLEET_PACKS_DIR") or os.path.join(
        os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "packs"
    )
    has_hub = bool(conf.get("HUB"))
    userns_ok = check_userns_ok() if has_hub else True

    selected = None
    for pack, model in candidates:
        if pack in excluded_packs or (model and f"{pack}:{model}" in excluded_packs):
            if args.explain:
                sys.stderr.write(f"skip {pack}: explicitly excluded\n")
            continue

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

        if has_hub and pack_requires_userns(pack, packs_dir) and not userns_ok:
            if args.explain:
                sys.stderr.write(f"skip {pack}: userns mount namespace unavailable for hub project\n")
            continue

        quota_active, quota_reason = is_pack_quota_active(pack, root, conf, manual_exceeded)
        if quota_active:
            sys.stderr.write(f"skip {pack}: quota exceeded ({quota_reason}), falling through\n")
            if proj_name:
                sdir = os.path.join(root, "dispatch", proj_name)
                if os.path.isdir(sdir):
                    try:
                        events_log = os.path.join(sdir, "events.log")
                        now_str = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                        with open(events_log, "a") as f:
                            f.write(f"{now_str} route-skip-quota pack={pack} reason={quota_reason}\n")
                    except OSError:
                        pass
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
