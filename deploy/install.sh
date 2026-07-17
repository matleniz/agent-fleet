#!/usr/bin/env bash
# install.sh (exposed as `fleet-vm-setup`) — first-run setup INSIDE the container.
# Idempotent: safe to re-run. Populates the persistent /home/fleet volume with the
# PATH symlinks, one or more projects' fleet config, and their repos. The generic
# tooling is already baked in the image at $FLEET_SRC; this only wires the volume.
# Generic: projects are described entirely by env vars, nothing is hardcoded here.
#
# The volume PERSISTS across a rebuild (`compose up -d --build` recreates the
# container, not the named volume), so repos and config survive. What is NOT
# reproducible on a fresh box / fresh volume is whatever was only added by hand —
# so declare every project here and it comes back on any rebuild.
#
# Two provisioning shapes:
#   Single project (legacy): set CODE_REPO_URL (+ PROJECT_NAME, HUB_REPO_URL, ...).
#   Multiple projects:        set PROJECTS="a b" and, per project, its vars under
#                             an UPPERCASED namespace, e.g. for "beta":
#                               BETA_CODE_REPO_URL=...  (required)
#                               BETA_HUB_REPO_URL=...   BETA_AGENTS="claude"
#                               BETA_QUEUE_KIND=linear  BETA_QUEUE_LINEAR_TEAM=...
#                               BETA_NTFY_TOPIC=...
#                             AGENTS / QUEUE_KIND / NTFY_TOPIC (un-namespaced) act
#                             as defaults for projects that omit their own.
#
# Add one project later WITHOUT touching the others (and make it survive rebuilds):
#   fleet-vm-setup --add-project <name> --repo <url> [--hub <url>] [--agents a,b]
#                  [--queue linear|github|none] [--ntfy topic]
#                  [--linear-team T] [--linear-project-id ID] [--linear-project-name N]
#                  [--github-repo owner/repo]
#   It records a namespaced block under ~/.config/fleet/extra-projects.d/<name>.env
#   (on the volume) and provisions just that project; every full run re-reads it.
#
# Required env (via compose env_file: .env, or `docker exec -e ...`):
#   GH_TOKEN        fine-grained GitHub token (contents:read+write on the repos).
#   CODE_REPO_URL   single-project mode: the code repo clone URL (>=1 commit).
#                   (multi-project mode uses <NS>_CODE_REPO_URL instead.)
# Optional: PROJECT_NAME (default main), HUB_REPO_URL, AGENTS (default claude),
#   QUEUE_KIND (+ its coordinates), NTFY_TOPIC, FLEET_SRC (default /opt/agent-fleet).
set -euo pipefail

FLEET_SRC="${FLEET_SRC:-/opt/agent-fleet}"
EXTRA_DIR="$HOME/.config/fleet/extra-projects.d"   # --add-project blocks (volume)

