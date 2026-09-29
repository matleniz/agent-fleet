"""fleet_common — shared helpers for the Python fleet tools (fleet-status.py,
fleet-context.py). No external deps; imported as a sibling module (both scripts
run from bin/, which is on sys.path[0]).

Holds what was copy-pasted between the two scripts: the minimal .env parser
(byte-identical duplicate, previously carrying a "keep in sync" comment) and the
barrier-file set, which is now DERIVED from the packs (each pack's
pack_barrier_files) rather than hardcoded — so a new pack's barrier file is
picked up automatically, matching bin/fleet's dynamic barrier_ignore_regex.
"""

import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

# --- .env parsing -----------------------------------------------------------
_ASSIGN = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
_VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")


def _expand(value, scope):
    """Expand ~, $VAR and ${VAR} against scope + the process environment."""
    value = os.path.expanduser(value) if value.startswith("~") else value

    def repl(m):
        name = m.group(1) or m.group(2)
        return scope.get(name, os.environ.get(name, ""))

    return _VAR.sub(repl, value)


def parse_env(path):
    """Minimal parser for the KEY="value" .env files fleet-init writes."""
    scope = {}
    try:
        with open(path) as fh:
            lines = fh.readlines()
    except OSError:
        return scope
    for line in lines:
        line = line.rstrip("\n")
        if not line or line.lstrip().startswith("#"):
            continue
        m = _ASSIGN.match(line)
        if not m:
            continue
        key, raw = m.group(1), m.group(2).strip()
        # strip an inline comment only when the value is unquoted
        if raw[:1] not in ('"', "'") and " #" in raw:
            raw = raw.split(" #", 1)[0].strip()
        if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in ('"', "'"):
            raw = raw[1:-1]
        scope[key] = _expand(raw, scope)
    return scope


# --- legacy isolation guard (transition period) ------------------------------
def assert_not_legacy(root):
    """Refuse to resolve the legacy claude-fleet config (mirror of the bash
    guard in fleet-config.sh: FLEET_ROOT matching */claude-fleet or
    */claude-fleet/*). The new tools must never read the old fleet's real
    projects (see AGENTS.md) — every Python entry point must call this on its
    resolved FLEET_HOME before the value is used for anything."""
    resolved = os.path.realpath(os.path.expanduser(root))
    if "claude-fleet" in resolved.split(os.sep):
        sys.stderr.write(
            f"error: FLEET_HOME resolves to the legacy claude-fleet config ({root}).\n"
            "  agent-fleet must not read the legacy fleet. Unset FLEET_HOME or point\n"
            "  it at ~/.config/fleet; migrate real projects with fleet-migrate.\n"
        )
        raise SystemExit(2)


# --- barrier files (derived from the packs, not hardcoded) ------------------
def packs_dir():
    """The packs directory: $FLEET_PACKS_DIR, else <engine>/packs relative to
    this module (bin/../packs). Mirrors fleet-config.sh's FLEET_PACKS_DIR."""
    env = os.environ.get("FLEET_PACKS_DIR")
    if env:
        return env
    here = os.path.dirname(os.path.realpath(__file__))
    return os.path.join(os.path.dirname(here), "packs")


