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
COMPOSE_PROJECT=""
COMPOSE_OVERRIDE_FILE=""

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
    # Must run before WORK_DIR is removed below -- it needs the override
    # file that lives under WORK_DIR/compose/ to know the compose project's
    # service list.
    if [ -n "${COMPOSE_PROJECT}" ]; then
        docker compose -p "${COMPOSE_PROJECT}" -f "${PROJECT_DIR}/docker-compose.yml" \
            -f "${COMPOSE_OVERRIDE_FILE:-/dev/null}" down -v --remove-orphans &>/dev/null || true
    fi
    # scripts/restore.sh always writes its pre-restore safety backup under
    # the real PROJECT_DIR/backups/ (it has no --output flag, unlike
    # backup.sh) -- test_disaster_recovery below points the main backup at a
    # WORK_DIR-scoped --output, but this one side effect isn't configurable,
    # so it's cleaned up explicitly here instead of leaking into a real
    # checkout's backups/ directory. Scoped to this run's RUN_ID so it can
    # never touch an operator's real backups if this is ever run outside CI.
    rm -f "${PROJECT_DIR}"/backups/claude-code-dock-smoke-dr-"${RUN_ID}"-*.tar.gz* &>/dev/null || true
    # Containers write into these mounted dirs as uid 1000 ('node'), which
    # doesn't match whoever ran this script (e.g. GitHub's ubuntu-24.04
    # runner user is uid 1001) -- a plain `rm -rf` can fail on files it
    # doesn't own (dock.log, backup snapshots, ...), which is harmless in CI
    # (the whole runner VM is discarded after the job) but would otherwise
    # leave undeletable directories behind on a real dev machine across
    # repeated local runs. `sudo` is passwordless on GitHub-hosted runners;
    # this stays a no-op failure (swallowed by `|| true`) wherever it isn't.
    if [ -n "${WORK_DIR}" ] && ! rm -rf "${WORK_DIR}" 2>/dev/null; then
        sudo rm -rf "${WORK_DIR}" 2>/dev/null || true
    fi
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

# Exercises the actual, real 'docker compose up' path -- every other check in
# this suite either mocks docker entirely (tests/*.bats) or boots the image
# via a raw 'docker run' (test_mode above), so nothing has ever verified that
# docker-compose.yml itself resolves and boots correctly end to end. Points
# the main service at the image already built above via a throwaway override
# (pull_policy: never, so it can never reach out to GHCR) instead of
# pulling/rebuilding.
test_compose_up() {
    local cdir="${WORK_DIR}/compose"
    local envfile="${cdir}/.env"
    local override="${cdir}/docker-compose.override.yml"
    local name="claude-code-dock-smoke-compose-${RUN_ID}"
    local project="smoke-compose-${RUN_ID}"

    log "Testing 'docker compose up'..."

    mkdir -p "${cdir}/workspace" "${cdir}/config"
    chmod 0777 "${cdir}/workspace" "${cdir}/config"

    cat > "${envfile}" <<ENV
WORKSPACE_PATH=${cdir}/workspace
CONFIG_BASE_PATH=${cdir}/config
REMOTE_SESSION_NAME=smoke-compose
CONTAINER_NAME=${name}
AUTO_START_MODE=interactive
ENV

    cat > "${override}" <<YAML
services:
  claude-code-dock:
    image: ${IMAGE_TAG}
    pull_policy: never
YAML

    if ! docker compose --env-file "${envfile}" -p "${project}" \
            -f "${PROJECT_DIR}/docker-compose.yml" -f "${override}" \
            up -d > "${cdir}/up.log" 2>&1; then
        err "FAILED: docker compose up failed"
        cat "${cdir}/up.log" >&2
        return 1
    fi
    # Recorded so cleanup() can 'compose down' this project even if a check
    # below fails and returns early.
    COMPOSE_PROJECT="${project}"
    COMPOSE_OVERRIDE_FILE="${override}"

    local deadline=$((SECONDS + HEALTHY_TIMEOUT))
    local status=""
    while [ $SECONDS -lt $deadline ]; do
        status="$(docker inspect --format '{{.State.Health.Status}}' "${name}" 2>/dev/null || echo "")"
        [ "${status}" = "healthy" ] && break
        [ "${status}" = "unhealthy" ] && break
        sleep 2
    done

    if [ "${status}" != "healthy" ]; then
        err "FAILED: compose-managed container did not become healthy within ${HEALTHY_TIMEOUT}s (last status: ${status:-none})"
        docker logs --tail 60 "${name}" 2>&1 >&2
        return 1
    fi

    ok "docker compose up: main service healthy."
    return 0
}