# Uppercase a project name into its env-var namespace (beta -> BETA, my-app -> MY_APP).
ns_of() { printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_' | tr -cd 'A-Z0-9_'; }
# Read a var by dynamic name, empty if unset (safe under set -u).
val()   { local v="$1"; printf '%s' "${!v-}"; }

wire_path() {
  echo "[fleet-vm-setup] PATH symlinks -> ~/.local/bin"
  mkdir -p "$HOME/.local/bin"
  # Keep in sync with deploy/entrypoint.sh (which re-wires these on every start).
  for t in fleet new-worker fleet-assess fleet-queue fleet-init fleet-migrate; do
    ln -sf "$FLEET_SRC/bin/$t" "$HOME/.local/bin/$t"
  done
}

# GitHub auth: clone private repos + let workers push/PR (gh as git credential
# helper). When GH_TOKEN is in the environment (compose env_file), gh uses it
# directly — `gh auth login --with-token` even refuses to run then — so only the
# git credential-helper wiring is needed.
wire_gh() {
  if [ -n "${GH_TOKEN:-}" ]; then
    echo "[fleet-vm-setup] wiring git credentials to GH_TOKEN (gh credential helper)"
    gh auth setup-git
  else
    echo "[fleet-vm-setup] WARNING: GH_TOKEN unset — private clones/pushes will fail." >&2
  fi
}

clone_if_absent() {  # <url> <dest>
  local url="$1" dest="$2"
  if [ -d "$dest/.git" ]; then
    echo "[fleet-vm-setup] $dest already present — leaving as is."
  else
    echo "[fleet-vm-setup] cloning $url -> $dest"
    git clone "$url" "$dest"
  fi
}

# Not-hub-coupled skills, global: .agents/skills is the cross-CLI standard dir;
# .claude/skills gets per-skill symlinks for Claude Code. Idempotent. Same set as
# the README quickstart / docs/07: the two worker skills plus dispatch-work (the
# coordinator's forward-dispatch playbook — the VM's headless-dispatch use case
# needs it). Hub-coupled skills (doc-nav, process-agent-queue) are seeded per hub
# by fleet-init, not here.
wire_skills() {
  mkdir -p "$HOME/.agents/skills" "$HOME/.claude/skills"
  local s
  for s in propose-doc-change resolve-finding dispatch-work; do
    if [ -d "$FLEET_SRC/templates/skills/$s" ]; then
      rm -rf "$HOME/.agents/skills/$s"
      cp -r "$FLEET_SRC/templates/skills/$s" "$HOME/.agents/skills/"
      ln -sfn "$HOME/.agents/skills/$s" "$HOME/.claude/skills/$s"
    fi
  done
}

# Provision ONE project from its namespaced vars. Un-namespaced AGENTS/QUEUE_KIND/
# NTFY_TOPIC act as defaults. Idempotent: existing repos are left as-is and
# fleet-init --force re-writes the project .env.
provision_project() {
  local p="$1" ns; ns="$(ns_of "$p")"
  local code hub agents queue qteam qpid qpname qghrepo ntfy a
  code="$(val "${ns}_CODE_REPO_URL")"
  hub="$(val "${ns}_HUB_REPO_URL")"
  agents="$(val "${ns}_AGENTS")";    agents="${agents:-${AGENTS:-claude}}"
  queue="$(val "${ns}_QUEUE_KIND")"; queue="${queue:-${QUEUE_KIND:-none}}"
  qteam="$(val "${ns}_QUEUE_LINEAR_TEAM")"
  qpid="$(val "${ns}_QUEUE_LINEAR_PROJECT_ID")"
  qpname="$(val "${ns}_QUEUE_LINEAR_PROJECT_NAME")"
  qghrepo="$(val "${ns}_QUEUE_GITHUB_REPO")"
  ntfy="$(val "${ns}_NTFY_TOPIC")";  ntfy="${ntfy:-${NTFY_TOPIC:-}}"
  [ -n "$code" ] || { echo "error: ${ns}_CODE_REPO_URL unset for project '$p' (set it in deploy/.env)" >&2; exit 2; }
  for a in $agents; do
    [ -f "$FLEET_SRC/packs/$a/pack.sh" ] || {
      echo "error: pack '$a' (project '$p') not baked in this image (rebuild with --build-arg PACKS=\"... $a ...\")" >&2
      exit 2
    }
  done

  echo "[fleet-vm-setup] === project '$p' ==="
  local code_dir; code_dir="$HOME/$(basename "$code" .git)"
  clone_if_absent "$code" "$code_dir"
  local hub_dir=""
  if [ -n "$hub" ]; then hub_dir="$HOME/$(basename "$hub" .git)"; clone_if_absent "$hub" "$hub_dir"; fi
  mkdir -p "$HOME/wt-$p"

  # One writer for the .env schema: fleet-init (--force = idempotent re-run). It
  # auto-detects the workers' base ref from the fresh clone (origin/HEAD).
  echo "[fleet-vm-setup] registering project '$p' (fleet-init --force)"
  "$FLEET_SRC/bin/fleet-init" "$p" \
    --code "$code_dir" \
    ${hub_dir:+--hub "$hub_dir"} \
    --wt "$HOME/wt-$p" \
    --agents "${agents// /,}" \
    --queue "$queue" \
    ${qteam:+--linear-team "$qteam"} \
    ${qpid:+--linear-project-id "$qpid"} \
    ${qpname:+--linear-project-name "$qpname"} \
    ${qghrepo:+--github-repo "$qghrepo"} \
    ${ntfy:+--ntfy "$ntfy"} \
    --force
}

login_hint() {  # <agent-pack> — one-time interactive login line
  local c="${FLEET_CONTAINER:-fleet}"
  case "$1" in
    claude)      echo "    docker exec -it $c claude          # OAuth: open the URL on your laptop, paste the code (also trusts the folder)" ;;
    gemini)      echo "    docker exec -it $c gemini          # or set GEMINI_API_KEY in the container env" ;;
    opencode)    echo "    docker exec -it $c opencode auth login   # (free gateway models need no login)" ;;
    cursor)      echo "    docker exec -it $c agent login     # Cursor: OAuth URL to open on your laptop" ;;
    antigravity) echo "    docker exec -it $c agy             # Google OAuth in the TUI" ;;
    *)           echo "    docker exec -it $c $1              # authenticate per this CLI's docs" ;;
  esac
}

