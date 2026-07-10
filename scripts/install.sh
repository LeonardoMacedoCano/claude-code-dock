#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
OVERRIDE_FILE="${PROJECT_DIR}/docker-compose.override.yml"
RESOURCES_FILE="${PROJECT_DIR}/docker-compose.resources.yml"
ENV_FILE="${PROJECT_DIR}/.env"
ENV_EXAMPLE="${PROJECT_DIR}/.env.example"
CONTAINER_NAME="${CONTAINER_NAME:-claude-code-dock}"
WITH_WATCHDOG=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║           claude-code-dock — Installation            ║${RESET}"
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

for arg in "$@"; do
    case $arg in
        --with-watchdog)
            WITH_WATCHDOG=true
            ;;
        -h|--help)
            echo "Usage: $0 [--with-watchdog]"
            echo ""
            echo "  --with-watchdog     After installing, add a crontab entry (every 5 minutes)"
            echo "                      that runs scripts/watchdog.sh to auto-restart the"
            echo "                      container if Docker ever reports it 'unhealthy' without"
            echo "                      actually exiting (restart: unless-stopped alone doesn't"
            echo "                      catch that case). Idempotent -- safe to pass again on a"
            echo "                      later re-run; the entry is only added once."
            exit 0
            ;;
    esac
done

# The container runs as PUID:PGID ('node', remapped from the default 1000:1000
# by entrypoint.sh's root step-down block if PUID/PGID are set in .env).
# Directories created here by install.sh (often run as root over SSH on
# Unraid/NAS) would otherwise stay root-owned, leaving the container unable
# to write its own config/workspace at startup — the #1 cause of silent
# restart loops. Best-effort: some hosts (rootless Docker, non-root
# install.sh runs, NFS with root-squash) can't chown to an arbitrary UID, so
# failures just fall back to a manual hint.
fix_ownership() {
    local dir="$1"
    local target_uid="${PUID:-1000}"
    local target_gid="${PGID:-1000}"
    if chown -R "${target_uid}:${target_gid}" "${dir}" 2>/dev/null; then
        ok "Ownership set to UID:GID ${target_uid}:${target_gid} (node): ${dir}"
    else
        warn "Could not chown ${dir} to ${target_uid}:${target_gid} (not root, or unsupported filesystem)."
        echo -e "    If the container fails to start with a 'not writable' error, run manually:"
        echo -e "    ${BOLD}chown -R ${target_uid}:${target_gid} ${dir}${RESET}"
    fi
}

# docker-compose.override.yml is Compose's own auto-loaded override filename
# -- generating/removing it here (instead of branching CLAUDE_SOURCE_PATH
# inside docker-compose.yml itself, via `${VAR:-x}` interpolation) keeps the
# base compose file free of any need to leak the raw host path into fields
# like image/pull_policy that don't tolerate arbitrary content (breaks on
# '/'). Once this file exists on disk, ANY `docker compose` invocation from
# this same directory picks it up automatically -- not just this script --
# including a bare `docker compose up -d` run by a tool that doesn't know
# this project's conventions (e.g. Unraid's Compose Manager plugin, as long
# as it also runs from this directory rather than a copy of the compose
# file elsewhere). See docker-compose.yml's own comment for what's inside it.
sync_override_file() {
    if [ -n "${CLAUDE_SOURCE_PATH:-}" ]; then
        cat > "${OVERRIDE_FILE}" <<'YAML'
services:
  claude-code-dock:
    image: claude-code-dock:local
    pull_policy: build
YAML
        ok "docker-compose.override.yml written — every 'docker compose up' from this directory now always builds from CLAUDE_SOURCE_PATH."
    elif [ -f "${OVERRIDE_FILE}" ]; then
        rm -f "${OVERRIDE_FILE}"
        ok "docker-compose.override.yml removed — back to pulling the published image."
    fi
}

