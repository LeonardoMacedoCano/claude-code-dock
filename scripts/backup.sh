#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${PROJECT_DIR}/.env"

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
OUTPUT_DIR="${PROJECT_DIR}/backups"
INCLUDE_WORKSPACE=false
QUIET=false
MASKED_ENV_TMPDIR=""

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
    log "${CYAN}${BOLD}║              claude-code-dock — Backup               ║${RESET}"
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

load_env() {
    CONFIG_BASE_PATH=""
    REMOTE_SESSION_NAME=""
    WORKSPACE_PATH=""

    if [ -f "${ENV_FILE}" ]; then
        CONFIG_BASE_PATH=$(grep "^CONFIG_BASE_PATH=" "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' | tr -d "'" 2>/dev/null || echo "")
        REMOTE_SESSION_NAME=$(grep "^REMOTE_SESSION_NAME=" "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' | tr -d "'" 2>/dev/null || echo "")
        WORKSPACE_PATH=$(grep "^WORKSPACE_PATH=" "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' | tr -d "'" 2>/dev/null || echo "")
    fi

    if [[ "${CONFIG_BASE_PATH}" == ./* ]]; then
        CONFIG_BASE_PATH="${PROJECT_DIR}/${CONFIG_BASE_PATH#./}"
    fi

    if [[ "${WORKSPACE_PATH}" == ./* ]]; then
        WORKSPACE_PATH="${PROJECT_DIR}/${WORKSPACE_PATH#./}"
    fi

    if [ -n "${CONFIG_BASE_PATH}" ] && [ -n "${REMOTE_SESSION_NAME}" ]; then
        CONFIG_DIR="${CONFIG_BASE_PATH}/${REMOTE_SESSION_NAME}"
    else
        CONFIG_DIR="${PROJECT_DIR}/configs/default"
        warn "CONFIG_BASE_PATH or REMOTE_SESSION_NAME not set — using fallback: ${CONFIG_DIR}"
    fi

    if [ -n "${REMOTE_SESSION_NAME}" ]; then
        BACKUP_NAME="claude-code-dock-${REMOTE_SESSION_NAME}-backup-${TIMESTAMP}"
        BACKUP_PATTERN="claude-code-dock-${REMOTE_SESSION_NAME}-backup-*.tar.gz"
    else
        BACKUP_NAME="claude-code-dock-backup-${TIMESTAMP}"
        BACKUP_PATTERN="claude-code-dock-backup-*.tar.gz"
    fi
}

setup_output_dir() {
    step "Preparing backup directory: ${OUTPUT_DIR}"

    mkdir -p "${OUTPUT_DIR}"

    if [ ! -w "${OUTPUT_DIR}" ]; then
        fail "No write permission in: ${OUTPUT_DIR}"
    fi

    ok "Backup directory ready."
}

check_config() {
    step "Checking session config (${CONFIG_DIR})..."

    if [ ! -d "${CONFIG_DIR}" ]; then
        warn "Directory not found: ${CONFIG_DIR}. Skipping."
        return
    fi

    if [ -z "$(ls -A "${CONFIG_DIR}" 2>/dev/null)" ]; then
        warn "Directory is empty (no credentials saved yet): ${CONFIG_DIR}. Skipping."
        return
    fi

    ok "Session config found: ${CONFIG_DIR}"
}

backup_env() {
    if [ ! -f "${ENV_FILE}" ]; then
        return
    fi

    step "Backing up .env (secrets masked)..."

    MASKED_ENV_TMPDIR=$(mktemp -d)
    grep -vE "^(GITHUB_TOKEN|CLAUDE_API_KEY)\s*=" "${ENV_FILE}" \
        > "${MASKED_ENV_TMPDIR}/.env.backup" 2>/dev/null || true
    ok ".env backed up (GITHUB_TOKEN and secrets excluded — included in archive)"
}

create_backup_archive() {
    BACKUP_FILE="${OUTPUT_DIR}/${BACKUP_NAME}.tar.gz"

    step "Creating backup archive: ${BACKUP_NAME}.tar.gz"

    local has_config=false
    local has_workspace=false

    if [ -d "${CONFIG_DIR}" ] && [ -n "$(ls -A "${CONFIG_DIR}" 2>/dev/null)" ]; then
        has_config=true
    fi

    if [ -d "${PROJECT_DIR}/workspaces" ] && [ -n "$(ls -A "${PROJECT_DIR}/workspaces" 2>/dev/null)" ]; then
        has_workspace=true
    fi

    if [ "${has_config}" == "false" ] && [ "${has_workspace}" == "false" ] && [ "${INCLUDE_WORKSPACE}" == "false" ]; then
        warn "Nothing to back up. No data found."
        exit 0
    fi

    local tar_cmd=("tar" "-czf" "${BACKUP_FILE}")

    if [ "${has_config}" == "true" ]; then
        tar_cmd+=("-C" "$(dirname "${CONFIG_DIR}")" "$(basename "${CONFIG_DIR}")")
    fi

    if [ "${has_workspace}" == "true" ]; then
        tar_cmd+=("-C" "${PROJECT_DIR}" "workspaces")
    fi

    if [ "${INCLUDE_WORKSPACE}" == "true" ] && [ -n "${WORKSPACE_PATH}" ]; then
        if [ -d "${WORKSPACE_PATH}" ]; then
            step "Including external workspace: ${WORKSPACE_PATH}"
            tar_cmd+=("-C" "$(dirname "${WORKSPACE_PATH}")" "$(basename "${WORKSPACE_PATH}")")
        else
            warn "External workspace not found: ${WORKSPACE_PATH}"
        fi
    fi

    if [ -n "${MASKED_ENV_TMPDIR}" ] && [ -f "${MASKED_ENV_TMPDIR}/.env.backup" ]; then
        tar_cmd+=("-C" "${MASKED_ENV_TMPDIR}" ".env.backup")
    fi

    "${tar_cmd[@]}"

    [ -n "${MASKED_ENV_TMPDIR}" ] && rm -rf "${MASKED_ENV_TMPDIR}"

    BACKUP_SIZE=$(du -sh "${BACKUP_FILE}" 2>/dev/null | cut -f1 || echo "unknown")
    ok "Backup created: ${BOLD}${BACKUP_FILE}${RESET} (${BACKUP_SIZE})"
}

manage_old_backups() {
    step "Checking existing backups..."

    RETENTION=10
    if [ -f "${ENV_FILE}" ]; then
        ENV_RETENTION=$(grep "^BACKUP_RETENTION=" "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' | tr -d "'" 2>/dev/null || echo "")
        [ -n "${ENV_RETENTION}" ] && RETENTION="${ENV_RETENTION}"
    fi
    RETENTION="${BACKUP_RETENTION:-${RETENTION}}"

    if ! [[ "${RETENTION}" =~ ^[0-9]+$ ]] || [ "${RETENTION}" -lt 1 ]; then
        warn "BACKUP_RETENTION='${RETENTION}' is not a valid positive integer — using default of 10."
        RETENTION=10
    fi

    BACKUP_COUNT=$(ls -1 "${OUTPUT_DIR}"/${BACKUP_PATTERN} 2>/dev/null | wc -l)
    ok "Total backups in ${OUTPUT_DIR}: ${BACKUP_COUNT} (retention: ${RETENTION})"

    if [ "${BACKUP_COUNT}" -gt "${RETENTION}" ]; then
        warn "More than ${RETENTION} backups found. Removing oldest ones..."
        ls -1t "${OUTPUT_DIR}"/${BACKUP_PATTERN} | tail -n +"$((RETENTION + 1))" | xargs rm -f
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
    load_env
    setup_output_dir
    check_config
    backup_env
    create_backup_archive
    manage_old_backups
    print_result
}

main "$@"
