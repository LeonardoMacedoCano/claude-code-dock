#!/usr/bin/env bash
# Launches Claude Code Remote Control, resuming the most recent conversation
# recorded for this workspace when one exists.
#
# `claude --continue` has no graceful "start fresh" fallback: it hard-fails
# when there is nothing to resume. A Claude Code project directory can also
# hold a .jsonl file that still isn't actually resumable (e.g. left over from
# an incompatible version, or a conversation Claude Code itself considers
# unfinished/corrupt) — so the presence of history is a hint, not a guarantee.
# This treats --continue as a best-effort first attempt: try it only when
# history looks present, and if it fails within FAST_FAIL_THRESHOLD seconds
# (i.e. before doing any real work), retry once without --continue instead of
# leaving the tmux pane dead.
#
# A failure *after* running for a while is a genuine crash, not a "nothing to
# continue" failure — that case is left alone so the tmux pane dies and
# Docker's `restart: unless-stopped` policy restarts the container cleanly,
# instead of this script silently discarding continuity on every real crash.
#
# No `set -e`: the whole point of this script is to inspect claude's exit
# status after it fails, which errexit would short-circuit.
set -uo pipefail

FAST_FAIL_THRESHOLD=15
HISTORY_DIR="${HOME}/.claude/projects/$(pwd | tr '/' '-')"

if compgen -G "${HISTORY_DIR}/*.jsonl" > /dev/null 2>&1; then
    START_TS=$(date +%s)
    claude "$@" --continue
    STATUS=$?
    ELAPSED=$(( $(date +%s) - START_TS ))

    if [ "${STATUS}" -eq 0 ]; then
        exit 0
    fi

    if [ "${ELAPSED}" -ge "${FAST_FAIL_THRESHOLD}" ]; then
        exit "${STATUS}"
    fi

    echo "claude-remote-launch: --continue exited immediately (no resumable session found) — retrying without --continue" >&2
fi

exec claude "$@"
