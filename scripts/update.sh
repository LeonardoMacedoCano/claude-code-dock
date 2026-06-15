#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
CONTAINER_NAME="claude-dock"
SKIP_BACKUP=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

for arg in "$@"; do
    case $arg in
        --skip-backup)
            SKIP_BACKUP=true
            ;;
        -h|--help)
            echo "Usage: $0 [--skip-backup]"
            echo ""
            echo "  --skip-backup    Skip automatic backup before updating"
            exit 0
            ;;
    esac
done

header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║             ClaudeDock — Update                     ║${RESET}"
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

detect_compose() {
    if docker compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        fail "Docker Compose not found."
    fi
}

check_current_status() {
    step "Checking current status..."

    if docker ps --filter "name=${CONTAINER_NAME}" --filter "status=running" | grep -q "${CONTAINER_NAME}"; then
        ok "Container ${CONTAINER_NAME} is running."
        CONTAINER_RUNNING=true
    else
        warn "Container ${CONTAINER_NAME} is not running."
        CONTAINER_RUNNING=false
    fi
}

run_backup() {
    if [ "${SKIP_BACKUP}" == "true" ]; then
        warn "Backup skipped (--skip-backup)"
        return
    fi

    step "Running automatic backup before updating..."

    if [ -f "${SCRIPT_DIR}/backup.sh" ]; then
        bash "${SCRIPT_DIR}/backup.sh" --quiet
        ok "Backup completed."
    else
        warn "backup.sh not found. Skipping backup."
    fi
}

stop_container() {
    step "Stopping current container..."

    cd "${PROJECT_DIR}"

    if [ "${CONTAINER_RUNNING}" == "true" ]; then
        ${COMPOSE_CMD} -f "${COMPOSE_FILE}" stop
        ok "Container stopped."
    else
        ok "Container was already stopped."
    fi
}

rebuild_image() {
    step "Rebuilding Docker image..."
    echo ""
    echo -e "  ${YELLOW}Using --no-cache to ensure the latest Claude Code version...${RESET}"
    echo ""

    cd "${PROJECT_DIR}"
    ${COMPOSE_CMD} -f "${COMPOSE_FILE}" build --no-cache

    ok "Image rebuilt successfully."
}

start_container() {
    step "Starting updated container..."

    cd "${PROJECT_DIR}"
    ${COMPOSE_CMD} -f "${COMPOSE_FILE}" up -d

    sleep 3

    if docker ps --filter "name=${CONTAINER_NAME}" --filter "status=running" | grep -q "${CONTAINER_NAME}"; then
        ok "Container ${BOLD}${CONTAINER_NAME}${RESET} updated and running."
    else
        fail "Container did not start after update. Check logs: ./scripts/logs.sh"
    fi
}

check_version() {
    step "Checking installed Claude Code version..."

    NEW_VERSION=$(docker exec "${CONTAINER_NAME}" claude --version 2>/dev/null || echo "unavailable")
    ok "Claude Code version: ${BOLD}${NEW_VERSION}${RESET}"
}

cleanup_old_images() {
    step "Removing unused old Docker images..."

    docker image prune -f --filter "label=org.opencontainers.image.title=ClaudeDock" 2>/dev/null || true
    ok "Cleanup done."
}

print_result() {
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}║           Update Completed Successfully!             ║${RESET}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  To reconnect to Claude Code:"
    echo -e "  ${BOLD}./scripts/attach.sh${RESET}"
    echo ""
}

main() {
    header
    detect_compose
    check_current_status
    run_backup
    stop_container
    rebuild_image
    start_container
    check_version
    cleanup_old_images
    print_result
}

main "$@"
