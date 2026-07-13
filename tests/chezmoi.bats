#!/usr/bin/env bats

# Full init + apply into an isolated $HOME per machine class. HOME is
# overridden for every chezmoi call, so the real machine is never touched
# and no real config is read or written.

setup() {
  command -v chezmoi > /dev/null 2>&1 || skip "chezmoi not installed"
  TMPHOME="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPHOME"
}

@test "ephemeral class deploys shell config and nothing sensitive" {
  cd "$BATS_TEST_DIRNAME/.."
  HOME="$TMPHOME" chezmoi init --source "$PWD" --promptString machineClass=ephemeral --apply
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
  [ ! -e "$TMPHOME/tests" ]
  [ ! -e "$TMPHOME/.macos" ]
}

@test "linux class deploys identity without signing" {
  cd "$BATS_TEST_DIRNAME/.."
  HOME="$TMPHOME" chezmoi init --source "$PWD" --promptString machineClass=linux --apply
  [ -f "$TMPHOME/.gitconfig.local" ]
  grep -q "email = owner@example.com" "$TMPHOME/.gitconfig.local"
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
  HOME="$TMPHOME" chezmoi init --source "$PWD" --promptString machineClass=wsl --apply
  grep -q "sshCommand = ssh.exe" "$TMPHOME/.gitconfig.local"
  ! grep -q "gpgsign = true" "$TMPHOME/.gitconfig.local"
}

@test "create_ file is never overwritten on re-apply" {
  cd "$BATS_TEST_DIRNAME/.."
  mkdir -p "$TMPHOME/.claude"
  echo "my custom notes" > "$TMPHOME/.claude/CLAUDE.local.md"
  HOME="$TMPHOME" chezmoi init --source "$PWD" --promptString machineClass=linux --apply
  grep -q "my custom notes" "$TMPHOME/.claude/CLAUDE.local.md"
}
