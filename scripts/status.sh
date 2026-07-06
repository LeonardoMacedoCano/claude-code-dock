#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${PROJECT_DIR}/.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

if [ -f "${ENV_FILE}" ]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
fi
CONTAINER_NAME="${CONTAINER_NAME:-claude-code-dock}"
REMOTE_SESSION_NAME="${REMOTE_SESSION_NAME:-}"
CONFIG_BASE_PATH="${CONFIG_BASE_PATH:-}"

if [ -n "${CONFIG_BASE_PATH}" ] && [ -n "${REMOTE_SESSION_NAME}" ]; then
    if [[ "${CONFIG_BASE_PATH}" == ./* ]]; then
        CONFIG_BASE_PATH="${PROJECT_DIR}/${CONFIG_BASE_PATH#./}"
    fi
    CONFIG_DIR="${CONFIG_BASE_PATH}/${REMOTE_SESSION_NAME}"
    BACKUP_PATTERN="claude-code-dock-${REMOTE_SESSION_NAME}-backup-*.tar.gz"
else
    CONFIG_DIR="${PROJECT_DIR}/configs/default"
    BACKUP_PATTERN="claude-code-dock-backup-*.tar.gz"
fi

header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║              claude-code-dock — Status               ║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

row() {
    local label="$1"
    local value="$2"
    local color="${3:-${RESET}}"
    printf "  ${BOLD}%-22s${RESET} ${color}%s${RESET}\n" "${label}" "${value}"
}

header

# --- Container ---
echo -e "  ${CYAN}Container${RESET}"

CONTAINER_STATUS=$(docker inspect --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "not found")
CONTAINER_HEALTH=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}' "${CONTAINER_NAME}" 2>/dev/null || echo "")
CONTAINER_UPTIME=$(docker inspect --format '{{.State.StartedAt}}' "${CONTAINER_NAME}" 2>/dev/null || echo "")

case "${CONTAINER_STATUS}" in
    running)   STATUS_COLOR="${GREEN}" ;;
    exited)    STATUS_COLOR="${RED}" ;;
    *)         STATUS_COLOR="${YELLOW}" ;;
esac

row "Container name:" "${CONTAINER_NAME}"
if [ -n "${REMOTE_SESSION_NAME}" ]; then
    row "Session ID:" "${REMOTE_SESSION_NAME}"
fi
row "Status:" "${CONTAINER_STATUS}" "${STATUS_COLOR}"

if [ -n "${CONTAINER_HEALTH}" ] && [ "${CONTAINER_HEALTH}" != "no healthcheck" ]; then
    case "${CONTAINER_HEALTH}" in
        healthy)   HEALTH_COLOR="${GREEN}" ;;
        unhealthy) HEALTH_COLOR="${RED}" ;;
        *)         HEALTH_COLOR="${YELLOW}" ;;
    esac
    row "Health:" "${CONTAINER_HEALTH}" "${HEALTH_COLOR}"
fi

if [ -n "${CONTAINER_UPTIME}" ] && [ "${CONTAINER_STATUS}" = "running" ]; then
    row "Started at:" "${CONTAINER_UPTIME}"
fi

echo ""

# --- Claude Code ---
if [ "${CONTAINER_STATUS}" = "running" ]; then
    echo -e "  ${CYAN}Claude Code${RESET}"
    CLAUDE_VERSION=$(docker exec "${CONTAINER_NAME}" cat /etc/claude-code-version 2>/dev/null || echo "unavailable")
    row "Version:" "${CLAUDE_VERSION}"

    if [ "${CLAUDE_VERSION}" != "unavailable" ] && command -v curl &>/dev/null; then
        # `|| true`: under `set -e`, a curl failure or a grep miss (both exit
        # non-zero) would otherwise abort this whole script instead of just
        # falling through to the "unavailable" branch below.
        LATEST_VERSION=$(curl -fsS --max-time 5 https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null \
            | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"' || true)
        if [ -n "${LATEST_VERSION}" ]; then
            if [ "${CLAUDE_VERSION}" = "${LATEST_VERSION}" ]; then
                row "Up to date:" "yes (latest: ${LATEST_VERSION})" "${GREEN}"
            else
                row "Update available:" "${LATEST_VERSION} (run ./scripts/update.sh)" "${YELLOW}"
            fi
        else
            row "Latest version:" "unavailable (npm registry unreachable)"
        fi
    fi

    MODE_ENV=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null \
        | grep "^AUTO_START_MODE=" | cut -d= -f2 || echo "unknown")
    row "Mode:" "${MODE_ENV:-interactive}"

    AUTO_APPROVE=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null \
        | grep "^CLAUDE_AUTO_APPROVE=" | cut -d= -f2 || echo "unknown")
    if [ "${AUTO_APPROVE}" = "true" ]; then
        row "Auto-approve:" "enabled (--dangerously-skip-permissions)" "${YELLOW}"
    else
        row "Auto-approve:" "disabled"
    fi

    echo ""
fi

# --- Workspace ---
echo -e "  ${CYAN}Workspace${RESET}"
WORKSPACE_PATH="${WORKSPACE_PATH:-${PROJECT_DIR}/workspaces}"
if [ -d "${WORKSPACE_PATH}" ]; then
    ITEM_COUNT=$(find "${WORKSPACE_PATH}" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    DISK_USAGE=$(du -sh "${WORKSPACE_PATH}" 2>/dev/null | cut -f1 || echo "?")
    row "Path:" "${WORKSPACE_PATH}"
    row "Items:" "${ITEM_COUNT} top-level item(s)"
    row "Disk usage:" "${DISK_USAGE}"
else
    row "Path:" "${WORKSPACE_PATH} (not found)" "${RED}"
fi

echo ""

# --- Credentials ---
echo -e "  ${CYAN}Credentials${RESET}"
CLAUDE_JSON="${CONFIG_DIR}/.claude.json"
if [ -f "${CLAUDE_JSON}" ]; then
    row "Login:" "authenticated" "${GREEN}"
    row "Config path:" "${CONFIG_DIR}"
else
    row "Login:" "not authenticated (first login required)" "${YELLOW}"
    row "Config path:" "${CONFIG_DIR}"
fi

echo ""

# --- Backups ---
echo -e "  ${CYAN}Backups${RESET}"
BACKUP_DIR="${PROJECT_DIR}/backups"
if [ -d "${BACKUP_DIR}" ]; then
    BACKUP_COUNT=$(ls -1 "${BACKUP_DIR}"/${BACKUP_PATTERN} 2>/dev/null | wc -l)
    LATEST_BACKUP=$(ls -1t "${BACKUP_DIR}"/${BACKUP_PATTERN} 2>/dev/null | head -1 || echo "")
    row "Total backups:" "${BACKUP_COUNT}"
    if [ -n "${LATEST_BACKUP}" ]; then
        row "Latest:" "$(basename "${LATEST_BACKUP}")"
    fi
else
    row "Backups:" "none (./backups/ not found)"
fi

echo ""

# --- Quick commands ---
if [ "${CONTAINER_STATUS}" = "running" ]; then
    echo -e "  ${YELLOW}Quick commands${RESET}"
    echo -e "  Attach:  ${BOLD}./scripts/attach.sh${RESET}"
    echo -e "  Shell:   ${BOLD}./scripts/shell.sh${RESET}"
    echo -e "  Logs:    ${BOLD}./scripts/logs.sh${RESET}"
    echo -e "  Backup:  ${BOLD}./scripts/backup.sh${RESET}"
    echo ""
fi
