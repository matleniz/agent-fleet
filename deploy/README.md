# Running the fleet on a VM (headless, persistent)

tmux already keeps a `fleet` session alive across SSH disconnects — but only while
the machine is on. Move it to an always-on VM and your sessions survive the laptop
being closed. This directory packages the fleet as a single Docker container so
that "always on" is also "isolated" (workers run with permissions bypassed; the
container bounds the blast radius).

The generic tooling and the selected agent CLIs are **baked into the image**;
only the per-project repos, config, and credentials live on a persistent volume.
So the only secrets that touch the VM are a GitHub token and each CLI's one-time
login.

## What lives where

| Layer | Where | Persists? |
|---|---|---|
| fleet tools + packs (`fleet`, `new-worker`, `packs/…`) | image, `/opt/agent-fleet` | rebuilt from the repo |
| agent CLIs (claude, opencode, …) | image (build arg `PACKS`) | rebuilt from the repo |
| repos, worktrees, `~/.config`, per-CLI creds + sessions | volume `fleet-home` | yes, across rebuilds |
| `GH_TOKEN`, project description | `deploy/.env` (gitignored) + container env | on the VM only |

## One-time setup (on the VM)

1. Get the repo onto the VM (this `agent-fleet` checkout) and describe your
   project in the env file:
   ```bash
   cp deploy/.env.example deploy/.env
   $EDITOR deploy/.env          # GH_TOKEN, PROJECT_NAME, clone URLs, AGENTS, QUEUE_*
   ```
   The token should be a fine-grained PAT scoped to the project's repos with
   **Contents: Read and write** (clone + workers push branches / open PRs).

2. Build and start the container (from the repo root). Pick the packs to bake
   with the `PACKS` build arg (compose: uncomment `args:` in the yml):
   ```bash
   docker compose -f deploy/docker-compose.yml up -d --build
   ```

3. Wire the volume (clones the repos, writes `<project>.env`, installs skills).
   Idempotent:
   ```bash
   docker exec -it fleet fleet-vm-setup
   ```
   For several projects, set `PROJECTS="a b"` in `deploy/.env` with each
   project's vars under its uppercased namespace (`A_CODE_REPO_URL`,
   `B_HUB_REPO_URL`, …); `fleet-vm-setup` provisions them all. See
   **Multiple projects** below.

4. Log in once per enabled agent CLI (each stores its credential on the volume
   and refreshes itself). `fleet-vm-setup` prints the exact command for each
   enabled pack; for example:
   ```bash
   docker exec -it fleet claude       # OAuth: open the URL on your laptop, paste the code
   ```
   Note: account-level MCP connectors (e.g. Linear) come with a Claude login
   only; for other CLIs give the skills an API path instead (e.g.
   `LINEAR_API_KEY` in `deploy/.env`) — the workflow skills support both.

## Multiple projects

The volume persists everything (repos, worktrees, config, logins), so a plain
`compose up -d --build` never wipes a project. What is not reproducible on a
fresh box or a recreated volume is anything added only by hand — so **declare
every project**, and it comes back on any rebuild.

Two ways, both idempotent and non-destructive:

```bash
# Declarative: in deploy/.env
PROJECTS="alpha beta"
ALPHA_CODE_REPO_URL=https://github.com/org/alpha.git
BETA_CODE_REPO_URL=https://github.com/org/beta.git
BETA_HUB_REPO_URL=https://github.com/org/beta-hub.git
BETA_AGENTS="claude"
BETA_QUEUE_KIND=linear
BETA_QUEUE_LINEAR_TEAM=BETA
# un-namespaced AGENTS / QUEUE_KIND / NTFY_TOPIC act as defaults per project
```

```bash
# Imperative: add one later without touching the others (and make it survive
# rebuilds — it is recorded on the volume and re-read on every full run).
docker exec -it fleet fleet-vm-setup --add-project beta \
  --repo https://github.com/org/beta.git --hub https://github.com/org/beta-hub.git \
  --agents claude --queue linear --linear-team BETA
```

The container runs any number of projects (each resolved by cwd / `--project`);
"one per container" is only the *default* provisioning, not a limit. Run several
**containers** on one host (distinct `FLEET_CONTAINER`/`FLEET_TMUX`/`FLEET_VOLUME`)
only when you want the projects isolated from each other.

## Day to day

From your laptop, the fleet launcher IS the remote control. Register the VM as a
machine (`fleet machines add <name> <vm-ssh-host>`) and add it to the project's
`MACHINES`, or use the legacy `REMOTE_HOST=<vm>` (`fleet-init --remote <vm>`):

