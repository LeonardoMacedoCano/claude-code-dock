#!/usr/bin/env bash

# Shared helpers for entrypoint tests.
# Loaded via 'load helpers' in each .bats file.
# Requires TEST_TMPDIR to be set and exported by the test's setup().

setup_entrypoint_env() {
  MOCK_HOME="$TEST_TMPDIR/home"
  MOCK_WORKSPACE="$TEST_TMPDIR/workspace"
  MOCK_BIN="$TEST_TMPDIR/bin"

  mkdir -p "$MOCK_HOME/.claude"
  mkdir -p "$MOCK_WORKSPACE"
  mkdir -p "$MOCK_BIN"

  export HOME="$MOCK_HOME"
  export WORKSPACE_DIR="$MOCK_WORKSPACE"
  export BUILD_SOURCE_FILE="$TEST_TMPDIR/no-build-source-marker"
  # Isolates the fatal() marker under TEST_TMPDIR -- without this override,
  # entrypoint.sh would rm/touch the real /tmp/claude-dock-fatal on whatever
  # host happens to be running this test suite.
  export FATAL_MARKER_FILE="$TEST_TMPDIR/fatal-marker"
  export PATH="$MOCK_BIN:$PATH"

  export AUTO_START_MODE="interactive"
  export CLAUDE_AUTO_APPROVE="true"
  export CLAUDE_EXTRA_ARGS=""
  export REMOTE_SESSION_NAME=""
  export TZ=""
  export GIT_USER_NAME=""
  export GIT_USER_EMAIL=""
  # Guaranteed-nonexistent path, not the real default (/run/secrets/github_token)
  # -- keeps tests hermetic regardless of what happens to exist on the host
  # actually running the suite, and matches the "no token mounted" state.
  export GITHUB_TOKEN_FILE="$TEST_TMPDIR/no-github-token-file-by-default"
  export GIT_REPO_URL=""

  _mock_claude
  _mock_tmux
  _mock_git
  _mock_sleep
}

_mock_claude() {
  cat > "$MOCK_BIN/claude" << 'EOF'
#!/bin/bash
[[ "$1" == "--version" ]] && echo "mock-claude-version"
exit 0
EOF
  chmod +x "$MOCK_BIN/claude"
}

_mock_tmux() {
  # Writes each received argument on its own line for easy grepping.
  cat > "$MOCK_BIN/tmux" << 'EOF'
#!/bin/bash
printf '%s\n' "$@" > "${TEST_TMPDIR}/tmux_args"
exit 0
EOF
  chmod +x "$MOCK_BIN/tmux"
}

_mock_git() {
  cat > "$MOCK_BIN/git" << 'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$MOCK_BIN/git"
}

# entrypoint.sh holds PID 1 on `sleep infinity` after a fatal config error
# instead of exiting, so tests must stub it out — otherwise `run bash
# entrypoint.sh` would hang forever on the fatal path. Marks that it ran via
# a sentinel file so tests can assert the fatal path was actually reached.
_mock_sleep() {
  cat > "$MOCK_BIN/sleep" << EOF
#!/bin/bash
touch "${TEST_TMPDIR}/sleep_called"
exit 0
EOF
  chmod +x "$MOCK_BIN/sleep"
}
