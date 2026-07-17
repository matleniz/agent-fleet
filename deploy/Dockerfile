# Dockerfile — a dedicated container to run the fleet on a VM, headless & persistent.
# Build from the REPO ROOT so the generic tools can be baked in:
#   docker build -f deploy/Dockerfile -t agent-fleet:latest .
# (or `docker compose -f deploy/docker-compose.yml up -d --build`, which does this).
#
# The generic fleet tooling ships in the image (/opt/agent-fleet, read-only).
# Only the per-project repos, config, and credentials live on the runtime volume.
# Agent CLIs are installed per pack — pick them at build time:
#   docker build --build-arg PACKS="claude opencode" ...
# (each pack's pack_install() prints its own install command). See deploy/README.md.
FROM node:20-bookworm-slim

# System deps: git + tmux (persistence) + python3 (guard hook, venvs) + gh (PRs).
RUN apt-get update && apt-get install -y --no-install-recommends \
      git tmux python3 python3-venv curl ca-certificates openssh-client less \
 && mkdir -p -m 755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# Bake the generic fleet tooling (root-owned, read-only for the fleet user).
COPY bin/                 /opt/agent-fleet/bin/
COPY packs/               /opt/agent-fleet/packs/
COPY templates/           /opt/agent-fleet/templates/
COPY docs/                /opt/agent-fleet/docs/
COPY deploy/install.sh    /opt/agent-fleet/deploy/install.sh
COPY deploy/entrypoint.sh /opt/agent-fleet/deploy/entrypoint.sh
RUN chmod +x /opt/agent-fleet/bin/* /opt/agent-fleet/deploy/install.sh /opt/agent-fleet/deploy/entrypoint.sh \
 && ln -s /opt/agent-fleet/deploy/install.sh /usr/local/bin/fleet-vm-setup

# Stamp the engine's git SHA into the image so `fleet --machine X` can warn when
# a VM lags the laptop. `fleet sync-remote` passes it as ENGINE_SHA=<short>;
# a plain local build leaves it "unknown" (no false mismatch warnings).
ARG ENGINE_SHA=unknown
RUN echo "$ENGINE_SHA" > /opt/agent-fleet/.engine-sha

# Install the agent CLIs for the selected packs. npm -g installers are global;
# curl-based installers (cursor, antigravity) drop their payload under
# /root/.local (mode 700 — invisible to the non-root fleet user): promote the
# payload to /usr/local/share and re-target the bin symlinks accordingly.
ARG PACKS="claude"
RUN bash -c 'set -e; for p in $PACKS; do \
      . "/opt/agent-fleet/packs/$p/pack.sh"; \
      cmd="$(pack_install)"; echo "[packs] $p: $cmd"; eval "$cmd"; \
    done; \
    if [ -d /root/.local/share ]; then cp -a /root/.local/share/. /usr/local/share/; fi; \
    if [ -d /root/.local/bin ]; then \
      for f in /root/.local/bin/*; do b="$(basename "$f")"; t="$(readlink -f "$f")"; \
        case "$t" in \
          /root/.local/share/*) ln -sf "/usr/local/share${t#/root/.local/share}" "/usr/local/bin/$b";; \
          *) cp -a "$f" "/usr/local/bin/$b";; \
        esac; \
      done; \
    fi'

# Non-root user. node:20 already occupies uid 1000 (user "node"), so fleet gets 1001.
RUN useradd -m -s /bin/bash -u 1001 fleet
USER fleet
WORKDIR /home/fleet
ENV PATH=/home/fleet/.local/bin:$PATH \
    FLEET_HOME=/home/fleet/.config/fleet \
    TERM=xterm-256color

# Every start re-wires the PATH symlinks (self-healing after a rebuild), then
# runs CMD. `docker exec` bypasses the entrypoint, so one-time logins/attach are
# unaffected. Keep the container alive with a tmux server ready to attach; the
# session name is $FLEET_TMUX (default "fleet") so several containers can coexist
# on one host, each addressed by a machine-registry entry with a matching MACHINE_TMUX.
ENTRYPOINT ["/opt/agent-fleet/deploy/entrypoint.sh"]
CMD ["bash","-lc","tmux new-session -d -s \"${FLEET_TMUX:-fleet}\" 2>/dev/null || true; exec tail -f /dev/null"]
