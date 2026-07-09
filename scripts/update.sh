#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
OVERRIDE_FILE="${PROJECT_DIR}/docker-compose.override.yml"
ENV_FILE="${PROJECT_DIR}/.env"
SKIP_BACKUP=false

if [ -f "${ENV_FILE}" ]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
fi
CONTAINER_NAME="${CONTAINER_NAME:-claude-code-dock}"

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
    echo -e "${CYAN}${BOLD}║              claude-code-dock — Update               ║${RESET}"
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

# docker-compose.override.yml is Compose's own auto-loaded override filename
# -- generating/removing it here (instead of branching CLAUDE_SOURCE_PATH
# inside docker-compose.yml itself) keeps the base compose file free of any
# need to leak the raw host path into fields like image/pull_policy that
# don't tolerate arbitrary content (breaks on '/'). Once this file exists on
# disk, ANY `docker compose` invocation from this same directory picks it up
# automatically -- not just this script -- including a bare `docker compose
# up -d` run by a tool that doesn't know this project's conventions.
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
    COMPOSE_FILE_ARGS=(-f "${COMPOSE_FILE}")
    if [ -f "${OVERRIDE_FILE}" ]; then
        COMPOSE_FILE_ARGS+=(-f "${OVERRIDE_FILE}")
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

    # Captured now, before anything is stopped/rebuilt/recreated below, so a
    # container that fails its healthcheck on the new image can be rolled
    # back to exactly what it was running before this update -- 'docker
    # image prune' (cleanup_old_images, at the very end of main()) only
    # removes dangling images, so as long as rollback happens before that
    # step, the old image is still on disk to retag back. Both stay empty
    # when the container doesn't exist yet (e.g. update.sh run before any
    # install) -- rollback is then correctly skipped as "nothing to roll
    # back to" instead of failing on an empty image reference.
    OLD_IMAGE_ID=$(docker inspect --format '{{.Image}}' "${CONTAINER_NAME}" 2>/dev/null || echo "")
    OLD_IMAGE_REF=$(docker inspect --format '{{.Config.Image}}' "${CONTAINER_NAME}" 2>/dev/null || echo "")
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
        ${COMPOSE_CMD} "${COMPOSE_FILE_ARGS[@]}" stop
        ok "Container stopped."
    else
        ok "Container was already stopped."
    fi
}

rebuild_image() {
    cd "${PROJECT_DIR}"

    if [ -n "${CLAUDE_SOURCE_PATH:-}" ]; then
        step "BUILD SOURCE: LOCAL folder (CLAUDE_SOURCE_PATH=${CLAUDE_SOURCE_PATH}) — GitHub and any cached image are ignored"
        echo ""
        echo -e "  ${YELLOW}Using --no-cache: CLAUDE_SOURCE_PATH always wins, no dependency on a stale image or layer cache.${RESET}"
        echo ""
        ${COMPOSE_CMD} "${COMPOSE_FILE_ARGS[@]}" build --no-cache
        ok "Image rebuilt successfully from local source."
        return
    fi

    step "BUILD SOURCE: prebuilt GHCR image (ghcr.io/leonardomacedocano/claude-code-dock:${CLAUDE_DOCK_TAG:-latest})"
    echo ""
    if ${COMPOSE_CMD} "${COMPOSE_FILE_ARGS[@]}" pull; then
        ok "Image pulled successfully."
    else
        warn "Pull failed — BUILD SOURCE: GitHub (${CLAUDE_DOCK_VERSION:-main}), rebuilding with --no-cache..."
        echo ""
        ${COMPOSE_CMD} "${COMPOSE_FILE_ARGS[@]}" build --no-cache
        ok "Image rebuilt successfully."
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

# Waits for Docker's own HEALTHCHECK (Dockerfile) to report "healthy" --
# distinct from wait_for_container above, which only confirms the process
# didn't immediately exit. A container can be "Running" for the full 30s
# --start-period and still never actually reach a usable state (e.g. a
# HEALTHCHECK CMD that can't parse, or a wedged tmux pane) -- this is what
# actually confirms the update produced a working container, not just one
# that's still up.
#
# Treats "no healthcheck configured" as an immediate pass rather than
# blocking forever waiting for a status that will never appear -- this
# project's own image always defines one (Dockerfile HEALTHCHECK), but this
# stays correct if that's ever missing (e.g. a custom CLAUDE_SOURCE_PATH
# build based on a modified Dockerfile).
wait_for_healthy() {
    local deadline=$((SECONDS + 60))
    local status=""
    while [ $SECONDS -lt $deadline ]; do
        status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${CONTAINER_NAME}" 2>/dev/null || echo "")"
        case "${status}" in
            healthy|none|"") return 0 ;;
            unhealthy) return 1 ;;
        esac
        sleep 2
    done
    return 1
}

