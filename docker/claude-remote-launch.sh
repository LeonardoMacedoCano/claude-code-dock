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

# Same file entrypoint.sh writes to (${HOME}/.claude/logs/dock.log) -- this
# script runs *after* entrypoint.sh has already exec'd into tmux, so its own
# stdout/stderr goes to the tmux pane, not `docker logs`. Without also
# writing here, the --continue/retry decision below would be invisible to
# anyone who isn't attached live, which is exactly the "why did the remote
# session not show up" gap this script's retry logic can silently fall into.
LOG_FILE="${HOME}/.claude/logs/dock.log"
log() {
    { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "REMOTE" "$1" >> "${LOG_FILE}"; } 2>/dev/null || true
}

FAST_FAIL_THRESHOLD=15
HISTORY_DIR="${HOME}/.claude/projects/$(pwd | tr '/' '-')"

if compgen -G "${HISTORY_DIR}/*.jsonl" > /dev/null 2>&1; then
    log "Resumable conversation found in ${HISTORY_DIR} -- attempting 'claude --continue'."
    START_TS=$(date +%s)
    claude "$@" --continue
    STATUS=$?
    ELAPSED=$(( $(date +%s) - START_TS ))

    if [ "${STATUS}" -eq 0 ]; then
        log "'claude --continue' exited 0 after ${ELAPSED}s (normal session end, e.g. user exited)."
        exit 0
    fi

    if [ "${ELAPSED}" -ge "${FAST_FAIL_THRESHOLD}" ]; then
        log "'claude --continue' failed after ${ELAPSED}s (>= ${FAST_FAIL_THRESHOLD}s threshold) -- treating as a real crash, not retrying. Exit code: ${STATUS}."
        exit "${STATUS}"
    fi

    log "'claude --continue' exited immediately after ${ELAPSED}s (nothing resumable) -- retrying once without --continue."
    echo "claude-remote-launch: --continue exited immediately (no resumable session found) — retrying without --continue" >&2
else
    log "No resumable conversation found in ${HISTORY_DIR} -- starting a fresh session directly."
fi

log "Launching 'claude $*' -- this is the process that shows the Remote Control pairing link/code, if this is a new session."
exec claude "$@"