# `restart: unless-stopped` only reacts to the container actually exiting --
# it never restarts a container Docker still reports as running but
# `unhealthy` (e.g. a wedged tmux pane). scripts/watchdog.sh closes that gap,
# but only if something actually runs it periodically; nothing does that on
# its own. --with-watchdog wires up a host crontab entry so this isn't a step
# operators have to discover and configure by hand after the fact.
#
# Idempotent by design: re-running install.sh --with-watchdog (e.g. after
# ./scripts/update.sh) must not pile up duplicate cron lines, so any existing
# line invoking this session's watchdog.sh is left untouched instead of
# appended again.
setup_watchdog_cron() {
    if [ "${WITH_WATCHDOG}" != "true" ]; then
        return
    fi

    step "Configuring watchdog cron job..."

    if ! command -v crontab &>/dev/null; then
        warn "crontab not found on this host — skipping automatic setup."
        echo -e "    Configure your platform's own scheduler to run this every few minutes instead:"
        echo -e "    ${BOLD}${SCRIPT_DIR}/watchdog.sh${RESET}"
        return
    fi

    local cron_line="*/5 * * * * CONTAINER_NAME=${CONTAINER_NAME} ${SCRIPT_DIR}/watchdog.sh >> ${PROJECT_DIR}/watchdog.log 2>&1"
    local existing
    existing="$(crontab -l 2>/dev/null || true)"

    if echo "${existing}" | grep -qF "${SCRIPT_DIR}/watchdog.sh"; then
        ok "Watchdog cron entry already present for this host — left unchanged."
        return
    fi

    if printf '%s\n%s\n' "${existing}" "${cron_line}" | crontab - 2>/dev/null; then
        ok "Watchdog cron entry added (runs every 5 minutes):"
        echo -e "    ${BOLD}${cron_line}${RESET}"
    else
        warn "Could not write the crontab automatically. Add this line manually:"
        echo -e "    ${BOLD}${cron_line}${RESET}"
    fi
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
            echo -e "  ${BOLD}CONFIG_BASE_PATH=/mnt/user/appdata/claude-code-dock/configs${RESET}"
            echo -e "  ${BOLD}REMOTE_SESSION_NAME=my-session${RESET}"
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

    if [ -z "${REMOTE_SESSION_NAME:-}" ]; then
        fail "REMOTE_SESSION_NAME not set in .env. Set a unique name for this session (e.g. REMOTE_SESSION_NAME=my-project)."
    fi
    ok "REMOTE_SESSION_NAME: ${REMOTE_SESSION_NAME}"

    if [ -z "${CONTAINER_NAME:-}" ]; then
        CONTAINER_NAME="claude-code-dock-${REMOTE_SESSION_NAME}"
        echo "CONTAINER_NAME=${CONTAINER_NAME}" >> "${ENV_FILE}"
        ok "CONTAINER_NAME auto-set: ${CONTAINER_NAME} (written to .env)"
    fi
    CONTAINER_NAME="${CONTAINER_NAME}"
    ok "CONTAINER_NAME: ${CONTAINER_NAME}"

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
                fix_ownership "${WORKSPACE_PATH}"
            else
                warn "Continuing anyway, but the workspace will be empty."
            fi
        else
            ok "Workspace exists: ${WORKSPACE_PATH}"
        fi
    fi

    if [ -z "${CONFIG_BASE_PATH:-}" ]; then
        fail "CONFIG_BASE_PATH not set in .env. Configure it before continuing."
    fi

    CONFIG_DIR="${CONFIG_BASE_PATH}/${REMOTE_SESSION_NAME}"
    mkdir -p "${CONFIG_DIR}"
    ok "Session config dir: ${CONFIG_DIR}"
    fix_ownership "${CONFIG_DIR}"

    if [ -n "${SHARED_CONFIG_PATH:-}" ]; then
        mkdir -p "${SHARED_CONFIG_PATH}"
        mkdir -p "${SHARED_CONFIG_PATH}/commands"
        ok "SHARED_CONFIG_PATH: ${SHARED_CONFIG_PATH}"
        fix_ownership "${SHARED_CONFIG_PATH}"
    fi

    if [ -n "${CLAUDE_SOURCE_PATH:-}" ]; then
        ok "CLAUDE_SOURCE_PATH: ${CLAUDE_SOURCE_PATH} (building from local clone)"
    else
        ok "Will pull ghcr.io/leonardomacedocano/claude-code-dock:${CLAUDE_DOCK_TAG:-latest} (falls back to building from GitHub ref ${CLAUDE_DOCK_VERSION:-main} only if the pull fails)"
    fi

    sync_override_file
    COMPOSE_FILE_ARGS=(-f "${COMPOSE_FILE}")
    if [ -f "${OVERRIDE_FILE}" ]; then
        COMPOSE_FILE_ARGS+=(-f "${OVERRIDE_FILE}")
    fi

    case "${AUTO_START_MODE:-interactive}" in
        interactive|remote|shell) ;;
        *)
            fail "AUTO_START_MODE=\"${AUTO_START_MODE}\" is not valid. Use one of: interactive, remote, shell."
            ;;
    esac
    ok "AUTO_START_MODE: ${AUTO_START_MODE:-interactive}"

    check_auto_approve_safety
}

