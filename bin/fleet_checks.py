#!/usr/bin/env python3
"""fleet_checks — the ONE deterministic-checks + report mechanism behind
`fleet gate` (convention checks) and the dispatch spec's scope allowlist.

Every check returns findings (file, line, message); the runner prints one
`<severity> <check> <file>:<line> <message>` line per finding and exits 1 iff a
*blocking* check has findings. Advisory findings are printed but never change
the exit code. A check is enabled by name, with an optional severity suffix:
`no-tracker-ids`, `scope:blocking` (default severity: advisory). Nothing is
enabled by default. Stdlib only.

CLI (used by bin/fleet):
  fleet_checks.py run --root DIR [--base REV] --checks "a,b:blocking" [--scope GLOBS]
  fleet_checks.py parse-spec FILE        # validated key=value lines
  fleet_checks.py norm-checks "<list>"   # validate + normalise to a comma list
  fleet_checks.py norm-scope "<globs>"   # validate + normalise to a comma list

Tunables (env, all optional): GATE_TRACKER_RE, GATE_CODE_DIRS (default "bin/"),
GATE_TEST_GLOB (default "test/*.sh"), GATE_CI_FILE (default
".github/workflows/ci.yml").
"""

import argparse
import fnmatch
import os
import re
import subprocess
import sys

import fleet_common

CHECK_NAMES = (
    "no-tracker-ids",
    "docs-with-bin",
    "tests-listed-in-ci",
    "paths-exist",
    "scope",
)

# Tracker-id lookalikes that are ordinary technical names.
_NOT_TRACKERS = {
    "UTF", "SHA", "ISO", "RFC", "CVE", "TLS", "AES", "RSA", "MD", "PEP",
    "HTTP", "IPV", "SSH", "GPT", "X", "UTC", "LC",
}
_DEFAULT_TRACKER_RE = r"\b[A-Z][A-Z0-9]{1,9}-[0-9]+\b"
_DOC_EXT = (".md", ".rst", ".txt")


