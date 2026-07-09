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
    BACKUP_PATTERN="claude-code-dock-${REMOTE_SESSION_NAME}-backup-*.tar.gz*"
else
    CONFIG_DIR="${PROJECT_DIR}/configs/default"
    BACKUP_PATTERN="claude-code-dock-backup-*.tar.gz*"
fi

# --json: machine-readable output for homelab dashboards (Homepage, Uptime
# Kuma, Grafana via a JSON exporter, ...) that want to poll this instead of
# scraping colored terminal output. No jq dependency assumed on the HOST
# (unlike inside the container, jq on the host isn't guaranteed) -- built by
# hand via json_escape() below instead. All data-gathering below runs exactly
# the same regardless of this flag; only which output function runs at the
# end differs.
JSON_MODE=false
if [ "${1:-}" = "--json" ]; then
    JSON_MODE=true
fi

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Called once, at the very end, in place of the human-readable sections below
# -- every field here reads variables populated by the same data-gathering
# code the human output uses, via `${VAR:-default}` since most of them are
# only ever assigned inside a conditional branch (container running,
# workspace directory exists, ...) and this must stay valid even when none of
# those branches ran (set -u would otherwise error on a truly unset var).
print_json() {
    local authenticated="false"
    [ -f "${CLAUDE_JSON}" ] && authenticated="true"

    local update_available="null"
    if [ -n "${LATEST_VERSION:-}" ] && [ "${LATEST_VERSION}" != "${CLAUDE_VERSION:-}" ]; then
        update_available="\"$(json_escape "${LATEST_VERSION}")\""
    fi

    local auto_approve_bool="false"
    [ "${AUTO_APPROVE:-}" = "true" ] && auto_approve_bool="true"

    local latest_backup_name=""
    [ -n "${LATEST_BACKUP:-}" ] && latest_backup_name="$(basename "${LATEST_BACKUP}")"

    printf '{\n'
    printf '  "container": {"name": "%s", "session_id": "%s", "status": "%s", "health": "%s", "started_at": "%s"},\n' \
        "$(json_escape "${CONTAINER_NAME}")" \
        "$(json_escape "${REMOTE_SESSION_NAME}")" \
        "$(json_escape "${CONTAINER_STATUS}")" \
        "$(json_escape "${CONTAINER_HEALTH:-}")" \
        "$(json_escape "${CONTAINER_UPTIME:-}")"
    printf '  "claude_code": {"version": "%s", "build_source": "%s", "update_available": %s, "mode": "%s", "auto_approve": %s},\n' \
        "$(json_escape "${CLAUDE_VERSION:-}")" \
        "$(json_escape "${BUILD_SOURCE_RAW:-}")" \
        "${update_available}" \
        "$(json_escape "${MODE_ENV:-interactive}")" \
        "${auto_approve_bool}"
    printf '  "workspace": {"path": "%s", "items": %s, "disk_usage": "%s"},\n' \
        "$(json_escape "${WORKSPACE_PATH}")" \
        "${ITEM_COUNT:-0}" \
        "$(json_escape "${DISK_USAGE:-unknown}")"
    printf '  "credentials": {"authenticated": %s, "config_path": "%s"},\n' \
        "${authenticated}" \
        "$(json_escape "${CONFIG_DIR}")"
    printf '  "backups": {"total": %s, "latest": "%s"}\n' \
        "${BACKUP_COUNT:-0}" \
        "$(json_escape "${latest_backup_name}")"
    printf '}\n'
}

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

if [ "${JSON_MODE}" != "true" ]; then
    header
    echo -e "  ${CYAN}Container${RESET}"
fi

CONTAINER_STATUS=$(docker inspect --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "not found")
CONTAINER_HEALTH=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}' "${CONTAINER_NAME}" 2>/dev/null || echo "")
CONTAINER_UPTIME=$(docker inspect --format '{{.State.StartedAt}}' "${CONTAINER_NAME}" 2>/dev/null || echo "")

if [ "${JSON_MODE}" != "true" ]; then
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
fi

