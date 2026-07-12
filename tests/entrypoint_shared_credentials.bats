#!/usr/bin/env bats

load helpers

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRYPOINT="$PROJECT_ROOT/docker/entrypoint.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  setup_entrypoint_env
  SHARED_CREDS_MOUNT="$HOME/.claude-shared-credentials.json"
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
}

@test "empty shared credentials file and no session credentials is a silent no-op" {
  : > "$SHARED_CREDS_MOUNT"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ ! -f "$SESSION_CREDS" ]
  [[ "$output" != *"Shared credentials"* ]]
}

@test "loads session credentials from a populated shared file" {
  echo '{"token":"shared-token"}' > "$SHARED_CREDS_MOUNT"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -f "$SESSION_CREDS" ]
  grep -q "shared-token" "$SESSION_CREDS"
  [[ "$output" == *"Shared credentials: loaded from SHARED_CREDENTIALS_FILE"* ]]
}

@test "seeds the shared file from an existing session login when the shared file is empty" {
  echo '{"token":"session-token"}' > "$SESSION_CREDS"
  : > "$SHARED_CREDS_MOUNT"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  grep -q "session-token" "$SHARED_CREDS_MOUNT"
  [[ "$output" == *"Shared credentials: seeded SHARED_CREDENTIALS_FILE"* ]]
}

@test "never overwrites a session's own existing credentials with a stale shared copy" {
  echo '{"token":"session-token"}' > "$SESSION_CREDS"
  echo '{"token":"stale-shared-token"}' > "$SHARED_CREDS_MOUNT"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  grep -q "session-token" "$SESSION_CREDS"
  ! grep -q "stale-shared-token" "$SESSION_CREDS"
  [[ "$output" != *"Shared credentials"* ]]
}

@test "shared credentials mount pointing at a directory warns instead of crashing" {
  mkdir -p "$SHARED_CREDS_MOUNT"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ ! -f "$SESSION_CREDS" ]
  [[ "$output" == *"SHARED_CREDENTIALS_FILE is a directory, not a file"* ]]
}