def _git(root, *args):
    try:
        r = subprocess.run(
            ["git", *args], cwd=root, capture_output=True, text=True, timeout=30
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


def tracked_files(root):
    out = _git(root, "ls-files")
    return out.splitlines() if out else []


def changed_files(root, base):
    """Paths changed on this branch vs `base` plus uncommitted/untracked ones.
    None when `base` does not resolve (diff-scoped checks then skip)."""
    if not base or _git(root, "rev-parse", "--verify", "--quiet", base) is None:
        return None
    names = set()
    injected = fleet_common.barrier_files() | fleet_common.SIDECARS
    for args in (
        ("diff", "--name-only", f"{base}...HEAD"),
        ("diff", "--name-only", "HEAD"),
        ("ls-files", "--others", "--exclude-standard"),
    ):
        out = _git(root, *args)
        if out is None and args[0] == "diff" and "..." in args[-1]:
            out = _git(root, "diff", "--name-only", base, "HEAD")
        lines = (out or "").splitlines()
        if args[0] == "ls-files":
            # Fleet-injected untracked files (pack barrier/setup configs, dispatch
            # sidecars) are not worker output. A tracked file the worker modified
            # (or a committed one) still comes from the diffs above.
            lines = [n for n in lines if n not in injected]
        names.update(lines)
    return sorted(n for n in names if n)


def _read_lines(root, rel):
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        return []
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().splitlines()
    except (OSError, UnicodeDecodeError):
        return []  # binary / unreadable: not a text convention target


def _scan_set(root, changed):
    """Files a content check looks at: the branch's changes, else the tree."""
    return changed if changed is not None else tracked_files(root)


# --- glob allowlist (scope) -------------------------------------------------
def glob_to_regex(glob):
    """`**` crosses directories, `*` and `?` do not; a pattern also covers
    everything under a directory it matches (`bin` and `bin/` both allow bin/x)."""
    g = glob[2:] if glob.startswith("./") else glob
    if g.endswith("/"):
        g += "**"
    out, i = "", 0
    while i < len(g):
        if g.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
        elif g.startswith("**", i):
            out += ".*"
            i += 2
        elif g[i] == "*":
            out += "[^/]*"
            i += 1
        elif g[i] == "?":
            out += "[^/]"
            i += 1
        else:
            out += re.escape(g[i])
            i += 1
    return re.compile(f"^(?:{out})(?:/.*)?$")


def split_list(value):
    return [t for t in re.split(r"[\s,]+", value or "") if t]


# --- the checks: (root, changed, base, cfg) -> [(file, line, message)] --------
def check_no_tracker_ids(root, changed, base, cfg):
    rx = re.compile(os.environ.get("GATE_TRACKER_RE") or _DEFAULT_TRACKER_RE)
    found = []
    for rel in _scan_set(root, changed):
        if rel.endswith(_DOC_EXT) or rel.startswith("docs/"):
            continue  # docs may cite the tracker; code and tests must not
        for n, line in enumerate(_read_lines(root, rel), 1):
            for m in rx.finditer(line):
                if m.group(0).rsplit("-", 1)[0] in _NOT_TRACKERS:
                    continue
                found.append((rel, n, f"tracker id '{m.group(0)}' in code/test"))
                break
    return found


def _is_test(path):
    base = os.path.basename(path)
    return (
        path.startswith(("test/", "tests/"))
        or base.startswith("test_")
        or re.search(r"(_test|\.test|\.spec)\.[^.]+$", base) is not None
    )


def check_docs_with_bin(root, changed, base, cfg):
    if changed is None:
        return []
    dirs = split_list(os.environ.get("GATE_CODE_DIRS") or "bin/")
    code = [f for f in changed if any(f.startswith(d) for d in dirs)]
    if not code:
        return []
    found = []
    if not any(f.endswith(_DOC_EXT) or f.startswith(("docs/", "templates/")) for f in changed):
        found.append((code[0], 1, "code changed but no doc changed in the same branch"))
    if not any(_is_test(f) for f in changed):
        found.append((code[0], 1, "code changed but no test changed in the same branch"))
    return found


def check_tests_listed_in_ci(root, changed, base, cfg):
    ci = os.environ.get("GATE_CI_FILE") or ".github/workflows/ci.yml"
    if not os.path.isfile(os.path.join(root, ci)):
        return []
    with open(os.path.join(root, ci), encoding="utf-8") as fh:
        text = fh.read()
    pat = os.environ.get("GATE_TEST_GLOB") or "test/*.sh"
    found = []
    for rel in tracked_files(root):
        if fnmatch.fnmatchcase(rel, pat) and rel not in text:
            found.append((rel, 1, f"not listed in {ci}"))
    return found


_SPAN = re.compile(r"`([^`\n]+)`")


def check_paths_exist(root, changed, base, cfg):
    tops = {t.split("/")[0] for t in tracked_files(root) if "/" in t}
    found = []
    for rel in _scan_set(root, changed):
        if not rel.endswith((".md", ".env", ".example")):
            continue
        for n, line in enumerate(_read_lines(root, rel), 1):
            for span in _SPAN.findall(line):
                for tok in span.split():
                    tok = re.sub(r":\d+(?::\d+)?$", "", tok.strip("\"'(),;."))
                    if "/" not in tok or tok.split("/")[0] not in tops:
                        continue
                    if re.search(r"[*<>${}\[\]|…]|\.\.\.", tok):
                        continue  # glob / placeholder, not a literal path
                    if not os.path.exists(os.path.join(root, tok)):
                        found.append((rel, n, f"referenced path '{tok}' does not exist"))
    return found


def check_scope(root, changed, base, cfg):
    globs = cfg.get("scope") or []
    if not globs or changed is None:
        return []
    rxs = [glob_to_regex(g) for g in globs]
    return [
        (f, 1, f"changed outside the allowed scope ({', '.join(globs)})")
        for f in changed
        if not any(r.match(f) for r in rxs)
    ]


CHECKS = {
    "no-tracker-ids": check_no_tracker_ids,
    "docs-with-bin": check_docs_with_bin,
    "tests-listed-in-ci": check_tests_listed_in_ci,
    "paths-exist": check_paths_exist,
    "scope": check_scope,
}


def parse_checks(value):
    """`a,b:blocking` -> [(name, blocking)]; raises ValueError on a bad token."""
    out = []
    for tok in split_list(value):
        name, _, sev = tok.partition(":")
        if name not in CHECKS:
            raise ValueError(f"unknown check '{name}' (known: {', '.join(CHECK_NAMES)})")
        if sev not in ("", "advisory", "blocking"):
            raise ValueError(f"bad severity '{sev}' for '{name}' (advisory|blocking)")
        out.append((name, sev == "blocking"))
    return out


def run_checks(root, base, checks, scope=None):
    """Run the enabled checks. Returns [(check, blocking, file, line, msg)]."""
    changed = changed_files(root, base)
    cfg = {"scope": scope or []}
    findings = []
    for name, blocking in checks:
        for f, n, msg in CHECKS[name](root, changed, base, cfg):
            findings.append((name, blocking, f, n, msg))
    return findings


def format_finding(f):
    name, blocking, path, line, msg = f
    return f"{'BLOCK' if blocking else 'WARN'} {name} {path}:{line} {msg}"


# --- spec file (dispatch): key=value, '#' comments ---------------------------
SPEC_KEYS = ("deliverable", "scope", "checks")


def parse_spec(path):
    spec = {}
    with open(path, encoding="utf-8") as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            key, sep, val = line.partition("=")
            key, val = key.strip(), val.strip().strip("\"'")
            if not sep or key not in SPEC_KEYS:
                raise ValueError(f"{path}:{n}: unknown or malformed line '{line}' (keys: {', '.join(SPEC_KEYS)})")
            spec[key] = val
    if spec.get("deliverable", "pr") not in ("pr", "push"):
        raise ValueError(f"{path}: deliverable must be pr or push")
    if "scope" in spec:
        spec["scope"] = norm_scope(spec["scope"])
    if "checks" in spec:
        spec["checks"] = norm_checks(spec["checks"])
    return spec


def norm_scope(value):
    toks = split_list(value)
    for t in toks:
        if not re.fullmatch(r"[A-Za-z0-9_./*?@+-]+", t):
            raise ValueError(f"bad scope glob '{t}' (letters, digits, _ . / * ? @ + - only)")
    return ",".join(toks)


def norm_checks(value):
    return ",".join(n + (":blocking" if b else "") for n, b in parse_checks(value))


def main(argv=None):
    ap = argparse.ArgumentParser(prog="fleet_checks")
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--root", default=".")
    r.add_argument("--base", default="")
    r.add_argument("--checks", default="")
    r.add_argument("--scope", default="")
    for name in ("parse-spec", "norm-checks", "norm-scope"):
        sub.add_parser(name).add_argument("value")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "parse-spec":
            for k, v in parse_spec(a.value).items():
                print(f"{k}={v}")
        elif a.cmd == "norm-checks":
            print(norm_checks(a.value))
        elif a.cmd == "norm-scope":
            print(norm_scope(a.value))
        else:
            checks = parse_checks(a.checks)
            if a.scope and not any(n == "scope" for n, _ in checks):
                checks.append(("scope", False))
            findings = run_checks(a.root, a.base, checks, split_list(a.scope))
            for f in findings:
                print(format_finding(f))
            return 1 if any(f[1] for f in findings) else 0
    except (ValueError, OSError) as e:
        print(f"fleet_checks: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
