#!/usr/bin/env bash
# Attaches to the tmux "main" session where Claude Code is running.
# Used by Unraid Console (Shell field: /usr/local/bin/claude-console).
# Disconnect without stopping: Ctrl+B then D
exec tmux attach-session -t main