# ----------------------------------------------------------------------------
# --add-project: record + provision ONE project without touching the others.
# ----------------------------------------------------------------------------
if [ "${1:-}" = --add-project ]; then
  shift
  add_name="${1:-}"; shift || true
  { [ -n "$add_name" ] && [ "${add_name#--}" = "$add_name" ]; } || {
    echo "usage: fleet-vm-setup --add-project <name> --repo <url> [--hub <url>] [--agents a,b]" >&2
    echo "                      [--queue linear|github|none] [--ntfy topic] [--linear-team T]" >&2
    echo "                      [--linear-project-id ID] [--linear-project-name N] [--github-repo owner/repo]" >&2
    exit 2
  }
  add_repo="" add_hub="" add_agents="" add_queue="" add_ntfy=""
  add_qteam="" add_qpid="" add_qpname="" add_qghrepo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)                 add_repo="${2:-}"; shift 2 ;;
      --hub)                  add_hub="${2:-}"; shift 2 ;;
      --agents)               add_agents="${2:-}"; shift 2 ;;
      --queue)                add_queue="${2:-}"; shift 2 ;;
      --ntfy)                 add_ntfy="${2:-}"; shift 2 ;;
      --linear-team)          add_qteam="${2:-}"; shift 2 ;;
      --linear-project-id)    add_qpid="${2:-}"; shift 2 ;;
      --linear-project-name)  add_qpname="${2:-}"; shift 2 ;;
      --github-repo)          add_qghrepo="${2:-}"; shift 2 ;;
      *) echo "error: unknown --add-project option '$1'" >&2; exit 2 ;;
    esac
  done
  [ -n "$add_repo" ] || { echo "error: --repo <url> is required" >&2; exit 2; }

  mkdir -p "$EXTRA_DIR"
  ns="$(ns_of "$add_name")"
  {
    echo "# project '$add_name' — recorded by fleet-vm-setup --add-project (re-read on every full run)"
    echo "${ns}_CODE_REPO_URL=\"$add_repo\""
    [ -n "$add_hub" ]     && echo "${ns}_HUB_REPO_URL=\"$add_hub\""
    [ -n "$add_agents" ]  && echo "${ns}_AGENTS=\"${add_agents//,/ }\""
    [ -n "$add_queue" ]   && echo "${ns}_QUEUE_KIND=\"$add_queue\""
    [ -n "$add_ntfy" ]    && echo "${ns}_NTFY_TOPIC=\"$add_ntfy\""
    [ -n "$add_qteam" ]   && echo "${ns}_QUEUE_LINEAR_TEAM=\"$add_qteam\""
    [ -n "$add_qpid" ]    && echo "${ns}_QUEUE_LINEAR_PROJECT_ID=\"$add_qpid\""
    [ -n "$add_qpname" ]  && echo "${ns}_QUEUE_LINEAR_PROJECT_NAME=\"$add_qpname\""
    [ -n "$add_qghrepo" ] && echo "${ns}_QUEUE_GITHUB_REPO=\"$add_qghrepo\""
  } > "$EXTRA_DIR/$add_name.env"
  echo "[fleet-vm-setup] recorded '$add_name' -> $EXTRA_DIR/$add_name.env"

  . "$EXTRA_DIR/$add_name.env"
  wire_path
  wire_gh
  provision_project "$add_name"
  wire_skills
  echo "[fleet-vm-setup] project '$add_name' added (others untouched). One-time login if new:"
  for a in ${add_agents//,/ }; do login_hint "$a"; done
  exit 0
fi

# ----------------------------------------------------------------------------
# Full provisioning: legacy single project OR a PROJECTS list, plus anything
# recorded via --add-project. Repeatable and non-destructive.
# ----------------------------------------------------------------------------
wire_path
wire_gh

ALL_PROJECTS="${PROJECTS:-}"
if [ -d "$EXTRA_DIR" ]; then
  for f in "$EXTRA_DIR"/*.env; do
    [ -e "$f" ] || continue
    . "$f"
    p="$(basename "$f" .env)"
    case " $ALL_PROJECTS " in *" $p "*) ;; *) ALL_PROJECTS="$ALL_PROJECTS $p" ;; esac
  done
fi

if [ -z "${ALL_PROJECTS// /}" ]; then
  # Legacy single-project: map the flat vars into the default project's namespace.
  : "${CODE_REPO_URL:?set CODE_REPO_URL (single project) or PROJECTS (multi) in deploy/.env}"
  ALL_PROJECTS="${PROJECT_NAME:-main}"
  ns="$(ns_of "$ALL_PROJECTS")"
  printf -v "${ns}_CODE_REPO_URL" '%s' "$CODE_REPO_URL"
  [ -n "${HUB_REPO_URL:-}" ]              && printf -v "${ns}_HUB_REPO_URL" '%s' "$HUB_REPO_URL"
  printf -v "${ns}_AGENTS" '%s' "${AGENTS:-claude}"
  printf -v "${ns}_QUEUE_KIND" '%s' "${QUEUE_KIND:-none}"
  [ -n "${QUEUE_LINEAR_TEAM:-}" ]         && printf -v "${ns}_QUEUE_LINEAR_TEAM" '%s' "$QUEUE_LINEAR_TEAM"
  [ -n "${QUEUE_LINEAR_PROJECT_ID:-}" ]   && printf -v "${ns}_QUEUE_LINEAR_PROJECT_ID" '%s' "$QUEUE_LINEAR_PROJECT_ID"
  [ -n "${QUEUE_LINEAR_PROJECT_NAME:-}" ] && printf -v "${ns}_QUEUE_LINEAR_PROJECT_NAME" '%s' "$QUEUE_LINEAR_PROJECT_NAME"
  [ -n "${QUEUE_GITHUB_REPO:-}" ]         && printf -v "${ns}_QUEUE_GITHUB_REPO" '%s' "$QUEUE_GITHUB_REPO"
  [ -n "${NTFY_TOPIC:-}" ]                && printf -v "${ns}_NTFY_TOPIC" '%s' "$NTFY_TOPIC"
fi

for p in $ALL_PROJECTS; do
  provision_project "$p"
done

wire_skills

echo "[fleet-vm-setup] done — projects:$ALL_PROJECTS"
echo "  Next (one-time login + folder-trust per agent CLI, interactive — headless != interactive auth):"
seen=" "
for p in $ALL_PROJECTS; do
  ns="$(ns_of "$p")"; pa="$(val "${ns}_AGENTS")"; pa="${pa:-${AGENTS:-claude}}"
  for a in $pa; do
    case "$seen" in *" $a "*) continue ;; esac
    seen="$seen$a "
    login_hint "$a"
  done
done
first="${ALL_PROJECTS#" "}"; first="${first%% *}"
echo "  Then, day to day:  docker exec -it ${FLEET_CONTAINER:-fleet} tmux attach -t ${FLEET_TMUX:-fleet} ; fleet --project $first w <task>"
echo "  From your laptop:  fleet machines add <name> <ssh-host>${FLEET_CONTAINER:+ ${FLEET_CONTAINER}}${FLEET_TMUX:+ ${FLEET_TMUX}}, then fleet --machine <name> ..."
