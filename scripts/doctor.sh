#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${PROJECT_DIR}/.env"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
OVERRIDE_FILE="${PROJECT_DIR}/docker-compose.override.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

ISSUES=0

header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║             claude-code-dock — Doctor                ║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  Preflight checks -- read-only, changes nothing. Run this whenever"
    echo -e "  something looks wrong, or before reporting a bug."
    echo ""
}

ok()   { echo -e "  ${GREEN}[✓]${RESET} $1"; }
info() { echo -e "  ${CYAN}[i]${RESET} $1"; }
warn() { echo -e "  ${YELLOW}[⚠]${RESET} $1"; ISSUES=$((ISSUES + 1)); }
fail() { echo -e "  ${RED}[✗]${RESET} $1" >&2; exit 1; }

# A proxy for "is this checkout's docker-compose.yml current enough to have
# the automatic permission fix" -- not a version number check (this project
# doesn't tag docker-compose.yml independently), just presence of the
# service name it introduced.
step_compose_file() {
    echo -e "  ${CYAN}docker-compose.yml${RESET}"

    if [ ! -f "${COMPOSE_FILE}" ]; then
        warn "docker-compose.yml not found at ${COMPOSE_FILE} -- is this script being run from a clone of claude-code-dock?"
        echo ""
        return
    fi

    if grep -q "claude-code-dock-init" "${COMPOSE_FILE}" 2>/dev/null; then
        ok "claude-code-dock-init permission-fixer service present -- new sessions get their config directory chowned automatically."
    else
        warn "This checkout's docker-compose.yml predates the claude-code-dock-init permission-fixer service. A brand-new REMOTE_SESSION_NAME can still fail with 'Config directory is not writable' on its first start. Update: git pull (or ./scripts/update.sh if CLAUDE_SOURCE_PATH is unset)."
    fi

    echo ""
}

step_required_vars() {
    echo -e "  ${CYAN}Required variables${RESET}"

    if [ -z "${REMOTE_SESSION_NAME}" ]; then
        warn "REMOTE_SESSION_NAME is not set -- sessions can't be isolated from each other."
    else
        ok "REMOTE_SESSION_NAME: ${REMOTE_SESSION_NAME}"
    fi

    if [ -z "${WORKSPACE_PATH}" ]; then
        warn "WORKSPACE_PATH is not set -- falls back to ./workspaces (relative to wherever docker compose runs from)."
    else
        ok "WORKSPACE_PATH: ${WORKSPACE_PATH}"
    fi

    if [ -z "${CONFIG_BASE_PATH}" ]; then
        warn "CONFIG_BASE_PATH is not set -- falls back to ./configs (relative to wherever docker compose runs from)."
    else
        ok "CONFIG_BASE_PATH: ${CONFIG_BASE_PATH}"
    fi

    echo ""
}

# Both of these are almost certainly a copy-paste of the same path into two
# different .env fields rather than an intentional choice -- CLAUDE_SOURCE_PATH
# is meant to be a claude-code-dock checkout (for building the image), not the
# runtime workspace/credentials directory. The one legitimate case (using
# claude-code-dock to develop claude-code-dock itself) still works fine, but
# is rare enough to be worth a confirmation rather than silence.
step_path_collisions() {
    echo -e "  ${CYAN}Path configuration sanity${RESET}"

    if [ -z "${CLAUDE_SOURCE_PATH}" ]; then
        ok "CLAUDE_SOURCE_PATH not set -- pulling the published image (default, most setups)."
        echo ""
        return
    fi

    ok "CLAUDE_SOURCE_PATH: ${CLAUDE_SOURCE_PATH} (building from local clone)"

    if [ -n "${WORKSPACE_PATH}" ] && [ "${CLAUDE_SOURCE_PATH}" = "${WORKSPACE_PATH}" ]; then
        warn "CLAUDE_SOURCE_PATH equals WORKSPACE_PATH (${CLAUDE_SOURCE_PATH}). This is only correct if you're deliberately using claude-code-dock to develop claude-code-dock itself -- otherwise it's almost always a copy-paste of the wrong variable. If unintentional, point WORKSPACE_PATH at your actual project directory instead."
    fi

    if [ -n "${CONFIG_BASE_PATH}" ] && [ "${CLAUDE_SOURCE_PATH}" = "${CONFIG_BASE_PATH}" ]; then
        warn "CLAUDE_SOURCE_PATH equals CONFIG_BASE_PATH (${CLAUDE_SOURCE_PATH}). That would mean the claude-code-dock source tree and Claude Code's session credentials live in the same directory -- almost certainly not intended."
    fi

    if [ ! -f "${OVERRIDE_FILE}" ]; then
        warn "CLAUDE_SOURCE_PATH is set but docker-compose.override.yml doesn't exist yet -- a bare 'docker compose up' will still PULL the published image instead of building from CLAUDE_SOURCE_PATH. Run ./scripts/install.sh, ./scripts/update.sh, or ./scripts/session-up.sh once to generate it."
    else
        ok "docker-compose.override.yml present -- 'docker compose up' from this directory builds from CLAUDE_SOURCE_PATH."
    fi

    echo ""
}

