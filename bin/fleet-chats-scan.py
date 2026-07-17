#!/usr/bin/env python3
"""fleet-chats-scan.py — a fleet-wide inventory of recorded agent conversations.

Invoked by `fleet chats --scan [--project P | --all] [--parse] [--history] [--since ISO] [--json]`.
Where
`fleet chats <worker>` gives ONE pointer for a cross-agent reprise, this walks
the whole fleet — every project in $FLEET_HOME/projects, the hub (coordinator)
plus every worktree (workers), every enabled pack — and emits a normalized
inventory of the conversation pointers each pack recorded. That inventory is the
input the conversation-feedback routine (docs/04-routines.md) reads, then feeds
the claude ones through fleet_chat_parse.py.

Two modes. DEFAULT: one latest pointer per LIVE location (hub + current worktrees)
— for a quick "what is recorded where" / reprise. `--history` (the retro's stage-B
input): one entry per transcript FILE over the window, including finished workers
whose worktree was deleted (their ~/.claude history survives del/prune), for packs
that implement pack_chat_history (claude today; others fall back to default). Pair
with `--since ISO` to bound the window.

Local machine only: transcripts are local and private (docs/04 cloud-vs-local).
A remote machine would follow the `fleet status --remote` ssh pattern — not
built here. Reads only data that already exists; changes nothing (a read
contract like fleet-status.py / fleet-context.py).

Pointer semantics vary by pack (see each pack's pack_chat_pointer): claude/cursor/
copilot/gemini return a path (file or dir), opencode returns a shell command, and
antigravity returns a conversation id. Each entry carries is_file so a consumer
knows whether it can open the pointer directly (only claude's is parsed today).
"""
import datetime
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from fleet_common import packs_dir, parse_env  # noqa: E402
from fleet_chat_parse import parse_transcript  # noqa: E402

ROOT = os.environ.get("FLEET_HOME") or os.path.expanduser("~/.config/fleet")
PROJECTS_DIR = os.path.join(ROOT, "projects")
DEFAULT_ENV = os.path.join(ROOT, "default.env")


def run(args, timeout=15):
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return out.stdout if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def worktrees(code_repo, wt_home):
    """Worktrees under WT_HOME, mirroring fleet-status.py: parse `git worktree
    list --porcelain` and keep those rooted under wt_home. Returns [(name, path)]."""
    out = run(["git", "-C", code_repo, "worktree", "list", "--porcelain"])
    paths, cur = [], None
    for line in out.splitlines() + [""]:
        if line.startswith("worktree "):
            cur = line[len("worktree "):]
        elif line == "" and cur:
            paths.append(cur)
            cur = None
    wt = wt_home.rstrip("/")
    return [(p[len(wt) + 1:], p) for p in paths if p.startswith(wt + "/")]


def chat_pointer(pack_sh, directory):
    """The pack's recorded-conversation pointer for <directory>, by sourcing its
    pack.sh and calling pack_chat_pointer — same standalone-source pattern as
    fleet_common.barrier_files and bin/fleet's `fleet chats`. Empty -> None."""
    r = subprocess.run(
        ["bash", "-c",
         '. "$0" >/dev/null 2>&1 && declare -F pack_chat_pointer >/dev/null '
         '&& pack_chat_pointer "$1"', pack_sh, directory],
        capture_output=True, text=True, timeout=20,
    )
    out = r.stdout.strip()
    return out or None


def entry_for(role, worktree, directory, pack, pdir):
    pack_sh = os.path.join(pdir, pack, "pack.sh")
    if not os.path.isfile(pack_sh):
        return None
    try:
        pointer = chat_pointer(pack_sh, directory)
    except (OSError, subprocess.SubprocessError):
        pointer = None
    if not pointer:
        return None
    is_file = os.path.isfile(pointer)
    mtime = None
    if os.path.exists(pointer):
        try:
            mtime = os.path.getmtime(pointer)
        except OSError:
            mtime = None
    return {"role": role, "worktree": worktree, "dir": directory, "pack": pack,
            "pointer": pointer, "is_file": is_file, "mtime": mtime}