# Retags the previous image back onto the ref docker-compose.yml resolves to
# (e.g. ghcr.io/.../claude-code-dock:latest) and recreates -- a purely local
# Docker operation, no registry access needed, since OLD_IMAGE_ID is still on
# disk at this point (cleanup_old_images/prune only runs later, in main(),
# specifically so this is still possible here).
attempt_rollback() {
    if [ -z "${OLD_IMAGE_ID}" ] || [ -z "${OLD_IMAGE_REF}" ]; then
        warn "No previous image was recorded (this looks like the first-ever start) -- nothing to roll back to."
        return 1
    fi

    local new_image_id
    new_image_id=$(docker inspect --format '{{.Image}}' "${CONTAINER_NAME}" 2>/dev/null || echo "")
    if [ "${new_image_id}" = "${OLD_IMAGE_ID}" ]; then
        warn "The unhealthy container is running the same image as before this update -- rolling back would change nothing."
        return 1
    fi

    step "Rolling back to the previous image (${OLD_IMAGE_REF}, ${OLD_IMAGE_ID:0:12})..."

    if ! docker tag "${OLD_IMAGE_ID}" "${OLD_IMAGE_REF}" 2>/dev/null; then
        warn "Could not re-tag the previous image (${OLD_IMAGE_ID:0:12}) -- it may already have been removed."
        return 1
    fi
    ok "Re-tagged ${OLD_IMAGE_REF} back onto the previous image."

    cd "${PROJECT_DIR}"
    if ! ${COMPOSE_CMD} "${COMPOSE_FILE_ARGS[@]}" up -d --force-recreate &>/dev/null; then
        warn "Rollback recreate failed to even start."
        return 1
    fi

    if wait_for_container && wait_for_healthy; then
        ok "Rolled back successfully — container is healthy again on the previous image."
        return 0
    fi

    warn "Rollback attempt did not reach a healthy state either."
    return 1
}

start_container() {
    step "Starting updated container..."

    cd "${PROJECT_DIR}"

    # Captured instead of streamed so a name conflict (e.g. another session's
    # container already holding CONTAINER_NAME) can be caught and re-worded
    # before the user ever sees Docker's raw daemon error.
    local up_output
    local up_status=0
    up_output="$(${COMPOSE_CMD} "${COMPOSE_FILE_ARGS[@]}" up -d 2>&1)" || up_status=$?

    if [ "${up_status}" -ne 0 ]; then
        if echo "${up_output}" | grep -q "is already in use by container"; then
            echo ""
            warn "CONTAINER_NAME \"${CONTAINER_NAME}\" is already in use by another container."
            echo ""
            echo -e "  This is a configuration issue, not an update failure — the image"
            echo -e "  updated fine. A container with this exact name already exists,"
            echo -e "  almost always because .env was copied from another session/project"
            echo -e "  without changing CONTAINER_NAME to something unique."
            echo ""
            echo -e "  ${BOLD}To fix:${RESET}"
            echo -e "  1. Edit .env and set a unique value, e.g.:"
            echo -e "     ${BOLD}CONTAINER_NAME=${CONTAINER_NAME}-2${RESET}"
            echo -e "  2. Run ${BOLD}./scripts/update.sh${RESET} again."
            echo ""
            fail "Aborted — fix CONTAINER_NAME in .env and re-run."
        fi

        echo "${up_output}" >&2
        fail "docker compose up failed. See output above."
    fi

    if ! wait_for_container; then
        warn "Container did not reach 'Running' after update."
        if attempt_rollback; then
            fail "Update aborted and rolled back to the previous, working image. Investigate the new image before trying ./scripts/update.sh again."
        fi
        fail "Container did not start after update, and rollback was not possible. Check logs: ./scripts/logs.sh"
    fi

    if ! wait_for_healthy; then
        warn "Container is running but did not become healthy within the expected time."
        if attempt_rollback; then
            fail "Update aborted and rolled back to the previous, working image. Investigate the new image (docker logs ${CONTAINER_NAME}) before trying ./scripts/update.sh again."
        fi
        fail "Container is unhealthy after update, and rollback was not possible. Check logs: ./scripts/logs.sh"
    fi

    ok "Container ${BOLD}${CONTAINER_NAME}${RESET} updated and healthy."
}

check_version() {
    step "Checking installed Claude Code version..."

    NEW_VERSION=$(docker exec "${CONTAINER_NAME}" claude --version 2>/dev/null || echo "unavailable")
    ok "Claude Code version: ${BOLD}${NEW_VERSION}${RESET}"
}

cleanup_old_images() {
    step "Removing dangling Docker images..."

    docker image prune -f 2>/dev/null || true
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
    sync_override_file
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
