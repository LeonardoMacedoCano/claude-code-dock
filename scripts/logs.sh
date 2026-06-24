#!/usr/bin/env bash

set -euo pipefail

CONTAINER_NAME="claude-code-dock"
TAIL_LINES=50
FOLLOW=true
SINCE=""

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
        -h|--help)
            echo "Usage: $0 [--tail N] [--no-follow] [--since DURATION]"
            echo ""
            echo "  --tail N          Show last N lines (default: 50)"
            echo "  --no-follow       Do not follow new log output"
            echo "  --since DURATION  Show logs since (e.g.: 1h, 30m, 2024-01-01)"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

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
echo -e "${CYAN}${BOLD}║              ClaudeCodeDock — Logs                      ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Container: ${BOLD}${CONTAINER_NAME}${RESET}"
echo -e "  Status:    ${BOLD}${CONTAINER_STATUS}${RESET}"
echo -e "  Last:      ${BOLD}${TAIL_LINES}${RESET} lines"
if [ -n "${SINCE}" ]; then
    echo -e "  Since:     ${BOLD}${SINCE}${RESET}"
fi
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
