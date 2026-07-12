#!/usr/bin/env bats

load helpers

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRYPOINT="$PROJECT_ROOT/docker/entrypoint.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  setup_entrypoint_env
  GLOBAL_DIR="$HOME/.claude-global"
  export GLOBAL_DIR
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

# --- GLOBAL_CONFIG_PATH: no global dir ---

@test "does not create CLAUDE.md when global dir does not exist" {
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.claude/CLAUDE.md" ]
}

# --- GLOBAL_CONFIG_PATH: CLAUDE.md merge ---

@test "creates CLAUDE.md from global when no instance CLAUDE.md exists" {
  mkdir -p "$GLOBAL_DIR"
  echo "# Global rules" > "$GLOBAL_DIR/CLAUDE.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -f "$HOME/.claude/CLAUDE.md" ]
  grep -q "# Global rules" "$HOME/.claude/CLAUDE.md"
}

@test "generated CLAUDE.md contains the global config header marker" {
  mkdir -p "$GLOBAL_DIR"
  echo "# Global rules" > "$GLOBAL_DIR/CLAUDE.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  grep -q "GLOBAL CONFIG" "$HOME/.claude/CLAUDE.md"
}

@test "migrates existing CLAUDE.md to CLAUDE-local.md on first global config run" {
  mkdir -p "$GLOBAL_DIR"
  echo "# Global rules" > "$GLOBAL_DIR/CLAUDE.md"
  echo "# Instance rules" > "$HOME/.claude/CLAUDE.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -f "$HOME/.claude/CLAUDE-local.md" ]
  grep -q "# Instance rules" "$HOME/.claude/CLAUDE-local.md"
}

@test "generated CLAUDE.md combines global and migrated local content" {
  mkdir -p "$GLOBAL_DIR"
  echo "# Global rules" > "$GLOBAL_DIR/CLAUDE.md"
  echo "# Instance rules" > "$HOME/.claude/CLAUDE.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  grep -q "# Global rules"   "$HOME/.claude/CLAUDE.md"
  grep -q "# Instance rules" "$HOME/.claude/CLAUDE.md"
}

@test "does not migrate existing CLAUDE.md when CLAUDE-local.md already exists" {
  mkdir -p "$GLOBAL_DIR"
  echo "# Global rules" > "$GLOBAL_DIR/CLAUDE.md"
  echo "# Previous generated" > "$HOME/.claude/CLAUDE.md"
  echo "# Local rules" > "$HOME/.claude/CLAUDE-local.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  CONTENT="$(cat "$HOME/.claude/CLAUDE-local.md")"
  [ "$CONTENT" = "# Local rules" ]
}

@test "does not re-migrate a previously generated CLAUDE.md (has GLOBAL CONFIG marker)" {
  mkdir -p "$GLOBAL_DIR"
  echo "# Global rules" > "$GLOBAL_DIR/CLAUDE.md"
  printf '# GLOBAL CONFIG — auto-generated at startup, do not edit\n\n# Global rules\n' > "$HOME/.claude/CLAUDE.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ ! -f "$HOME/.claude/CLAUDE-local.md" ]
}

@test "regenerates CLAUDE.md on restart combining global and local" {
  mkdir -p "$GLOBAL_DIR"
  echo "# Global rules" > "$GLOBAL_DIR/CLAUDE.md"
  echo "# Local rules" > "$HOME/.claude/CLAUDE-local.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  grep -q "# Global rules" "$HOME/.claude/CLAUDE.md"
  grep -q "# Local rules"  "$HOME/.claude/CLAUDE.md"
}

# --- GLOBAL_CONFIG_PATH: commands symlinks ---

@test "does not create commands dir when global commands dir does not exist" {
  mkdir -p "$GLOBAL_DIR"
  echo "# Global rules" > "$GLOBAL_DIR/CLAUDE.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ ! -d "$HOME/.claude/commands" ]
}

@test "creates symlinks for global command files in ~/.claude/commands/" {
  mkdir -p "$GLOBAL_DIR/commands"
  echo "# My skill" > "$GLOBAL_DIR/commands/my-skill.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -L "$HOME/.claude/commands/my-skill.md" ]
}

