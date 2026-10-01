#!/usr/bin/env bats

# update() (dot_functions) must never run its body from the caller's typed
# directory: a dead cwd (a removed worktree is the usual way) kills
# brew/npm/uv/gem outright on their own startup getcwd/[[ -d $PWD ]] checks,
# and even a live cwd inside a project misdirects asdf's node/ruby/uv shims to
# that project's .tool-versions instead of the global one in
# ~/.tool-versions. These tests stub every tool update() calls and drive it
# under a real zsh, sourcing dot_functions directly against a sandboxed
# $HOME. No real account, path, or repo name anywhere.
#
# CI can only guard the source copy: a machine that hasn't run
# `chezmoi apply` still runs whatever ~/.functions it last deployed.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  cd "$BATS_TEST_TMPDIR"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  for cmd in brew npm uv ruby gem; do
    cat > "$BATS_TEST_TMPDIR/bin/$cmd" <<'STUB'
#!/bin/sh
printf '%s\t%s\n' "$(pwd -P 2>/dev/null || echo DEAD)" "$(basename "$0") $*" >> "$BATS_TEST_TMPDIR/calls.log"
exit 0
STUB
  done
  # chezmoi: prints the fake source path so `update` finds a Brewfile under
  # it and actually exercises `brew bundle`.
  cat > "$BATS_TEST_TMPDIR/bin/chezmoi" <<'STUB'
#!/bin/sh
printf '%s\t%s\n' "$(pwd -P 2>/dev/null || echo DEAD)" "$(basename "$0") $*" >> "$BATS_TEST_TMPDIR/calls.log"
echo "$BATS_TEST_TMPDIR/src"
STUB
  # sudo: `-v` fails only when the test drops a flag file; every other call
  # (the keepalive's `-n true`, `gem`, `softwareupdate`) logs and succeeds.
  cat > "$BATS_TEST_TMPDIR/bin/sudo" <<'STUB'
#!/bin/sh
printf '%s\t%s\n' "$(pwd -P 2>/dev/null || echo DEAD)" "$(basename "$0") $*" >> "$BATS_TEST_TMPDIR/calls.log"
case "$1" in
  -v) [ -e "$BATS_TEST_TMPDIR/fail-sudo" ] && exit 1; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  mkdir -p "$BATS_TEST_TMPDIR/src"
  : > "$BATS_TEST_TMPDIR/src/Brewfile"

  DOTFUNCTIONS="$BATS_TEST_DIRNAME/../dot_functions"
  home_p="$(cd "$HOME" && pwd -P)"
}

# run_update <zsh snippet run after sourcing>; leaves out/err in the cwd
# (setup cd'd into $BATS_TEST_TMPDIR). Not `run`, and fd 3 closed: the
# keepalive loop's `sleep 60` survives the kill of its parent for up to 60s
# as an orphan, and would otherwise hold bats' fd 3 (or run's capture pipe)
# open for that long (bats-core writing-tests, "close FD 3 explicitly").
run_update() {
  zsh -c "source '$DOTFUNCTIONS'; $1; update; rc=\$?; print -r -- \"RC=\$rc PWD=\$(pwd -P)\"" \
    > out 2> err 3>&- < /dev/null
}

@test "dot_functions defines update" {
  run zsh -c "source '$DOTFUNCTIONS'; whence -w update"
  [ "$status" -eq 0 ]
  [[ "$output" == *"update: function"* ]]
}

@test "update runs every tool from \$HOME and returns the shell to where it started" {
  start="$BATS_TEST_TMPDIR/start"; mkdir -p "$start"
  run_update "cd -q -- '$start'"
  grep -q "^RC=0 PWD=$(cd "$start" && pwd -P)\$" out
  [ "$(cut -f1 calls.log | sort -u)" = "$home_p" ]
  grep -qF "brew bundle --no-upgrade --file=$BATS_TEST_TMPDIR/src/Brewfile" calls.log
  grep -qF "npm install npm -g" calls.log
  grep -qF "uv tool upgrade --all" calls.log
  grep -qF "sudo gem update --system" calls.log
  grep -qF "sudo gem cleanup" calls.log
  ! grep -q "no longer exists" err || { echo "warned on a live cwd"; false; }
}

@test "a cwd that no longer exists is reported once, the tools still run from \$HOME, and the shell ends in \$HOME" {
  dead="$BATS_TEST_TMPDIR/gone"; mkdir -p "$dead"
  run_update "cd -q -- '$dead' && command rmdir -- '$dead' || exit 99"
  grep -q "^RC=0 PWD=$home_p\$" out
  grep -qF "update: $dead no longer exists; running from ~ and leaving the shell there" err
  [ "$(grep -c 'no longer exists' err)" -eq 1 ]
  [ "$(cut -f1 calls.log | sort -u)" = "$home_p" ]
  grep -qF "brew update" calls.log
  grep -qF "sudo gem update" calls.log
}

@test "a refused sudo returns early, starts no keepalive, and still restores the cwd" {
  touch "$BATS_TEST_TMPDIR/fail-sudo"
  start="$BATS_TEST_TMPDIR/start"; mkdir -p "$start"
  run_update "cd -q -- '$start'"
  grep -q "^RC=1 PWD=$(cd "$start" && pwd -P)\$" out
  grep -qF "brew cleanup" calls.log
  ! grep -qF "sudo -n true" calls.log || { echo "keepalive started after sudo -v failed"; false; }
  ! grep -qF "sudo gem" calls.log || { echo "gem ran after sudo -v failed"; false; }
}

@test "update.check commands run after the upgrades; a failure is repeated at the end and never stops the update" {
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --file "$GIT_CONFIG_GLOBAL" --add update.check 'echo first-check-ran'
  git config --file "$GIT_CONFIG_GLOBAL" --add update.check 'echo 50% broken >&2; exit 3'
  start="$BATS_TEST_TMPDIR/start"; mkdir -p "$start"
  run_update "cd -q -- '$start'"
  grep -q "^RC=0 PWD=$(cd "$start" && pwd -P)\$" out
  grep -qF "first-check-ran" out
  grep -qF "== update.check: echo 50% broken >&2; exit 3" out
  # The banner comes last, after gem, and names the failing command verbatim.
  [ "$(tail -n 1 err | sed $'s/\e\\[[0-9;]*m//g')" = "✘ update.check failed: echo 50% broken >&2; exit 3" ]
  ! grep -q "update.check failed: echo first" err
  grep -qF "sudo gem cleanup" calls.log
}

@test "with no update.check configured, nothing extra is printed" {
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  : > "$GIT_CONFIG_GLOBAL"
  run_update ":"
  ! grep -q "update.check" out err
}
