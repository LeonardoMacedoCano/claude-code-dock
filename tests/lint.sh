#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

ERRORS=0

SHELL_FILES=(
  "$PROJECT_DIR/docker/entrypoint.sh"
  "$PROJECT_DIR/docker/claude-console.sh"
  "$PROJECT_DIR/docker/claude-remote-launch.sh"
  "$PROJECT_DIR/scripts/install.sh"
  "$PROJECT_DIR/scripts/new-session.sh"
  "$PROJECT_DIR/scripts/session-up.sh"
  "$PROJECT_DIR/scripts/sessions.sh"
  "$PROJECT_DIR/scripts/status.sh"
  "$PROJECT_DIR/scripts/watchdog.sh"
  "$PROJECT_DIR/scripts/update.sh"
  "$PROJECT_DIR/scripts/backup.sh"
  "$PROJECT_DIR/scripts/restore.sh"
  "$PROJECT_DIR/scripts/attach.sh"
  "$PROJECT_DIR/scripts/shell.sh"
  "$PROJECT_DIR/scripts/logs.sh"
  "$PROJECT_DIR/scripts/claude.sh"
  "$PROJECT_DIR/scripts/remote.sh"
  "$PROJECT_DIR/tests/smoke.sh"
)

echo -e "${CYAN}[→]${RESET} ${BOLD}shellcheck${RESET}"

if ! command -v shellcheck &>/dev/null; then
  echo -e "  ${YELLOW}⚠${RESET} shellcheck not found — install with: apt install shellcheck"
else
  for f in "${SHELL_FILES[@]}"; do
    if [ ! -f "$f" ]; then
      continue
    fi
    if shellcheck --severity=warning "$f" 2>&1; then
      echo -e "  ${GREEN}✓${RESET} $(basename "$f")"
    else
      echo -e "  ${RED}✗${RESET} $(basename "$f")"
      ERRORS=$((ERRORS + 1))
    fi
  done
fi

echo ""
echo -e "${CYAN}[→]${RESET} ${BOLD}hadolint${RESET}"

if ! command -v hadolint &>/dev/null; then
  echo -e "  ${YELLOW}⚠${RESET} hadolint not found — install from: https://github.com/hadolint/hadolint"
else
  if hadolint "$PROJECT_DIR/Dockerfile" 2>&1; then
    echo -e "  ${GREEN}✓${RESET} Dockerfile"
  else
    echo -e "  ${RED}✗${RESET} Dockerfile"
    ERRORS=$((ERRORS + 1))
  fi
fi

echo ""
echo -e "${CYAN}[→]${RESET} ${BOLD}docker compose config${RESET}"

if docker compose version &>/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE_CMD="docker-compose"
else
  COMPOSE_CMD=""
fi

if [ -z "$COMPOSE_CMD" ]; then
  echo -e "  ${YELLOW}⚠${RESET} docker compose not found — install Docker to validate docker-compose.yml"
else
  # Every variable in docker-compose.yml has a `:-default` fallback, so this
  # must resolve cleanly with no .env and no exported vars at all -- a bare
  # syntax/interpolation error here is the actual regression this guards.
  if $COMPOSE_CMD -f "$PROJECT_DIR/docker-compose.yml" config --quiet 2>&1; then
    echo -e "  ${GREEN}✓${RESET} docker-compose.yml"
  else
    echo -e "  ${RED}✗${RESET} docker-compose.yml"
    ERRORS=$((ERRORS + 1))
  fi
fi

echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}✓ lint passed${RESET}"
else
  echo -e "${RED}${BOLD}✗ ${ERRORS} lint failure(s)${RESET}"
  exit 1
fi
