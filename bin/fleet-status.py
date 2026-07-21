#!/usr/bin/env python3
"""fleet-status.py — the whole fleet tree as JSON (or a readable summary).

Invoked by `fleet status [--all] [--json]`. Reads only data that already
exists: project .env files, the machine registry, git worktrees, the dispatch
state dir (status + provenance meta), and the local tmux session. It is the
stable read contract the phone UI renders; it changes nothing.

Resolution mirrors fleet-config.sh / bin/fleet exactly:
  - machines: MACHINES in the project .env, else "local" (+ "remote" if a legacy
    REMOTE_HOST is set) plus MACHINES_DEFAULT from default.env; each resolved
    from $FLEET_HOME/machines/<name>.env (or the REMOTE_* synth for "remote").
  - a worker's provenance (parent coordinator, mode) comes from <name>.meta.
Remote machines are listed with their config; their sessions are gathered only
with --remote, which runs the container's OWN `fleet status --json` over ssh and
grafts it in (needs the remote engine synced + the project provisioned there).
Without --remote, remote sessions=None (default keeps `status` fast and local).
"""

import json
import os
import shlex
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from fleet_common import assert_not_legacy, barrier_files, parse_env  # noqa: E402

ROOT = os.environ.get("FLEET_HOME") or os.path.expanduser("~/.config/fleet")
assert_not_legacy(ROOT)
PROJECTS_DIR = os.path.join(ROOT, "projects")
MACHINES_DIR = os.path.join(ROOT, "machines")
DISPATCH_DIR = os.path.join(ROOT, "dispatch")
DEFAULT_ENV = os.path.join(ROOT, "default.env")

# Untracked files the packs write into every worktree — derived from each pack's
# pack_barrier_files (fleet_common.barrier_files), so a clean worker is not
# reported as uncommitted and a NEW pack is picked up with no edit here (matches
# bin/fleet's dynamic barrier_ignore_regex).
BARRIER = barrier_files()


def run(args, cwd=None):
    try:
        out = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=15)
        return out.stdout if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def run_out_rc(args, timeout=25):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return r.stdout, r.returncode
    except (OSError, subprocess.SubprocessError):
        return "", 1


def remote_sessions(m):
    """Gather a remote machine's sessions by running the container's OWN
    `fleet status --json` (one ssh round trip) and lifting its local machine's
    sessions. Returns (sessions_or_None, reachable). Degrades gracefully: an
    unreachable host, a missing container, or an engine too old to know `status`
    all yield (None, False) rather than an error. Needs the remote engine synced
    (fleet sync-remote) and the project provisioned there."""
    host, container, proj = m.get("host"), m.get("container"), m.get("project")
    if not host or not container:
        return None, False
    inner = "fleet --project %s status --json" % proj
    remote = "docker exec %s bash -lc %s" % (container, shlex.quote(inner))
    out, rc = run_out_rc(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", host, remote]
    )
    if rc != 0 or not out.strip():
        return None, False
    try:
        data = json.loads(out)
    except ValueError:
        return None, True  # reachable, but output was not the JSON we expect
    for p in data.get("projects", []):
        for rm in p.get("machines", []):
            if rm.get("local") and rm.get("sessions") is not None:
                return rm["sessions"], True
    return None, True


def machine_list(env, defaults):
    if env.get("MACHINES"):
        return env["MACHINES"].split()
    out = ["local"]
    if env.get("REMOTE_HOST"):
        out.append("remote")
    for m in defaults.split():
        if m not in out:
            out.append(m)
    return out


