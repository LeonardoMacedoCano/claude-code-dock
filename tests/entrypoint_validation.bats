#!/usr/bin/env bats

load helpers

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRYPOINT="$PROJECT_ROOT/docker/entrypoint.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  setup_entrypoint_env
}

teardown() {
  # Restore permissions so the tmpdir can be removed.
  chmod -R u+rwx "$TEST_TMPDIR" 2>/dev/null || true
  rm -rf "$TEST_TMPDIR"
}

@test "valid AUTO_START_MODE values pass validation" {
  for mode in interactive remote shell; do
    export AUTO_START_MODE="$mode"
    run bash "$ENTRYPOINT"
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMPDIR/sleep_called" ]
  done
}

@test "missing claude binary triggers fatal instead of a bare exit" {
  rm -f "$MOCK_BIN/claude"
  # Restrict PATH to the mocks plus base coreutils dirs only, so a real
  # 'claude' binary installed elsewhere on the host (e.g. /usr/local/bin,
  # true for this very repo's own dev container) can't leak into the test.
  export PATH="$MOCK_BIN:/usr/bin:/bin"
  run bash "$ENTRYPOINT"
  [ -f "$TEST_TMPDIR/sleep_called" ]
  [[ "$output" == *"FATAL"* ]]
  [[ "$output" == *"Claude Code binary missing"* ]]
}

@test "unwritable config directory triggers fatal with a chown hint" {
  if [ "$(id -u)" = "0" ]; then
    skip "running as root bypasses permission checks"
  fi
  chmod 000 "$MOCK_HOME/.claude"

  run bash "$ENTRYPOINT"

  chmod 700 "$MOCK_HOME/.claude"
  [ -f "$TEST_TMPDIR/sleep_called" ]
  [ ! -f "$TEST_TMPDIR/tmux_args" ]
  [[ "$output" == *"FATAL"* ]]
  [[ "$output" == *"chown -R 1000:1000"* ]]
}

@test "unwritable workspace directory triggers fatal with a chown hint" {
  if [ "$(id -u)" = "0" ]; then
    skip "running as root bypasses permission checks"
  fi
  chmod 000 "$MOCK_WORKSPACE"

  run bash "$ENTRYPOINT"

  chmod 700 "$MOCK_WORKSPACE"
  [ -f "$TEST_TMPDIR/sleep_called" ]
  [ ! -f "$TEST_TMPDIR/tmux_args" ]
  [[ "$output" == *"FATAL"* ]]
  [[ "$output" == *"WORKSPACE_PATH"* ]]
}

@test "writable directories and a valid mode never call the fatal path" {
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMPDIR/sleep_called" ]
  [ -f "$TEST_TMPDIR/tmux_args" ]
}

@test "fatal() leaves a marker file for scripts/watchdog.sh to detect" {
  export AUTO_START_MODE="not-a-real-mode"
  run bash "$ENTRYPOINT"
  [ -f "$TEST_TMPDIR/sleep_called" ]
  [ -f "$FATAL_MARKER_FILE" ]
}

@test "a successful run clears any stale fatal marker from a prior run" {
  touch "$FATAL_MARKER_FILE"
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ ! -f "$FATAL_MARKER_FILE" ]
}