# Exercises scripts/backup.sh + scripts/restore.sh end to end against a real
# container -- tests/backup_restore.bats already covers the file-level
# round trip (tar in, tar out, bytes match), but never proves the thing
# operators actually depend on: that a container booted against a restored
# config directory is recognized as already-authenticated, not asked to log
# in again. A real Claude Code login isn't feasible in CI, so this fakes the
# credential file instead -- the check that matters is entrypoint.sh's own
# dock.log line, not the credential's content.
test_disaster_recovery() {
    local dr_dir="${WORK_DIR}/dr"
    local config_base="${dr_dir}/config_base"
    local session="smoke-dr-${RUN_ID}"
    local backups_dir="${dr_dir}/backups"
    local name="claude-code-dock-smoke-dr-${RUN_ID}"

    log "Testing disaster recovery (backup -> wipe -> restore -> boot)..."

    mkdir -p "${dr_dir}/workspace" "${config_base}/${session}" "${backups_dir}"
    chmod -R 0777 "${dr_dir}"

    echo '{"smokeTest":true,"fakeCredential":"dr-drill"}' > "${config_base}/${session}/.claude.json"

    if ! ( cd "${PROJECT_DIR}" && CONFIG_BASE_PATH="${config_base}" REMOTE_SESSION_NAME="${session}" \
            bash scripts/backup.sh --quiet --output "${backups_dir}" ); then
        err "FAILED: disaster recovery -- scripts/backup.sh failed"
        return 1
    fi

    local backup_file
    backup_file="$(ls -1t "${backups_dir}"/claude-code-dock-"${session}"-backup-*.tar.gz 2>/dev/null | head -1)"
    if [ -z "${backup_file}" ]; then
        err "FAILED: disaster recovery -- no backup archive was created"
        return 1
    fi

    # The actual disaster this drill proves recovery from.
    rm -rf "${config_base:?}/${session:?}"

    if ! ( cd "${PROJECT_DIR}" && CONFIG_BASE_PATH="${config_base}" REMOTE_SESSION_NAME="${session}" \
            CONTAINER_NAME="claude-code-dock-smoke-dr-nonexistent-${RUN_ID}" \
            bash -c 'echo y | bash scripts/restore.sh "$1"' _ "${backup_file}" ); then
        err "FAILED: disaster recovery -- scripts/restore.sh failed"
        return 1
    fi

    if [ ! -f "${config_base}/${session}/.claude.json" ]; then
        err "FAILED: disaster recovery -- restored directory is missing .claude.json"
        return 1
    fi
    ok "backup -> wipe -> restore round trip via the real scripts succeeded."

    # tar (inside restore.sh) recreates this directory from scratch during
    # extraction, owned by whoever ran it -- the same "chmod instead of
    # chown" reasoning as test_mode() above applies again here, and for the
    # same real-world reason: GitHub's ubuntu-24.04 runner user is uid 1001,
    # not 1000, so without this the restored directory is unwritable by the
    # container's node user and entrypoint.sh's own fatal() (correctly)
    # refuses to start, which is exactly what broke here before this line
    # was added.
    chmod -R 0777 "${config_base}/${session}"

    if ! docker run -d -i -t --name "${name}" \
            -e AUTO_START_MODE=interactive \
            -e REMOTE_SESSION_NAME="${session}" \
            -v "${dr_dir}/workspace:/workspace" \
            -v "${config_base}/${session}:/home/node/.claude" \
            "${IMAGE_TAG}" > /dev/null 2>"${dr_dir}/run.log"; then
        err "FAILED: disaster recovery -- could not boot container against restored config"
        cat "${dr_dir}/run.log" >&2
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
        err "FAILED: disaster recovery -- restored container did not become healthy within ${HEALTHY_TIMEOUT}s"
        docker logs --tail 60 "${name}" 2>&1 >&2
        return 1
    fi

    if ! docker exec --user node "${name}" grep -q "Persistent login: credentials loaded" /home/node/.claude/logs/dock.log 2>/dev/null; then
        err "FAILED: disaster recovery -- restored container did not recognize the restored credentials as already-authenticated"
        docker exec --user node "${name}" cat /home/node/.claude/logs/dock.log >&2 2>&1 || true
        return 1
    fi

    ok "disaster recovery drill passed -- restored credentials recognized after reboot."
    return 0
}

for mode in interactive remote shell; do
    if ! test_mode "${mode}"; then
        FAILED=1
    fi
done

if ! test_compose_up; then
    FAILED=1
fi

if ! test_disaster_recovery; then
    FAILED=1
fi

echo ""
if [ "${FAILED}" -eq 0 ]; then
    ok "${BOLD}All modes booted and reported healthy.${RESET}"
    exit 0
else
    err "${BOLD}One or more modes failed to boot healthy. See logs above.${RESET}"
    exit 1
fi
