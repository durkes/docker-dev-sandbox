# Generic containerized dev environment for Node projects. Holds NO project
# code -- target repos are bind-mounted at /workspace at run time.

# Node 24 "Krypton" is the current Active LTS. Override for a project that needs
# a different runtime.
ARG NODE_VERSION=24

# -trixie-slim rather than bare -slim, so a future Debian default swap cannot
# silently change the base on rebuild.
# NOT Alpine: musl breaks Claude Code's bundled ripgrep.
FROM node:${NODE_VERSION}-trixie-slim

# git      - in-container status/diff/stash (commits/pushes happen on Windows)
# curl     - Claude Code login flow, general dev use
# less     - git pager
# procps   - ps/kill, for managing dev servers across multiple shells
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      less \
      procps \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code \
 && npm cache clean --force

# A Windows bind mount's ownership will not match the container user; tell git
# not to treat that as dubious ownership.
RUN git config --system --add safe.directory /workspace \
 && git config --system --add safe.directory '*'

ENV NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    PAGER=less

# Required, not cosmetic: Claude Code refuses to start with
# --dangerously-skip-permissions as root.
USER node

WORKDIR /workspace

CMD ["bash"]