# The opposite drift: override file says "always build locally" but nothing
# in the currently-loaded environment asked for that anymore -- e.g.
# CLAUDE_SOURCE_PATH was unset after switching back to the published image,
# but the override file (generated by an earlier install.sh/update.sh/
# session-up.sh run) was never cleaned up because none of them ran again.
step_stale_override() {
    if [ -n "${CLAUDE_SOURCE_PATH}" ]; then
        return
    fi
    if [ -f "${OVERRIDE_FILE}" ]; then
        echo -e "  ${CYAN}Override file${RESET}"
        warn "docker-compose.override.yml exists and forces a local build (claude-code-dock:local), but CLAUDE_SOURCE_PATH is not set in the currently-loaded environment. Every 'docker compose up' from this directory is still building locally, not pulling. Remove it if that's not intended: rm ${OVERRIDE_FILE}"
        echo ""
    fi
}

# entrypoint.sh's own validate_config() checks this at container startup and
# refuses to start on failure -- this check exists so it can be caught from
# the HOST, before ever running 'docker compose up', instead of learning
# about it from a fatal() in the logs after the fact.
step_host_ownership() {
    echo -e "  ${CYAN}Host directory ownership (vs PUID:PGID = ${PUID}:${PGID})${RESET}"

    local checked_any=false

    if [ -n "${WORKSPACE_PATH}" ] && [ -d "${WORKSPACE_PATH}" ]; then
        checked_any=true
        local owner
        owner=$(stat -c '%u:%g' "${WORKSPACE_PATH}" 2>/dev/null || echo "?:?")
        if [ "${owner}" = "${PUID}:${PGID}" ]; then
            ok "WORKSPACE_PATH (${WORKSPACE_PATH}) owned by ${owner}."
        else
            warn "WORKSPACE_PATH (${WORKSPACE_PATH}) is owned by ${owner}, not ${PUID}:${PGID}. Fix: chown -R ${PUID}:${PGID} ${WORKSPACE_PATH}"
        fi
    fi

    if [ -n "${CONFIG_BASE_PATH}" ] && [ -n "${REMOTE_SESSION_NAME}" ]; then
        local config_dir="${CONFIG_BASE_PATH}/${REMOTE_SESSION_NAME}"
        if [ -d "${config_dir}" ]; then
            checked_any=true
            local owner
            owner=$(stat -c '%u:%g' "${config_dir}" 2>/dev/null || echo "?:?")
            if [ "${owner}" = "${PUID}:${PGID}" ]; then
                ok "Session config dir (${config_dir}) owned by ${owner}."
            else
                warn "Session config dir (${config_dir}) is owned by ${owner}, not ${PUID}:${PGID}. The claude-code-dock-init service in docker-compose.yml should fix this automatically on the next 'docker compose up' -- if it doesn't (e.g. NFS with root-squash), fix manually: chown -R ${PUID}:${PGID} ${config_dir}"
            fi
        fi
    fi

    if [ "${checked_any}" = "false" ]; then
        info "Neither directory exists on the host yet -- nothing to check (normal before the first start)."
    fi

    echo ""
}

