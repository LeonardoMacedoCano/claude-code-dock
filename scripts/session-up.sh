#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║             claude-code-dock — Session Up             ║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

step() { echo -e "${CYAN}[→]${RESET} ${BOLD}$1${RESET}"; }
ok()   { echo -e "${GREEN}[✓]${RESET} $1"; }
warn() { echo -e "${YELLOW}[⚠]${RESET} $1"; }
fail() { echo -e "${RED}[✗]${RESET} $1" >&2; exit 1; }

detect_compose() {
    if docker compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        fail "Docker Compose not found."
    fi
}

header

SESSION_NAME="${1:-}"

if [ -z "${SESSION_NAME}" ]; then
    echo "Usage: $0 <session-name>"
    echo ""
    echo -e "  Starts (or recreates) the session created by ${BOLD}./scripts/new-session.sh <session-name>${RESET},"
    echo -e "  binding it to its own \`.env.<session-name>\` and its own Compose project"
    echo -e "  name -- so it never gets started under the wrong .env by mistake."
    echo ""
    echo -e "  Available sessions:"
    for f in "${PROJECT_DIR}"/.env.*; do
        [ -f "$f" ] || continue
        NAME="$(basename "$f")"
        [ "${NAME}" = ".env.example" ] && continue
        echo -e "    ${CYAN}${NAME#.env.}${RESET}"
    done
    exit 1
fi

ENV_FILE="${PROJECT_DIR}/.env.${SESSION_NAME}"

if [ ! -f "${ENV_FILE}" ]; then
    fail ".env.${SESSION_NAME} not found. Create it first with: ./scripts/new-session.sh ${SESSION_NAME}"
fi

detect_compose

step "Starting session '${SESSION_NAME}'..."

cd "${PROJECT_DIR}"
${COMPOSE_CMD} --env-file "${ENV_FILE}" -p "claude-${SESSION_NAME}" -f "${COMPOSE_FILE}" up -d

CONTAINER_NAME=$(grep "^CONTAINER_NAME=" "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
CONTAINER_NAME="${CONTAINER_NAME:-claude-code-dock-${SESSION_NAME}}"

ok "Session '${SESSION_NAME}' started as container ${BOLD}${CONTAINER_NAME}${RESET}."

echo ""
echo -e "  ${CYAN}To attach:${RESET}"
echo -e "  ${BOLD}docker exec -it ${CONTAINER_NAME} tmux attach-session -t main${RESET}"
echo ""
echo -e "  ${CYAN}To view status:${RESET}"
echo -e "  ${BOLD}CONTAINER_NAME=${CONTAINER_NAME} ./scripts/status.sh${RESET}"
echo ""