# CLAUDE_AUTO_APPROVE=true means Claude runs with --dangerously-skip-permissions
# -- no per-command human checkpoint. Combined with restart:unless-stopped and
# no CPU/memory ceiling (resource limits live in the opt-in
# docker-compose.resources.yml overlay, not in this file, since a hardcoded
# default would be wrong for most hosts — see that file), a single runaway or
# misbehaving command has nothing to cap how much of the host it can consume.
# This can't be silently defaulted for the operator (the right limit depends
# on their hardware), so instead of either ignoring it or blocking outright,
# this surfaces the risk and requires an explicit "yes, I understand" before
# continuing -- consistent with this script already confirming before other
# host-affecting actions (creating directories, chown). entrypoint.sh logs
# the same warning on every container start, so it's visible even when the
# container was brought up by something other than this script (a bare
# `docker compose up`, Unraid's Compose Manager plugin, scripts/update.sh,
# scripts/session-up.sh).
#
# Detection here is best-effort, same as before this file existed: it only
# checks whether docker-compose.resources.yml is present on disk, not whether
# THIS particular `docker compose up` invocation actually loads it (that
# overlay is always an explicit `-f`, install.sh never adds it to
# COMPOSE_FILE_ARGS automatically) -- presence is treated as a signal of
# intent, same heuristic previously used for the now-removed commented block
# in docker-compose.yml itself.
check_auto_approve_safety() {
    if [ "${CLAUDE_AUTO_APPROVE:-false}" != "true" ]; then
        return
    fi

    step "Checking CLAUDE_AUTO_APPROVE safety..."

    if grep -qE '^\s*deploy:\s*$' "${COMPOSE_FILE}" "${OVERRIDE_FILE}" "${RESOURCES_FILE}" 2>/dev/null; then
        ok "CLAUDE_AUTO_APPROVE=true with resource limits active (docker-compose.resources.yml present)."
        return
    fi

    warn "CLAUDE_AUTO_APPROVE=true with no CPU/memory limits configured."
    echo ""
    echo -e "  With --dangerously-skip-permissions, Claude Code runs commands with no"
    echo -e "  per-command human checkpoint. Nothing currently caps how much CPU or"
    echo -e "  memory a single Claude-issued command can consume on this host."
    echo ""
    echo -e "  Recommended: size docker-compose.resources.yml to your hardware, then run:"
    echo -e "  ${BOLD}docker compose -f docker-compose.yml -f docker-compose.resources.yml up -d${RESET}"
    echo -e "  See docs/security.md#credential-protection (point 6) for the full risk,"
    echo -e "  especially if GITHUB_TOKEN_FILE is also set for this session."
    echo ""
    read -r -p "  Continue anyway, without resource limits? [y/N]: " CONTINUE_UNSAFE
    if [[ "${CONTINUE_UNSAFE,,}" != "y" ]]; then
        fail "Aborted — size docker-compose.resources.yml (or unset CLAUDE_AUTO_APPROVE), then re-run."
    fi
}

setup_directories() {
    step "Creating project directory structure..."

    mkdir -p "${PROJECT_DIR}/workspaces"
    touch "${PROJECT_DIR}/workspaces/.gitkeep"
    ok "Directory workspaces/ created"
}