def history_entries(pack, pdir, hub, wt_home, since):
    """One entry per recorded transcript FILE for this pack over the project — the
    retro's input (docs/04 stage B), not the default one-latest-pointer-per-live-
    location. Includes finished workers whose worktree was deleted. Returns a list,
    or None if the pack does not implement pack_chat_history (caller then falls back
    to the default per-location enumeration for that pack)."""
    pack_sh = os.path.join(pdir, pack, "pack.sh")
    if not os.path.isfile(pack_sh):
        return None
    since_arg = "" if since is None else ("%d" % int(since))
    try:
        r = subprocess.run(
            ["bash", "-c",
             '. "$0" >/dev/null 2>&1 && { declare -F pack_chat_history >/dev/null '
             '|| exit 3; } && pack_chat_history "$1" "$2" "$3"',
             pack_sh, hub or "", wt_home or "", since_arg],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode == 3:       # pack has no history support
        return None
    ents = []
    for line in r.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 5:
            continue
        role, wt, cwd, path, mt = parts
        try:
            mtime = float(mt)
        except ValueError:
            mtime = None
        ents.append({"role": role, "worktree": (None if wt == "-" else wt),
                     "dir": cwd, "pack": pack, "pointer": path,
                     "is_file": os.path.isfile(path), "mtime": mtime})
    return ents


def default_entries(pack, pdir, hub, code_repo, wt_home):
    """The default enumeration for one pack: a single latest-pointer entry for the
    hub (coordinator) and for each LIVE worktree (worker)."""
    ents = []
    if hub and os.path.isdir(hub):
        e = entry_for("coordinator", None, hub, pack, pdir)
        if e:
            ents.append(e)
    if code_repo and wt_home and os.path.isdir(code_repo):
        for name, path in worktrees(code_repo, wt_home):
            e = entry_for("worker", name, path, pack, pdir)
            if e:
                ents.append(e)
    return ents


def since_epoch(value):
    """Parse an ISO date/datetime (`--since`) into an epoch float, or None if it
    cannot be parsed (the caller then applies no time filter)."""
    if not value:
        return None
    try:
        return datetime.datetime.fromisoformat(value).timestamp()
    except (ValueError, OverflowError, OSError):
        return None


def project_conversations(env, pdir, parse=False, since=None, history=False):
    agents = (env.get("AGENTS") or "claude").split()
    hub = env.get("HUB", "")
    code_repo, wt_home = env.get("CODE_REPO", ""), env.get("WT_HOME", "")
    convs = []
    for pack in agents:
        # History mode (docs/04 stage B): every transcript file for the project,
        # finished workers included. Falls back to the default per-location
        # enumeration for a pack that has no pack_chat_history.
        ents = history_entries(pack, pdir, hub, wt_home, since) if history else None
        if ents is None:
            ents = default_entries(pack, pdir, hub, code_repo, wt_home)
            # Default entries are not time-filtered by the pack, so apply --since
            # here (a token/time lever; entries with no mtime are kept).
            if since is not None:
                ents = [c for c in ents if c["mtime"] is None or c["mtime"] >= since]
        convs.extend(ents)
    # Optional: attach the parsed method signal for each claude transcript we can
    # open. Only claude's JSONL is parsed today (fleet_chat_parse is claude-first);
    # other packs' pointers pass through without a `parsed` key.
    if parse:
        for c in convs:
            if c["pack"] == "claude" and c["is_file"]:
                c["parsed"] = parse_transcript(c["pointer"])
    convs.sort(key=lambda c: (c["mtime"] or 0), reverse=True)
    return {"name": None, "hub": hub or None, "wt_home": wt_home or None,
            "agents": agents, "conversations": convs}


def render_text(tree):
    lines = []
    for p in tree["projects"]:
        n = len(p["conversations"])
        lines.append("● %s  (%d recorded conversation%s)"
                     % (p["name"], n, "" if n == 1 else "s"))
        for c in p["conversations"]:
            who = "coordinator" if c["role"] == "coordinator" else ("worker " + (c["worktree"] or "?"))
            kind = "" if c["is_file"] else "  [not a file: read via the pack]"
            lines.append("  %-11s %-22s %s%s" % (c["pack"], who, c["pointer"], kind))
    return "\n".join(lines) if lines else "(no recorded conversations found)"


def main():
    args = sys.argv[1:]
    as_json = "--json" in args
    all_projects = "--all" in args
    parse = "--parse" in args
    history = "--history" in args
    proj_arg = None
    if "--project" in args:
        i = args.index("--project")
        proj_arg = args[i + 1] if i + 1 < len(args) else None
    since = None
    if "--since" in args:
        i = args.index("--since")
        raw = args[i + 1] if i + 1 < len(args) else None
        since = since_epoch(raw)
        if since is None:
            sys.stderr.write("error: --since expects an ISO date/datetime "
                             "(e.g. 2026-07-01 or 2026-07-01T12:00:00)\n")
            sys.exit(2)

    confs = []
    if all_projects:
        if os.path.isdir(PROJECTS_DIR):
            for fn in sorted(os.listdir(PROJECTS_DIR)):
                if fn.endswith(".env") and fn != "default.env":
                    confs.append(os.path.join(PROJECTS_DIR, fn))
    else:
        conf = None
        if proj_arg:
            conf = os.path.join(PROJECTS_DIR, proj_arg + ".env")
        elif os.environ.get("FLEET_CONF"):
            conf = os.environ["FLEET_CONF"]
        if not conf or not os.path.isfile(conf):
            sys.stderr.write("error: no project resolved (run inside a project, "
                             "pass --project, or --all)\n")
            sys.exit(2)
        confs.append(conf)

    pdir = packs_dir()
    projects = []
    for conf in confs:
        name = os.path.basename(conf)[:-4]
        p = project_conversations(parse_env(conf), pdir, parse=parse, since=since,
                                  history=history)
        p["name"] = name
        projects.append(p)
    tree = {"machine": "local", "projects": projects}

    if as_json:
        print(json.dumps(tree, indent=2))
    else:
        print(render_text(tree))


if __name__ == "__main__":
    main()
