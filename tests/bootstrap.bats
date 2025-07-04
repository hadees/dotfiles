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
}
