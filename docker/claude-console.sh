#!/usr/bin/env bash
# Attaches to the tmux "main" session where Claude Code is running.
# Used by Unraid Console (Shell field: /usr/local/bin/claude-console).
# Disconnect without stopping: Ctrl+B then D
if ! tmux has-session -t main 2>/dev/null; then
    echo "No active session found (tmux 'main' not running)."
    echo "Container may be starting or running in shell mode."
    exit 1
fi
exec tmux attach-session -t main
