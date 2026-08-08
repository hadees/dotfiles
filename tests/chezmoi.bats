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
  # No identity, secrets, or long-lived-machine tooling. Note .extra and
  # .gitconfig.local are absent from every class now that they come from the
  # private overlay — these two assertions are belt-and-braces, and the
  # .chezmoiignore entries that used to cover them are gone.
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

@test "linux class deploys no identity and no secrets" {
  cd "$BATS_TEST_DIRNAME/.."
  chez init --source "$PWD" --promptString machineClass=linux --apply --exclude scripts
  # Identity and secrets live in the private overlay, so a public-only apply
  # must configure none of it. This is the intended end state, not a gap:
  # see "Private overlay" in CLAUDE.md.
  [ ! -e "$TMPHOME/.gitconfig.local" ]
  [ ! -e "$TMPHOME/.extra" ]
  [ ! -e "$TMPHOME/.claude/settings.json" ]
  # ...but the machinery that reads them still deploys
  [ -f "$TMPHOME/.gitconfig" ]
  grep -q "path = ~/.gitconfig.local" "$TMPHOME/.gitconfig"
  [ -x "$TMPHOME/bin/git-credential-gh-user" ]
  # Machine-local memory is created when missing
  [ -f "$TMPHOME/.claude/CLAUDE.local.md" ]
}

@test "wsl class renders shell config cleanly" {
  cd "$BATS_TEST_DIRNAME/.."
  chez init --source "$PWD" --promptString machineClass=wsl --apply --exclude scripts
  zsh -n "$TMPHOME/.zshrc"
  zsh -n "$TMPHOME/.functions"
  # The wsl-specific git bits (ssh.exe forwarding) moved to the private
  # overlay along with .gitconfig.local; nothing wsl-specific is left here.
  [ ! -e "$TMPHOME/.gitconfig.local" ]
}

# NOTE: the denylist check that asserts no work identity leaks into this repo
# lives in the private overlay (tests/no-public-leak.bats), not here — a test
# naming the forbidden strings would leak them itself.

@test "create_ file is never overwritten on re-apply" {
  cd "$BATS_TEST_DIRNAME/.."
  mkdir -p "$TMPHOME/.claude"
  echo "my custom notes" > "$TMPHOME/.claude/CLAUDE.local.md"
  chez init --source "$PWD" --promptString machineClass=linux --apply --exclude scripts
  grep -q "my custom notes" "$TMPHOME/.claude/CLAUDE.local.md"
}
