#!/usr/bin/env bats

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
BACKUP_SCRIPT="$PROJECT_ROOT/scripts/backup.sh"

SESSION="test-session"

setup() {
  if ! command -v gpg &>/dev/null; then
    skip "gpg not available"
  fi

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

@test "--encrypt produces a .tar.gz.gpg archive and removes the plaintext one" {
  export BACKUP_ENCRYPT_PASSPHRASE="test-passphrase"
  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet --encrypt
  [ "$status" -eq 0 ]

  GPG_FILE="$(ls "$TMP_PROJECT/backups"/claude-code-dock-${SESSION}-backup-*.tar.gz.gpg 2>/dev/null | head -1)"
  [ -n "$GPG_FILE" ]

  PLAIN_FILE="$(ls "$TMP_PROJECT/backups"/claude-code-dock-${SESSION}-backup-*.tar.gz 2>/dev/null | head -1)"
  [ -z "$PLAIN_FILE" ]
  unset BACKUP_ENCRYPT_PASSPHRASE
}

@test "encrypted archive decrypts back to a valid tar.gz with BACKUP_ENCRYPT_PASSPHRASE" {
  export BACKUP_ENCRYPT_PASSPHRASE="test-passphrase"
  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet --encrypt
  [ "$status" -eq 0 ]

  GPG_FILE="$(ls "$TMP_PROJECT/backups"/claude-code-dock-${SESSION}-backup-*.tar.gz.gpg 2>/dev/null | head -1)"
  [ -n "$GPG_FILE" ]

  gpg --batch --yes --pinentry-mode loopback --passphrase "test-passphrase" \
      --decrypt "$GPG_FILE" > "$TEST_TMPDIR/decrypted.tar.gz" 2>/dev/null
  tar -tzf "$TEST_TMPDIR/decrypted.tar.gz" | grep -q "${SESSION}/settings.json"
  unset BACKUP_ENCRYPT_PASSPHRASE
}

@test "retention counts encrypted and plaintext archives together for the same session" {
  export BACKUP_ENCRYPT_PASSPHRASE="test-passphrase"
  export BACKUP_RETENTION=3

  for i in 1 2 3 4; do
    touch -d "2024-01-0${i} 00:00:00" \
      "$TMP_PROJECT/backups/claude-code-dock-${SESSION}-backup-2024-01-0${i}_00-00-00.tar.gz"
  done

  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet --encrypt
  [ "$status" -eq 0 ]

  REMAINING="$(ls "$TMP_PROJECT/backups"/claude-code-dock-${SESSION}-backup-*.tar.gz* 2>/dev/null | wc -l | tr -d ' ')"
  [ "$REMAINING" -eq 3 ]
  unset BACKUP_ENCRYPT_PASSPHRASE BACKUP_RETENTION
}

@test "without gpg installed, --encrypt fails loudly and keeps the plaintext archive" {
  FAKE_BIN="$TEST_TMPDIR/fakebin"
  mkdir -p "$FAKE_BIN"
  # type -P (not command -v) resolves the actual on-disk binary, bypassing
  # any shell function/alias of the same name that might shadow it in this
  # shell -- command -v would return a bare name for those instead of a path,
  # silently dropping the tool from this deliberately gpg-less PATH.
  for tool in bash tar grep cut tr date du ls xargs mkdir rm cp seq wc head basename dirname stat find sed mktemp; do
    resolved="$(type -P "$tool" 2>/dev/null || true)"
    [ -n "$resolved" ] && ln -sf "$resolved" "$FAKE_BIN/$tool"
  done

  PATH="$FAKE_BIN" run bash "$TMP_PROJECT/scripts/backup.sh" --quiet --encrypt
  [ "$status" -ne 0 ]

  PLAIN_FILE="$(ls "$TMP_PROJECT/backups"/claude-code-dock-${SESSION}-backup-*.tar.gz 2>/dev/null | head -1)"
  [ -n "$PLAIN_FILE" ]
}
