#!/usr/bin/env bash
# Entrypoint for the optional watchdog sidecar (docker-compose.watchdog.yml).
# Runs scripts/watchdog.sh against the main claude-code-dock container on a
# fixed interval, forever -- the container-native equivalent of the host
# crontab entry `scripts/install.sh --with-watchdog` sets up. Prefer that
# cron entry unless this host genuinely can't run one (see
# docker-compose.watchdog.yml for the docker.sock trade-off this sidecar
# accepts in exchange).
#
# No `set -e`: watchdog.sh returning non-zero (e.g. a failed `docker restart`)
# must not kill this loop -- it should log the failure and try again next
# interval, same as a cron job would on its next tick.
set -uo pipefail

INTERVAL="${WATCHDOG_INTERVAL:-300}"
TARGET="${CONTAINER_NAME:-claude-code-dock}"

echo "watchdog sidecar: watching '${TARGET}' every ${INTERVAL}s"

while true; do
    /usr/local/bin/watchdog.sh "${TARGET}" || true
    sleep "${INTERVAL}"
done