def resolve_machine(name, env, proj):
    local_tmux = env.get("LOCAL_TMUX") or "fleet-" + proj
    if name == "local":
        return {
            "name": name,
            "local": True,
            "host": None,
            "container": None,
            "tmux": local_tmux,
            "engine_dir": None,
            "project": proj,
            "resolved": True,
        }
    f = os.path.join(MACHINES_DIR, name + ".env")
    if os.path.isfile(f):
        m = parse_env(f)
        host = m.get("MACHINE_HOST", "")
        is_local = host == "local"
        return {
            "name": name,
            "local": is_local,
            "host": host or None,
            "container": None if is_local else (m.get("MACHINE_CONTAINER") or "fleet"),
            "tmux": local_tmux if is_local else (m.get("MACHINE_TMUX") or "fleet"),
            "engine_dir": None
            if is_local
            else (m.get("MACHINE_ENGINE_DIR") or "agent-fleet"),
            "project": m.get("MACHINE_PROJECT") or proj,
            "resolved": bool(host),
        }
    if name == "remote" and env.get("REMOTE_HOST"):
        return {
            "name": name,
            "local": False,
            "host": env["REMOTE_HOST"],
            "container": env.get("REMOTE_CONTAINER") or "fleet",
            "tmux": env.get("REMOTE_TMUX") or "fleet",
            "engine_dir": env.get("REMOTE_ENGINE_DIR") or "agent-fleet",
            "project": env.get("REMOTE_PROJECT") or proj,
            "resolved": True,
        }
    return {
        "name": name,
        "local": False,
        "resolved": False,
        "host": None,
        "container": None,
        "tmux": None,
        "engine_dir": None,
        "project": proj,
    }


def worktrees(code_repo, wt_home):
    out = run(["git", "-C", code_repo, "worktree", "list", "--porcelain"])
    trees, cur = [], {}
    for line in out.splitlines() + [""]:
        if line.startswith("worktree "):
            cur = {"path": line[len("worktree ") :]}
        elif line.startswith("HEAD "):
            cur["sha"] = line[len("HEAD ") :][:7]
        elif line.startswith("branch "):
            cur["branch"] = line[len("branch ") :].replace("refs/heads/", "")
        elif line == "detached":
            cur["branch"] = "(detached)"
        elif line == "" and cur:
            trees.append(cur)
            cur = {}
    wt_home = wt_home.rstrip("/")
    return [t for t in trees if t.get("path", "").startswith(wt_home + "/")]


def uncommitted(path):
    out = run(["git", "-C", path, "status", "--porcelain", "-uall"])
    for line in out.splitlines():
        if line.startswith("?? ") and line[3:] in BARRIER:
            continue  # ignore the untracked barrier files the packs wrote
        if line.strip():
            return True
    return False


def commits_ahead(path, base):
    """Commits on this worker's branch above the project base — the deliverable
    signal. A worker that finished (rc=0) with 0 commits and nothing uncommitted
    is "done but empty-handed" (agent failed the task, not the fleet)."""
    if not base:
        return None
    out = run(["git", "-C", path, "rev-list", "--count", base + "..HEAD"])
    out = out.strip()
    return int(out) if out.isdigit() else None


def tmux_windows(session):
    out = run(["tmux", "list-windows", "-t", session, "-F", "#{window_name}"])
    return set(w for w in out.splitlines() if w)


def read_meta(path):
    meta = {}
    try:
        with open(path) as fh:
            for line in fh:
                if "=" in line:
                    k, v = line.rstrip("\n").split("=", 1)
                    meta[k] = v
    except OSError:
        pass
    return meta


def local_sessions(env, proj, tmux):
    code_repo = env.get("CODE_REPO", "")
    wt_home = env.get("WT_HOME", "")
    base = env.get("DEFAULT_BASE", "")
    windows = tmux_windows(tmux) if tmux else set()
    sdir = os.path.join(DISPATCH_DIR, proj)
    statuses, metas = {}, {}
    if os.path.isdir(sdir):
        for fn in os.listdir(sdir):
            if fn.endswith(".status"):
                try:
                    statuses[fn[:-7]] = open(os.path.join(sdir, fn)).read().strip()
                except OSError:
                    pass
            elif fn.endswith(".meta"):
                metas[fn[:-5]] = read_meta(os.path.join(sdir, fn))

    workers = []
    if code_repo and wt_home:
        for t in worktrees(code_repo, wt_home):
            name = t["path"][len(wt_home.rstrip("/")) + 1 :]
            meta = metas.get(name, {})
            mode = meta.get("mode") or (
                "dispatch" if name in statuses else "interactive"
            )
            workers.append(
                {
                    "name": name,
                    "branch": t.get("branch", "?"),
                    "sha": t.get("sha", ""),
                    "uncommitted": uncommitted(t["path"]),
                    "commits_ahead": commits_ahead(t["path"], base),
                    "present": name in windows,
                    "mode": mode,
                    "parent": meta.get("parent") or None,
                    "dispatch_status": statuses.get(name),
                    "created": meta.get("created") or None,
                }
            )

    coordinator = None
    if "hub" in windows or env.get("HUB"):
        coordinator = {
            "window": "hub",
            "present": "hub" in windows,
            "hub": env.get("HUB") or None,
        }
    return {"coordinator": coordinator, "workers": workers}


