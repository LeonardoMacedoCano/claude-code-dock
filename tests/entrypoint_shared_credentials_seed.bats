#!/usr/bin/env bats

# Covers SHARED_CREDENTIALS_MODE=seed: opt-in alternative to the default
# "live" symlink+poller mechanism (see entrypoint_shared_credentials.bats).
# One-time copy at boot, no live link, no background poller. Promotion in
# the other direction is scripts/promote-credentials.sh, covered separately
# in promote_credentials.bats.

load helpers

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRYPOINT="$PROJECT_ROOT/docker/entrypoint.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  setup_entrypoint_env
  export SHARED_CREDENTIALS_MODE="seed"
  SHARED_CREDS_DIR="$HOME/.claude-shared-credentials"
  SHARED_CREDS_FILE="$SHARED_CREDS_DIR/.credentials.json"
  SESSION_CREDS="$HOME/.claude/.credentials.json"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "seed mode: no shared mount (the /dev/null idiom) is a silent no-op, same as live mode" {
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ ! -f "$SESSION_CREDS" ]
  [[ "$output" != *"Shared credentials"* ]]
}

@test "seed mode: empty shared pool and no local credentials -- session prompts for login normally, no file created" {
  mkdir -p "$SHARED_CREDS_DIR"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ ! -f "$SESSION_CREDS" ]
  [ ! -L "$SESSION_CREDS" ]
  [[ "$output" == *"Shared credentials (seed mode): no seed found"* ]]
}

@test "seed mode: a populated shared pool is copied into the session's own credentials file -- a plain file, not a symlink" {
  mkdir -p "$SHARED_CREDS_DIR"
  echo '{"token":"seed-token"}' > "$SHARED_CREDS_FILE"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -f "$SESSION_CREDS" ]
  [ ! -L "$SESSION_CREDS" ]
  grep -q "seed-token" "$SESSION_CREDS"
  [[ "$output" == *"provisioned this session's login from SHARED_CREDENTIALS_PATH"* ]]
}

@test "seed mode: an existing local login is never overwritten by the shared pool" {
  mkdir -p "$SHARED_CREDS_DIR"
  echo '{"token":"seed-token"}' > "$SHARED_CREDS_FILE"
  echo '{"token":"own-existing-login"}' > "$SESSION_CREDS"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  grep -q "own-existing-login" "$SESSION_CREDS"
  ! grep -q "seed-token" "$SESSION_CREDS"
  [[ "$output" == *"this session already has its own login"* ]]
}

@test "seed mode: a claude-style rename()-over-target write after boot is never touched -- there is no poller to intercept it" {
  mkdir -p "$SHARED_CREDS_DIR"
  echo '{"token":"seed-token"}' > "$SHARED_CREDS_FILE"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ -f "$SESSION_CREDS" ]

  # Simulate a login/refresh happening after boot inside this session.
  rm -f "$SESSION_CREDS"
  echo '{"token":"post-boot-refresh"}' > "$SESSION_CREDS"

  sleep 0.3

  # Unlike live mode, the shared pool is never touched by anything that
  # happens inside this session after boot -- promotion is only ever the
  # explicit, operator-run scripts/promote-credentials.sh.
  grep -q "seed-token" "$SHARED_CREDS_FILE"
  ! grep -q "post-boot-refresh" "$SHARED_CREDS_FILE"
}

@test "seed mode: unwritable shared directory warns and this session still starts normally" {
  mkdir -p "$SHARED_CREDS_DIR"
  chmod 555 "$SHARED_CREDS_DIR"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [[ "$output" == *"SHARED_CREDENTIALS_PATH is not writable"* ]]
  [ ! -f "$SESSION_CREDS" ]

  chmod 755 "$SHARED_CREDS_DIR"
}

@test "unset SHARED_CREDENTIALS_MODE defaults to live mode, not seed" {
  unset SHARED_CREDENTIALS_MODE
  mkdir -p "$SHARED_CREDS_DIR"
  echo '{"token":"seed-token"}' > "$SHARED_CREDS_FILE"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  # Live mode's own signature: a symlink, not a plain copied file.
  [ -L "$SESSION_CREDS" ]
  [[ "$output" == *"Shared credentials: session linked to SHARED_CREDENTIALS_PATH"* ]]
  [[ "$output" != *"seed mode"* ]]
}
