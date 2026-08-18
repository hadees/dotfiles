#!/usr/bin/env bats

# git-doctor in dot_functions reports, for the cwd, what git itself will do:
# the commit identity the include chain selects (and which file supplied
# it), signing configuration and whether its parts exist, how an scp-style
# origin's SSH alias resolves, and every config file consulted. Sandboxed
# git config and HOME; no network. All names here are fixtures — no real
# account, org, or person may appear (see CLAUDE.md).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  unset GIT_AUTHOR_EMAIL GIT_COMMITTER_EMAIL

  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-personal.username personal-acct
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  # Identity arrives only through an include scoped to a directory, the way
  # the overlays scope theirs to a remote — so "from:" proves the include fired.
  REPO="$BATS_TEST_TMPDIR/repo"
  git config --file "$GIT_CONFIG_GLOBAL" "includeIf.gitdir:$REPO/.path" "$HOME/.gitconfig-personal"
  git config --file "$HOME/.gitconfig-personal" user.name "Octo Person"
  git config --file "$HOME/.gitconfig-personal" user.email "octo@example.com"

  DOTFUNCTIONS="$BATS_TEST_DIRNAME/../dot_functions"
}

make_repo() {
  rm -rf "$REPO"
  git init -q "$REPO"
  git -C "$REPO" remote add origin "$1"
}

doctor_in() {
  run zsh -c "source '$DOTFUNCTIONS'; cd '$1'; git-doctor"
}

@test "git-doctor: identity from the include that matched, signing off, ssh alias resolved" {
  make_repo 'git@github-personal:octo-personal/some-repo.git'
  doctor_in "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"origin:  git@github-personal:octo-personal/some-repo.git"* ]]
  [[ "$output" == *"account: personal-acct"* ]]
  [[ "$output" == *"author:  Octo Person <octo@example.com>"* ]]
  [[ "$output" == *"from:    $HOME/.gitconfig-personal"* ]]
  [[ "$output" == *"signing: off"* ]]
  # No ~/.ssh/config in the sandbox: the alias resolves to itself.
  [[ "$output" == *"ssh:     github-personal -> github-personal"* ]]
  [[ "$output" == *"configs: "*".gitconfig-personal"* ]]
}

@test "git-doctor: no identity in effect is called out loudly" {
  make_repo 'git@github.com:someone-else/some-repo.git'
  # Outside the include's directory scope there is no user.email at all.
  mv "$REPO" "$BATS_TEST_TMPDIR/elsewhere"
  doctor_in "$BATS_TEST_TMPDIR/elsewhere"
  [ "$status" -eq 0 ]
  [[ "$output" == *"account: <no credential pin matched>"* ]]
  [[ "$output" == *"author:  NOT SET"* ]]
  [[ "$output" != *"from:"* ]]
}

@test "git-doctor: signing on reports format, key, and missing signer/key" {
  make_repo 'https://github.com/octo-personal/some-repo.git'
  git config --file "$HOME/.gitconfig-personal" commit.gpgsign true
  git config --file "$HOME/.gitconfig-personal" gpg.format ssh
  git config --file "$HOME/.gitconfig-personal" user.signingkey '~/.ssh/id_missing.pub'
  git config --file "$HOME/.gitconfig-personal" gpg.ssh.program '/nonexistent/op-ssh-sign'
  doctor_in "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"signing: on (format ssh), key ~/.ssh/id_missing.pub"* ]]
  [[ "$output" == *"WARNING: signing key file ~/.ssh/id_missing.pub does not exist"* ]]
  [[ "$output" == *"signer:  /nonexistent/op-ssh-sign — NOT FOUND"* ]]
  # https origin: says which account the credential helper will use.
  [[ "$output" == *"https:   pushes authenticate via credential helper as 'personal-acct'"* ]]

  # With the key present and a real signer, no warnings.
  mkdir -p "$HOME/.ssh" && : > "$HOME/.ssh/id_missing.pub"
  git config --file "$HOME/.gitconfig-personal" gpg.ssh.program /bin/sh
  doctor_in "$REPO"
  [[ "$output" != *"WARNING"* ]]
  [[ "$output" == *"signer:  /bin/sh"* ]]
}

@test "doctor: runs all four doctors in order" {
  make_repo 'git@github-personal:octo-personal/some-repo.git'
  # Stubs so gh-/wrangler-doctor have something harmless to talk to.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/gh"; chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  run zsh -c "PATH='$BATS_TEST_TMPDIR/bin':\$PATH; source '$DOTFUNCTIONS'; cd '$REPO'; doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"== git-doctor"*"== gh-doctor"*"== claude-doctor"*"== wrangler-doctor"* ]]
  [[ "$output" == *"author:  Octo Person <octo@example.com>"* ]]
}
