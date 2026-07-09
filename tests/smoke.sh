#!/usr/bin/env bash
# Builds the image and boots REAL containers in each AUTO_START_MODE,
# waiting for Docker's own HEALTHCHECK to report "healthy". This is the one
# check nothing else in the test suite does: tests/*.bats mocks `docker`
# entirely and only exercises entrypoint.sh's shell logic in isolation, so a
# regression that only shows up when the script actually execs inside a real
# container (a `set -e` trap on a real failing command, a setpriv/tmux
# interaction, a HEALTHCHECK CMD that doesn't parse) can pass every bats test
# and still ship a broken image. Run this locally before opening a PR that
# touches Dockerfile/docker/entrypoint.sh, or let CI run it (see
# .github/workflows/docker-publish.yml) before anything is pushed to GHCR.
#
# No `set -e`: test_mode's own logic needs to keep going after a single
# mode fails, so every mode gets a result instead of aborting on the first
# failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

IMAGE_TAG="claude-code-dock:smoke-test"
RUN_ID="$$-$(date +%s)"
WORK_DIR=""
HEALTHY_TIMEOUT=90
FAILED=0
CONTAINERS_STARTED=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()  { echo -e "${CYAN}[smoke]${RESET} $1"; }
ok()   { echo -e "${GREEN}[smoke]${RESET} $1"; }
warn() { echo -e "${YELLOW}[smoke]${RESET} $1"; }
err()  { echo -e "${RED}[smoke]${RESET} $1" >&2; }

cleanup() {
    for name in "${CONTAINERS_STARTED[@]:-}"; do
        [ -n "$name" ] && docker rm -f "$name" &>/dev/null || true
    done
    [ -n "${WORK_DIR}" ] && rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

WORK_DIR="$(mktemp -d)"

log "Building image (${IMAGE_TAG})..."
if ! docker build -t "${IMAGE_TAG}" --build-arg CACHEBUST="${RUN_ID}" "${PROJECT_DIR}" \
        > "${WORK_DIR}/build.log" 2>&1; then
    err "Image build failed. Last 50 lines:"
    tail -50 "${WORK_DIR}/build.log" >&2
    exit 1
fi
ok "Image built."

# Verifies AUTO_START_MODE=$1 actually reaches Docker's "healthy" status
# within HEALTHY_TIMEOUT -- not just "the container didn't crash", but the
# same HEALTHCHECK Docker itself uses in production to decide whether to
# report this instance as up.
test_mode() {
    local mode="$1"
    local name="claude-code-dock-smoke-${mode}-${RUN_ID}"
    local mode_dir="${WORK_DIR}/${mode}"

    log "Testing AUTO_START_MODE=${mode}..."
    mkdir -p "${mode_dir}/workspace" "${mode_dir}/config"
    # The container always runs as uid/gid 1000 here (no PUID/PGID set
    # below), but the host user creating these dirs varies by CI runner
    # image (e.g. GitHub's ubuntu-24.04 runner user is uid 1001, not 1000)
    # and by whoever runs this locally. chmod instead of chown so this works
    # without root/sudo either way -- these are throwaway dirs under mktemp.
    chmod 0777 "${mode_dir}/workspace" "${mode_dir}/config"

    # -i -t mirrors docker-compose.yml's stdin_open/tty (required for the
    # tmux session entrypoint.sh execs into -- without a PTY, `tmux
    # new-session` fails with "open terminal failed: not a terminal" and
    # the session, and thus the healthcheck, never comes up.
    if ! docker run -d -i -t --name "${name}" \
            -e AUTO_START_MODE="${mode}" \
            -e REMOTE_SESSION_NAME="smoke-${mode}" \
            -v "${mode_dir}/workspace:/workspace" \
            -v "${mode_dir}/config:/home/node/.claude" \
            "${IMAGE_TAG}" > /dev/null 2>"${mode_dir}/run.log"; then
        err "FAILED: could not start container for mode=${mode}"
        cat "${mode_dir}/run.log" >&2
        return 1
    fi
    CONTAINERS_STARTED+=("${name}")

    local deadline=$((SECONDS + HEALTHY_TIMEOUT))
    local status=""
    while [ $SECONDS -lt $deadline ]; do
        status="$(docker inspect --format '{{.State.Health.Status}}' "${name}" 2>/dev/null || echo "")"
        [ "${status}" = "healthy" ] && break
        [ "${status}" = "unhealthy" ] && break
        sleep 2
    done

    if [ "${status}" != "healthy" ]; then
        err "FAILED: mode=${mode} did not become healthy within ${HEALTHY_TIMEOUT}s (last status: ${status:-none})"
        echo "--- docker logs ${name} (last 60 lines) ---" >&2
        docker logs --tail 60 "${name}" 2>&1 >&2
        return 1
    fi

    ok "mode=${mode} is healthy."
    return 0
}

for mode in interactive remote shell; do
    if ! test_mode "${mode}"; then
        FAILED=1
    fi
done

echo ""
if [ "${FAILED}" -eq 0 ]; then
    ok "${BOLD}All modes booted and reported healthy.${RESET}"
    exit 0
else
    err "${BOLD}One or more modes failed to boot healthy. See logs above.${RESET}"
    exit 1
fi