```bash
fleet r                   # attach the VM's tmux (its first non-local machine)
fleet r w <task>          # create/reopen the worker ON the VM, then attach
fleet --machine <name> w <task>   # same, naming the machine explicitly
fleet -a <pack> r w <task>  # same, with a specific enabled agent
fleet r del <task>        # delete a remote worker
fleet status --json       # the whole tree (what a dashboard/UI consumes)
fleet sync-remote [<name>] # update the VM engine(s) (rebuild; restarts its tmux)
```

Manual equivalent (also what you type from a phone / any box with SSM):

```bash
ssh <vm>
docker exec -it fleet tmux attach -t fleet
# inside tmux (no implicit default project — name it, or cd into the repo):
fleet --project <name> w <task>
fleet --project <name> ls
```

Detach with `Ctrl-b d`; close the laptop; the session keeps running on the VM.
Reattach from anywhere with `fleet r` (or the manual command above).

## Notifications (know when a remote worker is waiting)

The blind spot of a headless fleet is a worker stuck on a permission prompt.
Set `NTFY_TOPIC` in the project's .env (an unguessable topic on ntfy.sh, or a
full URL to your own server) and the claude pack wires every worker with
`Notification`/`Stop` hooks that push "<worker>: needs-attention" /
"<worker>: done" through `bin/fleet-notify`. Subscribe from the ntfy mobile
app, then `fleet r` to attach and answer. Other packs: not wired yet (their
hook support varies); `fleet r broadcast "..."` remains the manual lever.

## Updating the tools

The tools are baked in the image, so pull the repo and rebuild — the volume
(repos, sessions, logins) is untouched:

```bash
git -C <path-to-agent-fleet> pull
docker compose -f deploy/docker-compose.yml up -d --build
```

From your laptop, `fleet sync-remote [<name>]` does this over ssh (ship the
engine bundle + rebuild) and stamps the new git SHA into the image, so a later
`fleet --machine <name> w/dispatch` can warn you when a VM is behind. The PATH
symlinks (`~/.local/bin/fleet` → the baked tools) are re-wired on **every**
container start by the image entrypoint, so `fleet: command not found` after a
rebuild no longer needs a `fleet-vm-setup` re-run.

## Notes / limits

- **Provisioning is single-project by default, multi-project on request.**
  `fleet-vm-setup` wires the one project from the env file unless you set
  `PROJECTS=` or use `--add-project` (see **Multiple projects**). Run the
  container on infrastructure sanctioned for those projects' code, not a personal
  VPS for work repos. Use separate **containers** (distinct
  `FLEET_CONTAINER`/`FLEET_TMUX`/`FLEET_VOLUME`) when projects must be isolated
  from each other.
- **No GPU / training here.** The VM runs coding sessions; heavy compute stays
  wherever it lives today.
- **tmux sessions are in-memory.** A container restart drops the tmux windows,
  but worktrees, branches, and each CLI's sessions persist on the volume — just
  relaunch `fleet …`. (Auto-restore via tmux-resurrect is intentionally out of
  scope.)
- **`GH_TOKEN` is visible in `docker inspect`.** Acceptable on a single-tenant
  dev VM; scope the token to the project's repos and rotate it if the VM is
  shared.
- **Per-CLI logins are interactive, and headless ≠ interactive auth.**
  claude/cursor/antigravity all need a one-time interactive OAuth
  (`fleet-vm-setup` prints the exact command per enabled pack, e.g. `docker exec
  -it fleet claude`) — this also accepts the folder-trust prompt. A headless
  worker (`fleet dispatch`, `claude -p`) reuses the stored token and needs no
  prompt, but it cannot perform that first login/trust: do the `docker exec -it`
  once per CLI first. Do not try to pre-write the trust flag into `~/.claude.json`
  by hand — the auto-mode classifier blocks that self-modification, correctly.
- **antigravity/copilot need unprivileged user namespaces.** Having no in-CLI
  per-path deny, their read-only-hub barrier is an OS mount namespace that
  bind-mounts the hub read-only at launch (`packs/hub-mount-ns.sh`, see docs/02) —
  so they DO run on hub projects, worker jailed, coordinator in the hub unconfined.
  The pack fails closed only where unprivileged userns is unavailable (some
  hardened kernels / nested-container hosts): there, enable them on hub-less
  projects, or run the container with the privileges userns needs.
- **Hub hardening (optional).** For a belt-and-braces barrier, mount the hub
  clone read-only into worker containers or `chmod -R a-w` it outside
  coordinator sessions — the per-pack barriers block the edit tools, not shell
  redirects (see docs/02).
