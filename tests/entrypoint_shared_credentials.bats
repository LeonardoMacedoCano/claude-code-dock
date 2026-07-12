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

@test "empty shared credentials dir and no session credentials links and says the pool is empty" {
  mkdir -p "$SHARED_CREDS_DIR"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -L "$SESSION_CREDS" ]
  [ ! -f "$SESSION_CREDS" ]
  # A prior version of this code stayed completely silent here, which hid
  # the fact that shared mode was even active on a brand-new session -- must
  # always say which mode a boot ended up in, never silently no-op.
  [[ "$output" == *"Shared credentials: session linked to SHARED_CREDENTIALS_PATH (mode=shared, pool currently empty"* ]]
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

@test "an in-place write (open+truncate) after startup goes straight through the symlink" {
  mkdir -p "$SHARED_CREDS_DIR"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ -L "$SESSION_CREDS" ]

  # A shell redirection opens the existing path and truncates it in place,
  # following the symlink like any normal open() would -- this is the write
  # pattern the plain symlink alone has always handled correctly. `claude`'s
  # actual login/refresh does not write this way (see the next test).
  echo '{"token":"post-boot-login"}' > "$SESSION_CREDS"

  grep -q "post-boot-login" "$SHARED_CREDS_FILE"
}

@test "a login that replaces the path outright (rename-over-target, like claude does) is re-promoted and re-linked by the background poller" {
  mkdir -p "$SHARED_CREDS_DIR"
  # Real, unmocked sleep for just this test so there's an actual time window
  # between poller iterations to inject the break into -- the suite's mocked
  # sleep (helpers.bash) returns instantly, which is right for every other
  # test here but would make this one race the injected change against a
  # poller that already finished all its iterations before the test's next
  # line even runs.
  REAL_SLEEP_BIN="$TEST_TMPDIR/real-sleep-bin"
  mkdir -p "$REAL_SLEEP_BIN"
  ln -s /bin/sleep "$REAL_SLEEP_BIN/sleep"
  export PATH="$REAL_SLEEP_BIN:$PATH"
  export SHARED_CREDS_POLL_INTERVAL="0.15"
  export SHARED_CREDS_POLL_MAX_ITERATIONS=30

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ -L "$SESSION_CREDS" ]

  # Simulate what `claude` actually does on login/token refresh: write a new
  # file and rename() it over the old path, instead of opening the existing
  # path in place. This detaches the symlink outright, same as it would
  # detach any other file at that path -- reproducing the exact incident
  # this fix addresses (SHARED_CREDENTIALS_PATH stayed empty through a real
  # login because the write never went through the link at all).
  rm -f "$SESSION_CREDS"
  echo '{"token":"post-boot-login"}' > "$SESSION_CREDS"
  [ ! -L "$SESSION_CREDS" ]

  for _ in $(seq 1 20); do
    [ -L "$SESSION_CREDS" ] && grep -q "post-boot-login" "$SHARED_CREDS_FILE" 2>/dev/null && break
    /bin/sleep 0.2
  done

  [ -L "$SESSION_CREDS" ]
  grep -q "post-boot-login" "$SHARED_CREDS_FILE"
  grep -q "post-boot-login" "$SESSION_CREDS"
  grep -q "Shared credentials: re-linked to SHARED_CREDENTIALS_PATH after live write" "$HOME/.claude/logs/dock.log"
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
