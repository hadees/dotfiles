#!/usr/bin/env bats

setup() {
  TMPHOME="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPHOME"
}

@test "bootstrap script syncs dotfiles" {
  git() { :; }
  export -f git
  cd "$BATS_TEST_DIRNAME/.."
  HOME="$TMPHOME" run bash bootstrap.sh --force
  [ "$status" -eq 0 ]
  [ -f "$TMPHOME/.bashrc" ]
  [ -f "$TMPHOME/.bash_profile" ]
  [ -f "$TMPHOME/.claude/CLAUDE.md" ]
  [ ! -e "$TMPHOME/.claude/settings.local.json" ]
  [ -f "$TMPHOME/.claude/CLAUDE.local.md" ]
}

@test "bootstrap does not overwrite existing CLAUDE.local.md" {
  git() { :; }
  export -f git
  cd "$BATS_TEST_DIRNAME/.."
  mkdir -p "$TMPHOME/.claude"
  echo "my custom notes" > "$TMPHOME/.claude/CLAUDE.local.md"
  HOME="$TMPHOME" run bash bootstrap.sh --force
  [ "$status" -eq 0 ]
  grep -q "my custom notes" "$TMPHOME/.claude/CLAUDE.local.md"
}
