#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║           claude-code-dock — Test Suite              ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""

LINT_ERRORS=0
bash "$SCRIPT_DIR/lint.sh" || LINT_ERRORS=1
echo ""

if ! command -v bats &>/dev/null; then
  echo -e "${RED}[✗]${RESET} bats not found."
  echo ""
  echo -e "  Install with one of:"
  echo -e "  ${BOLD}npm install -g bats${RESET}"
  echo -e "  ${BOLD}apt install bats${RESET}"
  echo -e "  ${BOLD}brew install bats-core${RESET}"
  echo ""
  exit 1
fi

echo -e "${CYAN}[→]${RESET} ${BOLD}bats${RESET}"
echo ""

BATS_FILES=(
  "$SCRIPT_DIR/entrypoint_modes.bats"
  "$SCRIPT_DIR/entrypoint_validation.bats"
  "$SCRIPT_DIR/entrypoint_symlink.bats"
  "$SCRIPT_DIR/entrypoint_settings.bats"
  "$SCRIPT_DIR/entrypoint_shared_config.bats"
  "$SCRIPT_DIR/entrypoint_github_token.bats"
  "$SCRIPT_DIR/entrypoint_puid_pgid.bats"
  "$SCRIPT_DIR/backup_retention.bats"
  "$SCRIPT_DIR/backup_encrypt.bats"
  "$SCRIPT_DIR/backup_restore.bats"
  "$SCRIPT_DIR/healthcheck.bats"
  "$SCRIPT_DIR/status_update_check.bats"
  "$SCRIPT_DIR/session_up.bats"
  "$SCRIPT_DIR/watchdog.bats"
)

BATS_ERRORS=0
bats "${BATS_FILES[@]}" || BATS_ERRORS=1

echo ""
if [ "$LINT_ERRORS" -eq 0 ] && [ "$BATS_ERRORS" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}✓ All checks passed${RESET}"
else
  echo -e "${RED}${BOLD}✗ Some checks failed${RESET}"
  exit 1
fi
echo ""
