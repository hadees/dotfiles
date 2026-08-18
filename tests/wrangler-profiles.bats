#!/usr/bin/env bats

# The wrangler() wrapper in dot_functions keeps each repo bound to the
# Cloudflare auth profile mapped for its GitHub account: cwd origin ->
# credential.<url>.username pin -> wrangler.profile.<account> -> wrangler's
# own `auth activate <profile> <repo root>` directory binding. These tests
# source the real functions under zsh against a sandboxed git config, fake
# repos, and a stub `wrangler` binary that records its argv and emulates
# `auth activate` against a fake bindings file. All pins here are test
# fixtures — no real account, org, or profile names may appear (see CLAUDE.md).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  unset WRANGLER_PROFILE CLOUDFLARE_API_TOKEN
  # Pin wrangler's config dir so the wrapper's path guess is the same on
  # every platform: $XDG_CONFIG_HOME/.wrangler.
  export XDG_CONFIG_HOME="$HOME/xdg"
  WRANGLER_CFG="$XDG_CONFIG_HOME/.wrangler"
  mkdir -p "$WRANGLER_CFG/config" "$WRANGLER_CFG/profiles"

  # Fixture pins: work maps to wrangler's default login, personal to a named
  # profile that exists; a third account maps to a profile never created.
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-work-org.username work-account
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-personal.username personal-account
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-newbie.username newbie-account
  git config --file "$GIT_CONFIG_GLOBAL" wrangler.profile.work-account default
  git config --file "$GIT_CONFIG_GLOBAL" wrangler.profile.personal-account personal-profile
  git config --file "$GIT_CONFIG_GLOBAL" wrangler.profile.newbie-account never-created
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  : > "$WRANGLER_CFG/config/personal-profile.toml"

  # Stub wrangler: log every invocation's argv; emulate `auth activate
  # <profile> <dir>` (succeeds and records the binding when the profile's
  # config file exists, fails like wrangler otherwise).
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  WRANGLER_LOG="$BATS_TEST_TMPDIR/wrangler.log"
  : > "$WRANGLER_LOG"
  cat > "$BATS_TEST_TMPDIR/bin/wrangler" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/wrangler.log"
cfg="$XDG_CONFIG_HOME/.wrangler"
if [ "$1" = auth ] && [ "$2" = activate ]; then
  if [ -e "$cfg/config/$3.toml" ]; then
    b="$cfg/profiles/directory-bindings.json"
    [ -e "$b" ] || printf '{\n}\n' > "$b"
    printf '{\n\t"%s": "%s"\n}\n' "$4" "$3" > "$b"
    echo "Profile \"$3\" activated for \"$4\"."
    exit 0
  fi
  echo "Profile \"$3\" does not exist. Run \`wrangler auth create $3\` first." >&2
  exit 1
fi
echo "RAN: $*"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/wrangler"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  DOTFUNCTIONS="$BATS_TEST_DIRNAME/../dot_functions"
}

# Make a bare-bones repo whose origin is $1; prints its real path (git
# reports the toplevel with symlinks resolved, so compare against that).
make_repo() {
  local repo="$BATS_TEST_TMPDIR/repo"
  rm -rf "$repo"
  git init -q "$repo"
  git -C "$repo" remote add origin "$1"
  cd "$repo" && pwd -P
}

wrangler_in() {
  local dir=$1; shift
  run zsh -c "source '$DOTFUNCTIONS'; cd '$dir'; wrangler $*"
}

@test "dot_functions defines the wrangler wrapper and its helpers" {
  run zsh -c "source '$DOTFUNCTIONS'; whence -w wrangler wrangler-as wrangler_profile wrangler_bind wrangler_config_dir wrangler_profile_exists"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrangler: function"* ]]
  [[ "$output" == *"wrangler-as: function"* ]]
  [[ "$output" == *"wrangler_profile: function"* ]]
  [[ "$output" == *"wrangler_bind: function"* ]]
}

@test "wrangler: personal repo binds the repo root to its profile once, then runs" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  wrangler_in "$repo" deploy --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrangler: bound $repo to profile 'personal-profile'"* ]]
  [[ "$output" == *"RAN: deploy --dry-run"* ]]
  # Bind happened before the command, exactly once, against the repo root.
  [ "$(sed -n 1p "$WRANGLER_LOG")" = "auth activate personal-profile $repo" ]
  [ "$(sed -n 2p "$WRANGLER_LOG")" = "deploy --dry-run" ]
  grep -Fq "\"$repo\": \"personal-profile\"" "$WRANGLER_CFG/profiles/directory-bindings.json"

  # Second run: binding already present, no activate, no notice.
  : > "$WRANGLER_LOG"
  wrangler_in "$repo" whoami
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: whoami" ]
  [ "$(cat "$WRANGLER_LOG")" = "whoami" ]
}

