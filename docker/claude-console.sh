#!/usr/bin/env bash
# Attaches to the tmux "main" session where Claude Code is running.
# Used by Unraid Console (Shell field: /usr/local/bin/claude-console).
# Disconnect without stopping: Ctrl+B then D
#
# Unraid's Console feature may invoke this as root regardless of the
# image's default user (the image itself starts as root too -- see
# Dockerfile/entrypoint.sh's root step-down for PUID/PGID). The tmux
# session was created by 'node' (whatever UID/GID that currently maps to),
# whose default tmux server socket lives at a UID-specific path -- a
# root-invoked tmux client looks at root's own socket path instead and
# would always report "no session". Step down first so this always finds
# the right socket regardless of which UID actually invoked it.
if [ "$(id -u)" = "0" ]; then
    exec setpriv --reuid=node --regid=node --init-groups "$0"
fi

if ! tmux has-session -t main 2>/dev/null; then
    echo "No active session found (tmux 'main' not running)."
    echo "Container may be starting or running in shell mode."
    exit 1
fi
exec tmux attach-session -t main