def barrier_files(pdir=None):
    """The untracked worktree files the packs write (union of every pack's
    pack_barrier_files). Sourced from each packs/<name>/pack.sh the same way
    bin/fleet does, so status ignores them when judging a worktree dirty — and a
    new pack is picked up with no edit here. Returns a set (possibly empty)."""
    pdir = pdir or packs_dir()
    files = set()
    try:
        entries = sorted(os.listdir(pdir))
    except OSError:
        return files
    for entry in entries:
        pack = os.path.join(pdir, entry, "pack.sh")
        if not os.path.isfile(pack):
            continue
        try:
            r = subprocess.run(
                [
                    "bash",
                    "-c",
                    '. "$0" >/dev/null 2>&1 && declare -F pack_barrier_files '
                    ">/dev/null && pack_barrier_files",
                    pack,
                ],
                capture_output=True,
                text=True,
                timeout=10,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        for line in r.stdout.splitlines():
            line = line.strip()
            if line:
                files.add(line)
    return files


# --- worker stall / activity (shared by fleet-status + fleet wait/ls) --------
# Progress signal for a running headless worker: worktree commits / index /
# dirty-file mtimes, anchored at dispatch created/status time. Pane chatter
# alone does NOT reset the clock (a hung CLI retrying a network drop, or an
# agent blocked on a foreground dev server, keeps printing without progressing).
# WORKER_STALL_MINUTES (default 20; 0 = off) is the shared threshold.


def stall_threshold_sec(env=None):
    """Seconds of no worktree progress before a running worker is stalled.

    Reads WORKER_STALL_MINUTES from the project env dict, else the process
    environment, else 20. 0 (or negative) disables detection.
    """
    env = env or {}
    raw = env.get("WORKER_STALL_MINUTES")
    if raw is None or raw == "":
        raw = os.environ.get("WORKER_STALL_MINUTES", "20")
    try:
        minutes = float(raw)
    except (TypeError, ValueError):
        minutes = 20.0
    if minutes <= 0:
        return 0
    return int(minutes * 60)


def _mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return None


def _git_out(args, cwd):
    try:
        env = dict(os.environ)
        env["GIT_OPTIONAL_LOCKS"] = "0"
        r = subprocess.run(
            args, cwd=cwd, capture_output=True, text=True, timeout=10, env=env
        )
        return r.stdout if r.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def parse_created_epoch(created):
    """Parse meta `created` (ISO-8601 UTC, trailing Z) to a unix epoch."""
    if not created:
        return None
    s = created.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(s).timestamp()
    except (TypeError, ValueError):
        return None


def worktree_activity_epoch(path, created_epoch=None, status_mtime=None):
    """Best-effort unix epoch of last worktree *progress* for a worker.

    Cheap signals only (no full-tree walk): dispatch created/status mtime,
    `.git/index` mtime, dirty-path mtimes from `git status --porcelain` (capped),
    and HEAD commit time when it is at/after created (so a shared base tip does
    not look like fresh progress on a brand-new worktree).
    """
    candidates = []
    if created_epoch is not None:
        candidates.append(float(created_epoch))
    if status_mtime is not None:
        candidates.append(float(status_mtime))
    if not path or not os.path.isdir(path):
        return max(candidates) if candidates else None

    git_dir = os.path.join(path, ".git")
    if os.path.isfile(git_dir):
        # linked worktree: .git is a file; index lives under the common git dir
        try:
            with open(git_dir) as fh:
                line = fh.readline().strip()
            if line.startswith("gitdir:"):
                real = line.split(":", 1)[1].strip()
                if not os.path.isabs(real):
                    real = os.path.normpath(os.path.join(path, real))
                idx = _mtime(os.path.join(real, "index"))
                if idx is not None:
                    candidates.append(idx)
        except OSError:
            pass
    else:
        idx = _mtime(os.path.join(path, ".git", "index"))
        if idx is not None:
            candidates.append(idx)

    anchor = created_epoch if created_epoch is not None else status_mtime
    out = _git_out(["git", "log", "-1", "--format=%ct"], path).strip()
    if out.isdigit():
        commit_ts = float(out)
        if anchor is None or commit_ts >= float(anchor) - 60:
            candidates.append(commit_ts)

    porcelain = _git_out(["git", "status", "--porcelain", "-uall"], path)
    barrier = barrier_files()
    n = 0
    for line in porcelain.splitlines():
        if n >= 40:
            break
        if len(line) < 4:
            continue
        rel = line[3:]
        if " -> " in rel:
            rel = rel.split(" -> ", 1)[-1]
        rel = rel.strip().strip('"')
        if line.startswith("?? ") and rel in barrier:
            continue
        mt = _mtime(os.path.join(path, rel))
        if mt is not None:
            candidates.append(mt)
            n += 1
    return max(candidates) if candidates else None


def worker_stall_info(path, dispatch_status, created=None, status_mtime=None, env=None, now=None):
    """Return activity/stall fields for one worker (or None fields when N/A).

    Stall applies only while dispatch_status starts with 'running'.
    """
    threshold = stall_threshold_sec(env)
    created_epoch = parse_created_epoch(created)
    activity = worktree_activity_epoch(path, created_epoch, status_mtime)
    now = time.time() if now is None else float(now)
    age = None if activity is None else max(0, int(now - activity))
    running = bool(dispatch_status) and str(dispatch_status).startswith("running")
    stalled = bool(
        running and threshold > 0 and activity is not None and age is not None and age >= threshold
    )
    return {
        "last_activity": (
            None
            if activity is None
            else datetime.fromtimestamp(activity, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        ),
        "activity_age_sec": age,
        "stall_threshold_sec": threshold,
        "stalled": stalled,
    }


def load_worker_stall_info(
    path, status_file, meta_file=None, env=None, now=None
):
    """Load worker status and metadata, returning worker_stall_info."""
    status = ""
    if status_file and os.path.isfile(status_file):
        try:
            with open(status_file) as fh:
                status = fh.read().strip()
        except OSError:
            pass
    created = None
    if meta_file and os.path.isfile(meta_file):
        meta = parse_env(meta_file)
        created = meta.get("created")
    status_mtime = _mtime(status_file) if status_file else None
    return worker_stall_info(
        path,
        status,
        created=created,
        status_mtime=status_mtime,
        env=env,
        now=now,
    )


def commits_ahead(path, base):
    """Commits on this worker's branch above the project base — the deliverable
    signal. A worker that finished (rc=0) with 0 commits and nothing uncommitted
    is "done but empty-handed" (agent failed the task, not the fleet)."""
    if not base or not path or not os.path.isdir(path):
        return None
    out = _git_out(["git", "rev-list", "--count", f"{base}..HEAD"], path).strip()
    return int(out) if out.isdigit() else None


def get_pr_url(path, sdir=None, name=None):
    """Best-effort retrieval of PR URL for a worker."""
    if not sdir and name:
        fleet_home = os.environ.get("FLEET_HOME") or os.path.expanduser(
            "~/.config/fleet"
        )
        dispatch_dir = os.path.join(fleet_home, "dispatch")
        if os.path.isdir(dispatch_dir):
            import glob

            matches = glob.glob(os.path.join(dispatch_dir, "*", f"{name}.pr"))
            if matches:
                sdir = os.path.dirname(matches[0])
    if sdir and name:
        pr_file = os.path.join(sdir, f"{name}.pr")
        if os.path.isfile(pr_file):
            try:
                with open(pr_file) as fh:
                    url = fh.read().strip()
                if url:
                    return url
            except OSError:
                pass
    if path and os.path.isdir(path):
        try:
            r = subprocess.run(
                ["gh", "pr", "view", "--json", "url", "-q", ".url"],
                cwd=path,
                capture_output=True,
                text=True,
                timeout=5,
            )
            if r.returncode == 0 and r.stdout.strip().startswith("http"):
                return r.stdout.strip()
        except (OSError, subprocess.SubprocessError):
            pass
        out = _git_out(["git", "log", "-1", "--format=%B"], path)
        m = re.search(r"https://github\.com/[^\s]+/pull/\d+", out)
        if m:
            return m.group(0)
    return None


def worker_wait_summary(path, status_file, meta_file=None, base=None):
    """Structured summary for a worker on exit or wait check."""
    status = ""
    if status_file and os.path.isfile(status_file):
        try:
            with open(status_file) as fh:
                status = fh.read().strip()
        except OSError:
            pass
    name = (
        os.path.basename(status_file)[:-7]
        if status_file and status_file.endswith(".status")
        else "worker"
    )
    sdir = os.path.dirname(status_file) if status_file else None
    meta = parse_env(meta_file) if meta_file and os.path.isfile(meta_file) else {}
    created_epoch = parse_created_epoch(meta.get("created"))
    status_mtime = _mtime(status_file) if status_file else None
    now = time.time()
    end_time = (
        status_mtime
        if (status.startswith("done") and status_mtime is not None)
        else now
    )
    duration = (
        max(0, int(end_time - created_epoch))
        if created_epoch is not None
        else None
    )

    ca = commits_ahead(path, base)
    pr = get_pr_url(path, sdir=sdir, name=name)
    return {
        "worker": name,
        "status": status or "unknown",
        "duration_sec": duration,
        "commits": ca if ca is not None else 0,
        "pr": pr or "none",
    }


_SERVER_RE = re.compile(
    r"\b(vite|next\s+dev|webpack-dev-server|webpack\s+serve|uvicorn|gunicorn|flask\s+run|http\.server|npm\s+(?:run\s+)?dev|yarn\s+dev|pnpm\s+(?:run\s+)?dev|cargo\s+watch)\b|--watch\b",
    re.IGNORECASE,
)


def get_process_children(parent_pid, include_self=False):
    """Find all descendant processes of parent_pid (and optionally parent_pid itself)."""
    try:
        parent_pid = int(parent_pid)
    except (TypeError, ValueError):
        return []
    out = _git_out(["ps", "-eo", "pid=,ppid=,args="], cwd=".")
    if not out:
        return []
    tree = {}
    all_cmds = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 2:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
            args = parts[2] if len(parts) > 2 else ""
            tree.setdefault(ppid, []).append((pid, args))
            all_cmds[pid] = args
        except ValueError:
            continue
    descendants = []
    if include_self and parent_pid in all_cmds:
        descendants.append({"pid": parent_pid, "cmd": all_cmds[parent_pid]})
    queue = [parent_pid]
    visited = set()
    while queue:
        curr = queue.pop(0)
        if curr in visited:
            continue
        visited.add(curr)
        for child_pid, child_args in tree.get(curr, []):
            descendants.append({"pid": child_pid, "cmd": child_args})
            queue.append(child_pid)
    return descendants


def detect_blocking_server(parent_pid):
    """Detect if parent_pid or any descendant process is a long-lived blocking server or watch mode."""
    children = get_process_children(parent_pid, include_self=True)
    for c in children:
        cmd = c.get("cmd", "")
        m = _SERVER_RE.search(cmd)
        if m:
            return m.group(0).strip()
    return None


def check_deliverable(path, branch, deliverable_type="pr"):
    """Verify that a worker produced the expected deliverable on exit.

    - "push": checks that the branch exists on remote and matches local HEAD.
    - "pr": checks both that the branch is pushed and that a PR exists and is open.

    Returns (is_satisfied: bool, detail: str)
    """
    if not path or not os.path.isdir(path):
        return False, "no-worktree"

    remotes = _git_out(["git", "remote"], path).strip().splitlines()
    has_remote = bool(remotes)
    if has_remote:
        remote_ref = f"origin/{branch}"
        remote_sha = _git_out(
            ["git", "rev-parse", "--verify", remote_ref], path
        ).strip()
        local_sha = _git_out(["git", "rev-parse", "HEAD"], path).strip()
        if not remote_sha or remote_sha != local_sha:
            return False, "branch-not-pushed"
    else:
        ca = _git_out(["git", "rev-list", "--count", "HEAD"], path).strip()
        if not ca.isdigit() or int(ca) == 0:
            return False, "no-commits"

    if deliverable_type in ("push", "deliverable:push"):
        return True, "pushed"

    pr_url = get_pr_url(path, name=branch)
    if pr_url:
        return True, pr_url

    try:
        r = subprocess.run(
            ["gh", "pr", "view", branch, "--json", "state,url"],
            cwd=path,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if r.returncode == 0:
            import json

            data = json.loads(r.stdout)
            if data.get("state") == "OPEN":
                return True, data.get("url", "")
    except (OSError, subprocess.SubprocessError, ValueError):
        pass

    return False, "pr-missing"


def main():
    if len(sys.argv) < 2:
        return
    cmd = sys.argv[1]
    path = sys.argv[2] if len(sys.argv) > 2 else ""
    status_file = sys.argv[3] if len(sys.argv) > 3 else ""
    meta_file = sys.argv[4] if len(sys.argv) > 4 else None

    if cmd == "check-stall":
        info = load_worker_stall_info(path, status_file, meta_file)
        sys.exit(0 if info["stalled"] else 1)
    elif cmd == "stall-info":
        import json

        info = load_worker_stall_info(path, status_file, meta_file)
        print(json.dumps(info))
        sys.exit(0)
    elif cmd == "check-server":
        pid = path  # arg 2 is pid
        server = detect_blocking_server(pid)
        if server:
            print(server)
            sys.exit(0)
        sys.exit(1)
    elif cmd == "process-tree":
        import json

        pid = path  # arg 2 is pid
        children = get_process_children(pid)
        print(json.dumps(children))
        sys.exit(0)
    elif cmd == "check-deliverable":
        branch = status_file  # arg 3 is branch name
        deliv_type = meta_file or "pr"  # arg 4 is deliverable type
        ok, detail = check_deliverable(path, branch, deliv_type)
        if ok:
            print(detail)
            sys.exit(0)
        print(detail, file=sys.stderr)
        sys.exit(1)
    elif cmd == "wait-summary":
        base = sys.argv[5] if len(sys.argv) > 5 else None
        as_json = "--json" in sys.argv
        info = worker_wait_summary(path, status_file, meta_file, base)
        if as_json:
            import json

            print(json.dumps(info))
        else:
            dur = (
                f"{info['duration_sec']}s"
                if info["duration_sec"] is not None
                else "unknown"
            )
            print(
                f"worker={info['worker']} status=\"{info['status']}\" duration={dur} commits={info['commits']} pr={info['pr']}"
            )
        sys.exit(0)


if __name__ == "__main__":
    main()
