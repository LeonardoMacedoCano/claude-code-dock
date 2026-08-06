#!/usr/bin/env bats

# Covers backups/<instance>/ (backup.sh's default output location once
# REMOTE_SESSION_NAME is known) together with restore.sh's backward
# compatibility for backups taken before this change, still sitting flat
# under ./backups/.

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
BACKUP_SCRIPT="$PROJECT_ROOT/scripts/backup.sh"
RESTORE_SCRIPT="$PROJECT_ROOT/scripts/restore.sh"

SESSION="jornada"

setup() {
  unset CONFIG_BASE_PATH REMOTE_SESSION_NAME WORKSPACE_PATH INSTANCE_CONFIG_PATH

  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  TMP_PROJECT="$TEST_TMPDIR/project"
  mkdir -p "$TMP_PROJECT/scripts"
  cp -r "$PROJECT_ROOT/scripts/lib" "$TMP_PROJECT/scripts/lib"
  cp "$BACKUP_SCRIPT" "$TMP_PROJECT/scripts/backup.sh"
  cp "$RESTORE_SCRIPT" "$TMP_PROJECT/scripts/restore.sh"

  mkdir -p "$TMP_PROJECT/configs/$SESSION"
  echo '{"marker":"instance-data"}' > "$TMP_PROJECT/configs/$SESSION/settings.json"
  printf 'CONFIG_BASE_PATH=./configs\nREMOTE_SESSION_NAME=%s\n' "$SESSION" > "$TMP_PROJECT/.env"

  export TMP_PROJECT
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "backup.sh writes into backups/<session>/ by default, not the flat legacy layout" {
  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  [ -f "$TMP_PROJECT/backups/$SESSION"/claude-code-dock-${SESSION}-backup-*.tar.gz ]
  # Nothing lands directly under the flat backups/ root for a named session.
  FLAT_COUNT=$(find "$TMP_PROJECT/backups" -maxdepth 1 -name '*.tar.gz' | wc -l | tr -d ' ')
  [ "$FLAT_COUNT" -eq 0 ]
}

@test "backup.sh --output DIR bypasses the per-instance subfolder entirely" {
  EXPLICIT_OUT="$TEST_TMPDIR/wherever-i-said"
  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet --output "$EXPLICIT_OUT"
  [ "$status" -eq 0 ]

  [ -f "$EXPLICIT_OUT"/claude-code-dock-${SESSION}-backup-*.tar.gz ]
}

@test "restore.sh --list finds a new per-instance backup" {
  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  run bash "$TMP_PROJECT/scripts/restore.sh" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-code-dock-${SESSION}-backup-"* ]]
}

@test "restore.sh --list also finds a legacy flat-layout backup from before this change" {
  mkdir -p "$TMP_PROJECT/backups"
  touch "$TMP_PROJECT/backups/claude-code-dock-${SESSION}-backup-2024-01-01_00-00-00.tar.gz"

  run bash "$TMP_PROJECT/scripts/restore.sh" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-code-dock-${SESSION}-backup-2024-01-01_00-00-00.tar.gz"* ]]
}

@test "restore.sh restores correctly from a legacy flat-layout backup (backward compatibility)" {
  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]
  NEW_ARCHIVE="$(ls "$TMP_PROJECT/backups/$SESSION"/claude-code-dock-${SESSION}-backup-*.tar.gz)"

  # Simulate a backup taken before this change: same content, but sitting
  # flat instead of in the new per-instance subfolder.
  mkdir -p "$TMP_PROJECT/backups"
  LEGACY_ARCHIVE="$TMP_PROJECT/backups/claude-code-dock-${SESSION}-backup-2024-01-01_00-00-00.tar.gz"
  cp "$NEW_ARCHIVE" "$LEGACY_ARCHIVE"
  rm -rf "$TMP_PROJECT/backups/$SESSION"

  echo '{"marker":"corrupted"}' > "$TMP_PROJECT/configs/$SESSION/settings.json"

  run bash -c "echo y | bash '$TMP_PROJECT/scripts/restore.sh' '$LEGACY_ARCHIVE'"
  [ "$status" -eq 0 ]

  CONTENT="$(cat "$TMP_PROJECT/configs/$SESSION/settings.json")"
  [ "$CONTENT" = '{"marker":"instance-data"}' ]
}

@test "restore.sh with no file specified picks the most recent backup across both locations" {
  mkdir -p "$TMP_PROJECT/backups/$SESSION"
  touch -d "2024-01-01 00:00:00" "$TMP_PROJECT/backups/claude-code-dock-${SESSION}-backup-2024-01-01_00-00-00.tar.gz"
  tar -czf "$TMP_PROJECT/backups/$SESSION/claude-code-dock-${SESSION}-backup-2024-06-01_00-00-00.tar.gz" -C "$TMP_PROJECT/configs" "$SESSION"
  touch -d "2024-06-01 00:00:00" "$TMP_PROJECT/backups/$SESSION/claude-code-dock-${SESSION}-backup-2024-06-01_00-00-00.tar.gz"

  run bash -c "echo n | bash '$TMP_PROJECT/scripts/restore.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2024-06-01"* ]]
}
