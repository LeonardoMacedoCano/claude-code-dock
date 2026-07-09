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

# CACHEBUST is unused by the commands below but referenced in their RUN lines
# so changing it invalidates Docker's layer cache for those instructions.
# Needed because CI (docker-publish.yml) builds with a persistent GitHub
# Actions cache — without this, apt/npm package resolution would happen once
# and then get served from cache indefinitely, never picking up newer Debian
# security fixes or Claude Code releases on the weekly scheduled rebuild.
ARG CACHEBUST=1

# upgrade: pulls Debian security-repo fixes for packages already present in
# the base node:lts-bookworm image (not just the ones we explicitly install
# below) -- without it, CVEs patched upstream but not yet in this base image
# layer keep failing the Trivy scan step in CI on every rebuild.
#
# Trade-off, stated explicitly: this is a full `apt-get upgrade`, not scoped
# to the security suite only, and it is forced fresh on every build via
# CACHEBUST (see below). That means the exact set of Debian package versions
# in a given image tag is NOT reproducible across rebuilds -- two builds of
# the same claude-code-dock commit, a week apart, can legitimately contain
# different apt package versions. This is a deliberate choice of
# freshness/security over bit-for-bit reproducibility: pinning package
# versions would make builds reproducible but would also mean this image
# stops receiving Debian security patches until someone manually bumps the
# pin. If you need a reproducible build for auditing, pin to a specific
# published image digest (`docker pull ...@sha256:...`) rather than a moving
# tag -- that image's package set is then fixed, even though future rebuilds
# of the same source won't match it exactly.
#
# Because the package set isn't reproducible across rebuilds, this layer also
# snapshots `dpkg -l` to /etc/claude-dock-packages.list (same pattern as the
# /etc/claude-code-version and /etc/claude-dock-build-source markers below) --
# without it, there would be no way to tell which Debian package versions a
# given running container actually has after the fact, making a regression
# introduced by a routine weekly rebuild unbisectable. Compare two images with:
#   docker run --rm <image> cat /etc/claude-dock-packages.list > a.list
#   diff a.list b.list
RUN echo "cachebust=${CACHEBUST}" > /dev/null && \
    apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
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
    tzdata \
    && dpkg -l > /etc/claude-dock-packages.list \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ARG CLAUDE_CODE_VERSION=latest
RUN echo "cachebust=${CACHEBUST}" > /dev/null && \
    npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} --no-update-notifier && \
    grep '"version"' /usr/local/lib/node_modules/@anthropic-ai/claude-code/package.json \
        | head -1 | awk -F'"' '{print $4}' \
        > /etc/claude-code-version 2>/dev/null || echo "unknown" > /etc/claude-code-version

# Records whether this image came from a local clone (CLAUDE_SOURCE_PATH, used
# to test claude-code-dock changes before pushing) or a GitHub ref, so
# entrypoint.sh and `scripts/status.sh` can show unambiguously which one is
# actually running instead of leaving it to guesswork after the build scrolls by.
# Also echoed directly to the build log (not just written to the file) so it's
# visible immediately during `docker compose build`/`up --build` -- note this
# only prints when this layer actually runs; if Docker serves it from cache
# (e.g. a plain rebuild with no --no-cache), nothing prints here at all, same
# as the two RUN layers above it.
ARG CLAUDE_DOCK_SOURCE_PATH=
ARG CLAUDE_DOCK_VERSION=main
RUN if [ -n "${CLAUDE_DOCK_SOURCE_PATH}" ]; then \
        echo "BUILD SOURCE: local clone (${CLAUDE_DOCK_SOURCE_PATH})"; \
        echo "local:${CLAUDE_DOCK_SOURCE_PATH}" > /etc/claude-dock-build-source; \
    else \
        echo "BUILD SOURCE: GitHub (ref: ${CLAUDE_DOCK_VERSION})"; \
        echo "github:${CLAUDE_DOCK_VERSION}" > /etc/claude-dock-build-source; \
    fi

RUN mkdir -p /workspace && chown node:node /workspace

WORKDIR /workspace
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/entrypoint.sh
# claude-console: used by Unraid Console (Shell field = claude-console)
COPY --chmod=755 docker/claude-console.sh /usr/bin/claude-console
# claude-remote-launch: internal helper invoked by entrypoint.sh in remote
# mode only, to try --continue and fall back safely if it isn't resumable.
COPY --chmod=755 docker/claude-remote-launch.sh /usr/local/bin/claude-remote-launch.sh

# setpriv (util-linux) is what entrypoint.sh uses to drop from root to the
# 'node' account (optionally remapped to PUID/PGID first) before ever
# exec'ing bash/tmux/claude -- it's part of every Debian base image already,
# this is just a build-time sanity check so a future base image swap that
# somehow dropped it fails loudly here instead of silently breaking the
# step-down at container startup.
RUN command -v setpriv >/dev/null || (echo "setpriv (util-linux) not found in base image" >&2 && exit 1)

# Claude Code 2.x blocks --dangerously-skip-permissions when running as root.
# The node:lts-bookworm image already includes user 'node' (UID/GID 1000).
# No permanent USER directive here (deliberately) -- the container starts as
# root by default so entrypoint.sh's root step-down block can remap 'node' to
# PUID/PGID (if set) via usermod/groupmod, which requires root, before it
# drops to that user via setpriv and execs everything else. The *actual*
# long-running process (bash in shell mode, or the tmux session in
# interactive/remote mode) always still ends up non-root by the time it
# starts -- see the "Root step-down" block at the top of entrypoint.sh. Do
# not add USER node/USER <anything> back here; it would make PUID/PGID
# remapping impossible (usermod/groupmod need root) without reintroducing a
# runtime privilege escalation back to root, which is what this pattern is
# built specifically to avoid.
ENV HOME=/home/node

VOLUME ["/home/node/.claude"]

# Shell mode: PID 1 must actually be bash (not just "some process alive" --
# kill -0 1 is trivially true for the whole container lifetime and catches
# nothing). Interactive/remote: the tmux session must exist AND its pane must
# not be dead -- a crashed/exited claude process leaves the session up with a
# dead pane, which a bare `tmux has-session` check would report as healthy.
#
# The tmux checks run via `setpriv --reuid=node --regid=node` rather than
# directly: HEALTHCHECK CMD executes as this image's default user, which is
# now root (no permanent USER directive -- see above), but the actual tmux
# session was created by 'node' (whatever UID/GID that currently maps to via
# PUID/PGID), whose default tmux server socket lives at a UID-specific path
# under /tmp. A root-invoked `tmux has-session` would look in root's own
# socket path instead and always report "no session", regardless of PUID/PGID.
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD if [ "${AUTO_START_MODE:-interactive}" = "shell" ]; then \
            [ "$(ps -p 1 -o comm= 2>/dev/null)" = "bash" ] || exit 1; \
        else \
            setpriv --reuid=node --regid=node --init-groups tmux has-session -t main 2>/dev/null || exit 1; \
            [ "$(setpriv --reuid=node --regid=node --init-groups tmux list-panes -t main -F '#{pane_dead}' 2>/dev/null | head -1)" = "0" ] || exit 1; \
        fi

ENTRYPOINT ["/bin/bash", "/usr/local/bin/entrypoint.sh"]
