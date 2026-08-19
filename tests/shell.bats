#!/usr/bin/env bats

# The shell dotfiles must parse and source cleanly under zsh on every CI
# platform (ubuntu + macos + rocky + wsl). Catches zsh syntax errors and
# unguarded macOS-only commands that execute at source time. Source files
# use chezmoi naming (dot_*) but are plain files, so they parse directly;
# tests/chezmoi.bats covers the rendered output.

setup() {
  # Container CI checkouts are owned by another uid and git refuses to read
  # them ("dubious ownership"). Point the global config at a per-test file
  # so marking the repo safe never touches the real machine's config.
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  git config --file "$GIT_CONFIG_GLOBAL" safe.directory '*'
}

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

@test "bats itself runs under bash >= 4" {
  # bash 3.2 (macOS's /bin/bash) does not fail a test on a failing `[[ ]]`
  # unless it is the last command, so every mid-test [[ ]] assertion in
  # this suite would be silently ignored. Put a modern bash first on PATH
  # (Homebrew's: PATH="$(brew --prefix)/bin:$PATH" bats tests) — CI does.
  [ "${BASH_VERSINFO[0]}" -ge 4 ]
}

@test "exports put Homebrew's bin and sbin ahead of the system dirs" {
  # Simulate a brew that lives in a prefix of our choosing; the exports must
  # prepend both <prefix>/bin and <prefix>/sbin, bin first, so Homebrew's
  # bash/git/ssh/curl win over the macOS copies (see the comment in
  # dot_exports; bats under /bin/bash 3.2 was how this surfaced).
  cd "$BATS_TEST_DIRNAME/.."
  fake="$BATS_TEST_TMPDIR/fakebrew"
  mkdir -p "$fake/bin" "$fake/sbin" "$BATS_TEST_TMPDIR/stub"
  printf '#!/bin/sh\necho "%s"\n' "$fake" > "$BATS_TEST_TMPDIR/stub/brew"
  chmod +x "$BATS_TEST_TMPDIR/stub/brew"
  run zsh -c "export PATH='$BATS_TEST_TMPDIR/stub:/usr/bin:/bin'; source dot_exports; print -r -- \$PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == "$fake/bin:$fake/sbin:"* ]]
  [[ "$output" == *":/usr/bin:/bin"* ]]
}
