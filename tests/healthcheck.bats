#!/usr/bin/env bats

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DOCKERFILE="$PROJECT_ROOT/Dockerfile"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  MOCK_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$MOCK_BIN"
  export PATH="$MOCK_BIN:$PATH"

  # Extracted verbatim from the Dockerfile (not retyped here) so this test
  # always exercises whatever HEALTHCHECK logic actually ships, instead of a
  # hand-copied version that could silently drift from it.
  HEALTHCHECK_CMD="$(sed -n '/^    CMD if/,/^        fi$/p' "$DOCKERFILE" | sed '1s/^[[:space:]]*CMD[[:space:]]*//')"
  export HEALTHCHECK_CMD
  [ -n "$HEALTHCHECK_CMD" ]
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

_mock_ps_comm() {
  cat > "$MOCK_BIN/ps" << EOF
#!/bin/bash
echo "$1"
EOF
  chmod +x "$MOCK_BIN/ps"
}

# $1: exit code for 'tmux has-session', $2: value printed for 'pane_dead'
_mock_tmux() {
  cat > "$MOCK_BIN/tmux" << EOF
#!/bin/bash
if [ "\$1" = "has-session" ]; then
  exit $1
fi
if [ "\$1" = "list-panes" ]; then
  echo "$2"
  exit 0
fi
exit 1
EOF
  chmod +x "$MOCK_BIN/tmux"
}

@test "shell mode: healthy when PID 1 is bash" {
  export AUTO_START_MODE="shell"
  _mock_ps_comm "bash"
  run bash -c "$HEALTHCHECK_CMD"
  [ "$status" -eq 0 ]
}

@test "shell mode: unhealthy when PID 1 is not bash" {
  export AUTO_START_MODE="shell"
  _mock_ps_comm "sh"
  run bash -c "$HEALTHCHECK_CMD"
  [ "$status" -ne 0 ]
}

@test "interactive mode: healthy when tmux session exists and pane is alive" {
  export AUTO_START_MODE="interactive"
  _mock_tmux 0 0
  run bash -c "$HEALTHCHECK_CMD"
  [ "$status" -eq 0 ]
}

@test "interactive mode: unhealthy when tmux session does not exist" {
  export AUTO_START_MODE="interactive"
  _mock_tmux 1 0
  run bash -c "$HEALTHCHECK_CMD"
  [ "$status" -ne 0 ]
}

@test "interactive mode: unhealthy when tmux session exists but pane is dead" {
  export AUTO_START_MODE="interactive"
  _mock_tmux 0 1
  run bash -c "$HEALTHCHECK_CMD"
  [ "$status" -ne 0 ]
}

@test "remote mode: uses the same session+pane check as interactive" {
  export AUTO_START_MODE="remote"
  _mock_tmux 0 0
  run bash -c "$HEALTHCHECK_CMD"
  [ "$status" -eq 0 ]

  _mock_tmux 0 1
  run bash -c "$HEALTHCHECK_CMD"
  [ "$status" -ne 0 ]
}

@test "unset AUTO_START_MODE defaults to the interactive (tmux) check" {
  unset AUTO_START_MODE
  _mock_tmux 0 0
  run bash -c "$HEALTHCHECK_CMD"
  [ "$status" -eq 0 ]
}
