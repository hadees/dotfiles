#!/usr/bin/env bats

# The claude() wrapper in dot_functions picks a Claude Code config directory
# from the cwd's origin remote, via the credential.<url>.username pins and
# claude.profile.<account> mappings in git config. These tests source the
# real functions under zsh against a sandboxed git config, fake repos with
# every supported origin-URL shape, and a stub `claude` binary that reports
# the CLAUDE_CONFIG_DIR it was launched with. All pins here are test
# fixtures — no real account or org names may appear (see CLAUDE.md).
#
# CI can only guard the source copy: a machine that hasn't run
# `chezmoi apply` still runs whatever ~/.functions it last deployed.
# tests/chezmoi.bats guards that the file renders at all.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  unset CLAUDE_PROFILE CLAUDE_CONFIG_DIR

  # Fixture pins: one "work" org and one "personal" owner, mapped to two
  # accounts; work maps to the default dir, personal to a separate profile.
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-work-org.username work-account
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-personal.username personal-account
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.work-account '~/.claude'
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.personal-account '~/.claude-personal'
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

  # Stub claude: prove which config dir (if any) the wrapper handed it.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR-UNSET}"\n' \
    > "$BATS_TEST_TMPDIR/bin/claude"
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  DOTFUNCTIONS="$BATS_TEST_DIRNAME/../dot_functions"
}

# Make a bare-bones repo whose origin is $1; prints its path.
make_repo() {
  local repo="$BATS_TEST_TMPDIR/repo"
  rm -rf "$repo"
  git init -q "$repo"
  git -C "$repo" remote add origin "$1"
  echo "$repo"
}

account_in() {
  run zsh -c "source '$DOTFUNCTIONS'; cd '$1'; gh_account_for_cwd"
}

claude_in() {
  run zsh -c "source '$DOTFUNCTIONS'; cd '$1'; claude"
}

@test "dot_functions defines the claude wrapper and account resolver" {
  run zsh -c "source '$DOTFUNCTIONS'; whence -w claude gh_account_for_cwd gh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude: function"* ]]
  [[ "$output" == *"gh_account_for_cwd: function"* ]]
  [[ "$output" == *"gh: function"* ]]
}

@test "resolver: SSH host-alias origin resolves through the owner segment" {
  repo=$(make_repo 'git@github-workalias:octo-work-org/some-repo.git')
  account_in "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "work-account" ]
}

@test "resolver: plain github.com SSH origin resolves" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  account_in "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "personal-account" ]
}

@test "resolver: HTTPS origin resolves" {
  repo=$(make_repo 'https://github.com/octo-work-org/some-repo.git')
  account_in "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "work-account" ]
}

@test "resolver: unpinned owner fails silently" {
  repo=$(make_repo 'git@github.com:someone-else/some-repo.git')
  account_in "$repo"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "resolver: outside any git repo fails silently" {
  account_in "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "claude: repo mapped to the default dir runs with CLAUDE_CONFIG_DIR unset" {
  # Keychain regression guard: setting CLAUDE_CONFIG_DIR at all — even to
  # ~/.claude itself — switches Claude Code off Keychain auth.
  repo=$(make_repo 'git@github-workalias:octo-work-org/some-repo.git')
  claude_in "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "CLAUDE_CONFIG_DIR=UNSET" ]
}

@test "claude: repo mapped to a non-default profile exports its expanded dir" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  claude_in "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "CLAUDE_CONFIG_DIR=$HOME/.claude-personal" ]
}

@test "claude: unpinned repo falls back to plain claude" {
  repo=$(make_repo 'git@github.com:someone-else/some-repo.git')
  claude_in "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "CLAUDE_CONFIG_DIR=UNSET" ]
}

@test "claude: CLAUDE_PROFILE account override beats the cwd" {
  repo=$(make_repo 'git@github-workalias:octo-work-org/some-repo.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; CLAUDE_PROFILE=personal-account claude"
  [ "$status" -eq 0 ]
  [ "$output" = "CLAUDE_CONFIG_DIR=$HOME/.claude-personal" ]
}

@test "claude: CLAUDE_PROFILE literal directory override is used as-is" {
  repo=$(make_repo 'git@github-workalias:octo-work-org/some-repo.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; CLAUDE_PROFILE='$BATS_TEST_TMPDIR/custom-profile' claude"
  [ "$status" -eq 0 ]
  [ "$output" = "CLAUDE_CONFIG_DIR=$BATS_TEST_TMPDIR/custom-profile" ]
}

@test "claude-doctor: traces resolution and flags a missing login" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; claude-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrapper: claude: function"* ]]
  [[ "$output" == *"account: personal-account"* ]]
  [[ "$output" == *"launch:  $HOME/.claude-personal"* ]]
  [[ "$output" == *"NOT LOGGED IN"* ]]
}

@test "claude-doctor: names the logged-in account from the profile's .claude.json" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  mkdir -p "$HOME/.claude-personal"
  echo '{"oauthAccount":{"emailAddress":"person@example.com"}}' \
    > "$HOME/.claude-personal/.claude.json"
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; claude-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"logged in as person@example.com"* ]]
}

@test "no underscore-prefixed function names in dot_functions" {
  # Claude Code's shell snapshot (Bash tool, `!` commands) carries shell
  # functions over but silently drops underscore-prefixed ones, leaving
  # callers like claude() half-defined in those shells.
  run grep -En '^(function +_|_[A-Za-z0-9_]+ *\(\))' "$BATS_TEST_DIRNAME/../dot_functions"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "claude-doctor: unpinned repo reports the bare-claude fallback" {
  repo=$(make_repo 'git@github.com:someone-else/some-repo.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; claude-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"account: <no credential pin matched>"* ]]
  [[ "$output" == *"(bare claude fallback)"* ]]
}