@test "wrangler: a per-repo pin outranks the owner's account mapping" {
  # A side project hosted under the personal GitHub account but deploying to
  # its own Cloudflare login: `wrangler.<owner>/<repo>.profile` wins.
  git config --file "$GIT_CONFIG_GLOBAL" wrangler.octo-personal/side-project.profile side-profile
  : > "$WRANGLER_CFG/config/side-profile.toml"
  repo=$(make_repo 'git@github.com:octo-personal/side-project.git')
  wrangler_in "$repo" deploy
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$WRANGLER_LOG")" = "auth activate side-profile $repo" ]
  # Sibling repos of the same owner are unaffected.
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  : > "$WRANGLER_LOG"
  wrangler_in "$repo" deploy
  [ "$(sed -n 1p "$WRANGLER_LOG")" = "auth activate personal-profile $repo" ]
}

@test "wrangler: the per-repo pin matches https and mixed-case origins too" {
  git config --file "$GIT_CONFIG_GLOBAL" wrangler.octo-personal/side-project.profile side-profile
  : > "$WRANGLER_CFG/config/side-profile.toml"
  repo=$(make_repo 'https://github.com/Octo-Personal/Side-Project.git')
  wrangler_in "$repo" deploy
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$WRANGLER_LOG")" = "auth activate side-profile $repo" ]
}

@test "git_origin_slug: owner/repo from every origin shape, lowercased, .git stripped" {
  for origin in 'git@github.com:Octo-Personal/Some-Repo.git' 'github-alias:octo-personal/some-repo' 'https://github.com/octo-personal/some-repo.git' 'ssh://git@github.com/octo-personal/some-repo.git'; do
    repo=$(make_repo "$origin")
    run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; git_origin_slug"
    [ "$status" -eq 0 ]
    [ "$output" = "octo-personal/some-repo" ]
  done
  repo=$(make_repo '/some/local/path.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; git_origin_slug"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "wrangler: a subdirectory of the repo still binds the repo root" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  mkdir -p "$repo/packages/worker"
  wrangler_in "$repo/packages/worker" deploy
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$WRANGLER_LOG")" = "auth activate personal-profile $repo" ]
}

@test "wrangler: a stale binding to another profile is rebound to the pinned one" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  printf '{\n\t"%s": "%s"\n}\n' "$repo" "somebody-else" > "$WRANGLER_CFG/profiles/directory-bindings.json"
  wrangler_in "$repo" deploy
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$WRANGLER_LOG")" = "auth activate personal-profile $repo" ]
  grep -Fq "\"$repo\": \"personal-profile\"" "$WRANGLER_CFG/profiles/directory-bindings.json"
}

@test "wrangler: mapped profile that was never created refuses to run the command" {
  # Running on would silently use whatever profile wrangler falls back to.
  repo=$(make_repo 'git@github.com:octo-newbie/some-repo.git')
  wrangler_in "$repo" deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
  [[ "$output" == *"wrangler auth create never-created"* ]]
  [[ "$output" != *"RAN:"* ]]
  ! grep -q '^deploy' "$WRANGLER_LOG"
}

@test "wrangler: repo mapped to default manages no binding and runs plainly" {
  repo=$(make_repo 'git@github-workalias:octo-work-org/some-repo.git')
  wrangler_in "$repo" deploy
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: deploy" ]
  [ "$(cat "$WRANGLER_LOG")" = "deploy" ]
}

@test "wrangler: unpinned repo and non-repo cwd fall back to plain wrangler" {
  repo=$(make_repo 'git@github.com:someone-else/some-repo.git')
  wrangler_in "$repo" deploy
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: deploy" ]
  wrangler_in "$BATS_TEST_TMPDIR" whoami
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: whoami" ]
  ! grep -q '^auth activate' "$WRANGLER_LOG"
}

@test "wrangler: auth, login, and logout pass straight through, even in a pinned repo" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  for cmd in "auth list" "auth deactivate" login logout; do
    : > "$WRANGLER_LOG"
    wrangler_in "$repo" $cmd
    [ "$status" -eq 0 ]
    [ "$(cat "$WRANGLER_LOG")" = "$cmd" ]
  done
}

