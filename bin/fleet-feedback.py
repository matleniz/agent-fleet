#!/usr/bin/env python3
"""fleet-feedback.py — the "seen ledger" for the conversation-feedback routine.

Invoked by `fleet feedback <sub>`. The routine (docs/04-routines.md) reads the
fleet's conversations, distills recurring method lessons, and files each as a
queue proposal. Without a ledger it would re-file the same lesson every run; this
records what has already been surfaced so the next run only files what is new.

A lesson is identified by a FINGERPRINT — a short canonical string the routine
chooses (e.g. "worker edits hub instead of proposing" or a target+summary pair).
The ledger keys on a normalized hash of that fingerprint, so trivial wording
differences collapse to the same entry. It tracks which projects a lesson showed
up in and how many runs re-surfaced it (a lesson recurring across projects/runs
is a stronger signal, not noise to file again).

Subcommands:
  seen   <fingerprint>                 exit 0 if already recorded, 1 if new
  record <fingerprint> [--project P] [--note N]   add/update; prints the key
  list   [--project P] [--json]        show the ledger
  prune  --before YYYY-MM-DD           drop entries last seen before a date

Store: $FLEET_HOME/feedback-seen.json (instance state, never in the repo).
Override with --file for tests. Reads/writes only that file; touches nothing else.
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from fleet_common import assert_not_legacy  # noqa: E402

ROOT = os.environ.get("FLEET_HOME") or os.path.expanduser("~/.config/fleet")
assert_not_legacy(ROOT)
DEFAULT_FILE = os.path.join(ROOT, "feedback-seen.json")

_WS = re.compile(r"\s+")


def normalize(fingerprint):
    """Canonical form for hashing: lowercased, whitespace-collapsed, stripped."""
    return _WS.sub(" ", fingerprint.strip().lower())


def key_for(fingerprint):
    return hashlib.sha256(normalize(fingerprint).encode("utf-8")).hexdigest()[:16]


def today():
    return datetime.date.today().isoformat()


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {"version": 1, "entries": {}}
    if not isinstance(data, dict) or "entries" not in data:
        return {"version": 1, "entries": {}}
    return data


def save(path, data):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
    os.replace(tmp, path)


def cmd_seen(args):
    data = load(args.file)
    k = key_for(args.fingerprint)
    print(k)
    return 0 if k in data["entries"] else 1


def cmd_record(args):
    data = load(args.file)
    k = key_for(args.fingerprint)
    e = data["entries"].get(k)
    if e is None:
        e = {
            "fingerprint": args.fingerprint,
            "projects": [],
            "first_seen": today(),
            "last_seen": today(),
            "count": 0,
            "note": "",
        }
        data["entries"][k] = e
    e["last_seen"] = today()
    e["count"] += 1
    if args.project and args.project not in e["projects"]:
        e["projects"].append(args.project)
    if args.note:
        e["note"] = args.note
    save(args.file, data)
    print(k)
    return 0


def cmd_list(args):
    data = load(args.file)
    entries = data["entries"]
    if args.project:
        entries = {
            k: e for k, e in entries.items() if args.project in e.get("projects", [])
        }
    if args.json:
        print(
            json.dumps(
                {"version": data.get("version", 1), "entries": entries},
                indent=2,
                sort_keys=True,
            )
        )
        return 0
    if not entries:
        print("(ledger empty)")
        return 0
    for k, e in sorted(
        entries.items(), key=lambda kv: kv[1].get("last_seen", ""), reverse=True
    ):
        projs = ",".join(e.get("projects", [])) or "-"
        print(
            "%s  x%-3d  last=%s  [%s]  %s"
            % (
                k,
                e.get("count", 0),
                e.get("last_seen", "?"),
                projs,
                e.get("fingerprint", "")[:70],
            )
        )
    return 0


def cmd_prune(args):
    data = load(args.file)
    before = args.before
    kept = {
        k: e for k, e in data["entries"].items() if e.get("last_seen", "") >= before
    }
    dropped = len(data["entries"]) - len(kept)
    data["entries"] = kept
    save(args.file, data)
    print(
        "pruned %d entr%s last seen before %s"
        % (dropped, "y" if dropped == 1 else "ies", before)
    )
    return 0


def main():
    ap = argparse.ArgumentParser(prog="fleet feedback", add_help=True)
    ap.add_argument(
        "--file",
        default=DEFAULT_FILE,
        help="ledger path (default $FLEET_HOME/feedback-seen.json)",
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("seen", help="exit 0 if the fingerprint is already recorded")
    s.add_argument("fingerprint")
    s.set_defaults(func=cmd_seen)

    r = sub.add_parser("record", help="record a fingerprint as surfaced")
    r.add_argument("fingerprint")
    r.add_argument("--project", default=None)
    r.add_argument("--note", default=None)
    r.set_defaults(func=cmd_record)

    ls = sub.add_parser("list", help="show the ledger")
    ls.add_argument("--project", default=None)
    ls.add_argument("--json", action="store_true")
    ls.set_defaults(func=cmd_list)

    p = sub.add_parser("prune", help="drop entries last seen before a date")
    p.add_argument("--before", required=True, help="YYYY-MM-DD")
    p.set_defaults(func=cmd_prune)

    args = ap.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