build_image() {
    cd "${PROJECT_DIR}"

    if [ -n "${CLAUDE_SOURCE_PATH:-}" ]; then
        step "BUILD SOURCE: LOCAL folder (CLAUDE_SOURCE_PATH=${CLAUDE_SOURCE_PATH}) — GitHub and any cached image are ignored"
        echo ""
        # --no-cache: CLAUDE_SOURCE_PATH must always win, with no dependency on
        # a stale image already tagged locally or on Docker's layer cache.
        ${COMPOSE_CMD} "${COMPOSE_FILE_ARGS[@]}" build --no-cache
        ok "Image built successfully from local source."
        return
    fi

    step "BUILD SOURCE: prebuilt GHCR image (ghcr.io/leonardomacedocano/claude-code-dock:${CLAUDE_DOCK_TAG:-latest})"
    echo ""
    if ${COMPOSE_CMD} "${COMPOSE_FILE_ARGS[@]}" pull; then
        ok "Image pulled successfully."
    else
        warn "Pull failed — BUILD SOURCE: GitHub (${CLAUDE_DOCK_VERSION:-main}), this may take a few minutes..."
        echo ""
        ${COMPOSE_CMD} "${COMPOSE_FILE_ARGS[@]}" build --no-cache
        ok "Image built successfully from GitHub."
    fi
}

wait_for_container() {
    local deadline=$((SECONDS + 30))
    while [ $SECONDS -lt $deadline ]; do
        if [ "$(docker inspect --format '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null)" = "true" ]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

start_services() {
    step "Starting claude-code-dock..."

    cd "${PROJECT_DIR}"

    # Captured instead of streamed so a name conflict (the #1 cause of a
    # confusing-looking failure right after a successful build/pull) can be
    # caught and re-worded before the user ever sees Docker's raw daemon
    # error -- see the grep below.
    local up_output
    local up_status=0
    up_output="$(${COMPOSE_CMD} "${COMPOSE_FILE_ARGS[@]}" up -d 2>&1)" || up_status=$?

    if [ "${up_status}" -ne 0 ]; then
        if echo "${up_output}" | grep -q "is already in use by container"; then
            echo ""
            warn "CONTAINER_NAME \"${CONTAINER_NAME}\" is already in use by another container."
            echo ""
            echo -e "  This is a configuration issue, not a build problem — the image built"
            echo -e "  (or pulled) fine. A container with this exact name already exists,"
            echo -e "  almost always because .env was copied from another session/project"
            echo -e "  without changing CONTAINER_NAME to something unique."
            echo ""
            echo -e "  ${BOLD}To fix:${RESET}"
            echo -e "  1. Edit .env and set a unique value, e.g.:"
            echo -e "     ${BOLD}CONTAINER_NAME=${CONTAINER_NAME}-2${RESET}"
            echo -e "  2. Run ${BOLD}./scripts/install.sh${RESET} again."
            echo ""
            fail "Aborted — fix CONTAINER_NAME in .env and re-run."
        fi

        echo "${up_output}" >&2
        fail "docker compose up failed. See output above."
    fi

    ok "Container started."

    if wait_for_container; then
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
    echo -e "     Credentials are saved in ${BOLD}${CONFIG_DIR}${RESET} and persist across restarts."
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
    echo -e "  ${CYAN}6.${RESET} To add another session (new project):"
    echo -e "     ${BOLD}./scripts/new-session.sh${RESET}"
    echo ""
    echo -e "  ${CYAN}7.${RESET} To list all running sessions:"
    echo -e "     ${BOLD}./scripts/sessions.sh${RESET}"
    echo ""
    if [ "${WITH_WATCHDOG}" != "true" ]; then
        echo -e "  ${CYAN}8.${RESET} (optional) Auto-restart if Docker ever reports this container"
        echo -e "     unhealthy without exiting: re-run ${BOLD}./scripts/install.sh --with-watchdog${RESET}"
        echo -e "     or see ${BOLD}./scripts/watchdog.sh --help${RESET}."
        echo ""
    fi
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
    setup_watchdog_cron
    print_next_steps
}

main "$@"
