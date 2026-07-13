#!/usr/bin/env bats

# Full init + apply into an isolated $HOME per machine class, so the real
# machine is never touched and no real config is read or written. Applies
# use --exclude scripts: the .chezmoiscripts package installers must never
# run brew/apt inside a test. XDG dirs
# must be pinned too, not just HOME: GitHub's ubuntu runners export
# XDG_CONFIG_HOME, which chezmoi prefers over $HOME/.config — without the
# override, the first test's machineClass leaks into every later test via
# promptStringOnce.

chez() {
  HOME="$TMPHOME" \
  XDG_CONFIG_HOME="$TMPHOME/.config" \
  XDG_DATA_HOME="$TMPHOME/.local/share" \
  XDG_STATE_HOME="$TMPHOME/.local/state" \
  XDG_CACHE_HOME="$TMPHOME/.cache" \
    chezmoi "$@"
}

setup() {
  command -v chezmoi > /dev/null 2>&1 || skip "chezmoi not installed"
  TMPHOME="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPHOME"
}

@test "ephemeral class deploys shell config and nothing sensitive" {
  cd "$BATS_TEST_DIRNAME/.."
  chez init --source "$PWD" --promptString machineClass=ephemeral --apply --exclude scripts
  # Shell layer lands
  [ -f "$TMPHOME/.zshrc" ]
  [ -f "$TMPHOME/.aliases" ]
  [ -f "$TMPHOME/.functions" ]
  [ -x "$TMPHOME/bin/has-glyphs" ]
  # Rendered shell files parse
  zsh -n "$TMPHOME/.zshrc"
  zsh -n "$TMPHOME/.aliases"
  # No identity, secrets, or long-lived-machine tooling
  [ ! -e "$TMPHOME/.extra" ]
  [ ! -e "$TMPHOME/.gitconfig.local" ]
  [ ! -e "$TMPHOME/.claude" ]
  [ ! -e "$TMPHOME/CLAUDE.md" ]
  # Repo-level files never deploy
  [ ! -e "$TMPHOME/README.md" ]
  [ ! -e "$TMPHOME/Brewfile" ]
  [ ! -e "$TMPHOME/packages-apt.txt" ]
  [ ! -e "$TMPHOME/tests" ]
  [ ! -e "$TMPHOME/.macos" ]
}

@test "linux class deploys identity without signing" {
  cd "$BATS_TEST_DIRNAME/.."
  chez init --source "$PWD" --promptString machineClass=linux --apply --exclude scripts
  [ -f "$TMPHOME/.gitconfig.local" ]
  grep -q "email = evan.alter@gmail.com" "$TMPHOME/.gitconfig.local"
  grep -q "user = hadees" "$TMPHOME/.gitconfig.local"
  ! grep -q "gpgsign = true" "$TMPHOME/.gitconfig.local"
  ! grep -q "sshCommand" "$TMPHOME/.gitconfig.local"
  # Secrets template renders (currently reference-free) with private mode
  [ -f "$TMPHOME/.extra" ]
  run stat -f "%Lp" "$TMPHOME/.extra"
  [ "$output" = "600" ] || { run stat -c "%a" "$TMPHOME/.extra"; [ "$output" = "600" ]; }
  # Machine-local memory is created when missing
  [ -f "$TMPHOME/.claude/CLAUDE.local.md" ]
}

@test "wsl class wires git through Windows ssh.exe" {
  cd "$BATS_TEST_DIRNAME/.."
  chez init --source "$PWD" --promptString machineClass=wsl --apply --exclude scripts
  grep -q "sshCommand = ssh.exe" "$TMPHOME/.gitconfig.local"
  ! grep -q "gpgsign = true" "$TMPHOME/.gitconfig.local"
}

@test "create_ file is never overwritten on re-apply" {
  cd "$BATS_TEST_DIRNAME/.."
  mkdir -p "$TMPHOME/.claude"
  echo "my custom notes" > "$TMPHOME/.claude/CLAUDE.local.md"
  chez init --source "$PWD" --promptString machineClass=linux --apply --exclude scripts
  grep -q "my custom notes" "$TMPHOME/.claude/CLAUDE.local.md"
}