# Compares the .env this script just loaded against what the RUNNING
# container actually has baked into its process environment. These only
# drift apart when .env was edited after the last 'docker compose up
# --force-recreate' -- Compose does not live-reload environment: values into
# an already-running container, so a running container can silently be
# acting on stale configuration indefinitely until someone happens to notice.
step_running_drift() {
    echo -e "  ${CYAN}Running container${RESET}"

    if ! docker inspect "${CONTAINER_NAME}" &>/dev/null; then
        info "No container named '${CONTAINER_NAME}' found -- nothing running to compare against."
        echo ""
        return
    fi

    local status
    status=$(docker inspect --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")
    ok "Container '${CONTAINER_NAME}' found (status: ${status})."

    local live_env
    live_env=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null || echo "")

    local drifted=false
    for var in AUTO_START_MODE CLAUDE_AUTO_APPROVE REMOTE_SESSION_NAME; do
        local live_val current_val
        live_val=$(echo "${live_env}" | grep "^${var}=" | cut -d= -f2- || echo "")
        current_val="${!var:-}"
        if [ "${var}" = "AUTO_START_MODE" ] && [ -z "${current_val}" ]; then
            current_val="interactive"
        fi
        if [ "${var}" = "CLAUDE_AUTO_APPROVE" ] && [ -z "${current_val}" ]; then
            current_val="false"
        fi
        if [ -n "${live_val}" ] && [ "${live_val}" != "${current_val}" ]; then
            drifted=true
            warn "${var} is '${live_val}' in the running container but the currently-loaded environment now says '${current_val}'. Recreate to apply: docker compose up -d --force-recreate"
        fi
    done

    if [ "${drifted}" = "false" ]; then
        ok "Running container's config matches the currently-loaded environment."
    fi

    echo ""
}

step_credentials() {
    echo -e "  ${CYAN}Credentials${RESET}"

    if [ -z "${CONFIG_BASE_PATH}" ] || [ -z "${REMOTE_SESSION_NAME}" ]; then
        info "Skipped -- CONFIG_BASE_PATH/REMOTE_SESSION_NAME not both set."
        echo ""
        return
    fi

    local claude_json="${CONFIG_BASE_PATH}/${REMOTE_SESSION_NAME}/.claude.json"
    if [ -f "${claude_json}" ]; then
        ok "Persistent login found: ${claude_json}"
    else
        info "No persistent login yet -- expected before the first attach/login."
    fi

    echo ""
}

header

if ! command -v docker &>/dev/null; then
    fail "docker not found in PATH -- run this on the host that actually runs claude-code-dock's containers."
fi

# Same "process env wins, .env only fills gaps" rule as backup.sh's load_env()
# and this project's own AI Guidelines for GitHub checks -- a value already
# exported by the shell, cron, or a docker-compose env_file must not be
# silently overwritten by a stale or absent .env on disk.
if [ -f "${ENV_FILE}" ]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
    info ".env found: ${ENV_FILE}"
else
    info "No .env file at ${ENV_FILE} -- relying entirely on process environment variables (valid, e.g. Compose Manager-style setups). Checks below still apply to whatever is actually set."
fi
echo ""

CONTAINER_NAME="${CONTAINER_NAME:-claude-code-dock}"
REMOTE_SESSION_NAME="${REMOTE_SESSION_NAME:-}"
WORKSPACE_PATH="${WORKSPACE_PATH:-}"
CONFIG_BASE_PATH="${CONFIG_BASE_PATH:-}"
CLAUDE_SOURCE_PATH="${CLAUDE_SOURCE_PATH:-}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

step_compose_file
step_required_vars
step_path_collisions
step_stale_override
step_host_ownership
step_running_drift
step_credentials

echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
if [ "${ISSUES}" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}No issues found.${RESET}"
else
    echo -e "  ${YELLOW}${BOLD}${ISSUES} issue(s) found above.${RESET} None of them were changed -- this command is read-only."
fi
echo ""
