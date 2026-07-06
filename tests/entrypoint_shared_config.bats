#!/usr/bin/env bats

load helpers

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRYPOINT="$PROJECT_ROOT/docker/entrypoint.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  setup_entrypoint_env
  SHARED_DIR="$HOME/.claude-shared"
  export SHARED_DIR
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# --- REMOTE_SESSION_NAME validation ---

@test "warns when REMOTE_SESSION_NAME is not set" {
  export REMOTE_SESSION_NAME=""
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMOTE_SESSION_NAME is not set"* ]]
}

@test "does not warn about REMOTE_SESSION_NAME when it is set" {
  export REMOTE_SESSION_NAME="my-project"
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"REMOTE_SESSION_NAME is not set"* ]]
}

@test "shows session ID in startup output when REMOTE_SESSION_NAME is set" {
  export REMOTE_SESSION_NAME="my-project"
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"my-project"* ]]
}

# --- SHARED_CONFIG_PATH: no shared dir ---

@test "does not create CLAUDE.md when shared dir does not exist" {
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.claude/CLAUDE.md" ]
}

# --- SHARED_CONFIG_PATH: CLAUDE.md merge ---

@test "creates CLAUDE.md from shared when no instance CLAUDE.md exists" {
  mkdir -p "$SHARED_DIR"
  echo "# Global rules" > "$SHARED_DIR/CLAUDE.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -f "$HOME/.claude/CLAUDE.md" ]
  grep -q "# Global rules" "$HOME/.claude/CLAUDE.md"
}

@test "generated CLAUDE.md contains the shared config header marker" {
  mkdir -p "$SHARED_DIR"
  echo "# Global rules" > "$SHARED_DIR/CLAUDE.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  grep -q "SHARED CONFIG" "$HOME/.claude/CLAUDE.md"
}

@test "migrates existing CLAUDE.md to CLAUDE-local.md on first shared config run" {
  mkdir -p "$SHARED_DIR"
  echo "# Global rules" > "$SHARED_DIR/CLAUDE.md"
  echo "# Instance rules" > "$HOME/.claude/CLAUDE.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -f "$HOME/.claude/CLAUDE-local.md" ]
  grep -q "# Instance rules" "$HOME/.claude/CLAUDE-local.md"
}

@test "generated CLAUDE.md combines shared and migrated local content" {
  mkdir -p "$SHARED_DIR"
  echo "# Global rules" > "$SHARED_DIR/CLAUDE.md"
  echo "# Instance rules" > "$HOME/.claude/CLAUDE.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  grep -q "# Global rules"   "$HOME/.claude/CLAUDE.md"
  grep -q "# Instance rules" "$HOME/.claude/CLAUDE.md"
}

@test "does not migrate existing CLAUDE.md when CLAUDE-local.md already exists" {
  mkdir -p "$SHARED_DIR"
  echo "# Global rules" > "$SHARED_DIR/CLAUDE.md"
  echo "# Previous generated" > "$HOME/.claude/CLAUDE.md"
  echo "# Local rules" > "$HOME/.claude/CLAUDE-local.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  CONTENT="$(cat "$HOME/.claude/CLAUDE-local.md")"
  [ "$CONTENT" = "# Local rules" ]
}

@test "does not re-migrate a previously generated CLAUDE.md (has SHARED CONFIG marker)" {
  mkdir -p "$SHARED_DIR"
  echo "# Global rules" > "$SHARED_DIR/CLAUDE.md"
  printf '# SHARED CONFIG — auto-generated at startup, do not edit\n\n# Global rules\n' > "$HOME/.claude/CLAUDE.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ ! -f "$HOME/.claude/CLAUDE-local.md" ]
}

@test "regenerates CLAUDE.md on restart combining shared and local" {
  mkdir -p "$SHARED_DIR"
  echo "# Global rules" > "$SHARED_DIR/CLAUDE.md"
  echo "# Local rules" > "$HOME/.claude/CLAUDE-local.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  grep -q "# Global rules" "$HOME/.claude/CLAUDE.md"
  grep -q "# Local rules"  "$HOME/.claude/CLAUDE.md"
}

# --- SHARED_CONFIG_PATH: commands symlinks ---

@test "does not create commands dir when shared commands dir does not exist" {
  mkdir -p "$SHARED_DIR"
  echo "# Global rules" > "$SHARED_DIR/CLAUDE.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ ! -d "$HOME/.claude/commands" ]
}

@test "creates symlinks for shared command files in ~/.claude/commands/" {
  mkdir -p "$SHARED_DIR/commands"
  echo "# My skill" > "$SHARED_DIR/commands/my-skill.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -L "$HOME/.claude/commands/my-skill.md" ]
}

@test "symlink for shared command points to the shared dir file" {
  mkdir -p "$SHARED_DIR/commands"
  echo "# My skill" > "$SHARED_DIR/commands/my-skill.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  TARGET="$(readlink "$HOME/.claude/commands/my-skill.md")"
  [ "$TARGET" = "$SHARED_DIR/commands/my-skill.md" ]
}

@test "creates symlinks for all .md files in shared commands dir" {
  mkdir -p "$SHARED_DIR/commands"
  echo "# Skill A" > "$SHARED_DIR/commands/skill-a.md"
  echo "# Skill B" > "$SHARED_DIR/commands/skill-b.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -L "$HOME/.claude/commands/skill-a.md" ]
  [ -L "$HOME/.claude/commands/skill-b.md" ]
}

@test "does not create symlinks for non-.md files in shared commands dir" {
  mkdir -p "$SHARED_DIR/commands"
  echo "# Skill" > "$SHARED_DIR/commands/skill.md"
  echo "ignored"  > "$SHARED_DIR/commands/ignore.txt"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -L "$HOME/.claude/commands/skill.md" ]
  [ ! -e "$HOME/.claude/commands/ignore.txt" ]
}

@test "shared commands output shows skill count in startup log" {
  mkdir -p "$SHARED_DIR/commands"
  echo "# A" > "$SHARED_DIR/commands/a.md"
  echo "# B" > "$SHARED_DIR/commands/b.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 skill(s) linked"* ]]
}
