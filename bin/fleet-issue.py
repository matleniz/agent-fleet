#!/usr/bin/env python3
"""fleet issue — drive the project's GitHub issue queue (QUEUE_KIND=github).

Invoked by `fleet issue ...` (bin/fleet resolves the project and passes its
QUEUE_* keys in the environment). Agents use it instead of hand-rolling
`gh project` GraphQL: one command keeps the board's Status column, the
`status:*` label and the lifecycle comment in sync.

  fleet issue new --type T --priority P [--area A]... [--parent N] [--needs-human]
                  "<title>" <body-file|->
  fleet issue start|review|block|done <n> [--note "..."] [--by NAME]
  fleet issue bootstrap [--create] [--area NAME=DESC]... [--board-title T]
                        [--product P] [--code-repos TEXT] [--overwrite]

Conventions (docs/03-queue.md): every issue has one `type:*`, one `priority:*`,
an `area:*` when it applies, `agent` when an agent filed it. Status lives in two
places kept equal: the board's Status column (Backlog / In progress / In review /
Blocked / Done) and one `status:*` label (none for Backlog / Done). The merge of
a PR whose body says `Closes <repo>#<n>` closes the issue.

Environment (set by bin/fleet from the project .env):
  QUEUE_KIND                 must be "github"
  QUEUE_GITHUB_REPO          owner/name of the (private) issues repo
  QUEUE_GITHUB_PROJECT       board number (GitHub Projects v2); unset = labels only
  QUEUE_GITHUB_PROJECT_OWNER board owner (default: the repo owner)
  QUEUE_NEEDS_LABEL          label for "a human must decide" (default needs:human)
  FLEET_ISSUE_PROJECT / WT_HOME / HUB   used to name the actor ("Started by ...")
No external deps: everything goes through the authenticated `gh` CLI.
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile

# --- the shared label taxonomy (same names in every queue repo) -------------
TYPES = [
    ("bug", "d73a4a", "Something is broken"),
    ("feature", "0e8a16", "New capability"),
    ("improvement", "a2eeef", "Better existing behaviour, refactor, perf"),
    ("epic", "5319e7", "Parent issue grouping sub-issues"),
    ("doc-proposal", "c5def5", "Proposed change to a trusted doc (hub / AGENTS.md / skill)"),
    ("workflow", "bfdadc", "How-we-work item with no single target file"),
    ("chore", "ededed", "Housekeeping (cleanup, config, deps)"),
]
PRIORITIES = [
    ("p1-urgent", "b60205", "Drop everything"),
    ("p2-high", "d93f0b", "Next up"),
    ("p3-medium", "fbca04", "Normal"),
    ("p4-low", "c2e0c6", "Someday"),
]
STATUS_LABELS = [
    ("in-progress", "1d76db", "Someone is on it (named in a comment)"),
    ("in-review", "0052cc", "PR open, waiting for review / merge"),
    ("blocked", "000000", "Waiting on something external; say what in a comment"),
]
AGENT_LABEL = ("agent", "7057ff", "Filed by an agent (worker, coordinator, retro)")

# Board columns, in order: (name, color, description). Status → column.
COLUMNS = [
    ("Backlog", "GRAY", "Open, not started"),
    ("In progress", "BLUE", "Someone is on it"),
    ("In review", "PURPLE", "PR open"),
    ("Blocked", "RED", "Waiting on something; see the comment"),
    ("Done", "GREEN", "Closed"),
]
COLUMN_OF = {"backlog": "Backlog", "start": "In progress", "review": "In review",
             "block": "Blocked", "done": "Done"}
LABEL_OF = {"start": "status:in-progress", "review": "status:in-review",
            "block": "status:blocked"}

TEMPLATES = os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "templates")


class QueueError(Exception):
    pass


def die(msg, code=2):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)


def gh(*args, ok_fail=False, stdin=None):
    """Run gh; return stdout. ok_fail=True returns None on a non-zero exit."""
    try:
        r = subprocess.run(["gh", *args], capture_output=True, text=True, input=stdin, check=False)
    except FileNotFoundError:
        die("the gh CLI is not installed (https://cli.github.com), fleet issue needs it")
    if r.returncode != 0:
        if ok_fail:
            return None
        err = (r.stderr or r.stdout).strip()
        hint = ""
        if "project" in args[:1] or "scope" in err.lower():
            hint = "\n  (board access needs the token's project scope: gh auth refresh -s project)"
        raise QueueError(f"gh {' '.join(args[:3])} ... failed: {err}{hint}")
    return r.stdout


def gh_json(*args):
    out = gh(*args)
    try:
        return json.loads(out)
    except json.JSONDecodeError as e:
        raise QueueError(f"gh {' '.join(args[:3])} returned non-JSON: {out[:200]!r}") from e


# --- config -----------------------------------------------------------------
class Queue:
    def __init__(self, repo_override=None):
        kind = os.environ.get("QUEUE_KIND") or "none"
        self.repo = repo_override or os.environ.get("QUEUE_GITHUB_REPO", "")
        if not repo_override and kind != "github":
            die(f"fleet issue drives a GitHub queue; this project has QUEUE_KIND={kind}"
                " (linear is a legacy backend: use the tracker's own tools, see the skills;"
                " none: no queue, surface findings directly)")
        if "/" not in self.repo:
            die("QUEUE_GITHUB_REPO is not set to owner/name in the project .env")
        self.owner = self.repo.split("/", 1)[0]
        self.board = os.environ.get("QUEUE_GITHUB_PROJECT", "").strip()
        self.board_owner = os.environ.get("QUEUE_GITHUB_PROJECT_OWNER", "").strip() or self.owner
        self.needs_label = os.environ.get("QUEUE_NEEDS_LABEL", "").strip() or "needs:human"
        self._field = None
        self.allow_reset = False

    # board ------------------------------------------------------------------
    def status_field(self):
        if self._field is None:
            proj = gh_json("project", "view", self.board, "--owner", self.board_owner, "--format", "json")
            fields = gh_json("project", "field-list", self.board, "--owner", self.board_owner,
                             "--format", "json")["fields"]
            field = next((f for f in fields if f.get("name") == "Status"), None)
            if not field:
                raise QueueError(f"board #{self.board} has no Status field (run: fleet issue bootstrap)")
            self._field = (proj["id"], field)
        return self._field

    def set_column(self, number, column):
        if not self.board:
            print("warning: QUEUE_GITHUB_PROJECT unset, board not updated (labels only)", file=sys.stderr)
            return
        url = f"https://github.com/{self.repo}/issues/{number}"
        item = gh_json("project", "item-add", self.board, "--owner", self.board_owner,
                       "--url", url, "--format", "json")
        proj_id, field = self.status_field()
        opt = next((o for o in field.get("options", []) if o.get("name") == column), None)
        if not opt:
            names = ", ".join(o.get("name", "?") for o in field.get("options", []))
            raise QueueError(f"board #{self.board} Status has no '{column}' option (has: {names});"
                             " run: fleet issue bootstrap")
        gh("project", "item-edit", "--id", item["id"], "--project-id", proj_id,
           "--field-id", field["id"], "--single-select-option-id", opt["id"])

    # labels -----------------------------------------------------------------
    def set_status_label(self, number, action):
        args = ["issue", "edit", str(number), "-R", self.repo]
        want = LABEL_OF.get(action)
        for lab in LABEL_OF.values():
            if lab != want:
                args += ["--remove-label", lab]
        if want:
            args += ["--add-label", want]
        gh(*args)


# --- actor name ---------------------------------------------------------------
def actor():
    """Who is acting: the worktree name for a worker, 'coordinator' in the hub."""
    try:
        top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True,
                             text=True, check=False).stdout.strip()
    except FileNotFoundError:
        top = ""
    cwd = os.path.realpath(top or os.getcwd())
    proj = os.environ.get("FLEET_ISSUE_PROJECT", "")
    wt_home = os.environ.get("WT_HOME", "")
    hub = os.environ.get("HUB", "")
    if wt_home and os.path.dirname(cwd) == os.path.realpath(wt_home):
        return os.path.basename(cwd)
    if hub and cwd == os.path.realpath(hub):
        return f"coordinator ({proj})" if proj else "coordinator"
    return os.environ.get("USER") or os.path.basename(cwd)


# --- label normalisation ------------------------------------------------------
def norm_type(t):
    t = t.removeprefix("type:")
    names = [n for n, _, _ in TYPES]
    if t not in names:
        die(f"--type must be one of: {', '.join(names)} (got '{t}')")
    return f"type:{t}"


def norm_priority(p):
    p = p.removeprefix("priority:")
    for name, _, _ in PRIORITIES:
        if p in (name, name.split("-")[0]):
            return f"priority:{name}"
    die(f"--priority must be one of: {', '.join(n for n, _, _ in PRIORITIES)} or p1..p4 (got '{p}')")
    return ""  # unreachable


def norm_area(a):
    a = a.removeprefix("area:")
    if not a or any(c.isspace() for c in a):
        die(f"bad --area '{a}'")
    return f"area:{a}"


# --- commands -----------------------------------------------------------------
def cmd_new(q, a):
    labels = [norm_type(a.type), norm_priority(a.priority)] + [norm_area(x) for x in a.area]
    if not a.no_agent:
        labels.append(AGENT_LABEL[0])
    if a.needs_human:
        labels.append(q.needs_label)
    if a.body == "-":
        body = sys.stdin.read()
    else:
        try:
            with open(a.body, encoding="utf-8") as f:
                body = f.read()
        except OSError as e:
            die(f"cannot read body file: {e}")
    if not body.strip():
        die("empty issue body (sections: ## Context / ## Problem / Goal / ## Do / ## Acceptance)")
    if a.needs_human and "### Decision needed" not in body:
        print("warning: --needs-human without a '### Decision needed' section in the body"
              " (list the options and a recommendation)", file=sys.stderr)
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as tf:
        tf.write(body)
        body_path = tf.name
    try:
        args = ["issue", "create", "-R", q.repo, "--title", a.title, "--body-file", body_path]
        for lab in labels:
            args += ["--label", lab]
        url = gh(*args).strip().splitlines()[-1]
    finally:
        os.unlink(body_path)
    try:
        number = int(url.rstrip("/").rsplit("/", 1)[-1])
    except ValueError as e:
        raise QueueError(f"could not parse the new issue number from: {url!r}") from e
    q.set_column(number, COLUMN_OF["backlog"])
    if a.parent:
        sub_id = gh("api", f"repos/{q.repo}/issues/{number}", "--jq", ".id").strip()
        gh("api", "-X", "POST", f"repos/{q.repo}/issues/{a.parent}/sub_issues",
           "-F", f"sub_issue_id={sub_id}")
    print(url)
    extra = f", sub-issue of #{a.parent}" if a.parent else ""
    print(f"{q.repo}#{number} -> Backlog [{', '.join(labels)}]{extra}", file=sys.stderr)


def cmd_move(q, a):
    action, number = a.cmd, a.number
    note = (a.note or "").strip()
    if action == "block" and not note:
        die("block needs --note naming the blocker")
    state = None
    if action == "done":
        state = gh("issue", "view", str(number), "-R", q.repo, "--json", "state", "--jq", ".state").strip()
        if state == "OPEN" and not note:
            die(f"#{number} is still open: closing it by hand needs --note saying why"
                " (normally the merge of the PR with 'Closes ...' closes it)")
    q.set_column(number, COLUMN_OF[action])
    q.set_status_label(number, action)
    comment = ""
    if action == "start":
        comment = f"Started by {a.by or actor()}"
        if note:
            comment += f"\n\n{note}"
    elif action == "block":
        comment = f"Blocked: {note}"
    elif note and not (action == "done" and state == "OPEN"):
        comment = note
    if action == "done" and state == "OPEN":
        gh("issue", "close", str(number), "-R", q.repo, "--comment", note)
    elif comment:
        gh("issue", "comment", str(number), "-R", q.repo, "--body", comment)
    print(f"{q.repo}#{number} -> {COLUMN_OF[action]}")


# --- bootstrap ----------------------------------------------------------------
def taxonomy(q, areas):
    out = [(f"type:{n}", c, d) for n, c, d in TYPES]
    out += [(f"priority:{n}", c, d) for n, c, d in PRIORITIES]
    out += [(f"status:{n}", c, d) for n, c, d in STATUS_LABELS]
    out += [(q.needs_label, "e99695", "Decision or approval only a human can give"), AGENT_LABEL]
    palette = ["006b75", "0075ca", "5319e7", "1d76db", "0e8a16", "fbca04"]
    out += [(name, palette[i % len(palette)], desc) for i, (name, desc) in enumerate(areas)]
    return out


def issue_forms(needs_label):
    forms = {
        "bug.yml": ("Bug", "Something is broken", "type:bug", [
            ("what", "What happened", "Observed vs expected; exact error text."),
            ("repro", "Repro", "Minimal steps or command."),
            ("where", "Where", "Repo, file:line, screen or command."),
        ]),
        "feature.yml": ("Feature or improvement", "New capability or better behaviour", "type:feature", [
            ("context", "Context", "Why this is needed; links."),
            ("goal", "Goal", "What should be possible afterwards."),
            ("acceptance", "Acceptance", "How we check it is done."),
        ]),
        "doc-proposal.yml": ("Doc proposal", "Proposed change to a trusted doc", "type:doc-proposal", [
            ("target", "Target", "Doc file and section."),
            ("evidence", "Evidence", "Code file:line that proves the doc is wrong or missing."),
            ("change", "Proposed change", "The new text, or a precise description."),
        ]),
        "epic.yml": ("Epic", "Parent issue grouping sub-issues", "type:epic", [
            ("goal", "Goal", "Outcome of the whole epic."),
            ("plan", "Plan", "Waves / sub-issues and their order."),
        ]),
    }
    out = {}
    for fname, (name, about, label, fields) in forms.items():
        lines = [f"name: {name}", f"description: {about}", f'labels: ["{label}"]', "body:"]
        for fid, title, hint in fields:
            lines += ["  - type: textarea", f"    id: {fid}", "    attributes:",
                      f"      label: {title}", f"      description: {hint}",
                      "    validations:", "      required: true"]
        out[f".github/ISSUE_TEMPLATE/{fname}"] = "\n".join(lines) + "\n"
    out[".github/ISSUE_TEMPLATE/config.yml"] = "blank_issues_enabled: true\n"
    return out


def render_readme(q, product, code_repos, areas):
    with open(os.path.join(TEMPLATES, "queue-README.md"), encoding="utf-8") as f:
        tpl = f.read()
    rows = "".join(f"| `{n}` | {d} |\n" for n, d in areas)
    return (tpl.replace("__REPO__", q.repo.split("/", 1)[1]).replace("__SLUG__", q.repo)
            .replace("__PRODUCT__", product).replace("__CODE_REPOS__", code_repos)
            .replace("__NEEDS__", q.needs_label).replace("__AREA_ROWS__", rows))


def put_file(repo, path, content, overwrite):
    """Create (or, with overwrite, update) one file through the contents API."""
    cur = gh("api", f"repos/{repo}/contents/{path}", ok_fail=True)
    sha = None
    if cur:
        if not overwrite:
            return "kept"
        sha = json.loads(cur).get("sha")
    payload = {"message": f"queue: {path}", "content": base64.b64encode(content.encode()).decode()}
    if sha:
        payload["sha"] = sha
    gh("api", "-X", "PUT", f"repos/{repo}/contents/{path}", "--input", "-", stdin=json.dumps(payload))
    return "updated" if sha else "created"


def ensure_board(q, title):
    projects = gh_json("project", "list", "--owner", q.board_owner, "--format", "json",
                       "--limit", "200").get("projects", [])
    proj = None
    if q.board:
        proj = next((p for p in projects if str(p.get("number")) == q.board), None)
        if not proj:
            raise QueueError(f"QUEUE_GITHUB_PROJECT={q.board}: no such board for {q.board_owner}")
    else:
        proj = next((p for p in projects if p.get("title") == title), None)
    if not proj:
        proj = gh_json("project", "create", "--owner", q.board_owner, "--title", title, "--format", "json")
        print(f"board: created #{proj['number']} '{title}'")
    number = str(proj["number"])
    gh("project", "link", number, "--owner", q.board_owner, "--repo", q.repo, ok_fail=True)
    fields = gh_json("project", "field-list", number, "--owner", q.board_owner, "--format", "json")["fields"]
    status = next((f for f in fields if f.get("name") == "Status"), None)
    if not status:
        raise QueueError(f"board #{number} has no built-in Status field")
    have = [o.get("name") for o in status.get("options", [])]
    want = [n for n, _, _ in COLUMNS]
    if have != want:
        if any(n not in want for n in have) and not q.allow_reset:
            raise QueueError(f"board #{number} Status options are {have}; rewriting them to {want} would"
                             " reset the column of existing items. Re-run with --reset-columns to accept.")
        opts = ", ".join(f'{{name: "{n}", color: {c}, description: "{d}"}}' for n, c, d in COLUMNS)
        query = ("mutation($id: ID!) { updateProjectV2Field(input: {fieldId: $id, "
                 f"singleSelectOptions: [{opts}]}}) {{ projectV2Field {{ ... on ProjectV2SingleSelectField"
                 " { name } } } }")
        gh("api", "graphql", "-f", f"query={query}", "-f", f"id={status['id']}")
        print(f"board: Status columns set to {', '.join(want)}")
    return number


def cmd_bootstrap(q, a):
    areas = []
    for spec in a.area:
        name, _, desc = spec.partition("=")
        areas.append((norm_area(name.strip()), desc.strip() or name.strip()))
    q.allow_reset = a.reset_columns
    if gh("repo", "view", q.repo, "--json", "name", ok_fail=True) is None:
        if not a.create:
            die(f"{q.repo} does not exist (or is not visible): pass --create to make it a PRIVATE repo")
        gh("repo", "create", q.repo, "--private", "--description",
           f"Issue queue for {a.product or q.repo}")
        print(f"repo: created {q.repo} (private)")
    for name, color, desc in taxonomy(q, areas):
        gh("label", "create", name, "-R", q.repo, "--color", color, "--description", desc, "--force")
    print(f"labels: {len(taxonomy(q, areas))} ensured on {q.repo}")
    product = a.product or q.repo.split("/", 1)[1].removesuffix("-issues")
    code_repos = a.code_repos or f"{q.owner}/{product}"
    files = {"README.md": render_readme(q, product, code_repos, areas)}
    files.update(issue_forms(q.needs_label))
    for path, content in files.items():
        print(f"{path}: {put_file(q.repo, path, content, a.overwrite)}")
    number = ensure_board(q, a.board_title or product)
    print("\nproject .env (fleet issue reads these):")
    print('QUEUE_KIND="github"')
    print(f'QUEUE_GITHUB_REPO="{q.repo}"')
    print(f'QUEUE_GITHUB_PROJECT="{number}"')
    if q.board_owner != q.owner:
        print(f'QUEUE_GITHUB_PROJECT_OWNER="{q.board_owner}"')
    if q.needs_label != "needs:human":
        print(f'QUEUE_NEEDS_LABEL="{q.needs_label}"')


def main(argv):
    p = argparse.ArgumentParser(prog="fleet issue", description=__doc__.split("\n\n")[0])
    sp = p.add_subparsers(dest="cmd", required=True)
    n = sp.add_parser("new", help="file an issue (labels + agent, board Backlog, optional parent)")
    n.add_argument("--type", required=True)
    n.add_argument("--priority", required=True)
    n.add_argument("--area", action="append", default=[])
    n.add_argument("--parent", type=int)
    n.add_argument("--needs-human", action="store_true",
                   help="add QUEUE_NEEDS_LABEL (body needs a '### Decision needed' section)")
    n.add_argument("--no-agent", action="store_true", help="filed by a human: no `agent` label")
    n.add_argument("title")
    n.add_argument("body", help="body file, or - for stdin")
    for action, what in (("start", "In progress + status:in-progress + 'Started by <name>'"),
                         ("review", "In review + status:in-review (PR open)"),
                         ("block", "Blocked + status:blocked + the blocker (--note required)"),
                         ("done", "Done, status labels cleared; closes an open issue (--note required)")):
        m = sp.add_parser(action, help=what)
        m.add_argument("number", type=int)
        m.add_argument("--note", default="")
        m.add_argument("--by", default="", help="actor name for start (default: worktree name)")
    b = sp.add_parser("bootstrap", help="labels + board (5 Status columns) + README/forms on the queue repo")
    b.add_argument("--create", action="store_true", help="create the repo (private) if missing")
    b.add_argument("--repo", default="", help="owner/name (default: QUEUE_GITHUB_REPO)")
    b.add_argument("--area", action="append", default=[], help="NAME=DESC, repeatable (area: prefix optional)")
    b.add_argument("--board-title", default="")
    b.add_argument("--product", default="")
    b.add_argument("--code-repos", default="", help="README text naming the code repo(s)")
    b.add_argument("--overwrite", action="store_true", help="rewrite README/forms that already exist")
    b.add_argument("--reset-columns", action="store_true",
                   help="accept rewriting a board's non-standard Status options")
    a = p.parse_args(argv)
    q = Queue(repo_override=getattr(a, "repo", "") or None)
    try:
        if a.cmd == "new":
            cmd_new(q, a)
        elif a.cmd == "bootstrap":
            cmd_bootstrap(q, a)
        else:
            cmd_move(q, a)
    except QueueError as e:
        die(str(e), 1)


if __name__ == "__main__":
    main(sys.argv[1:])
