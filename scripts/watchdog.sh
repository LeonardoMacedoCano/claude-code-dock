#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${PROJECT_DIR}/.env"

# Captured BEFORE sourcing .env: .env almost always defines CONTAINER_NAME
# (install.sh/new-session.sh both write it) for docker compose's own use,
# which is not a signal that this run should only ever watch one container
# -- if sourcing .env were allowed to populate this, auto-discovery below
# would never trigger for anyone with a normal .env, defeating the one case
# (multiple sessions) it exists for. Only a CONTAINER_NAME already present in
# the process environment before this script even started (e.g. a crontab
# line prefixed with `CONTAINER_NAME=foo ... watchdog.sh`) counts as "pin
# this one".
PRESET_CONTAINER_NAME="${CONTAINER_NAME:-}"

if [ -f "${ENV_FILE}" ]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

step() { echo -e "${CYAN}[→]${RESET} ${BOLD}$1${RESET}"; }
ok()   { echo -e "${GREEN}[✓]${RESET} $1"; }
warn() { echo -e "${YELLOW}[⚠]${RESET} $1"; }
fail() { echo -e "${RED}[✗]${RESET} $1" >&2; exit 1; }

usage() {
    echo "Usage: $0 [container-name]"
    echo ""
    echo "  With a container name (or \$CONTAINER_NAME set): restarts just that"
    echo "  container if Docker reports its healthcheck as 'unhealthy'."
    echo ""
    echo "  With NEITHER a name NOR \$CONTAINER_NAME set: auto-discovers every"
    echo "  container whose name contains 'claude-code-dock' (same filter"
    echo "  scripts/sessions.sh uses) and checks each one in turn. This is what"
    echo "  lets a single crontab entry cover every session created via"
    echo "  new-session.sh/session-up.sh, including ones created after the cron"
    echo "  entry was installed -- nothing to edit when you add a session."
    echo ""
    echo "  Optional: set \$WATCHDOG_NTFY_URL to a webhook URL (e.g. an ntfy.sh"
    echo "  topic) to get a notification when this script restarts a container,"
    echo "  fails to restart one, or skips one due to a fatal misconfiguration"
    echo "  marker. Silently a no-op if unset, or if curl isn't installed."
    echo ""
    echo "  'restart: unless-stopped' in docker-compose.yml only reacts to a"
    echo "  container actually exiting -- a wedged tmux pane that Docker marks"
    echo "  unhealthy but that hasn't crashed is never auto-restarted on its own."
    echo "  This script closes that gap. Run it periodically from the HOST via"
    echo "  cron, e.g. every 5 minutes:"
    echo ""
    echo "    */5 * * * * ${SCRIPT_DIR}/watchdog.sh >> ${PROJECT_DIR}/watchdog.log 2>&1"
    echo ""
    echo "  An 'unhealthy' container that entrypoint.sh's fatal() put into"
    echo "  'sleep infinity' (invalid AUTO_START_MODE, unwritable config/workspace)"
    echo "  is skipped, not restarted -- that state is a persistent misconfiguration"
    echo "  a restart can't fix, and restarting it anyway would just recreate the"
    echo "  same fatal() call every cycle, i.e. the exact restart loop fatal()"
    echo "  exists to avoid. Check 'docker logs <container>' for the fix instead."
    echo ""
    echo "  Exit codes: 0 = every checked container healthy/starting/skipped/restarted OK"
    echo "              1 = a container was not found, or a restart failed"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

# Optional, best-effort notification when this script actually takes (or
# skips) action -- not on every healthy/starting no-op, which would just be
# cron-frequency noise. Generic HTTP POST of a plain-text body: works as-is
# with ntfy.sh (WATCHDOG_NTFY_URL=https://ntfy.sh/your-topic) or any webhook
# that accepts a raw POST body. Never fails the watchdog run itself -- a
# missing curl, an unreachable URL, or a non-2xx response is swallowed, since
# a notification failing is not a reason to skip the actual restart logic.
notify() {
    local message="$1"
    [ -z "${WATCHDOG_NTFY_URL:-}" ] && return 0
    command -v curl &>/dev/null || return 0
    curl -fsS -m 10 -d "${message}" "${WATCHDOG_NTFY_URL}" &>/dev/null || true
}

# Checks and, if needed, restarts a single container. Never calls exit --
# returns a status instead, so both single-name mode and auto-discovery mode
# below can decide what a failure means for the run as a whole (discovery
# mode must keep checking the remaining containers even if one fails).
#   0 = healthy/starting/no-healthcheck/restarted OK/skipped via fatal marker
#   1 = restart failed
#   2 = container not found
check_one() {
    local name="$1"
    local status
    status=$(docker inspect --format '{{.State.Health.Status}}' "${name}" 2>/dev/null || echo "")

    if [ -z "${status}" ]; then
        if ! docker inspect "${name}" &>/dev/null; then
            echo -e "  ${RED}[✗]${RESET} Container not found: ${name}" >&2
            return 2
        fi
        ok "${name}: no healthcheck configured or health status unavailable — nothing to do."
        return 0
    fi

    case "${status}" in
        unhealthy)
            # entrypoint.sh's fatal() leaves this marker before parking PID 1 on
            # `sleep infinity` -- that's a persistent misconfiguration (invalid
            # AUTO_START_MODE, unwritable config/workspace dir), not a wedged
            # process, and restarting won't fix it. Restarting anyway would just
            # reproduce the same fatal() call next cycle, recreating the restart
            # loop fatal() was specifically built to avoid.
            if docker exec "${name}" test -f /tmp/claude-dock-fatal 2>/dev/null; then
                warn "${name} is unhealthy due to a fatal startup misconfiguration, not a wedged process — restarting would not fix it."
                echo -e "    Check: docker logs ${name}"
                notify "claude-code-dock: ${name} is unhealthy due to a fatal startup misconfiguration — not restarted. Check: docker logs ${name}"
                return 0
            fi

            warn "${name} is unhealthy — restarting..."
            step "docker restart ${name}"
            if docker restart "${name}" &>/dev/null; then
                ok "${name} restarted."
                notify "claude-code-dock: ${name} was unhealthy — restarted successfully."
                return 0
            fi

            notify "claude-code-dock: ${name} is unhealthy and docker restart FAILED — needs manual attention."
            echo -e "  ${RED}[✗]${RESET} docker restart failed for ${name}." >&2
            return 1
            ;;
        healthy)
            ok "${name}: healthy."
            ;;
        starting)
            ok "${name}: starting (within HEALTHCHECK --start-period) — no action."
            ;;
        *)
            ok "${name}: health status '${status}' — no action."
            ;;
    esac
    return 0
}

