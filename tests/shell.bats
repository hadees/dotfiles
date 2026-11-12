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

@test "a negated command in a test always carries a failure branch" {
  # bash never trips errexit on a command negated with `!`, so a bare
  # `! grep -q x f` mid-test can never fail the test. Spell it
  #   ! cmd || { echo "<what went wrong>"; false; }
  # (`run !` is no substitute: it overwrites $status and $output.)
  # Backslash continuations are joined first, so the idiom may span two lines.
  local f hits bad=""
  for f in "$BATS_TEST_DIRNAME"/*.bats; do
    case "${f##*/}" in
      claude-peer*.bats) continue ;; # converted on feat/peer-contexts; delete this line when that branch lands
    esac
    hits="$(awk -v f="${f##*/}" '
      !cont { start = FNR; buf = "" }
      { l = $0; cont = (l ~ /\\$/); sub(/\\$/, "", l); buf = buf l }
      !cont {
        t = buf; sub(/^[ \t]+/, "", t)
        if (t ~ /^!([ \t]|$)/ && t !~ /\|\|/) print f ":" start ": " t
      }
    ' "$f")"
    [ -z "$hits" ] || bad+="$hits"$'\n'
  done
  [ -z "$bad" ] || { echo "negated command with no failure branch:"; echo "$bad"; false; }
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

@test "bash -ic runs its command instead of handing over to zsh" {
  # dot_bash_profile used to exec zsh for every interactive bash, so a tool's
  # `$SHELL -ilc CMD` (or `bash -ic CMD`) lost its command and zsh read stdin.
  cd "$BATS_TEST_DIRNAME/.."
  home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home"
  cp dot_bashrc "$home/.bashrc"
  cp dot_bash_profile "$home/.bash_profile"
  run env -i HOME="$home" PATH="/usr/bin:/bin" "$(command -v bash)" -ic 'echo marker-$((6*7))' </dev/null
  [[ "$output" == *"marker-42"* ]] || { echo "bash -ic dropped its command: $output"; false; }
}

@test "exports pick code, else vim, else vi for the editors" {
  cd "$BATS_TEST_DIRNAME/.."
  home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home" "$BATS_TEST_TMPDIR/code" "$BATS_TEST_TMPDIR/vim" "$BATS_TEST_TMPDIR/none"
  touch "$BATS_TEST_TMPDIR/code/code" "$BATS_TEST_TMPDIR/vim/vim"
  chmod +x "$BATS_TEST_TMPDIR/code/code" "$BATS_TEST_TMPDIR/vim/vim"
  zsh_bin="$(command -v zsh)"
  ed() {
    env -i HOME="$home" PATH="$1" "$zsh_bin" -c 'source ./dot_exports; print -r -- "$EDITOR|$GEM_EDITOR"' 2>/dev/null
  }
  [ "$(ed "$BATS_TEST_TMPDIR/code")" = "code --wait|code" ]
  [ "$(ed "$BATS_TEST_TMPDIR/vim")" = "vim|vim" ]
  [ "$(ed "$BATS_TEST_TMPDIR/none")" = "vi|vi" ]
}

@test "zshrc leaves extendedglob off so an unquoted caret reaches git" {
  cd "$BATS_TEST_DIRNAME/.."
  home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home"
  run env -i HOME="$home" PATH="/usr/bin:/bin" "$(command -v zsh)" -c \
    'source ./dot_zshrc; print -r -- HEAD^; [[ -o extendedglob ]] && print on || print off'
  [ "${lines[-2]}" = "HEAD^" ] || { echo "caret did not survive: $output"; false; }
  [ "${lines[-1]}" = "off" ] || { echo "extendedglob is on: $output"; false; }
  [ "$(grep -c 'setopt EXTENDED_GLOB' dot_zshrc)" -eq 0 ] || { echo "dot_zshrc still sets EXTENDED_GLOB"; false; }
  zsh -n dot_zshrc
}

@test "exports fill in LANG only when it is missing and the locale exists, and never force LC_ALL" {
  cd "$BATS_TEST_DIRNAME/.."
  home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home" "$BATS_TEST_TMPDIR/bare" "$BATS_TEST_TMPDIR/rich" "$BATS_TEST_TMPDIR/upper"
  printf '#!/bin/sh\nprintf "C\\nC.utf8\\nPOSIX\\n"\n' > "$BATS_TEST_TMPDIR/bare/locale"
  printf '#!/bin/sh\nprintf "C\\nen_US.utf8\\nPOSIX\\n"\n' > "$BATS_TEST_TMPDIR/rich/locale"
  printf '#!/bin/sh\nprintf "C\\nen_US.UTF-8\\nPOSIX\\n"\n' > "$BATS_TEST_TMPDIR/upper/locale"
  chmod +x "$BATS_TEST_TMPDIR"/{bare,rich,upper}/locale
  zsh_bin="$(command -v zsh)"
  loc() { # $1 stub dir, $2 OSTYPE, then optional VAR=value for the environment
    local dir="$1" ostype="$2"; shift 2
    env -i HOME="$home" PATH="$dir:/usr/bin:/bin" "$@" "$zsh_bin" -c \
      "OSTYPE=$ostype; source ./dot_exports; print -r -- \"\${LANG-unset}|\${LC_ALL-unset}\"" 2>/dev/null
  }
  [ "$(loc "$BATS_TEST_TMPDIR/bare" linux-gnu)" = "unset|unset" ]
  [ "$(loc "$BATS_TEST_TMPDIR/rich" linux-gnu)" = "en_US.UTF-8|unset" ]
  [ "$(loc "$BATS_TEST_TMPDIR/upper" linux-gnu)" = "en_US.UTF-8|unset" ]
  [ "$(loc "$BATS_TEST_TMPDIR/bare" linux-gnu LANG=de_DE.UTF-8)" = "de_DE.UTF-8|unset" ]
  [ "$(loc "$BATS_TEST_TMPDIR/bare" darwin23.0)" = "en_US.UTF-8|unset" ]
}

@test "exports point fzf at fd, else fdfind, else leave its default command alone" {
  cd "$BATS_TEST_DIRNAME/.."
  home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home" "$BATS_TEST_TMPDIR/fd" "$BATS_TEST_TMPDIR/fdfind" "$BATS_TEST_TMPDIR/neither"
  for d in fd fdfind neither; do touch "$BATS_TEST_TMPDIR/$d/fzf"; chmod +x "$BATS_TEST_TMPDIR/$d/fzf"; done
  touch "$BATS_TEST_TMPDIR/fd/fd" "$BATS_TEST_TMPDIR/fdfind/fdfind"
  chmod +x "$BATS_TEST_TMPDIR/fd/fd" "$BATS_TEST_TMPDIR/fdfind/fdfind"
  zsh_bin="$(command -v zsh)"
  finder() { # PATH holds only the stub dir; LANG set so no `locale` is needed
    env -i HOME="$home" LANG=C PATH="$BATS_TEST_TMPDIR/$1" "$zsh_bin" -c \
      'source ./dot_exports; print -r -- "${FZF_DEFAULT_COMMAND-unset}|${FZF_CTRL_T_COMMAND-unset}|${FZF_ALT_C_COMMAND-unset}"' 2>/dev/null
  }
  [[ "$(finder fd)" == "fd --type f"*"|fd --type f"*"|fd --type d"* ]]
  [[ "$(finder fdfind)" == "fdfind --type f"*"|fdfind --type f"*"|fdfind --type d"* ]]
  [ "$(finder neither)" = "unset|unset|unset" ]
}
