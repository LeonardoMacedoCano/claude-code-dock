#!/usr/bin/env bash

set -euo pipefail

CONTAINER_NAME="claude-dock"

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
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║          ClaudeDock — Interactive Shell             ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${GREEN}[✓]${RESET} Connecting to container ${BOLD}${CONTAINER_NAME}${RESET}..."
echo ""
echo -e "  ${YELLOW}NOTE:${RESET} This is a separate shell from Claude Code."
echo -e "  The Claude Code session continues running normally."
echo ""
echo -e "  Type ${BOLD}exit${RESET} to leave the shell and return to the host."
echo ""
echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

docker exec -it "${CONTAINER_NAME}" /bin/bash

echo ""
echo -e "  ${GREEN}[✓]${RESET} Shell closed. Back on host."
echo ""
