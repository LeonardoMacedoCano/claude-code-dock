#!/usr/bin/env bats

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
BACKUP_SCRIPT="$PROJECT_ROOT/scripts/backup.sh"

SESSION="test-session"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  TMP_PROJECT="$TEST_TMPDIR/project"
  mkdir -p "$TMP_PROJECT/scripts"
  mkdir -p "$TMP_PROJECT/configs/$SESSION"
  mkdir -p "$TMP_PROJECT/backups"

  echo '{"skipDangerousModePermissionPrompt":true}' > "$TMP_PROJECT/configs/$SESSION/settings.json"

  printf 'CONFIG_BASE_PATH=./configs\nREMOTE_SESSION_NAME=%s\n' "$SESSION" > "$TMP_PROJECT/.env"

  cp "$BACKUP_SCRIPT" "$TMP_PROJECT/scripts/backup.sh"

  export TMP_PROJECT
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

_backup_pattern() {
  echo "claude-code-dock-${SESSION}-backup-*.tar.gz"
}

_create_old_backups() {
  local count="$1"
  for i in $(seq 1 "$count"); do
    local name
    name="$TMP_PROJECT/backups/claude-code-dock-${SESSION}-backup-2024-01-$(printf '%02d' "$i")_00-00-00.tar.gz"
    touch "$name"
    touch -d "2024-01-$(printf '%02d' "$i") 00:00:00" "$name"
  done
}

@test "keeps only 10 most recent backups when 11 pre-existing backups are found" {
  _create_old_backups 11

  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  REMAINING="$(ls "$TMP_PROJECT/backups"/claude-code-dock-${SESSION}-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
  [ "$REMAINING" -eq 10 ]
}

@test "does not remove any backup when count stays at 10 or fewer" {
  _create_old_backups 9

  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  REMAINING="$(ls "$TMP_PROJECT/backups"/claude-code-dock-${SESSION}-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
  [ "$REMAINING" -eq 10 ]
}

@test "exits cleanly and creates no archive when config directory is empty" {
  rm "$TMP_PROJECT/configs/$SESSION/settings.json"

  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  ARCHIVES="$(ls "$TMP_PROJECT/backups"/claude-code-dock-${SESSION}-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
  [ "$ARCHIVES" -eq 0 ]
}

@test "quiet flag suppresses all output but still creates the backup" {
  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  COUNT="$(ls "$TMP_PROJECT/backups"/claude-code-dock-${SESSION}-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
  [ "$COUNT" -eq 1 ]
}

@test "backup archive is a valid tar.gz containing session config data" {
  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  ARCHIVE="$(ls "$TMP_PROJECT/backups"/claude-code-dock-${SESSION}-backup-*.tar.gz 2>/dev/null | head -1)"
  [ -n "$ARCHIVE" ]
  tar -tzf "$ARCHIVE" | grep -q "${SESSION}/settings.json"
}

@test "backup filename includes REMOTE_SESSION_NAME" {
  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  ARCHIVE="$(ls "$TMP_PROJECT/backups"/claude-code-dock-${SESSION}-backup-*.tar.gz 2>/dev/null | head -1)"
  [ -n "$ARCHIVE" ]
}

@test "excludes GITHUB_TOKEN and CLAUDE_API_KEY from .env backup" {
  printf 'GITHUB_TOKEN=ghp_secret\nCLAUDE_API_KEY=sk-secret\nTZ=UTC\nCONFIG_BASE_PATH=./configs\nREMOTE_SESSION_NAME=%s\n' "$SESSION" > "$TMP_PROJECT/.env"

  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  ENV_BACKUP="$(ls "$TMP_PROJECT/backups/"*.env.backup 2>/dev/null | head -1)"
  [ -n "$ENV_BACKUP" ]
  run grep -E "^(GITHUB_TOKEN|CLAUDE_API_KEY)=" "$ENV_BACKUP"
  [ "$status" -ne 0 ]
}

@test "respects BACKUP_RETENTION env var when set to a custom value" {
  _create_old_backups 6
  export BACKUP_RETENTION=5

  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  REMAINING="$(ls "$TMP_PROJECT/backups"/claude-code-dock-${SESSION}-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
  [ "$REMAINING" -eq 5 ]
  unset BACKUP_RETENTION
}

@test "retention only counts backups from the same session, not other sessions" {
  for i in $(seq 1 12); do
    touch "$TMP_PROJECT/backups/claude-code-dock-other-session-backup-2024-01-$(printf '%02d' "$i")_00-00-00.tar.gz"
  done
  _create_old_backups 9

  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  SESSION_COUNT="$(ls "$TMP_PROJECT/backups"/claude-code-dock-${SESSION}-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
  OTHER_COUNT="$(ls "$TMP_PROJECT/backups"/claude-code-dock-other-session-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
  [ "$SESSION_COUNT" -eq 10 ]
  [ "$OTHER_COUNT" -eq 12 ]
}