@test "symlink for global command points to the global dir file" {
  mkdir -p "$GLOBAL_DIR/commands"
  echo "# My skill" > "$GLOBAL_DIR/commands/my-skill.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  TARGET="$(readlink "$HOME/.claude/commands/my-skill.md")"
  [ "$TARGET" = "$GLOBAL_DIR/commands/my-skill.md" ]
}

@test "creates symlinks for all .md files in global commands dir" {
  mkdir -p "$GLOBAL_DIR/commands"
  echo "# Skill A" > "$GLOBAL_DIR/commands/skill-a.md"
  echo "# Skill B" > "$GLOBAL_DIR/commands/skill-b.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -L "$HOME/.claude/commands/skill-a.md" ]
  [ -L "$HOME/.claude/commands/skill-b.md" ]
}

@test "does not create symlinks for non-.md files in global commands dir" {
  mkdir -p "$GLOBAL_DIR/commands"
  echo "# Skill" > "$GLOBAL_DIR/commands/skill.md"
  echo "ignored"  > "$GLOBAL_DIR/commands/ignore.txt"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -L "$HOME/.claude/commands/skill.md" ]
  [ ! -e "$HOME/.claude/commands/ignore.txt" ]
}

@test "global commands output shows skill count in startup log" {
  mkdir -p "$GLOBAL_DIR/commands"
  echo "# A" > "$GLOBAL_DIR/commands/a.md"
  echo "# B" > "$GLOBAL_DIR/commands/b.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 skill(s) linked"* ]]
}

# --- GLOBAL_CONFIG_PATH: skills symlinks ---

@test "does not create skills dir when global skills dir does not exist" {
  mkdir -p "$GLOBAL_DIR"
  echo "# Global rules" > "$GLOBAL_DIR/CLAUDE.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ ! -d "$HOME/.claude/skills" ]
}

@test "creates symlinks for global skill directories in ~/.claude/skills/" {
  mkdir -p "$GLOBAL_DIR/skills/my-skill"
  echo "# My skill" > "$GLOBAL_DIR/skills/my-skill/SKILL.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -L "$HOME/.claude/skills/my-skill" ]
}

@test "symlink for global skill points to the global dir skill directory" {
  mkdir -p "$GLOBAL_DIR/skills/my-skill"
  echo "# My skill" > "$GLOBAL_DIR/skills/my-skill/SKILL.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  TARGET="$(readlink "$HOME/.claude/skills/my-skill")"
  [ "$TARGET" = "$GLOBAL_DIR/skills/my-skill" ]
}

@test "creates symlinks for all skill directories in global skills dir" {
  mkdir -p "$GLOBAL_DIR/skills/skill-a"
  mkdir -p "$GLOBAL_DIR/skills/skill-b"
  echo "# Skill A" > "$GLOBAL_DIR/skills/skill-a/SKILL.md"
  echo "# Skill B" > "$GLOBAL_DIR/skills/skill-b/SKILL.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -L "$HOME/.claude/skills/skill-a" ]
  [ -L "$HOME/.claude/skills/skill-b" ]
}

@test "does not create symlinks for files (non-directories) in global skills dir" {
  mkdir -p "$GLOBAL_DIR/skills/skill-a"
  echo "# Skill A" > "$GLOBAL_DIR/skills/skill-a/SKILL.md"
  echo "ignored" > "$GLOBAL_DIR/skills/stray-file.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -L "$HOME/.claude/skills/skill-a" ]
  [ ! -e "$HOME/.claude/skills/stray-file.md" ]
}

@test "global skills output shows skill count in startup log" {
  mkdir -p "$GLOBAL_DIR/skills/skill-a"
  mkdir -p "$GLOBAL_DIR/skills/skill-b"
  echo "# A" > "$GLOBAL_DIR/skills/skill-a/SKILL.md"
  echo "# B" > "$GLOBAL_DIR/skills/skill-b/SKILL.md"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 skill(s) linked"* ]]
}
