#!/usr/bin/env bats

# The shell dotfiles must parse and source cleanly under zsh on every CI
# platform (ubuntu + macos + rocky + wsl). Catches zsh syntax errors and
# unguarded macOS-only commands that execute at source time. Source files
# use chezmoi naming (dot_*) but are plain files, so they parse directly;
# tests/chezmoi.bats covers the rendered output.

@test "zsh parses the zsh dotfiles" {
  cd "$BATS_TEST_DIRNAME/.."
  for f in dot_zshrc dot_zsh_prompt dot_exports dot_aliases dot_functions; do
    zsh -n "$f"
  done
}

@test "bash parses the bash dotfiles and bootstrap" {
  cd "$BATS_TEST_DIRNAME/.."
  for f in dot_bash_profile dot_bashrc bootstrap.sh; do
    bash -n "$f"
  done
}

@test "every bin executable and init/mackup.sh parse under their shebang shell" {
  cd "$BATS_TEST_DIRNAME/.."
  [ -n "$(git ls-files 'bin/executable_*')" ]
  for f in $(git ls-files 'bin/executable_*') init/mackup.sh; do
    case "$(head -n 1 "$f")" in
      *zsh*)  zsh -n "$f" ;;
      *bash*) bash -n "$f" ;;
      *)      sh -n "$f" ;;
    esac
  done
}

@test "exports, aliases, functions, and prompt source cleanly in zsh" {
  cd "$BATS_TEST_DIRNAME/.."
  run zsh -c '
    source ./dot_exports; true
    source ./dot_aliases; true
    source ./dot_functions; true
    source ./dot_zsh_prompt; true
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"command not found"* ]]
  [[ "$output" != *"parse error"* ]]
  [[ "$output" != *"no such file"* ]]
}
