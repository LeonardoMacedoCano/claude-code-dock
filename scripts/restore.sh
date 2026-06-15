#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
DEFAULT_BACKUP_DIR="${PROJECT_DIR}/backups"
CONTAINER_NAME="claude-dock"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║             ClaudeDock — Restore                    ║${RESET}"
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
    echo -e "${RED}[✗]${RESET} $1" >&2
    exit 1
}

list_backups() {
    echo ""
    echo -e "${CYAN}${BOLD}Available backups in ${DEFAULT_BACKUP_DIR}:${RESET}"
    echo ""

    if [ ! -d "${DEFAULT_BACKUP_DIR}" ]; then
        echo -e "  ${YELLOW}Backup directory not found: ${DEFAULT_BACKUP_DIR}${RESET}"
        echo ""
        exit 0
    fi

    BACKUPS=$(ls -1t "${DEFAULT_BACKUP_DIR}"/claude-dock-backup-*.tar.gz 2>/dev/null || echo "")

    if [ -z "${BACKUPS}" ]; then
        echo -e "  ${YELLOW}No backups found.${RESET}"
        echo ""
        echo -e "  Create a backup with:"
        echo -e "  ${BOLD}./scripts/backup.sh${RESET}"
        echo ""
        exit 0
    fi

    INDEX=1
    while IFS= read -r backup_file; do
        BACKUP_SIZE=$(du -sh "${backup_file}" 2>/dev/null | cut -f1 || echo "?")
        echo -e "  ${CYAN}[${INDEX}]${RESET} $(basename "${backup_file}") ${YELLOW}(${BACKUP_SIZE})${RESET}"
        INDEX=$((INDEX + 1))
    done <<< "${BACKUPS}"

    echo ""
    echo -e "  Usage: ${BOLD}./scripts/restore.sh <backup-path>${RESET}"
    echo ""
    exit 0
}

BACKUP_FILE=""

case "${1:-}" in
    --list|-l)
        list_backups
        ;;
    -h|--help)
        echo "Usage: $0 <backup-file.tar.gz>"
        echo "       $0 --list    (list available backups)"
        exit 0
        ;;
    "")
        LATEST=$(ls -1t "${DEFAULT_BACKUP_DIR}"/claude-dock-backup-*.tar.gz 2>/dev/null | head -1 || echo "")
        if [ -z "${LATEST}" ]; then
            echo ""
            echo -e "${RED}[✗]${RESET} No backup found and no file specified."
            echo ""
            echo -e "  Usage: ${BOLD}$0 <backup-file.tar.gz>${RESET}"
            echo -e "  List:  ${BOLD}$0 --list${RESET}"
            echo ""
            exit 1
        fi

        echo ""
        warn "No file specified. Most recent backup found:"
        echo -e "  ${BOLD}${LATEST}${RESET}"
        echo ""
        read -r -p "  Restore this backup? [y/N]: " USE_LATEST
        if [[ "${USE_LATEST,,}" != "y" ]]; then
            echo ""
            echo -e "  Cancelled."
            exit 0
        fi
        BACKUP_FILE="${LATEST}"
        ;;
    *)
        BACKUP_FILE="$1"
        ;;
esac

header

step "Validating backup file..."

