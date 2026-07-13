#!/usr/bin/env bats

# The shell dotfiles must parse and source cleanly under zsh on every CI
# platform (ubuntu + macos). Catches zsh syntax errors and unguarded
# macOS-only commands that execute at source time.

@test "zsh parses the zsh dotfiles" {
  cd "$BATS_TEST_DIRNAME/.."
  for f in .zshrc .zsh_prompt .exports .aliases .functions; do
    zsh -n "$f"
  done
}

@test "bash parses the bash dotfiles and bootstrap" {
  cd "$BATS_TEST_DIRNAME/.."
  for f in .bash_profile .bashrc bootstrap.sh; do
    bash -n "$f"
  done
}

@test "exports, aliases, functions, and prompt source cleanly in zsh" {
  cd "$BATS_TEST_DIRNAME/.."
  run zsh -c '
    source ./.exports; true
    source ./.aliases; true
    source ./.functions; true
    source ./.zsh_prompt; true
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"command not found"* ]]
  [[ "$output" != *"parse error"* ]]
  [[ "$output" != *"no such file"* ]]
}
