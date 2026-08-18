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

# Content-level leak guard: after an apply, nothing in the rendered home may
# look like a secret. Generic patterns only — a test naming a real account,
# org, or address would itself be the leak (see the NOTE below). Excluded as
# known-benign: vendored vim syntax files (upstream maintainer addresses),
# .gitconfig's git@github.com URL rewrites (hosts, not identities), and
# CLAUDE.md's documented onepasswordRead template example (an op:// reference
# shape from the public docs, not a rendered secret).
assert_no_secret_leaks() {
  local leaks
  leaks="$(grep -rEIn --exclude-dir=.vim \
    -e 'op://' \
    -e 'ghp_[A-Za-z0-9]{16,}' \
    -e 'gho_[A-Za-z0-9]{16,}' \
    -e 'github_pat_[A-Za-z0-9_]{20,}' \
    -e 'AKIA[0-9A-Z]{16}' \
    -e 'BEGIN [A-Z ]*PRIVATE KEY' \
    -e '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
    "$TMPHOME" | grep -vE 'git@(gist\.)?github\.com|\{\{ onepasswordRead ' || true)"
  echo "$leaks"
  [ -z "$leaks" ]
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
  [ ! -e "$TMPHOME/docs" ]
  [ ! -e "$TMPHOME/Brewfile" ]
  [ ! -e "$TMPHOME/packages-apt.txt" ]
  [ ! -e "$TMPHOME/tests" ]
  [ ! -e "$TMPHOME/.macos" ]
  # Nothing rendered may look like a secret
  assert_no_secret_leaks
}

@test "mac class pins sourceDir and deploys the shell layer" {
  cd "$BATS_TEST_DIRNAME/.."
  chez init --source "$PWD" --promptString machineClass=mac --apply --exclude scripts
  # The mac-only bit that renders identically on every platform: the config
  # pins the development clone as the source of truth.
  grep -q 'sourceDir = "~/code/dotfiles"' "$TMPHOME/.config/chezmoi/chezmoi.toml"
  grep -q 'machineClass = "mac"' "$TMPHOME/.config/chezmoi/chezmoi.toml"
  # Shell layer lands and parses
  [ -f "$TMPHOME/.zshrc" ]
  [ -f "$TMPHOME/.functions" ]
  zsh -n "$TMPHOME/.zshrc"
  # macOS GUI config deploys only where a GUI exists — .chezmoiignore keys
  # these off the OS, not the machine class, so gate on uname for Linux CI.
  if [ "$(uname -s)" = "Darwin" ]; then
    [ -f "$TMPHOME/.mackup.cfg" ]
    [ -f "$TMPHOME/com.googlecode.iterm2.plist" ]
    [ -f "$TMPHOME/.finicky.ts" ]
    [ -f "$TMPHOME/.config/finicky/lib.ts" ]
  else
    [ ! -e "$TMPHOME/.mackup.cfg" ]
    [ ! -e "$TMPHOME/com.googlecode.iterm2.plist" ]
    [ ! -e "$TMPHOME/.finicky.ts" ]
    [ ! -e "$TMPHOME/.config/finicky" ]
  fi
  assert_no_secret_leaks
}

@test "finicky: composer, helpers, and overwritable fragment stubs deploy on macOS" {
  [ "$(uname -s)" = "Darwin" ] || skip "Finicky is macOS-only"
  cd "$BATS_TEST_DIRNAME/.."
  chez init --source "$PWD" --promptString machineClass=mac --apply --exclude scripts
  # The composer imports exactly the two overlay-owned fragments...
  grep -q 'from "./.config/finicky/personal.ts"' "$TMPHOME/.finicky.ts"
  grep -q 'from "./.config/finicky/work.ts"' "$TMPHOME/.finicky.ts"
  # ...which the public repo only stubs (create_: written when missing) so
  # the bundle always resolves; an overlay overwrites its own without a
  # fight because create_ never rewrites an existing file.
  grep -q '^export default \[\];' "$TMPHOME/.config/finicky/personal.ts"
  grep -q '^export default \[\];' "$TMPHOME/.config/finicky/work.ts"
  echo 'export default [{ match: "x", browser: "y" }];' > "$TMPHOME/.config/finicky/work.ts"
  chez apply --source "$PWD" --exclude scripts
  grep -q 'match: "x"' "$TMPHOME/.config/finicky/work.ts"
  # (Identity stays out of the public composer/lib by construction; the
  # personal overlay's no-public-leak test polices the whole public tree.)
  # And Finicky is in the bundle.
  grep -q "^cask 'finicky'" Brewfile
}

@test "an invalid machineClass fails init before anything is applied" {
  cd "$BATS_TEST_DIRNAME/.."
  run chez init --source "$PWD" --promptString machineClass=bogus --apply --exclude scripts
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *machineClass* ]]
  [ ! -e "$TMPHOME/.zshrc" ]
}

@test "package-install script templates render to valid shell" {
  cd "$BATS_TEST_DIRNAME/.."
  # Init gives execute-template the sandbox config, so .chezmoi data and the
  # source dir exist. Render only — the scripts must never execute in a test.
  chez init --source "$PWD" --promptString machineClass=linux
  local tmpl rendered shebang
  for tmpl in .chezmoiscripts/*/run_onchange_*.sh.tmpl; do
    rendered="$TMPHOME/$(dirname "$tmpl" | tr / -)-$(basename "$tmpl" .tmpl)"
    chez execute-template --source "$PWD" < "$tmpl" > "$rendered"
    shebang="$(head -n 1 "$rendered")"
    case "$shebang" in
      *bash*) bash -n "$rendered" ;;
      *) sh -n "$rendered" ;;
    esac
  done
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
