#!/usr/bin/env bats

# Characterization test, not a regression test for a bug fix -- documents a
# gap identified in docs/multi-instance-architecture-proposal.md §2.4 #14 /
# §9.2: SHARED_CREDENTIALS_PATH's promotion has no locking. This test
# changes no production code and asserts CURRENT (unchanged) behavior, so it
# can be used as a before/after comparison once the credential-seed model
# proposed in that document's §5.2 (a one-time copy, not a live symlink)
# actually ships.
#
# Two instances are simulated as two independent HOME trees, each with its
# own pre-existing (not yet promoted) local credentials, both pointed at the
# SAME shared directory -- mirroring two containers bind-mounting the same
# host SHARED_CREDENTIALS_PATH. Run sequentially (not truly concurrently)
# deliberately: the risk being documented does not require nanosecond-level
# interleaving to demonstrate, and a genuinely racy test here would make an
# unrelated PR's CI run flaky for no benefit -- see the proposal §9.2.

load helpers

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRYPOINT="$PROJECT_ROOT/docker/entrypoint.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  SHARED_DIR="$TEST_TMPDIR/shared"
  mkdir -p "$SHARED_DIR"

  MOCK_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$MOCK_BIN"

  cat > "$MOCK_BIN/claude" << 'EOF'
#!/bin/bash
[[ "$1" == "--version" ]] && echo "mock-claude-version"
exit 0
EOF

  cat > "$MOCK_BIN/tmux" << 'EOF'
#!/bin/bash
printf '%s\n' "$@" > "${INSTANCE_HOME}/tmux_args"
exit 0
EOF

  cat > "$MOCK_BIN/git" << 'EOF'
#!/bin/bash
exit 0
EOF

  cat > "$MOCK_BIN/sleep" << 'EOF'
#!/bin/bash
exit 0
EOF

  chmod +x "$MOCK_BIN"/*
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# Runs one simulated instance's entrypoint.sh to completion with its own
# isolated HOME, sharing SHARED_DIR (created in setup()) with every other
# instance run this way.
_run_instance() {
  local name="$1" token="$2"
  local home="$TEST_TMPDIR/$name-home"
  mkdir -p "$home/.claude"
  echo "{\"token\":\"$token\"}" > "$home/.claude/.credentials.json"
  ln -s "$SHARED_DIR" "$home/.claude-shared-credentials"

  HOME="$home" \
  WORKSPACE_DIR="$TEST_TMPDIR/$name-workspace" \
  BUILD_SOURCE_FILE="$TEST_TMPDIR/no-build-source-marker" \
  FATAL_MARKER_FILE="$TEST_TMPDIR/$name-fatal-marker" \
  PATH="$MOCK_BIN:$PATH" \
  AUTO_START_MODE="interactive" \
  CLAUDE_EXTRA_ARGS="" \
  REMOTE_SESSION_NAME="$name" \
  TZ="" GIT_USER_NAME="" GIT_USER_EMAIL="" \
  GITHUB_TOKEN_FILE="$TEST_TMPDIR/no-github-token-file" \
  GIT_REPO_URL="" \
  SHARED_CREDS_POLL_MAX_ITERATIONS=1 \
  INSTANCE_HOME="$home" \
  bash "$ENTRYPOINT" > "$TEST_TMPDIR/$name.log" 2>&1
}

@test "a second instance's promotion silently overwrites the first's, and -- because the link is live, not a one-time copy -- the first instance's own credentials file starts resolving to the second instance's login with no restart and no error" {
  _run_instance "instance-a" "token-from-a"
  _run_instance "instance-b" "token-from-b"

  # No corruption: the shared file holds exactly the second instance's
  # content, not a mix of both / truncated / empty.
  SHARED_CONTENT="$(cat "$SHARED_DIR/.credentials.json")"
  [ "$SHARED_CONTENT" = '{"token":"token-from-b"}' ]

  # instance-b's own warning about overwriting different content already
  # in the pool -- confirms this was a detected, not silent-at-the-code-level,
  # overwrite (it IS silent from the operator's point of view unless they're
  # watching dock.log).
  grep -q "SHARED_CREDENTIALS_PATH already held different credentials" "$TEST_TMPDIR/instance-b.log"

  # The actual risk: instance-a's own credentials file is a LIVE symlink,
  # not a one-time copy. Reading it now -- with no further action inside
  # instance-a, no restart, nothing -- returns instance-b's token, not
  # instance-a's own. Any process inside instance-a reading its own
  # credentials from this point on is silently using instance-b's login.
  A_RESOLVED_CONTENT="$(cat "$TEST_TMPDIR/instance-a-home/.claude/.credentials.json")"
  [ "$A_RESOLVED_CONTENT" = '{"token":"token-from-b"}' ]
  [ -L "$TEST_TMPDIR/instance-a-home/.claude/.credentials.json" ]
}
