#!/usr/bin/env bats

# Roundtrip coverage for backup.sh + restore.sh together: create data, back it
# up, simulate loss/corruption, restore, and assert the data actually comes
# back byte-for-byte. Existing tests cover retention and encryption on the
# backup side only -- none exercised restore.sh at all before this file.

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
BACKUP_SCRIPT="$PROJECT_ROOT/scripts/backup.sh"
RESTORE_SCRIPT="$PROJECT_ROOT/scripts/restore.sh"

SESSION="restore-test-session"

setup() {
  # Same rationale as backup_retention.bats: don't let this suite inherit
  # CONFIG_BASE_PATH/REMOTE_SESSION_NAME/WORKSPACE_PATH from whatever
  # environment happens to be running it.
  unset CONFIG_BASE_PATH REMOTE_SESSION_NAME WORKSPACE_PATH

  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  TMP_PROJECT="$TEST_TMPDIR/project"
  mkdir -p "$TMP_PROJECT/scripts"
  mkdir -p "$TMP_PROJECT/configs/$SESSION"
  mkdir -p "$TMP_PROJECT/backups"

  echo '{"original":"credentials","marker":"roundtrip-test-value"}' > "$TMP_PROJECT/configs/$SESSION/settings.json"

  printf 'CONFIG_BASE_PATH=./configs\nREMOTE_SESSION_NAME=%s\n' "$SESSION" > "$TMP_PROJECT/.env"

  # Copied into place (not run from PROJECT_ROOT directly) so PROJECT_DIR
  # inside each script resolves to TMP_PROJECT -- matching how
  # backup_retention.bats isolates itself.
  cp "$BACKUP_SCRIPT" "$TMP_PROJECT/scripts/backup.sh"
  cp "$RESTORE_SCRIPT" "$TMP_PROJECT/scripts/restore.sh"

  export TMP_PROJECT
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

_latest_archive() {
  ls -t "$TMP_PROJECT/backups"/claude-code-dock-${SESSION}-backup-*.tar.gz 2>/dev/null | head -1
}

@test "restore roundtrip: corrupted data is restored byte-for-byte from backup" {
  ORIGINAL_CONTENT="$(cat "$TMP_PROJECT/configs/$SESSION/settings.json")"

  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  ARCHIVE="$(_latest_archive)"
  [ -n "$ARCHIVE" ]

  # Simulate data loss/corruption on the live config dir.
  echo '{"corrupted":"data"}' > "$TMP_PROJECT/configs/$SESSION/settings.json"

  # restore.sh's only prompt in this path ("Confirm restore? ... [y/N]")
  # since the archive path is passed explicitly as $1.
  run bash -c "echo y | bash '$TMP_PROJECT/scripts/restore.sh' '$ARCHIVE'"
  [ "$status" -eq 0 ]

  RESTORED_CONTENT="$(cat "$TMP_PROJECT/configs/$SESSION/settings.json")"
  [ "$RESTORED_CONTENT" = "$ORIGINAL_CONTENT" ]
}

@test "restore roundtrip: pre-restore safety backup of the corrupted state is created" {
  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]
  ARCHIVE="$(_latest_archive)"
  [ -n "$ARCHIVE" ]

  echo '{"corrupted":"data"}' > "$TMP_PROJECT/configs/$SESSION/settings.json"

  run bash -c "echo y | bash '$TMP_PROJECT/scripts/restore.sh' '$ARCHIVE'"
  [ "$status" -eq 0 ]

  SAFETY_COUNT=$(ls "$TMP_PROJECT/backups"/claude-code-dock-${SESSION}-pre-restore-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
  [ "$SAFETY_COUNT" -eq 1 ]
}

@test "restore --dry-run leaves current data untouched" {
  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]
  ARCHIVE="$(_latest_archive)"
  [ -n "$ARCHIVE" ]

  echo '{"corrupted":"data"}' > "$TMP_PROJECT/configs/$SESSION/settings.json"

  run bash "$TMP_PROJECT/scripts/restore.sh" --dry-run "$ARCHIVE"
  [ "$status" -eq 0 ]

  CURRENT_CONTENT="$(cat "$TMP_PROJECT/configs/$SESSION/settings.json")"
  [ "$CURRENT_CONTENT" = '{"corrupted":"data"}' ]
}

@test "restore declining confirmation leaves current data untouched" {
  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]
  ARCHIVE="$(_latest_archive)"
  [ -n "$ARCHIVE" ]

  echo '{"corrupted":"data"}' > "$TMP_PROJECT/configs/$SESSION/settings.json"

  run bash -c "echo n | bash '$TMP_PROJECT/scripts/restore.sh' '$ARCHIVE'"
  [ "$status" -eq 0 ]

  CURRENT_CONTENT="$(cat "$TMP_PROJECT/configs/$SESSION/settings.json")"
  [ "$CURRENT_CONTENT" = '{"corrupted":"data"}' ]
}
