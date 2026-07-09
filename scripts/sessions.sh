#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║            claude-code-dock — Sessions               ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""

# Excludes the one-shot claude-code-dock-init permission-fixer containers
# (docker-compose.yml) -- the name filter below matches them too (it's a
# substring match), and without this they'd show up as fake "sessions"
# permanently sitting in Exited state, which isn't what they are. The `|| true`
# around grep matters: with zero matches (the common "no sessions yet" case),
# `grep -v` exits 1, and under this script's `set -o pipefail` that would
# otherwise abort the whole script right here instead of falling through to
# the empty-list message below.
CONTAINERS=$(docker ps -a --filter "name=claude-code-dock" --format "{{.Names}}" 2>/dev/null | { grep -v -- '-init$' || true; } | sort)

if [ -z "${CONTAINERS}" ]; then
    echo -e "  ${YELLOW}No claude-code-dock containers found.${RESET}"
    echo ""
    echo -e "  Start one with: ${BOLD}docker compose up -d${RESET}"
    echo ""
    exit 0
fi

printf "  ${BOLD}%-32s %-12s %-13s %-10s %s${RESET}\n" "CONTAINER" "STATUS" "MODE" "HEALTH" "SESSION"
echo -e "  ${CYAN}$(printf '%.0s─' {1..75})${RESET}"

while IFS= read -r name; do
    STATUS=$(docker inspect --format '{{.State.Status}}' "${name}" 2>/dev/null || echo "?")
    MODE=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${name}" 2>/dev/null \
        | grep "^AUTO_START_MODE=" | cut -d= -f2 || echo "")
    HEALTH=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}—{{end}}' "${name}" 2>/dev/null || echo "?")
    SESSION=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${name}" 2>/dev/null \
        | grep "^REMOTE_SESSION_NAME=" | cut -d= -f2 || echo "")

    case "${STATUS}" in
        running)  STATUS_COLOR="${GREEN}" ;;
        exited)   STATUS_COLOR="${RED}" ;;
        *)        STATUS_COLOR="${YELLOW}" ;;
    esac

    case "${HEALTH}" in
        healthy)   HEALTH_COLOR="${GREEN}" ;;
        unhealthy) HEALTH_COLOR="${RED}" ;;
        *)         HEALTH_COLOR="${RESET}" ;;
    esac

    printf "  %-32s ${STATUS_COLOR}%-12s${RESET} %-13s ${HEALTH_COLOR}%-10s${RESET} %s\n" \
        "${name}" \
        "${STATUS}" \
        "${MODE:-interactive}" \
        "${HEALTH}" \
        "${SESSION:-—}"
done <<< "${CONTAINERS}"

TOTAL=$(echo "${CONTAINERS}" | wc -l | tr -d ' ')
RUNNING=$(docker ps --filter "name=claude-code-dock" --format "{{.Names}}" 2>/dev/null | { grep -v -- '-init$' || true; } | wc -l | tr -d ' ')

echo ""
echo -e "  ${BOLD}${RUNNING}/${TOTAL}${RESET} container(s) running"
echo ""
echo -e "  ${YELLOW}Quick commands${RESET}"
echo -e "  Attach to a session:  ${BOLD}docker exec -it --user node <container> tmux attach-session -t main${RESET}"
echo -e "  New session:          ${BOLD}./scripts/new-session.sh${RESET}"
echo -e "  Session detail:       ${BOLD}CONTAINER_NAME=<name> ./scripts/status.sh${RESET}"
echo ""