def project_tree(name, env, defaults, probe_remote=False):
    machines = []
    for mname in machine_list(env, defaults):
        m = resolve_machine(mname, env, name)
        if m.get("local") and m.get("resolved"):
            m["sessions"] = local_sessions(env, name, m.get("tmux"))
        elif m.get("resolved") and probe_remote:
            m["sessions"], m["reachable"] = remote_sessions(m)
        else:
            m["sessions"] = None  # remote: pass --remote to gather over ssh
        machines.append(m)
    return {
        "name": name,
        "code_repo": env.get("CODE_REPO") or None,
        "hub": env.get("HUB") or None,
        "wt_home": env.get("WT_HOME") or None,
        "agents": (env.get("AGENTS") or "claude").split(),
        "default_base": env.get("DEFAULT_BASE") or None,
        "queue": {
            "kind": env.get("QUEUE_KIND") or "none",
            "linear_team": env.get("QUEUE_LINEAR_TEAM") or None,
            "linear_project_id": env.get("QUEUE_LINEAR_PROJECT_ID") or None,
            "linear_project_name": env.get("QUEUE_LINEAR_PROJECT_NAME") or None,
            "github_repo": env.get("QUEUE_GITHUB_REPO") or None,
        },
        "machines": machines,
    }


def render_text(tree):
    lines = []
    for p in tree["projects"]:
        lines.append("● %s  (queue: %s)" % (p["name"], p["queue"]["kind"]))
        for m in p["machines"]:
            where = "local" if m.get("local") else (m.get("host") or "?")
            tag = "" if m.get("resolved") else " [unresolved]"
            lines.append("  ├─ machine %s (%s)%s" % (m["name"], where, tag))
            s = m.get("sessions")
            if s is None:
                if "reachable" in m and not m["reachable"]:
                    lines.append(
                        "  │    sessions: unreachable / no status (sync the engine there)"
                    )
                elif "reachable" in m:
                    lines.append("  │    sessions: none")
                else:
                    lines.append("  │    sessions: not gathered (pass --remote)")
                continue
            c = s["coordinator"]
            if c:
                lines.append(
                    "  │    coordinator: hub %s"
                    % ("[live]" if c["present"] else "[not running]")
                )
            deps = [w for w in s["workers"] if w["parent"]]
            indep = [w for w in s["workers"] if not w["parent"]]
            for group, label in ((deps, "dispatched"), (indep, "independent")):
                for w in group:
                    st = w["dispatch_status"] or ("live" if w["present"] else "idle")
                    ca = w["commits_ahead"]
                    deliver = "" if ca is None else " %dc" % ca
                    dirty = " +uncommitted" if w["uncommitted"] else ""
                    warn = ""
                    if (
                        (w["dispatch_status"] or "").startswith("done rc=0")
                        and ca == 0
                        and not w["uncommitted"]
                    ):
                        warn = "  [empty: finished, no commits]"
                    lines.append(
                        "  │      %-14s %-11s %s (%s)%s%s%s"
                        % (
                            w["name"],
                            "[" + label + "]",
                            w["branch"],
                            st,
                            deliver,
                            dirty,
                            warn,
                        )
                    )
    return "\n".join(lines) if lines else "(no projects)"


def main():
    args = sys.argv[1:]
    as_json = "--json" in args
    all_projects = "--all" in args
    probe_remote = "--remote" in args
    proj_arg = None
    if "--project" in args:
        i = args.index("--project")
        proj_arg = args[i + 1] if i + 1 < len(args) else None

    defaults = parse_env(DEFAULT_ENV).get("MACHINES_DEFAULT", "")

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
            sys.stderr.write(
                "error: no project resolved (run inside a project, "
                "pass --project, or --all)\n"
            )
            sys.exit(2)
        confs.append(conf)

    projects = []
    for conf in confs:
        name = os.path.basename(conf)[:-4]
        projects.append(project_tree(name, parse_env(conf), defaults, probe_remote))
    tree = {"projects": projects}

    if as_json:
        print(json.dumps(tree, indent=2))
    else:
        print(render_text(tree))


if __name__ == "__main__":
    main()