@test "wrangler: CLOUDFLARE_API_TOKEN in the environment disables profile management" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; CLOUDFLARE_API_TOKEN=x wrangler deploy"
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: deploy" ]
  [ "$(cat "$WRANGLER_LOG")" = "deploy" ]
}

@test "wrangler: WRANGLER_PROFILE mapped account injects --profile= and skips binding" {
  git config --file "$GIT_CONFIG_GLOBAL" wrangler.profile.octo-alias personal-profile
  repo=$(make_repo 'git@github-workalias:octo-work-org/some-repo.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; WRANGLER_PROFILE=octo-alias wrangler deploy --env prod"
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: --profile=personal-profile deploy --env prod" ]
  ! grep -q '^auth activate' "$WRANGLER_LOG"
}

@test "wrangler: WRANGLER_PROFILE accepts an existing literal profile and default" {
  run zsh -c "source '$DOTFUNCTIONS'; WRANGLER_PROFILE=personal-profile wrangler deploy"
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: --profile=personal-profile deploy" ]
  run zsh -c "source '$DOTFUNCTIONS'; WRANGLER_PROFILE=default wrangler deploy"
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: --profile=default deploy" ]
}

@test "wrangler: WRANGLER_PROFILE typo warns and falls back to the cwd's profile" {
  # A misspelling must never become a fresh OAuth login under that name.
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; WRANGLER_PROFILE=persnal-profile wrangler deploy 2>'$BATS_TEST_TMPDIR/stderr'"
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: deploy" ]
  grep -q "WRANGLER_PROFILE='persnal-profile' is neither a mapped account nor an existing wrangler profile" "$BATS_TEST_TMPDIR/stderr"
  [ "$(sed -n 1p "$WRANGLER_LOG")" = "auth activate personal-profile $repo" ]
}

@test "wrangler: an explicit --profile in the arguments is not duplicated by the override" {
  run zsh -c "source '$DOTFUNCTIONS'; WRANGLER_PROFILE=personal-profile wrangler deploy --profile default"
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: deploy --profile default" ]
  run zsh -c "source '$DOTFUNCTIONS'; WRANGLER_PROFILE=personal-profile wrangler --profile=default deploy"
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: --profile=default deploy" ]
}

@test "wrangler-as: mapped alias pins the profile and forwards args intact" {
  git config --file "$GIT_CONFIG_GLOBAL" wrangler.profile.octo-alias personal-profile
  run zsh -c "source '$DOTFUNCTIONS'; wrangler-as octo-alias d1 execute mydb --command 'select 1'"
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: --profile=personal-profile d1 execute mydb --command select 1" ]
}

@test "wrangler-as: unknown profile errors, lists profiles, never launches wrangler" {
  run zsh -c "source '$DOTFUNCTIONS'; wrangler-as no-such-profile deploy 2>'$BATS_TEST_TMPDIR/stderr'"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -s "$WRANGLER_LOG" ]
  grep -q "unknown profile 'no-such-profile'" "$BATS_TEST_TMPDIR/stderr"
  grep -q '^work-account$' "$BATS_TEST_TMPDIR/stderr"
  grep -q '^personal-account$' "$BATS_TEST_TMPDIR/stderr"
}

@test "wrangler-as: no arguments prints usage and the profile list on stderr" {
  run zsh -c "source '$DOTFUNCTIONS'; wrangler-as 2>'$BATS_TEST_TMPDIR/stderr'"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  grep -q 'usage: wrangler-as <profile>' "$BATS_TEST_TMPDIR/stderr"
  grep -q '^personal-account$' "$BATS_TEST_TMPDIR/stderr"
}

@test "wrangler_config_dir: legacy ~/.wrangler wins, else XDG_CONFIG_HOME, else the platform default" {
  run zsh -c "source '$DOTFUNCTIONS'; wrangler_config_dir"
  [ "$output" = "$XDG_CONFIG_HOME/.wrangler" ]
  run zsh -c "source '$DOTFUNCTIONS'; unset XDG_CONFIG_HOME; wrangler_config_dir"
  if [ "$(uname)" = Darwin ]; then
    [ "$output" = "$HOME/Library/Preferences/.wrangler" ]
  else
    [ "$output" = "$HOME/.config/.wrangler" ]
  fi
  mkdir -p "$HOME/.wrangler"
  run zsh -c "source '$DOTFUNCTIONS'; wrangler_config_dir"
  [ "$output" = "$HOME/.wrangler" ]
}
