#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${PROJECT_DIR}/.env"

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
    echo "  Restarts <container-name> (default: \$CONTAINER_NAME from .env, or"
    echo "  claude-code-dock) if Docker reports its healthcheck as 'unhealthy'."
    echo ""
    echo "  Optional: set \$WATCHDOG_NTFY_URL to a webhook URL (e.g. an ntfy.sh"
    echo "  topic) to get a notification when this script restarts the container,"
    echo "  fails to restart it, or skips it due to a fatal misconfiguration marker."
    echo "  Silently a no-op if unset, or if curl isn't installed."
    echo ""
    echo "  'restart: unless-stopped' in docker-compose.yml only reacts to the"
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
    echo "  Exit codes: 0 = healthy/starting/no-healthcheck (no action needed)"
    echo "              0 = unhealthy, restart succeeded"
    echo "              0 = unhealthy due to a fatal() misconfiguration, skipped"
    echo "              1 = container not found, or restart failed"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

CONTAINER_NAME="${1:-${CONTAINER_NAME:-claude-code-dock}}"

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

STATUS=$(docker inspect --format '{{.State.Health.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "")

if [ -z "${STATUS}" ]; then
    if ! docker inspect "${CONTAINER_NAME}" &>/dev/null; then
        fail "Container not found: ${CONTAINER_NAME}"
    fi
    ok "${CONTAINER_NAME}: no healthcheck configured or health status unavailable — nothing to do."
    exit 0
fi

case "${STATUS}" in
    unhealthy)
        # entrypoint.sh's fatal() leaves this marker before parking PID 1 on
        # `sleep infinity` -- that's a persistent misconfiguration (invalid
        # AUTO_START_MODE, unwritable config/workspace dir), not a wedged
        # process, and restarting won't fix it. Restarting anyway would just
        # reproduce the same fatal() call next cycle, recreating the restart
        # loop fatal() was specifically built to avoid.
        if docker exec "${CONTAINER_NAME}" test -f /tmp/claude-dock-fatal 2>/dev/null; then
            warn "${CONTAINER_NAME} is unhealthy due to a fatal startup misconfiguration, not a wedged process — restarting would not fix it."
            echo -e "    Check: docker logs ${CONTAINER_NAME}"
            notify "claude-code-dock: ${CONTAINER_NAME} is unhealthy due to a fatal startup misconfiguration — not restarted. Check: docker logs ${CONTAINER_NAME}"
            exit 0
        fi

        warn "${CONTAINER_NAME} is unhealthy — restarting..."
        step "docker restart ${CONTAINER_NAME}"
        if docker restart "${CONTAINER_NAME}" &>/dev/null; then
            ok "${CONTAINER_NAME} restarted."
            notify "claude-code-dock: ${CONTAINER_NAME} was unhealthy — restarted successfully."
        else
            notify "claude-code-dock: ${CONTAINER_NAME} is unhealthy and docker restart FAILED — needs manual attention."
            fail "docker restart failed for ${CONTAINER_NAME}."
        fi
        ;;
    healthy)
        ok "${CONTAINER_NAME}: healthy."
        ;;
    starting)
        ok "${CONTAINER_NAME}: starting (within HEALTHCHECK --start-period) — no action."
        ;;
    *)
        ok "${CONTAINER_NAME}: health status '${STATUS}' — no action."
        ;;
esac
