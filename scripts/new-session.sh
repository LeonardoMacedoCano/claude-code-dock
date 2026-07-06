#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${PROJECT_DIR}/.env"
ENV_EXAMPLE="${PROJECT_DIR}/.env.example"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║            claude-code-dock — New Session            ║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

step() { echo -e "${CYAN}[→]${RESET} ${BOLD}$1${RESET}"; }
ok()   { echo -e "${GREEN}[✓]${RESET} $1"; }
warn() { echo -e "${YELLOW}[⚠]${RESET} $1"; }
fail() { echo -e "${RED}[✗]${RESET} $1" >&2; exit 1; }

header

SESSION_NAME="${1:-}"

if [ -z "${SESSION_NAME}" ]; then
    echo -e "  Enter a unique name for this session."
    echo -e "  Used as: config subdirectory, backup prefix, container name suffix."
    echo -e "  Allowed: letters, numbers, hyphens, underscores. Example: ${BOLD}finances${RESET}"
    echo ""
    read -r -p "  Session name: " SESSION_NAME
fi

if [ -z "${SESSION_NAME}" ]; then
    fail "Session name cannot be empty."
fi

if [[ ! "${SESSION_NAME}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    fail "Invalid name '${SESSION_NAME}'. Use only letters, numbers, hyphens and underscores."
fi

NEW_ENV="${PROJECT_DIR}/.env.${SESSION_NAME}"

if [ -f "${NEW_ENV}" ]; then
    warn ".env.${SESSION_NAME} already exists."
    read -r -p "  Overwrite? [y/N]: " OVERWRITE
    if [[ "${OVERWRITE,,}" != "y" ]]; then
        echo ""
        echo -e "  Cancelled."
        exit 0
    fi
fi

SOURCE_ENV="${ENV_FILE}"
if [ ! -f "${SOURCE_ENV}" ]; then
    SOURCE_ENV="${ENV_EXAMPLE}"
    if [ ! -f "${SOURCE_ENV}" ]; then
        fail "Neither .env nor .env.example found. Clone the repository again."
    fi
    warn "No .env found — using .env.example as base. Review the generated file before starting."
fi

step "Creating .env.${SESSION_NAME} from ${SOURCE_ENV##*/}..."

cp "${SOURCE_ENV}" "${NEW_ENV}"

if grep -q "^REMOTE_SESSION_NAME=" "${NEW_ENV}"; then
    sed -i "s|^REMOTE_SESSION_NAME=.*|REMOTE_SESSION_NAME=${SESSION_NAME}|" "${NEW_ENV}"
else
    echo "REMOTE_SESSION_NAME=${SESSION_NAME}" >> "${NEW_ENV}"
fi

CONTAINER_NAME_VALUE="claude-code-dock-${SESSION_NAME}"
if grep -q "^CONTAINER_NAME=" "${NEW_ENV}"; then
    sed -i "s|^CONTAINER_NAME=.*|CONTAINER_NAME=${CONTAINER_NAME_VALUE}|" "${NEW_ENV}"
else
    echo "CONTAINER_NAME=${CONTAINER_NAME_VALUE}" >> "${NEW_ENV}"
fi

ok ".env.${SESSION_NAME} created"

step "Creating session config directory..."

CONFIG_BASE_PATH=""
if [ -f "${NEW_ENV}" ]; then
    CONFIG_BASE_PATH=$(grep "^CONFIG_BASE_PATH=" "${NEW_ENV}" | cut -d'=' -f2- | tr -d '"' | tr -d "'" 2>/dev/null || echo "")
fi

if [ -z "${CONFIG_BASE_PATH}" ]; then
    CONFIG_BASE_PATH="${PROJECT_DIR}/configs"
elif [[ "${CONFIG_BASE_PATH}" == ./* ]]; then
    CONFIG_BASE_PATH="${PROJECT_DIR}/${CONFIG_BASE_PATH#./}"
fi

CONFIG_DIR="${CONFIG_BASE_PATH}/${SESSION_NAME}"
mkdir -p "${CONFIG_DIR}"
ok "Config directory: ${CONFIG_DIR}"

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║            Session Created Successfully!             ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Session:${RESET}    ${SESSION_NAME}"
echo -e "  ${BOLD}Env file:${RESET}   .env.${SESSION_NAME}"
echo -e "  ${BOLD}Config:${RESET}     ${CONFIG_DIR}"
echo -e "  ${BOLD}Container:${RESET}  ${CONTAINER_NAME_VALUE}"
echo ""
echo -e "  ${YELLOW}Before starting, review the env file:${RESET}"
echo -e "  ${BOLD}nano .env.${SESSION_NAME}${RESET}"
echo ""
echo -e "  ${CYAN}To start this session:${RESET}"
echo -e "  ${BOLD}docker compose --env-file .env.${SESSION_NAME} up -d${RESET}"
echo ""
echo -e "  ${CYAN}To attach:${RESET}"
echo -e "  ${BOLD}docker exec -it ${CONTAINER_NAME_VALUE} tmux attach-session -t main${RESET}"
echo ""
echo -e "  ${CYAN}To view status:${RESET}"
echo -e "  ${BOLD}CONTAINER_NAME=${CONTAINER_NAME_VALUE} ./scripts/status.sh${RESET}"
echo ""
