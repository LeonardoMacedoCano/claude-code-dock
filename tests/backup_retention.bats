#!/usr/bin/env bats

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
BACKUP_SCRIPT="$PROJECT_ROOT/scripts/backup.sh"

SESSION="test-session"

setup() {
  # backup.sh now honors an already-exported CONFIG_BASE_PATH/
  # REMOTE_SESSION_NAME/WORKSPACE_PATH over .env (see load_env() fix) -- so
  # these tests must not inherit whatever the ambient shell running the suite
  # happens to have set (e.g. this very suite can run inside a
  # claude-code-dock container, which exports exactly these three), or the
  # test's own throwaway .env would be silently ignored.
  unset CONFIG_BASE_PATH REMOTE_SESSION_NAME WORKSPACE_PATH

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

@test "excludes secret-looking variables (TOKEN/KEY/SECRET/PASSWORD/PASSPHRASE) from .env backup" {
  printf 'SOME_SERVICE_TOKEN=ghp_secret\nEXAMPLE_API_KEY=sk-secret\nSOME_SECRET=s3cr3t\nSOME_PASSWORD=hunter2\nSOME_PASSPHRASE=letmein\nTZ=UTC\nCONFIG_BASE_PATH=./configs\nREMOTE_SESSION_NAME=%s\n' "$SESSION" > "$TMP_PROJECT/.env"

  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  ARCHIVE="$(ls "$TMP_PROJECT/backups"/claude-code-dock-${SESSION}-backup-*.tar.gz 2>/dev/null | head -1)"
  [ -n "$ARCHIVE" ]

  EXTRACT_DIR="$(mktemp -d)"
  tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR" .env.backup 2>/dev/null
  [ -f "$EXTRACT_DIR/.env.backup" ]
  run grep -E "^(SOME_SERVICE_TOKEN|EXAMPLE_API_KEY|SOME_SECRET|SOME_PASSWORD|SOME_PASSPHRASE)=" "$EXTRACT_DIR/.env.backup"
  [ "$status" -ne 0 ]
  grep -q "^TZ=UTC" "$EXTRACT_DIR/.env.backup"
  rm -rf "$EXTRACT_DIR"
}

@test "excludes secret-looking variables (CREDENTIAL/AUTH/CERT) while preserving *_PATH vars from .env backup" {
  printf 'SOME_CREDENTIAL=abc123\nSOME_AUTH_HEADER=bearer-xyz\nSOME_CERT_DATA=----BEGIN\nWORKSPACE_PATH=/mnt/user/projects\nCONFIG_BASE_PATH=./configs\nGLOBAL_CONFIG_PATH=./global\nREMOTE_SESSION_NAME=%s\n' "$SESSION" > "$TMP_PROJECT/.env"

  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  ARCHIVE="$(ls "$TMP_PROJECT/backups"/claude-code-dock-${SESSION}-backup-*.tar.gz 2>/dev/null | head -1)"
  [ -n "$ARCHIVE" ]

  EXTRACT_DIR="$(mktemp -d)"
  tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR" .env.backup 2>/dev/null
  [ -f "$EXTRACT_DIR/.env.backup" ]

  run grep -E "^(SOME_CREDENTIAL|SOME_AUTH_HEADER|SOME_CERT_DATA)=" "$EXTRACT_DIR/.env.backup"
  [ "$status" -ne 0 ]

  # *_PATH vars must survive -- PAT is deliberately not in the denylist
  # because it collides with this exact suffix (see backup.sh comment).
  grep -q "^WORKSPACE_PATH=/mnt/user/projects$" "$EXTRACT_DIR/.env.backup"
  grep -q "^CONFIG_BASE_PATH=./configs$" "$EXTRACT_DIR/.env.backup"
  grep -q "^GLOBAL_CONFIG_PATH=./global$" "$EXTRACT_DIR/.env.backup"
  rm -rf "$EXTRACT_DIR"
}

@test "process-exported CONFIG_BASE_PATH/REMOTE_SESSION_NAME are honored even without a matching .env file" {
  rm -f "$TMP_PROJECT/.env"
  mkdir -p "$TMP_PROJECT/other-configs/$SESSION"
  echo '{"skipDangerousModePermissionPrompt":true}' > "$TMP_PROJECT/other-configs/$SESSION/settings.json"

  export CONFIG_BASE_PATH="$TMP_PROJECT/other-configs"
  export REMOTE_SESSION_NAME="$SESSION"

  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  ARCHIVE="$(ls "$TMP_PROJECT/backups"/claude-code-dock-${SESSION}-backup-*.tar.gz 2>/dev/null | head -1)"
  [ -n "$ARCHIVE" ]
  tar -tzf "$ARCHIVE" | grep -q "${SESSION}/settings.json"

  unset CONFIG_BASE_PATH REMOTE_SESSION_NAME
}

@test "excludes credential-embedded URLs (e.g. GIT_REPO_URL with an inline token) from .env backup" {
  printf 'GIT_REPO_URL=https://x-access-token:ghp_secrettoken@github.com/user/repo.git\nTZ=UTC\nCONFIG_BASE_PATH=./configs\nREMOTE_SESSION_NAME=%s\n' "$SESSION" > "$TMP_PROJECT/.env"

  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  ARCHIVE="$(ls "$TMP_PROJECT/backups"/claude-code-dock-${SESSION}-backup-*.tar.gz 2>/dev/null | head -1)"
  [ -n "$ARCHIVE" ]

  EXTRACT_DIR="$(mktemp -d)"
  tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR" .env.backup 2>/dev/null
  [ -f "$EXTRACT_DIR/.env.backup" ]
  run grep -q "ghp_secrettoken" "$EXTRACT_DIR/.env.backup"
  [ "$status" -ne 0 ]
  grep -q "^TZ=UTC" "$EXTRACT_DIR/.env.backup"
  rm -rf "$EXTRACT_DIR"
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
