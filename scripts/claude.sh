#!/usr/bin/env bash

set -euo pipefail

CONTAINER_NAME="claude-code-dock"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

if ! docker ps --filter "name=${CONTAINER_NAME}" --filter "status=running" | grep -q "${CONTAINER_NAME}"; then
    echo -e "${RED}[✗]${RESET} Container ${BOLD}${CONTAINER_NAME}${RESET} is not running."
    echo ""
    echo -e "  Start the container with:"
    echo -e "  ${BOLD}docker compose up -d${RESET}"
    echo ""
    exit 1
fi

echo ""
echo -e "  ${GREEN}[✓]${RESET} Running Claude Code in container ${BOLD}${CONTAINER_NAME}${RESET}..."
if [ $# -gt 0 ]; then
    echo -e "  ${CYAN}→${RESET}  Arguments: ${BOLD}$*${RESET}"
fi
echo ""

docker exec -it "${CONTAINER_NAME}" claude "$@"
