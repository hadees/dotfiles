#!/usr/bin/env bats

# Behavioral tests for the gh() wrapper in dot_functions: it pins the GitHub
# account per invocation by exporting GH_TOKEN for that single command,
# resolving an explicit owner in the arguments first and the cwd's origin
# remote second, via the credential.<url>.username pins in git config.
# Modeled on tests/claude-profiles.bats: real functions sourced under zsh
# against a sandboxed git config, fixture repos, and a stub `gh` earlier in
# PATH that reports the GH_TOKEN it was invoked with. All pins here are test
# fixtures — no real account or org names may appear (see CLAUDE.md).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  unset GH_TOKEN GH_STUB_NO_TOKEN_FOR

  # Fixture pins: one "work" org and one "personal" owner, each mapped to a
  # gh account name.
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-work-org.username work-acct
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-personal.username personal-acct
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

  # Stub gh: answer the wrapper's token lookup with a recognizable token
  # (or nothing at all for $GH_STUB_NO_TOKEN_FOR, to simulate a pinned
  # account with no stored credential); for every other invocation, prove
  # which GH_TOKEN (if any) the wrapper handed it.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/bin/sh
if [ "$1" = auth ] && [ "$2" = token ] && [ "$3" = --user ]; then
  [ "$4" = "${GH_STUB_NO_TOKEN_FOR-}" ] && exit 0
  echo "tok-$4"
  exit 0
fi
echo "GH_TOKEN=${GH_TOKEN-UNSET} args: $*"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
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

# Run `gh <args...>` through the sourced wrapper from inside repo $1.
gh_in() {
  local repo="$1"
  shift
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; gh \"\$@\"" zsh "$@"
}

@test "gh: explicit owner argument beats the cwd pin" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  gh_in "$repo" repo list octo-work-org
  [ "$status" -eq 0 ]
  [ "$output" = "GH_TOKEN=tok-work-acct args: repo list octo-work-org" ]
}

@test "gh: cwd pin picks the work token in a work repo" {
  repo=$(make_repo 'git@github.com:octo-work-org/some-repo.git')
  gh_in "$repo" pr list
  [ "$status" -eq 0 ]
  [ "$output" = "GH_TOKEN=tok-work-acct args: pr list" ]
}

@test "gh: auth subcommand passes straight through with no GH_TOKEN" {
  repo=$(make_repo 'git@github.com:octo-work-org/some-repo.git')
  gh_in "$repo" auth status
  [ "$status" -eq 0 ]
  [ "$output" = "GH_TOKEN=UNSET args: auth status" ]
}

@test "gh: no pins configured means plain passthrough" {
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig-empty"
  repo=$(make_repo 'git@github.com:octo-work-org/some-repo.git')
  gh_in "$repo" repo list octo-work-org
  [ "$status" -eq 0 ]
  [ "$output" = "GH_TOKEN=UNSET args: repo list octo-work-org" ]
}

@test "gh: a local-path argument naming a pinned owner cannot hijack the account" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  touch "$repo/octo-work-org.md"
  mkdir -p "$repo/octo-work-org"
  touch "$repo/octo-work-org/notes.md"
  gh_in "$repo" gist create ./octo-work-org.md octo-work-org/notes.md
  [ "$status" -eq 0 ]
  [ "$output" = "GH_TOKEN=tok-personal-acct args: gist create ./octo-work-org.md octo-work-org/notes.md" ]
}

@test "gh: mixed-case owner in the origin URL still resolves" {
  repo=$(make_repo 'git@github.com:Octo-Personal/Some-Repo.git')
  gh_in "$repo" pr list
  [ "$status" -eq 0 ]
  [ "$output" = "GH_TOKEN=tok-personal-acct args: pr list" ]
}

@test "gh: empty token for the pinned account warns on stderr and runs unpinned" {
  repo=$(make_repo 'git@github.com:octo-work-org/some-repo.git')
  export GH_STUB_NO_TOKEN_FOR=work-acct
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; gh pr list 2>'$BATS_TEST_TMPDIR/stderr'"
  [ "$status" -eq 0 ]
  [ "$output" = "GH_TOKEN=UNSET args: pr list" ]
  run cat "$BATS_TEST_TMPDIR/stderr"
  [[ "$output" == *"no token for pinned account 'work-acct'"* ]]
}

@test "gh: a leading-slash api endpoint owner outranks the cwd" {
  # `gh api /repos/<owner>/<repo>` is a documented endpoint form; the
  # path-argument skip must not swallow it (that would silently fall back
  # to the cwd's account — the wrong token for a work-org endpoint).
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  gh_in "$repo" api /repos/octo-work-org/some-repo
  [ "$status" -eq 0 ]
  [ "$output" = "GH_TOKEN=tok-work-acct args: api /repos/octo-work-org/some-repo" ]
}

# --- gh-doctor -------------------------------------------------------------
#
# The stub answers `gh api user --jq .login` with $GH_STUB_API_LOGIN when set,
# else with the account the token was minted for (tok-<acct> -> <acct>).

@test "gh-doctor: traces the pin, finds the token, and verifies identity" {
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/bin/sh
if [ "$1" = auth ] && [ "$2" = token ] && [ "$3" = --user ]; then
  [ "$4" = "${GH_STUB_NO_TOKEN_FOR-}" ] && exit 0
  echo "tok-$4"
  exit 0
fi
if [ "$1" = api ] && [ "$2" = user ]; then
  [ -n "${GH_STUB_API_LOGIN-}" ] && { echo "$GH_STUB_API_LOGIN"; exit 0; }
  echo "${GH_TOKEN#tok-}"
  exit 0
fi
echo "GH_TOKEN=${GH_TOKEN-UNSET} args: $*"
EOF
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; gh-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrapper: gh: function"* ]]
  [[ "$output" == *"defined: ok (3 helpers)"* ]]
  [[ "$output" == *"binary:  $BATS_TEST_TMPDIR/bin/gh"* ]]
  [[ "$output" == *"account: personal-acct"* ]]
  [[ "$output" == *"pins:    octo-work-org -> work-acct, octo-personal -> personal-acct"* ]]
  [[ "$output" == *"token:   present for 'personal-acct'"* ]]
  [[ "$output" == *"verify:  token authenticates as personal-acct — OK"* ]]

  # Keyring handed back another user's token: flagged loudly.
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; GH_STUB_API_LOGIN=work-acct gh-doctor"
  [[ "$output" == *"verify:  MISMATCH — token for 'personal-acct' authenticates as 'work-acct'"* ]]

  # No token stored for the pinned account.
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; GH_STUB_NO_TOKEN_FOR=personal-acct gh-doctor"
  [[ "$output" == *"token:   NONE for 'personal-acct'"* ]]
  [[ "$output" != *"verify:"* ]]

  # A GH_TOKEN in the environment is reported as set, never echoed.
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; GH_TOKEN=sekrit gh-doctor"
  [[ "$output" == *"GH_TOKEN=<set"* ]]
  [[ "$output" != *"sekrit"* ]]

  # A dropped helper is named before the account line that would otherwise
  # misreport "no pin matched".
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; unfunction gh_account_for_cwd; gh-doctor 2>/dev/null"
  [[ "$output" == *"defined: MISSING gh_account_for_cwd — "* ]]
}

@test "gh-doctor: unpinned repo says gh runs as the active account and stops" {
  repo=$(make_repo 'git@github.com:someone-else/some-repo.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; gh-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"account: <no credential pin matched"* ]]
  [[ "$output" != *"token:"* ]]
}
