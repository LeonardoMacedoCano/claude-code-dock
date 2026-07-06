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
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} --no-update-notifier

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

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD kill -0 1 2>/dev/null || exit 1

ENTRYPOINT ["/bin/bash", "/usr/local/bin/entrypoint.sh"]
