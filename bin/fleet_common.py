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

# --- .env parsing -----------------------------------------------------------
_ASSIGN = re.compile(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$')
_VAR = re.compile(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)')


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
                ["bash", "-c",
                 '. "$0" >/dev/null 2>&1 && declare -F pack_barrier_files '
                 '>/dev/null && pack_barrier_files', pack],
                capture_output=True, text=True, timeout=10,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        for line in r.stdout.splitlines():
            line = line.strip()
            if line:
                files.add(line)
    return files