run_single() {
    local name="$1"
    local rc=0
    check_one "${name}" || rc=$?
    case "${rc}" in
        0) exit 0 ;;
        2) fail "Container not found: ${name}" ;;
        *) exit 1 ;;
    esac
}

# No explicit name and no $CONTAINER_NAME: instead of guessing a single
# default name, ask Docker for every container this project could have
# created (same "name=claude-code-dock" substring filter scripts/sessions.sh
# already uses to list them). This is what makes one crontab entry keep
# covering every session from new-session.sh/session-up.sh automatically,
# including ones that didn't exist yet when the entry was installed.
run_discovery() {
    local names
    names="$(docker ps -a --filter "name=claude-code-dock" --format "{{.Names}}" 2>/dev/null || true)"

    if [ -z "${names}" ]; then
        warn "No claude-code-dock containers found on this host — nothing to watch."
        exit 0
    fi

    step "Auto-discovered $(echo "${names}" | wc -l | tr -d ' ') claude-code-dock container(s): $(echo "${names}" | tr '\n' ' ')"
    echo ""

    local failures=0
    local rc
    while IFS= read -r name; do
        [ -z "${name}" ] && continue
        rc=0
        check_one "${name}" || rc=$?
        [ "${rc}" -ne 0 ] && failures=$((failures + 1))
        echo ""
    done <<< "${names}"

    [ "${failures}" -gt 0 ] && exit 1
    exit 0
}

CONTAINER_ARG="${1:-}"

if [ -n "${CONTAINER_ARG}" ]; then
    run_single "${CONTAINER_ARG}"
elif [ -n "${PRESET_CONTAINER_NAME}" ]; then
    run_single "${PRESET_CONTAINER_NAME}"
else
    run_discovery
fi
