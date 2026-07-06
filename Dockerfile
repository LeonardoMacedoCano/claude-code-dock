FROM node:lts-bookworm

LABEL maintainer="claude-code-dock Contributors"
LABEL description="Claude Code running persistently in Docker for homelab servers"
LABEL org.opencontainers.image.title="claude-code-dock"
LABEL org.opencontainers.image.description="Persistent Claude Code environment for 24/7 servers"
LABEL org.opencontainers.image.source="https://github.com/LeonardoMacedoCano/claude-code-dock"

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV TERM=xterm-256color
ENV PATH="/usr/local/bin:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    wget \
    git \
    nano \
    tmux \
    ca-certificates \
    procps \
    less \
    jq \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ARG CLAUDE_CODE_VERSION=latest
# CACHEBUST is unused by npm but referenced in the RUN line below so changing
# it invalidates Docker's layer cache for this instruction. Needed because CI
# (docker-publish.yml) builds with a persistent GitHub Actions cache — without
# this, @${CLAUDE_CODE_VERSION}=latest would resolve once and then get served
# from cache indefinitely, never picking up newer Claude Code releases.
ARG CACHEBUST=1
RUN echo "cachebust=${CACHEBUST}" > /dev/null && \
    npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} --no-update-notifier && \
    grep '"version"' /usr/local/lib/node_modules/@anthropic-ai/claude-code/package.json \
        | head -1 | awk -F'"' '{print $4}' \
        > /etc/claude-code-version 2>/dev/null || echo "unknown" > /etc/claude-code-version

# Records whether this image came from a local clone (CLAUDE_SOURCE_PATH, used
# to test claude-code-dock changes before pushing) or a GitHub ref, so
# entrypoint.sh and `scripts/status.sh` can show unambiguously which one is
# actually running instead of leaving it to guesswork after the build scrolls by.
ARG CLAUDE_DOCK_SOURCE_PATH=
ARG CLAUDE_DOCK_VERSION=main
RUN if [ -n "${CLAUDE_DOCK_SOURCE_PATH}" ]; then \
        echo "local:${CLAUDE_DOCK_SOURCE_PATH}" > /etc/claude-dock-build-source; \
    else \
        echo "github:${CLAUDE_DOCK_VERSION}" > /etc/claude-dock-build-source; \
    fi

RUN mkdir -p /workspace && chown node:node /workspace

WORKDIR /workspace
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/entrypoint.sh
# claude-console: used by Unraid Console (Shell field = claude-console)
COPY --chmod=755 docker/claude-console.sh /usr/bin/claude-console

# Claude Code 2.x blocks --dangerously-skip-permissions when running as root.
# The node:lts-bookworm image already includes user 'node' (UID/GID 1000).
ENV HOME=/home/node
USER node

VOLUME ["/home/node/.claude"]

# Shell mode: PID 1 must actually be bash (not just "some process alive" --
# kill -0 1 is trivially true for the whole container lifetime and catches
# nothing). Interactive/remote: the tmux session must exist AND its pane must
# not be dead -- a crashed/exited claude process leaves the session up with a
# dead pane, which a bare `tmux has-session` check would report as healthy.
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD if [ "${AUTO_START_MODE:-interactive}" = "shell" ]; then \
            [ "$(ps -p 1 -o comm= 2>/dev/null)" = "bash" ] || exit 1; \
        else \
            tmux has-session -t main 2>/dev/null || exit 1; \
            [ "$(tmux list-panes -t main -F '#{pane_dead}' 2>/dev/null | head -1)" = "0" ] || exit 1; \
        fi

ENTRYPOINT ["/bin/bash", "/usr/local/bin/entrypoint.sh"]
