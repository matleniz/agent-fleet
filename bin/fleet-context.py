#!/usr/bin/env python3
"""fleet-context.py — the front-loaded context footprint of a project, per role.

Invoked by `fleet context [--project P] [--role R] [--json] [--budget N]`.
Answers docs/06's "measure before optimizing": what does an agent AUTO-READ into
its context the moment it launches (coordinator in the hub, worker in a worktree),
and roughly how many tokens is that? It reads only files that already exist and
changes nothing — a read contract like fleet-status.py.

What counts as front-loaded (auto-read at launch): the per-user global
instructions (~/.agents/AGENTS.md, wired by `fleet global`), the AGENTS.md/CLAUDE.md
of the hub (coordinator) or code repo (worker), and skill *descriptions* (the
frontmatter the CLI loads to decide triggering — NOT the bodies). Pulled on demand
(NOT counted): the hub INDEX router, skill bodies, docs/, and hub content the agent
navigates to. The resource guard (fleet_guard) and settings.local.json add zero
context — the guard is a runtime bash gate, settings.local.json is harness config.

Token counts are a rough estimate (bytes / 4); use the CLI's own `/cost` for the
real bill. Resolution mirrors fleet-config.sh: --project, else $FLEET_CONF (which
bin/fleet exports before dispatching the subcommand), else error.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from fleet_common import parse_env  # noqa: E402

ROOT = os.environ.get("FLEET_HOME") or os.path.expanduser("~/.config/fleet")
PROJECTS_DIR = os.path.join(ROOT, "projects")
DEFAULT_ENV = os.path.join(ROOT, "default.env")


# --- helpers ----------------------------------------------------------------
def tok(nbytes):
    """Rough token estimate: ~4 bytes/token."""
    return (nbytes + 3) // 4


def home_short(path):
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path.startswith(home) else path


def global_file():
    return os.environ.get("FLEET_GLOBAL_AGENTS") or os.path.expanduser("~/.agents/AGENTS.md")


def file_entry(path, label):
    """A front-loaded file, or None if it does not exist."""
    try:
        nbytes = os.path.getsize(path)
    except OSError:
        return None
    return {"path": home_short(path), "label": label, "bytes": nbytes, "tokens": tok(nbytes)}


def frontmatter(path):
    """Top-level scalar keys of a SKILL.md YAML frontmatter (best-effort)."""
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError:
        return {}
    if not lines or lines[0].strip() != "---":
        return {}
    fm, key, buf = {}, None, []
    for line in lines[1:]:
        if line.strip() == "---":
            break
        m = re.match(r'^([A-Za-z_][\w-]*):\s?(.*)$', line)
        if m:
            if key is not None:
                fm[key] = " ".join(buf).strip()
            key = m.group(1)
            val = m.group(2).strip()
            if val in (">", "|", ">-", "|-", ">+", "|+"):
                val = ""
            elif len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
                val = val[1:-1]
            buf = [val] if val else []
        elif key is not None and line[:1] in (" ", "\t"):
            buf.append(line.strip())
    if key is not None:
        fm[key] = " ".join(buf).strip()
    return fm


def scan_skills(dirs):
    """Deduped skills across dirs. Returns (front_bytes, body_bytes, names).
    front_bytes = name+description (what the CLI loads to trigger); body_bytes =
    full SKILL.md (loaded only on invocation). Deduped by skill NAME (a CLI loads
    a given skill once even if several dirs hold a copy, e.g. ~/.agents/skills and
    ~/.claude/skills); the first dir wins, so a project/hub override counts, not
    the global copy — pass the more specific dirs first."""
    seen, front, body, names = set(), 0, 0, []
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for entry in sorted(os.listdir(d)):
            skill_md = os.path.join(d, entry, "SKILL.md")
            if not os.path.isfile(skill_md):
                continue
            fm = frontmatter(skill_md)
            name = fm.get("name", entry)
            if name in seen:
                continue
            seen.add(name)
            desc = fm.get("description", "")
            front += len((name + " " + desc).encode("utf-8"))
            try:
                body += os.path.getsize(skill_md)
            except OSError:
                pass
            names.append(name)
    return front, body, names


def dispatch_preamble(dest, name, hub):
    """The framing string bin/fleet prepends to a dispatched worker's task.
    Keep in sync with cmd_dispatch_run (bin/fleet)."""
    p = "You are a code WORKER in the git worktree %s (branch %s)." % (dest, name)
    if hub:
        p += (" The docs hub at %s is READ-ONLY: do not edit it; if a hub doc "
              "needs changing, note it for the coordinator (do not write there)." % hub)
    p += " Do the task, run the tests, commit on this branch. Task follows."
    return p


# --- roles ------------------------------------------------------------------
def role_report(label, base_dir, files, skill_dirs):
    """Assemble one role: existing files + a skills-descriptions aggregate."""
    entries = [e for e in files if e is not None]
    front, body, names = scan_skills(skill_dirs)
    if names:
        entries.append({
            "path": "(skill frontmatter)", "label": "skills ×%d (descriptions)" % len(names),
            "bytes": front, "tokens": tok(front), "names": names,
        })
    sub_b = sum(e["bytes"] for e in entries)
    return {
        "role": label, "dir": home_short(base_dir) if base_dir else None,
        "files": entries, "subtotal_bytes": sub_b, "subtotal_tokens": tok(sub_b),
        "skill_body_bytes": body,
    }


def coordinator_report(env):
    hub = env.get("HUB", "")
    if not hub or not os.path.isdir(hub):
        return None
    home = os.path.expanduser("~")
    files = [
        file_entry(global_file(), "global instructions"),
        file_entry(os.path.join(hub, "CLAUDE.md"), "hub bridge"),
        file_entry(os.path.join(hub, "AGENTS.md"), "hub instructions"),
    ]
    skill_dirs = [
        os.path.join(hub, ".agents/skills"), os.path.join(hub, ".claude/skills"),
        os.path.join(home, ".agents/skills"), os.path.join(home, ".claude/skills"),
    ]
    return role_report("coordinator", hub, files, skill_dirs)


def worker_report(env):
    code = env.get("CODE_REPO", "")
    if not code:
        return None
    home = os.path.expanduser("~")
    files = [
        file_entry(global_file(), "global instructions"),
        file_entry(os.path.join(code, "AGENTS.md"), "code instructions"),
        file_entry(os.path.join(code, "CLAUDE.md"), "code bridge"),
    ]
    skill_dirs = [
        os.path.join(code, ".agents/skills"), os.path.join(code, ".claude/skills"),
        os.path.join(home, ".agents/skills"), os.path.join(home, ".claude/skills"),
    ]
    rep = role_report("worker", code, files, skill_dirs)
    # Dispatched (headless) workers also get the fleet preamble prepended.
    wt = env.get("WT_HOME", "")
    dest = os.path.join(wt, "<name>") if wt else "<worktree>"
    pre = dispatch_preamble(dest, "<name>", env.get("HUB", ""))
    pb = len(pre.encode("utf-8"))
    rep["files"].append({"path": "(generated)", "label": "dispatch preamble (headless only)",
                         "bytes": pb, "tokens": tok(pb)})
    rep["subtotal_bytes"] += pb
    rep["subtotal_tokens"] = tok(rep["subtotal_bytes"])
    return rep


def on_demand(env):
    """Notable things pulled on demand — NOT front-loaded, shown for contrast."""
    items = []
    hub = env.get("HUB", "")
    if hub:
        e = file_entry(os.path.join(hub, "INDEX.md"), "hub INDEX (router)")
        if e:
            e["note"] = "read it, open the one file, grep the section"
            items.append(e)
    # Skill bodies (sum) from whichever role is present: coordinator if there's a
    # hub, else the worker. A hub-less (solo/early) project still has skills sitting
    # in its code repo, and the front-loaded vs on-demand contrast is exactly the
    # point of this tool — it must not vanish just because there's no hub.
    rep = coordinator_report(env) or worker_report(env)
    if rep and rep.get("skill_body_bytes"):
        b = rep["skill_body_bytes"]
        items.append({"path": "(skill bodies)", "label": "skill bodies",
                      "bytes": b, "tokens": tok(b), "note": "loaded only on invocation"})
    return items


# --- rendering --------------------------------------------------------------
def render_role(rep):
    out = ["%s (%s)" % (rep["role"].upper(), rep["dir"] or "-")]
    out.append("  %-42s %8s %7s" % ("file", "bytes", "~tok"))
    for e in rep["files"]:
        out.append("  %-42s %8d %7d" % (e["label"][:42], e["bytes"], e["tokens"]))
        if e.get("names"):   # list skill names on a continuation line (untruncated)
            out.append("      %s" % ", ".join(e["names"]))
    out.append("  " + "-" * 59)
    out.append("  %-42s %8d %7d" % ("subtotal", rep["subtotal_bytes"], rep["subtotal_tokens"]))
    return "\n".join(out)


def render_text(report):
    out = ["fleet context — front-loaded per role for project '%s'" % report["project"]]
    out.append("(auto-read at launch; ~tokens ≈ bytes/4, rough — use the CLI's /cost for real)")
    out.append("")
    for role in ("coordinator", "worker"):
        rep = report["roles"].get(role)
        if rep:
            out.append(render_role(rep))
            out.append("")
    if report["on_demand"]:
        out.append("ON DEMAND (not front-loaded — pulled only when needed)")
        for e in report["on_demand"]:
            note = ("  " + e["note"]) if e.get("note") else ""
            out.append("  %-42s %8d b%s" % (e["label"][:42], e["bytes"], note))
        out.append("  docs/ and hub content            navigated on demand, never auto-loaded")
        out.append("")
    for n in report["notes"]:
        out.append("note: " + n)
    return "\n".join(out)


def main():
    args = sys.argv[1:]
    as_json = "--json" in args
    role_filter = None
    if "--role" in args:
        i = args.index("--role")
        role_filter = args[i + 1] if i + 1 < len(args) else None
    budget = None
    if "--budget" in args:
        i = args.index("--budget")
        try:
            budget = int(args[i + 1])
        except (IndexError, ValueError):
            sys.stderr.write("error: --budget needs an integer token count\n")
            sys.exit(2)
    proj_arg = None
    if "--project" in args:
        i = args.index("--project")
        proj_arg = args[i + 1] if i + 1 < len(args) else None

    conf = None
    if proj_arg:
        conf = os.path.join(PROJECTS_DIR, proj_arg + ".env")
    elif os.environ.get("FLEET_CONF"):
        conf = os.environ["FLEET_CONF"]
    if not conf or not os.path.isfile(conf):
        sys.stderr.write("error: no project resolved (run inside a project or pass --project)\n")
        sys.exit(2)

    name = os.path.basename(conf)[:-4]
    env = parse_env(conf)

    roles = {}
    if role_filter in (None, "coordinator"):
        c = coordinator_report(env)
        if c:
            roles["coordinator"] = c
    if role_filter in (None, "worker"):
        w = worker_report(env)
        if w:
            roles["worker"] = w

    report = {
        "project": name,
        "token_estimate": "bytes/4 (rough)",
        "roles": roles,
        "on_demand": on_demand(env),
        "notes": [
            "the resource guard (fleet_guard/MAX_WORKERS) is a runtime bash check — 0 context",
            "settings.local.json is harness config (barrier/hooks), never context",
        ],
    }

    if as_json:
        print(json.dumps(report, indent=2))
    else:
        print(render_text(report))

    if budget is not None:
        over = [(r, rep["subtotal_tokens"]) for r, rep in roles.items()
                if rep["subtotal_tokens"] > budget]
        if over:
            for r, t in over:
                sys.stderr.write("over budget: %s front-load ~%d tok > %d\n" % (r, t, budget))
            sys.exit(2)


if __name__ == "__main__":
    main()
