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
echo -e "  ${GREEN}[✓]${RESET} Running Claude Remote Control in container ${BOLD}${CONTAINER_NAME}${RESET}..."
if [ $# -gt 0 ]; then
    echo -e "  ${CYAN}→${RESET}  Extra arguments: ${BOLD}$*${RESET}"
fi
echo ""
echo -e "  ${YELLOW}To run Remote Control as the main process, set:${RESET}"
echo -e "  ${BOLD}AUTO_START_MODE=remote${RESET} in .env"
echo ""

# --user node: the container starts as root by default (see
# entrypoint.sh's PUID/PGID step-down); claude must never run as root.
docker exec -it --user node "${CONTAINER_NAME}" claude --remote-control "$@"
