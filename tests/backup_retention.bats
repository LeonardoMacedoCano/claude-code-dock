#!/usr/bin/env bats

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
BACKUP_SCRIPT="$PROJECT_ROOT/scripts/backup.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  # Fake project structure so SCRIPT_DIR/.. resolves to our temp project.
  TMP_PROJECT="$TEST_TMPDIR/project"
  mkdir -p "$TMP_PROJECT/scripts"
  mkdir -p "$TMP_PROJECT/config"
  mkdir -p "$TMP_PROJECT/backups"

  # config must have content for backup to proceed past the empty-dir check.
  echo '{"skipDangerousModePermissionPrompt":true}' > "$TMP_PROJECT/config/settings.json"

  # Copy the real script so PROJECT_DIR resolves to TMP_PROJECT.
  cp "$BACKUP_SCRIPT" "$TMP_PROJECT/scripts/backup.sh"

  export TMP_PROJECT
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

_create_old_backups() {
  local count="$1"
  for i in $(seq 1 "$count"); do
    local name
    name="$TMP_PROJECT/backups/claude-code-dock-backup-2024-01-$(printf '%02d' "$i")_00-00-00.tar.gz"
    touch "$name"
    # Set an old modification time so the new backup sorts ahead of these.
    touch -d "2024-01-$(printf '%02d' "$i") 00:00:00" "$name"
  done
}

@test "keeps only 10 most recent backups when 11 pre-existing backups are found" {
  _create_old_backups 11

  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  # After: 11 old + 1 new = 12 total; prune to 10.
  REMAINING="$(ls "$TMP_PROJECT/backups"/claude-code-dock-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
  [ "$REMAINING" -eq 10 ]
}

@test "does not remove any backup when count stays at 10 or fewer" {
  _create_old_backups 9

  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  # After: 9 old + 1 new = 10 total; no pruning.
  REMAINING="$(ls "$TMP_PROJECT/backups"/claude-code-dock-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
  [ "$REMAINING" -eq 10 ]
}

@test "exits cleanly and creates no archive when config directory is empty" {
  rm "$TMP_PROJECT/config/settings.json"

  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  ARCHIVES="$(ls "$TMP_PROJECT/backups"/claude-code-dock-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
  [ "$ARCHIVES" -eq 0 ]
}

@test "quiet flag suppresses all output" {
  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "respects BACKUP_RETENTION env var when set to a custom value" {
  _create_old_backups 6
  export BACKUP_RETENTION=5

  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  # After: 6 old + 1 new = 7 total; prune to 5.
  REMAINING="$(ls "$TMP_PROJECT/backups"/claude-code-dock-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
  [ "$REMAINING" -eq 5 ]
  unset BACKUP_RETENTION
}
