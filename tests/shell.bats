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
  # stderr is dropped: dot_exports sets LC_ALL=en_US.UTF-8, and on a box
  # without that locale (the Rocky container) the brew subshell then warns
  # about it, which `run` would fold into $output ahead of the PATH line.
  run zsh -c "export PATH='$BATS_TEST_TMPDIR/stub:/usr/bin:/bin'; source dot_exports 2>/dev/null; print -r -- \$PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == "$fake/bin:$fake/sbin:"* ]]
  [[ "$output" == *":/usr/bin:/bin"* ]]
}

@test "zshrc finds zsh plugins under Homebrew or /usr/share, Homebrew first" {
  cd "$BATS_TEST_DIRNAME/.."
  # The block is extracted and its system dir swapped for a fixture, so this
  # is hermetic on machines that do and do not carry the apt packages.
  awk '/^# zsh plugins\./,/^unset _zsh_plugin_dir _zsh_plugin_dirs$/' dot_zshrc \
    > "$BATS_TEST_TMPDIR/block.zsh"
  [ -s "$BATS_TEST_TMPDIR/block.zsh" ]

  sys="$BATS_TEST_TMPDIR/usr-share"
  brewp="$BATS_TEST_TMPDIR/brewprefix"
  mkdir -p "$sys/zsh-autosuggestions" "$sys/zsh-syntax-highlighting" \
           "$brewp/share/zsh-autosuggestions" "$brewp/share/zsh-syntax-highlighting" \
           "$BATS_TEST_TMPDIR/stub" "$BATS_TEST_TMPDIR/empty"
  echo 'AS=sys' > "$sys/zsh-autosuggestions/zsh-autosuggestions.zsh"
  echo 'SH=sys' > "$sys/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
  echo 'AS=brew' > "$brewp/share/zsh-autosuggestions/zsh-autosuggestions.zsh"
  echo 'SH=brew' > "$brewp/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
  sed "s|/usr/share|$sys|" "$BATS_TEST_TMPDIR/block.zsh" > "$BATS_TEST_TMPDIR/run.zsh"

  printf '#!/bin/sh\necho %s\n' "$brewp" > "$BATS_TEST_TMPDIR/stub/brew"
  chmod +x "$BATS_TEST_TMPDIR/stub/brew"

  # Homebrew present and carrying the plugins: its copies win.
  run env PATH="$BATS_TEST_TMPDIR/stub:$PATH" \
    zsh -c "source '$BATS_TEST_TMPDIR/run.zsh'; echo \$AS \$SH"
  [ "$status" -eq 0 ]
  [ "$output" = "brew brew" ]

  # No Homebrew at all — a plain Linux box: the distro copies are found.
  # Before this fell back, apt could install the plugins and .zshrc would
  # silently never source them. zsh is invoked by absolute path because env
  # resolves the command against the PATH it is setting, which is empty here.
  zsh_bin="$(command -v zsh)"
  run env PATH="$BATS_TEST_TMPDIR/empty" \
    "$zsh_bin" -c "source '$BATS_TEST_TMPDIR/run.zsh'; echo \$AS \$SH"
  [ "$status" -eq 0 ]
  [ "$output" = "sys sys" ]
}
