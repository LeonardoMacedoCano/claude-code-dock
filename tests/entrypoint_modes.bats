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
  rm -rf "$TEST_TMPDIR"
}

@test "interactive mode: tmux is called with claude as the command" {
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/tmux_args" ]
  grep -q "^claude$" "$TEST_TMPDIR/tmux_args"
}

@test "remote mode: passes --remote-control to claude" {
  export AUTO_START_MODE="remote"
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  grep -q "^--remote-control$" "$TEST_TMPDIR/tmux_args"
}

@test "remote mode: REMOTE_SESSION_NAME is appended after --remote-control" {
  export AUTO_START_MODE="remote"
  export REMOTE_SESSION_NAME="HomeServer"
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  CTRL_LINE=$(grep -n "^--remote-control$" "$TEST_TMPDIR/tmux_args" | cut -d: -f1)
  SESS_LINE=$(grep -n "^HomeServer$"       "$TEST_TMPDIR/tmux_args" | cut -d: -f1)
  [ -n "$CTRL_LINE" ]
  [ -n "$SESS_LINE" ]
  [ "$SESS_LINE" -gt "$CTRL_LINE" ]
}

@test "shell mode: does not call tmux" {
  export AUTO_START_MODE="shell"
  run bash "$ENTRYPOINT"
  [ ! -f "$TEST_TMPDIR/tmux_args" ]
}

@test "unknown mode is rejected with a fatal error instead of silently starting" {
  export AUTO_START_MODE="nonexistent"
  run bash "$ENTRYPOINT"
  [ -f "$TEST_TMPDIR/sleep_called" ]
  [ ! -f "$TEST_TMPDIR/tmux_args" ]
  [[ "$output" == *"FATAL"* ]]
  [[ "$output" == *"AUTO_START_MODE"* ]]
}

@test "CLAUDE_EXTRA_ARGS are appended to the command" {
  export CLAUDE_EXTRA_ARGS="--verbose --debug"
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  grep -q "^--verbose$" "$TEST_TMPDIR/tmux_args"
  grep -q "^--debug$"   "$TEST_TMPDIR/tmux_args"
}

@test "CLAUDE_EXTRA_ARGS preserves a quoted substring with spaces as one argument" {
  export CLAUDE_EXTRA_ARGS='--append-system-prompt "be terse" --verbose'
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  grep -q "^--append-system-prompt$" "$TEST_TMPDIR/tmux_args"
  grep -q "^be terse$"               "$TEST_TMPDIR/tmux_args"
  grep -q "^--verbose$"              "$TEST_TMPDIR/tmux_args"
}

@test "CLAUDE_EXTRA_ARGS with unbalanced quotes falls back to plain whitespace splitting instead of crashing" {
  export CLAUDE_EXTRA_ARGS='--verbose "unterminated'
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unbalanced quotes"* ]]
  grep -q "^--verbose$" "$TEST_TMPDIR/tmux_args"
}

@test "tmux session is always named 'main'" {
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/tmux_args" ]
  grep -q "^main$" "$TEST_TMPDIR/tmux_args"
}