if [[ "${BACKUP_FILE}" != /* ]]; then
    BACKUP_FILE="${PROJECT_DIR}/${BACKUP_FILE}"
fi

if [ ! -f "${BACKUP_FILE}" ]; then
    fail "Backup file not found: ${BACKUP_FILE}"
fi

BACKUP_SIZE=$(du -sh "${BACKUP_FILE}" 2>/dev/null | cut -f1 || echo "unknown")
ok "File found: ${BOLD}$(basename "${BACKUP_FILE}")${RESET} (${BACKUP_SIZE})"

step "Verifying backup integrity..."
if tar -tzf "${BACKUP_FILE}" &>/dev/null; then
    ok "File is intact."
else
    fail "Backup file is corrupted: ${BACKUP_FILE}"
fi

echo ""
echo -e "  ${BOLD}Backup contents:${RESET}"
tar -tzf "${BACKUP_FILE}" | head -20 | while read -r line; do
    echo -e "    ${CYAN}→${RESET} ${line}"
done
echo ""

echo -e "  ${RED}${BOLD}WARNING: This operation will overwrite current data!${RESET}"
echo ""

CONTAINER_RUNNING=false
if docker ps --filter "name=${CONTAINER_NAME}" --filter "status=running" | grep -q "${CONTAINER_NAME}" 2>/dev/null; then
    CONTAINER_RUNNING=true
    warn "Container ${CONTAINER_NAME} is running and will be stopped during restore."
fi

echo ""
read -r -p "  Confirm restore? CURRENT DATA WILL BE OVERWRITTEN [y/N]: " CONFIRM

if [[ "${CONFIRM,,}" != "y" ]]; then
    echo ""
    echo -e "  Restore cancelled."
    exit 0
fi

if [ "${CONTAINER_RUNNING}" == "true" ]; then
    step "Stopping container ${CONTAINER_NAME}..."

    if docker compose version &>/dev/null 2>&1; then
        cd "${PROJECT_DIR}" && docker compose stop 2>/dev/null || docker stop "${CONTAINER_NAME}" 2>/dev/null || true
    else
        docker stop "${CONTAINER_NAME}" 2>/dev/null || true
    fi

    ok "Container stopped."
fi

step "Creating safety backup of current data..."

SAFETY_BACKUP="${PROJECT_DIR}/backups/pre-restore-safety-$(date +"%Y-%m-%d_%H-%M-%S").tar.gz"
mkdir -p "${PROJECT_DIR}/backups"

SAFETY_ITEMS=()
[ -d "${PROJECT_DIR}/config" ] && [ -n "$(ls -A "${PROJECT_DIR}/config" 2>/dev/null)" ] && SAFETY_ITEMS+=("config")
[ -d "${PROJECT_DIR}/workspaces" ] && [ -n "$(ls -A "${PROJECT_DIR}/workspaces" 2>/dev/null)" ] && SAFETY_ITEMS+=("workspaces")

if [ ${#SAFETY_ITEMS[@]} -gt 0 ]; then
    cd "${PROJECT_DIR}"
    tar -czf "${SAFETY_BACKUP}" "${SAFETY_ITEMS[@]}" 2>/dev/null && \
        ok "Safety backup created: ${BOLD}$(basename "${SAFETY_BACKUP}")${RESET}" || \
        warn "Could not create safety backup. Continuing anyway."
else
    warn "Nothing to safety-backup. Directories are empty."
fi

step "Restoring backup..."

cd "${PROJECT_DIR}"
tar -xzf "${BACKUP_FILE}" -C "${PROJECT_DIR}"

ok "Data restored successfully."

if [ "${CONTAINER_RUNNING}" == "true" ]; then
    step "Restarting container ${CONTAINER_NAME}..."

    if docker compose version &>/dev/null 2>&1; then
        cd "${PROJECT_DIR}" && docker compose up -d 2>/dev/null || true
    else
        docker start "${CONTAINER_NAME}" 2>/dev/null || true
    fi

    ok "Container restarted."
fi

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║         Restore Completed Successfully!              ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Backup restored: ${BOLD}$(basename "${BACKUP_FILE}")${RESET}"
echo ""
echo -e "  ${YELLOW}Safety backup of previous data:${RESET}"
echo -e "  ${BOLD}$(basename "${SAFETY_BACKUP:-no-backup}")${RESET}"
echo ""

if [ "${CONTAINER_RUNNING}" == "true" ]; then
    echo -e "  Connect to Claude Code:"
    echo -e "  ${BOLD}./scripts/attach.sh${RESET}"
    echo ""
fi
