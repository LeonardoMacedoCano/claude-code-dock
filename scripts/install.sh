#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
ENV_FILE="${PROJECT_DIR}/.env"
ENV_EXAMPLE="${PROJECT_DIR}/.env.example"
CONTAINER_NAME="claude-code-dock"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║             ClaudeCodeDock — Installation               ║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

step() {
    echo -e "${CYAN}[→]${RESET} ${BOLD}$1${RESET}"
}

ok() {
    echo -e "${GREEN}[✓]${RESET} $1"
}

warn() {
    echo -e "${YELLOW}[⚠]${RESET} $1"
}

fail() {
    echo -e "${RED}[✗]${RESET} $1"
    exit 1
}

check_docker() {
    step "Checking Docker..."

    if ! command -v docker &>/dev/null; then
        fail "Docker not found. Install it at: https://docs.docker.com/get-docker/"
    fi

    if ! docker info &>/dev/null; then
        fail "Docker daemon is not running. Start Docker and try again."
    fi

    DOCKER_VERSION=$(docker --version | awk '{print $3}' | tr -d ',')
    ok "Docker found: ${DOCKER_VERSION}"
}

check_docker_compose() {
    step "Checking Docker Compose..."

    # Support both plugin (docker compose) and standalone (docker-compose)
    if docker compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
        COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "unknown")
        ok "Docker Compose (plugin) found: ${COMPOSE_VERSION}"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
        COMPOSE_VERSION=$(docker-compose --version | awk '{print $3}' | tr -d ',')
        ok "Docker Compose (standalone) found: ${COMPOSE_VERSION}"
    else
        fail "Docker Compose not found. Install it at: https://docs.docker.com/compose/install/"
    fi

    export COMPOSE_CMD
}

check_env() {
    step "Checking .env configuration..."

    if [ ! -f "${ENV_FILE}" ]; then
        warn ".env file not found."

        if [ -f "${ENV_EXAMPLE}" ]; then
            echo ""
            echo -e "  Copying .env.example to .env..."
            cp "${ENV_EXAMPLE}" "${ENV_FILE}"
            echo ""
            echo -e "  ${YELLOW}ACTION REQUIRED:${RESET}"
            echo -e "  Edit the ${BOLD}.env${RESET} file and configure the main variables:"
            echo ""
            echo -e "  ${CYAN}nano ${ENV_FILE}${RESET}"
            echo ""
            echo -e "  Example (Unraid):"
            echo -e "  ${BOLD}WORKSPACE_PATH=/mnt/user/projects${RESET}"
            echo -e "  ${BOLD}CONFIG_PATH=/mnt/user/appdata/claude-code-dock/config${RESET}"
            echo ""
            read -r -p "  Press Enter after editing .env to continue (or Ctrl+C to cancel)..."
        else
            fail ".env.example also not found. Clone the repository again."
        fi
    fi

    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a

    ok ".env file loaded."

    if [ -z "${WORKSPACE_PATH:-}" ]; then
        fail "WORKSPACE_PATH not set in .env. Configure it before continuing."
    fi
    ok "WORKSPACE_PATH: ${WORKSPACE_PATH}"

    if [[ "${WORKSPACE_PATH}" == /* ]]; then
        if [ ! -d "${WORKSPACE_PATH}" ]; then
            warn "Directory ${WORKSPACE_PATH} does not exist on the host."
            echo ""
            read -r -p "  Create it now? [y/N]: " CREATE_DIR
            if [[ "${CREATE_DIR,,}" == "y" ]]; then
                mkdir -p "${WORKSPACE_PATH}"
                ok "Directory created: ${WORKSPACE_PATH}"
            else
                warn "Continuing anyway, but the workspace will be empty."
            fi
        else
            ok "Workspace exists: ${WORKSPACE_PATH}"
        fi
    fi

    if [ -n "${CONFIG_PATH:-}" ]; then
        mkdir -p "${CONFIG_PATH}"
        ok "CONFIG_PATH: ${CONFIG_PATH}"
    fi

    if [ -n "${CLAUDE_SOURCE_PATH:-}" ]; then
        ok "CLAUDE_SOURCE_PATH: ${CLAUDE_SOURCE_PATH}"
    fi

    ok "AUTO_START_MODE: ${AUTO_START_MODE:-interactive}"
}

setup_directories() {
    step "Creating project directory structure..."

    mkdir -p "${PROJECT_DIR}/config"
    touch "${PROJECT_DIR}/config/.gitkeep"
    ok "Directory config/ created"

    mkdir -p "${PROJECT_DIR}/workspaces"
    touch "${PROJECT_DIR}/workspaces/.gitkeep"
    ok "Directory workspaces/ created"
}

build_image() {
    step "Building Docker image..."
    echo ""
    echo -e "  ${YELLOW}This may take a few minutes on first run...${RESET}"
    echo ""

    cd "${PROJECT_DIR}"
    ${COMPOSE_CMD} -f "${COMPOSE_FILE}" build

    ok "Image built successfully."
}

start_services() {
    step "Starting ClaudeCodeDock..."

    cd "${PROJECT_DIR}"
    ${COMPOSE_CMD} -f "${COMPOSE_FILE}" up -d

    ok "Container started."

    sleep 2

    if docker ps --filter "name=${CONTAINER_NAME}" --filter "status=running" | grep -q "${CONTAINER_NAME}"; then
        ok "Container ${BOLD}${CONTAINER_NAME}${RESET} is running."
    else
        warn "Container may not have started correctly."
        echo ""
        docker ps -a --filter "name=${CONTAINER_NAME}"
    fi
}

print_next_steps() {
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}║         Installation Completed Successfully!         ║${RESET}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  ${BOLD}Next steps:${RESET}"
    echo ""
    echo -e "  ${CYAN}1.${RESET} Connect to Claude Code:"
    echo -e "     ${BOLD}./scripts/attach.sh${RESET}"
    echo ""
    echo -e "  ${CYAN}2.${RESET} Log in when prompted by Claude Code."
    echo -e "     Credentials are saved in ${BOLD}./config/${RESET} and persist across restarts."
    echo ""
    echo -e "  ${CYAN}3.${RESET} To disconnect without stopping Claude:"
    echo -e "     Press ${BOLD}Ctrl+B${RESET} then ${BOLD}D${RESET}"
    echo ""
    echo -e "  ${CYAN}4.${RESET} To open a shell in the container (without touching Claude):"
    echo -e "     ${BOLD}./scripts/shell.sh${RESET}"
    echo ""
    echo -e "  ${CYAN}5.${RESET} To view logs:"
    echo -e "     ${BOLD}./scripts/logs.sh${RESET}"
    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

main() {
    header
    check_docker
    check_docker_compose
    check_env
    setup_directories
    build_image
    start_services
    print_next_steps
}

main "$@"
