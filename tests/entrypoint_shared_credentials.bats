#!/usr/bin/env bats

load helpers

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRYPOINT="$PROJECT_ROOT/docker/entrypoint.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  setup_entrypoint_env
  SHARED_CREDS_DIR="$HOME/.claude-shared-credentials"
  SHARED_CREDS_FILE="$SHARED_CREDS_DIR/.credentials.json"
  SESSION_CREDS="$HOME/.claude/.credentials.json"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "no shared credentials mount (the /dev/null idiom) is a silent no-op" {
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ ! -f "$SESSION_CREDS" ]
  [[ "$output" != *"Shared credentials"* ]]
  [[ "$output" != *"SHARED_CREDENTIALS_PATH"* ]]
}

@test "empty shared credentials dir and no session credentials links without logging" {
  mkdir -p "$SHARED_CREDS_DIR"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -L "$SESSION_CREDS" ]
  [ ! -f "$SESSION_CREDS" ]
  [[ "$output" != *"Shared credentials"* ]]
}

@test "loads session credentials from a populated shared directory" {
  mkdir -p "$SHARED_CREDS_DIR"
  echo '{"token":"shared-token"}' > "$SHARED_CREDS_FILE"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -L "$SESSION_CREDS" ]
  [ -f "$SESSION_CREDS" ]
  grep -q "shared-token" "$SESSION_CREDS"
  [[ "$output" == *"Shared credentials: session linked to SHARED_CREDENTIALS_PATH"* ]]
}

@test "promotes an existing session login into an empty shared directory and links to it" {
  echo '{"token":"session-token"}' > "$SESSION_CREDS"
  mkdir -p "$SHARED_CREDS_DIR"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -L "$SESSION_CREDS" ]
  grep -q "session-token" "$SHARED_CREDS_FILE"
  grep -q "session-token" "$SESSION_CREDS"
  [[ "$output" == *"Shared credentials: promoted this session's own login into SHARED_CREDENTIALS_PATH"* ]]
  # The "session linked ... skips first login" message is for the load-from-shared
  # case only -- it must not also fire right after a promotion, which would
  # falsely imply this session skipped a login it actually just provided.
  [[ "$output" != *"session linked to SHARED_CREDENTIALS_PATH"* ]]
}

@test "an existing session login promotion overwrites a stale shared copy and warns about it" {
  echo '{"token":"session-token"}' > "$SESSION_CREDS"
  mkdir -p "$SHARED_CREDS_DIR"
  echo '{"token":"stale-shared-token"}' > "$SHARED_CREDS_FILE"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -L "$SESSION_CREDS" ]
  grep -q "session-token" "$SESSION_CREDS"
  grep -q "session-token" "$SHARED_CREDS_FILE"
  ! grep -q "stale-shared-token" "$SESSION_CREDS"
  [[ "$output" == *"Shared credentials: promoted this session's own login into SHARED_CREDENTIALS_PATH"* ]]
  [[ "$output" == *"SHARED_CREDENTIALS_PATH already held different credentials"* ]]
}

@test "promoting identical session/shared credentials does not warn about replacing different content" {
  echo '{"token":"same-token"}' > "$SESSION_CREDS"
  mkdir -p "$SHARED_CREDS_DIR"
  echo '{"token":"same-token"}' > "$SHARED_CREDS_FILE"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [[ "$output" != *"already held different credentials"* ]]
}

@test "a login performed after startup is written straight into the shared file via the symlink" {
  mkdir -p "$SHARED_CREDS_DIR"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ -L "$SESSION_CREDS" ]

  echo '{"token":"post-boot-login"}' > "$SESSION_CREDS"

  grep -q "post-boot-login" "$SHARED_CREDS_FILE"
}

@test "unwritable shared credentials directory warns and skips sync instead of crashing" {
  mkdir -p "$SHARED_CREDS_DIR"
  chmod 555 "$SHARED_CREDS_DIR"
  echo '{"token":"session-token"}' > "$SESSION_CREDS"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [[ "$output" == *"SHARED_CREDENTIALS_PATH is not writable"* ]]
  [ ! -L "$SESSION_CREDS" ]

  chmod 755 "$SHARED_CREDS_DIR"
}

@test "a session already linked recovers a local copy when the shared dir turns unwritable" {
  mkdir -p "$SHARED_CREDS_DIR"
  echo '{"token":"already-shared-token"}' > "$SHARED_CREDS_FILE"
  ln -sf "$SHARED_CREDS_FILE" "$SESSION_CREDS"
  chmod 555 "$SHARED_CREDS_DIR"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [[ "$output" == *"SHARED_CREDENTIALS_PATH is not writable"* ]]
  [[ "$output" == *"Recovered a local copy of this session's credentials"* ]]
  [ ! -L "$SESSION_CREDS" ]
  grep -q "already-shared-token" "$SESSION_CREDS"

  chmod 755 "$SHARED_CREDS_DIR"
}