# --- Claude Code ---
if [ "${CONTAINER_STATUS}" = "running" ]; then
    [ "${JSON_MODE}" != "true" ] && echo -e "  ${CYAN}Claude Code${RESET}"
    CLAUDE_VERSION=$(docker exec "${CONTAINER_NAME}" cat /etc/claude-code-version 2>/dev/null || echo "unavailable")
    [ "${JSON_MODE}" != "true" ] && row "Version:" "${CLAUDE_VERSION}"

    BUILD_SOURCE_RAW=$(docker exec "${CONTAINER_NAME}" cat /etc/claude-dock-build-source 2>/dev/null || echo "")
    if [ -n "${BUILD_SOURCE_RAW}" ] && [ "${JSON_MODE}" != "true" ]; then
        BUILD_SOURCE_KIND="${BUILD_SOURCE_RAW%%:*}"
        BUILD_SOURCE_REF="${BUILD_SOURCE_RAW#*:}"
        if [ "${BUILD_SOURCE_KIND}" = "local" ]; then
            row "Build source:" "local clone (CLAUDE_SOURCE_PATH=${BUILD_SOURCE_REF})" "${YELLOW}"
        else
            row "Build source:" "GitHub (ref: ${BUILD_SOURCE_REF})"
        fi
    fi

    if [ "${CLAUDE_VERSION}" != "unavailable" ] && command -v curl &>/dev/null; then
        # `|| true`: under `set -e`, a curl failure or a grep miss (both exit
        # non-zero) would otherwise abort this whole script instead of just
        # falling through to the "unavailable" branch below.
        LATEST_VERSION=$(curl -fsS --max-time 5 https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null \
            | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"' || true)
        if [ "${JSON_MODE}" != "true" ]; then
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
    fi

    MODE_ENV=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null \
        | grep "^AUTO_START_MODE=" | cut -d= -f2 || echo "unknown")
    [ "${JSON_MODE}" != "true" ] && row "Mode:" "${MODE_ENV:-interactive}"

    AUTO_APPROVE=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null \
        | grep "^CLAUDE_AUTO_APPROVE=" | cut -d= -f2 || echo "unknown")
    if [ "${JSON_MODE}" != "true" ]; then
        if [ "${AUTO_APPROVE}" = "true" ]; then
            row "Auto-approve:" "enabled (--dangerously-skip-permissions)" "${YELLOW}"
        else
            row "Auto-approve:" "disabled"
        fi
        echo ""
    fi
fi

# --- Workspace ---
[ "${JSON_MODE}" != "true" ] && echo -e "  ${CYAN}Workspace${RESET}"
WORKSPACE_PATH="${WORKSPACE_PATH:-${PROJECT_DIR}/workspaces}"
if [ -d "${WORKSPACE_PATH}" ]; then
    ITEM_COUNT=$(find "${WORKSPACE_PATH}" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    DISK_USAGE=$(du -sh "${WORKSPACE_PATH}" 2>/dev/null | cut -f1 || echo "?")
    if [ "${JSON_MODE}" != "true" ]; then
        row "Path:" "${WORKSPACE_PATH}"
        row "Items:" "${ITEM_COUNT} top-level item(s)"
        row "Disk usage:" "${DISK_USAGE}"
    fi
else
    [ "${JSON_MODE}" != "true" ] && row "Path:" "${WORKSPACE_PATH} (not found)" "${RED}"
fi

[ "${JSON_MODE}" != "true" ] && echo ""

# --- Credentials ---
[ "${JSON_MODE}" != "true" ] && echo -e "  ${CYAN}Credentials${RESET}"
CLAUDE_JSON="${CONFIG_DIR}/.claude.json"
if [ "${JSON_MODE}" != "true" ]; then
    if [ -f "${CLAUDE_JSON}" ]; then
        row "Login:" "authenticated" "${GREEN}"
        row "Config path:" "${CONFIG_DIR}"
    else
        row "Login:" "not authenticated (first login required)" "${YELLOW}"
        row "Config path:" "${CONFIG_DIR}"
    fi
    echo ""
fi

# --- Backups ---
[ "${JSON_MODE}" != "true" ] && echo -e "  ${CYAN}Backups${RESET}"
BACKUP_DIR="${PROJECT_DIR}/backups"
if [ -d "${BACKUP_DIR}" ]; then
    # `ls` on a non-matching glob exits non-zero even with 2>/dev/null; under
    # this script's `set -o pipefail`, that would otherwise abort the whole
    # script right here (a bare `VAR=$(...)` assignment failing under `set
    # -e`) whenever backups/ exists but is still empty -- a normal state
    # before the first backup is ever taken, not an error.
    BACKUP_COUNT=$( { ls -1 "${BACKUP_DIR}"/${BACKUP_PATTERN} 2>/dev/null || true; } | wc -l)
    LATEST_BACKUP=$(ls -1t "${BACKUP_DIR}"/${BACKUP_PATTERN} 2>/dev/null | head -1 || echo "")
    if [ "${JSON_MODE}" != "true" ]; then
        row "Total backups:" "${BACKUP_COUNT}"
        if [ -n "${LATEST_BACKUP}" ]; then
            row "Latest:" "$(basename "${LATEST_BACKUP}")"
        fi
    fi
else
    [ "${JSON_MODE}" != "true" ] && row "Backups:" "none (./backups/ not found)"
fi

if [ "${JSON_MODE}" = "true" ]; then
    print_json
    exit 0
fi

echo ""

# --- Quick commands ---
if [ "${CONTAINER_STATUS}" = "running" ]; then
    echo -e "  ${YELLOW}Quick commands${RESET}"
    echo -e "  Attach:  ${BOLD}./scripts/attach.sh${RESET}"
    echo -e "  Shell:   ${BOLD}./scripts/shell.sh${RESET}"
    echo -e "  Logs:    ${BOLD}./scripts/logs.sh${RESET}"
    echo -e "  Backup:  ${BOLD}./scripts/backup.sh${RESET}"
    if [ "${CONTAINER_HEALTH}" = "unhealthy" ]; then
        echo -e "  ${RED}Container reports unhealthy${RESET} — restart it: ${BOLD}./scripts/watchdog.sh ${CONTAINER_NAME}${RESET}"
    fi
    echo ""
fi
