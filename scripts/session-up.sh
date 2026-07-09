#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
OVERRIDE_FILE="${PROJECT_DIR}/docker-compose.override.yml"
RESOURCES_FILE="${PROJECT_DIR}/docker-compose.resources.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║             claude-code-dock — Session Up             ║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

step() { echo -e "${CYAN}[→]${RESET} ${BOLD}$1${RESET}"; }
ok()   { echo -e "${GREEN}[✓]${RESET} $1"; }
warn() { echo -e "${YELLOW}[⚠]${RESET} $1"; }
fail() { echo -e "${RED}[✗]${RESET} $1" >&2; exit 1; }

detect_compose() {
    if docker compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        fail "Docker Compose not found."
    fi
}

# docker-compose.override.yml is Compose's own auto-loaded override filename
# -- generating/removing it here (instead of branching CLAUDE_SOURCE_PATH
# inside docker-compose.yml itself) keeps the base compose file free of any
# need to leak the raw host path into fields like image/pull_policy. Once
# this file exists on disk, ANY `docker compose` invocation from this same
# directory picks it up automatically, not just this script.
#
# NOTE: this file lives at the project root, shared by every session's
# .env.<session> -- it always reflects whichever session was started last
# via this script. Running two sessions from the same checkout with
# different CLAUDE_SOURCE_PATH values at the same time isn't supported by
# this mechanism; each `session-up.sh` run re-syncs it to match the session
# being started.
sync_override_file() {
    local source_path
    source_path=$(grep "^CLAUDE_SOURCE_PATH=" "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    if [ -n "${source_path}" ]; then
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
    COMPOSE_FILE_ARGS=(-f "${COMPOSE_FILE}")
    if [ -f "${OVERRIDE_FILE}" ]; then
        COMPOSE_FILE_ARGS+=(-f "${OVERRIDE_FILE}")
    fi
}

# Mirrors install.sh's check_auto_approve_safety() -- that one only ever runs
# for the session started via check_env() in install.sh's own .env, so every
# additional session created via new-session.sh + session-up.sh (this
# script) was silently skipping the confirmation entirely, no matter how
# many times CLAUDE_AUTO_APPROVE=true showed up in a .env.<session> file.
# entrypoint.sh's own startup warning still fires regardless (belt and
# braces), but that's after the container is already running -- this is the
# same pre-flight, deliberately blocking confirmation install.sh gives the
# very first session.
check_auto_approve_safety() {
    local auto_approve
    auto_approve=$(grep "^CLAUDE_AUTO_APPROVE=" "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    if [ "${auto_approve}" != "true" ]; then
        return
    fi

    if grep -qE '^\s*deploy:\s*$' "${COMPOSE_FILE}" "${OVERRIDE_FILE}" "${RESOURCES_FILE}" 2>/dev/null; then
        ok "CLAUDE_AUTO_APPROVE=true with resource limits active (docker-compose.resources.yml present)."
        return
    fi

    warn "CLAUDE_AUTO_APPROVE=true (in .env.${SESSION_NAME}) with no CPU/memory limits configured."
    echo ""
    echo -e "  With --dangerously-skip-permissions, Claude Code runs commands with no"
    echo -e "  per-command human checkpoint. Nothing currently caps how much CPU or"
    echo -e "  memory a single Claude-issued command can consume on this host."
    echo ""
    echo -e "  Recommended: size docker-compose.resources.yml to your hardware, then run:"
    echo -e "  ${BOLD}${COMPOSE_CMD} --env-file ${ENV_FILE} -p claude-${SESSION_NAME} -f ${COMPOSE_FILE} -f ${RESOURCES_FILE} up -d${RESET}"
    echo -e "  See docs/security.md#credential-protection (point 6) for the full risk."
    echo ""
    read -r -p "  Continue anyway, without resource limits? [y/N]: " CONTINUE_UNSAFE
    if [[ "${CONTINUE_UNSAFE,,}" != "y" ]]; then
        fail "Aborted — size docker-compose.resources.yml (or unset CLAUDE_AUTO_APPROVE in .env.${SESSION_NAME}), then re-run."
    fi
}

header

SESSION_NAME="${1:-}"

if [ -z "${SESSION_NAME}" ]; then
    echo "Usage: $0 <session-name>"
    echo ""
    echo -e "  Starts (or recreates) the session created by ${BOLD}./scripts/new-session.sh <session-name>${RESET},"
    echo -e "  binding it to its own \`.env.<session-name>\` and its own Compose project"
    echo -e "  name -- so it never gets started under the wrong .env by mistake."
    echo ""
    echo -e "  Available sessions:"
    for f in "${PROJECT_DIR}"/.env.*; do
        [ -f "$f" ] || continue
        NAME="$(basename "$f")"
        [ "${NAME}" = ".env.example" ] && continue
        echo -e "    ${CYAN}${NAME#.env.}${RESET}"
    done
    exit 1
fi

ENV_FILE="${PROJECT_DIR}/.env.${SESSION_NAME}"

if [ ! -f "${ENV_FILE}" ]; then
    fail ".env.${SESSION_NAME} not found. Create it first with: ./scripts/new-session.sh ${SESSION_NAME}"
fi

detect_compose
sync_override_file

CONTAINER_NAME=$(grep "^CONTAINER_NAME=" "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
CONTAINER_NAME="${CONTAINER_NAME:-claude-code-dock-${SESSION_NAME}}"

check_auto_approve_safety

step "Starting session '${SESSION_NAME}'..."

cd "${PROJECT_DIR}"

# Captured instead of streamed so a name conflict (the #1 cause of a
# confusing-looking failure right after a clean build/pull) can be caught
# and re-worded before the user ever sees Docker's raw daemon error.
up_output=""
up_status=0
up_output="$(${COMPOSE_CMD} --env-file "${ENV_FILE}" -p "claude-${SESSION_NAME}" "${COMPOSE_FILE_ARGS[@]}" up -d 2>&1)" || up_status=$?

if [ "${up_status}" -ne 0 ]; then
    if echo "${up_output}" | grep -q "is already in use by container"; then
        echo ""
        warn "CONTAINER_NAME \"${CONTAINER_NAME}\" is already in use by another container."
        echo ""
        echo -e "  This is a configuration issue, not a startup failure — a container"
        echo -e "  with this exact name already exists, almost always because"
        echo -e "  .env.${SESSION_NAME} was copied from another session without changing"
        echo -e "  CONTAINER_NAME to something unique."
        echo ""
        echo -e "  ${BOLD}To fix:${RESET}"
        echo -e "  1. Edit .env.${SESSION_NAME} and set a unique value, e.g.:"
        echo -e "     ${BOLD}CONTAINER_NAME=${CONTAINER_NAME}-2${RESET}"
        echo -e "  2. Run ${BOLD}./scripts/session-up.sh ${SESSION_NAME}${RESET} again."
        echo ""
        fail "Aborted — fix CONTAINER_NAME in .env.${SESSION_NAME} and re-run."
    fi

    echo "${up_output}" >&2
    fail "docker compose up failed. See output above."
fi

ok "Session '${SESSION_NAME}' started as container ${BOLD}${CONTAINER_NAME}${RESET}."

echo ""
echo -e "  ${CYAN}To attach:${RESET}"
echo -e "  ${BOLD}docker exec -it --user node ${CONTAINER_NAME} tmux attach-session -t main${RESET}"
echo ""
echo -e "  ${CYAN}To view status:${RESET}"
echo -e "  ${BOLD}CONTAINER_NAME=${CONTAINER_NAME} ./scripts/status.sh${RESET}"
echo ""
