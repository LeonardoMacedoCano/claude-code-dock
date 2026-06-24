#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${PROJECT_DIR}/.env"

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_NAME="claude-code-dock-backup-${TIMESTAMP}"
OUTPUT_DIR="${PROJECT_DIR}/backups"
INCLUDE_WORKSPACE=false
QUIET=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

while [[ $# -gt 0 ]]; do
    case $1 in
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --include-workspace)
            INCLUDE_WORKSPACE=true
            shift
            ;;
        --quiet)
            QUIET=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--output DIR] [--include-workspace] [--quiet]"
            echo ""
            echo "  --output DIR          Backup destination directory (default: ./backups/)"
            echo "  --include-workspace   Include external workspace in backup"
            echo "  --quiet               Quiet mode (for use by other scripts)"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

log() {
    if [ "${QUIET}" == "false" ]; then
        echo -e "$1"
    fi
}

header() {
    log ""
    log "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    log "${CYAN}${BOLD}║              ClaudeCodeDock — Backup                    ║${RESET}"
    log "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
    log ""
}

step() {
    log "${CYAN}[→]${RESET} ${BOLD}$1${RESET}"
}

ok() {
    log "${GREEN}[✓]${RESET} $1"
}

warn() {
    log "${YELLOW}[⚠]${RESET} $1"
}

fail() {
    echo -e "${RED}[✗]${RESET} $1" >&2
    exit 1
}

setup_output_dir() {
    step "Preparing backup directory: ${OUTPUT_DIR}"

    mkdir -p "${OUTPUT_DIR}"

    if [ ! -w "${OUTPUT_DIR}" ]; then
        fail "No write permission in: ${OUTPUT_DIR}"
    fi

    ok "Backup directory ready."
}

backup_config() {
    step "Checking configuration (./config/)..."

    CONFIG_DIR="${PROJECT_DIR}/config"

    if [ ! -d "${CONFIG_DIR}" ]; then
        warn "Directory ./config/ not found. Skipping."
        return
    fi

    if [ -z "$(ls -A "${CONFIG_DIR}" 2>/dev/null)" ]; then
        warn "Directory ./config/ is empty (no credentials saved yet). Skipping."
        return
    fi

    ok "Configuration found in: ${CONFIG_DIR}"
}

load_workspace_path() {
    WORKSPACE_PATH=""

    if [ -f "${ENV_FILE}" ]; then
        WORKSPACE_PATH=$(grep "^WORKSPACE_PATH=" "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")
    fi

    if [[ "${WORKSPACE_PATH}" == ./* ]]; then
        WORKSPACE_PATH="${PROJECT_DIR}/${WORKSPACE_PATH#./}"
    fi
}

create_backup_archive() {
    BACKUP_FILE="${OUTPUT_DIR}/${BACKUP_NAME}.tar.gz"

    step "Creating backup archive: ${BACKUP_NAME}.tar.gz"

    INCLUDE_ITEMS=()

    if [ -d "${PROJECT_DIR}/config" ] && [ -n "$(ls -A "${PROJECT_DIR}/config" 2>/dev/null)" ]; then
        INCLUDE_ITEMS+=("config")
    fi

    if [ -d "${PROJECT_DIR}/workspaces" ] && [ -n "$(ls -A "${PROJECT_DIR}/workspaces" 2>/dev/null)" ]; then
        INCLUDE_ITEMS+=("workspaces")
    fi

    if [ "${INCLUDE_WORKSPACE}" == "true" ] && [ -n "${WORKSPACE_PATH}" ]; then
        if [ -d "${WORKSPACE_PATH}" ]; then
            step "Including external workspace: ${WORKSPACE_PATH}"
        else
            warn "External workspace not found: ${WORKSPACE_PATH}"
        fi
    fi

    if [ ${#INCLUDE_ITEMS[@]} -eq 0 ] && [ "${INCLUDE_WORKSPACE}" == "false" ]; then
        warn "Nothing to back up. No data found."
        exit 0
    fi

    cd "${PROJECT_DIR}"

    TAR_ARGS=(-czf "${BACKUP_FILE}")

    for item in "${INCLUDE_ITEMS[@]}"; do
        TAR_ARGS+=("${item}")
    done

    if [ "${INCLUDE_WORKSPACE}" == "true" ] && [ -n "${WORKSPACE_PATH}" ] && [ -d "${WORKSPACE_PATH}" ]; then
        tar -czf "${BACKUP_FILE}" "${INCLUDE_ITEMS[@]+"${INCLUDE_ITEMS[@]}"}" \
            -C "$(dirname "${WORKSPACE_PATH}")" "$(basename "${WORKSPACE_PATH}")" 2>/dev/null || \
        tar "${TAR_ARGS[@]}" 2>/dev/null
    else
        if [ ${#INCLUDE_ITEMS[@]} -gt 0 ]; then
            tar "${TAR_ARGS[@]}"
        fi
    fi

    BACKUP_SIZE=$(du -sh "${BACKUP_FILE}" 2>/dev/null | cut -f1 || echo "unknown")
    ok "Backup created: ${BOLD}${BACKUP_FILE}${RESET} (${BACKUP_SIZE})"
}

manage_old_backups() {
    step "Checking existing backups..."

    BACKUP_COUNT=$(ls -1 "${OUTPUT_DIR}"/claude-code-dock-backup-*.tar.gz 2>/dev/null | wc -l)
    ok "Total backups in ${OUTPUT_DIR}: ${BACKUP_COUNT}"

    if [ "${BACKUP_COUNT}" -gt 10 ]; then
        warn "More than 10 backups found. Removing oldest ones..."
        ls -1t "${OUTPUT_DIR}"/claude-code-dock-backup-*.tar.gz | tail -n +11 | xargs rm -f
        ok "Old backups removed."
    fi
}

print_result() {
    log ""
    log "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    log "${GREEN}${BOLD}║           Backup Completed Successfully!             ║${RESET}"
    log "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
    log ""
    log "  File: ${BOLD}${BACKUP_FILE}${RESET}"
    log ""
    log "  To restore:"
    log "  ${BOLD}./scripts/restore.sh ${BACKUP_FILE}${RESET}"
    log ""
}

main() {
    header
    setup_output_dir
    backup_config
    load_workspace_path
    create_backup_archive
    manage_old_backups
    print_result
}

main "$@"
