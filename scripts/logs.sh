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
CONTAINER_NAME="${CONTAINER_NAME:-claude-code-dock}"
CONFIG_BASE_PATH="${CONFIG_BASE_PATH:-./configs}"
REMOTE_SESSION_NAME="${REMOTE_SESSION_NAME:-default}"
TAIL_LINES=50
FOLLOW=true
SINCE=""
APP_LOG=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

while [[ $# -gt 0 ]]; do
    case $1 in
        --tail)
            TAIL_LINES="$2"
            shift 2
            ;;
        --no-follow)
            FOLLOW=false
            shift
            ;;
        --since)
            SINCE="$2"
            shift 2
            ;;
        --app)
            APP_LOG=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--tail N] [--no-follow] [--since DURATION] [--app]"
            echo ""
            echo "  --tail N          Show last N lines (default: 50)"
            echo "  --no-follow       Do not follow new log output"
            echo "  --since DURATION  Show logs since (e.g.: 1h, 30m, 2024-01-01)"
            echo "  --app             Show the persistent startup log (dock.log) instead of"
            echo "                    'docker logs'. Use this when docker logs shows nothing or"
            echo "                    just the raw tmux/Claude terminal screen — that happens"
            echo "                    because Claude takes over the container's tty once it"
            echo "                    starts, and docker logs simply mirrors that tty."
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

if [ "${APP_LOG}" == "true" ]; then
    APP_LOG_FILE="${CONFIG_BASE_PATH}/${REMOTE_SESSION_NAME}/logs/dock.log"

    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║          claude-code-dock — Startup log                   ║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  File: ${BOLD}${APP_LOG_FILE}${RESET}"
    echo ""

    if [ ! -f "${APP_LOG_FILE}" ]; then
        echo -e "${RED}[✗]${RESET} No startup log found yet at that path."
        echo -e "  It is created on first container start. Check REMOTE_SESSION_NAME"
        echo -e "  and CONFIG_BASE_PATH in .env if this session has already run."
        echo ""
        exit 1
    fi

    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    if [ "${FOLLOW}" == "true" ]; then
        echo -e "  ${YELLOW}Press Ctrl+C to stop.${RESET}"
        echo ""
        tail -n "${TAIL_LINES}" -f "${APP_LOG_FILE}"
    else
        tail -n "${TAIL_LINES}" "${APP_LOG_FILE}"
        echo ""
        echo -e "  ${GREEN}[✓]${RESET} End of log."
        echo ""
    fi
    exit 0
fi

if ! docker ps -a --filter "name=${CONTAINER_NAME}" | grep -q "${CONTAINER_NAME}"; then
    echo -e "${RED}[✗]${RESET} Container ${BOLD}${CONTAINER_NAME}${RESET} not found."
    echo ""
    echo -e "  Create the container with:"
    echo -e "  ${BOLD}./scripts/install.sh${RESET}"
    echo ""
    exit 1
fi

CONTAINER_STATUS=$(docker inspect --format='{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║              claude-code-dock — Logs                      ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Container: ${BOLD}${CONTAINER_NAME}${RESET}"
echo -e "  Status:    ${BOLD}${CONTAINER_STATUS}${RESET}"
echo -e "  Last:      ${BOLD}${TAIL_LINES}${RESET} lines"
if [ -n "${SINCE}" ]; then
    echo -e "  Since:     ${BOLD}${SINCE}${RESET}"
fi
echo ""
echo -e "  ${YELLOW}Note:${RESET} once Claude Code starts, this stream mirrors the tmux"
echo -e "  terminal screen (not scrolling log lines). For a clean, persistent"
echo -e "  startup log instead, run: ${CYAN}./scripts/logs.sh --app${RESET}"
echo ""
echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

if [ "${FOLLOW}" == "true" ]; then
    echo -e "  ${YELLOW}Press Ctrl+C to stop.${RESET}"
    echo ""
fi

LOG_ARGS=(--tail "${TAIL_LINES}")

if [ -n "${SINCE}" ]; then
    LOG_ARGS+=(--since "${SINCE}")
fi

if [ "${FOLLOW}" == "true" ]; then
    LOG_ARGS+=(-f)
fi

docker logs "${LOG_ARGS[@]}" "${CONTAINER_NAME}"

if [ "${FOLLOW}" == "false" ]; then
    echo ""
    echo -e "  ${GREEN}[✓]${RESET} End of logs."
    echo ""
fi
