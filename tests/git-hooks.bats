#!/usr/bin/env bats

# The global git hooks in dot_git-hooks/ (deployed to ~/.git-hooks, selected
# by core.hooksPath in dot_gitconfig). pre-commit refuses a commit whose
# author/committer email does not belong to the account the origin's owner
# is pinned to — the same credential pins the wrappers route on, plus
# `identity.<account>.email` mappings the overlays declare. Every hook name
# chains to the repo's own .git/hooks/<name>. Sandboxed git config, fixture
# pins only (see CLAUDE.md: no real names here).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  unset GIT_IDENTITY_CHECK GIT_AUTHOR_EMAIL GIT_COMMITTER_EMAIL GIT_AUTHOR_NAME GIT_COMMITTER_NAME

  # Deploy the hooks the way chezmoi would: executable_ prefix dropped,
  # symlink_ files become symlinks to their content.
  HOOKS="$HOME/.git-hooks"
  mkdir -p "$HOOKS"
  local src="$BATS_TEST_DIRNAME/../dot_git-hooks" f
  for f in "$src"/executable_*; do
    cp "$f" "$HOOKS/${f##*/executable_}"; chmod +x "$HOOKS/${f##*/executable_}"
  done
  for f in "$src"/symlink_*; do
    ln -s "$(cat "$f")" "$HOOKS/${f##*/symlink_}"
  done

  git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath "$HOOKS"
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  # Fixture pins and the emails each account may commit as.
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-work-org.username work-account
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-personal.username personal-account
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-nomail.username nomail-account
  git config --file "$GIT_CONFIG_GLOBAL" identity.work-account.email work@example.com
  git config --file "$GIT_CONFIG_GLOBAL" --add identity.personal-account.email 12345+personal@example.net
  git config --file "$GIT_CONFIG_GLOBAL" --add identity.personal-account.email personal@example.org
  # The "wrong" default identity, as a personal overlay would set globally.
  git config --file "$GIT_CONFIG_GLOBAL" user.name Fixture
  git config --file "$GIT_CONFIG_GLOBAL" user.email personal@example.org
}

make_repo() {
  local repo="$BATS_TEST_TMPDIR/repo"
  rm -rf "$repo"
  git init -q "$repo"
  [ -n "$1" ] && git -C "$repo" remote add origin "$1"
  echo x > "$repo/f"
  git -C "$repo" add f
  echo "$repo"
}

@test "dot_git-hooks: every hook file is deployable and the shims point at run-local-hook" {
  [ -x "$HOOKS/pre-commit" ]
  [ -x "$HOOKS/run-local-hook" ]
  for h in pre-push commit-msg prepare-commit-msg post-commit post-checkout post-merge pre-rebase post-rewrite pre-merge-commit; do
    [ "$(readlink "$HOOKS/$h")" = run-local-hook ]
    [ -x "$HOOKS/$h" ]
  done
  sh -n "$HOOKS/pre-commit"
  sh -n "$HOOKS/run-local-hook"
}

@test "pre-commit: personal identity in a work-owned repo is refused, with the expected emails" {
  repo=$(make_repo 'git@github-work:octo-work-org/some-repo.git')
  run git -C "$repo" commit -q -m init
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to commit as personal@example.org"* ]]
  [[ "$output" == *"owned by 'octo-work-org' (pinned to account 'work-account'"* ]]
  [[ "$output" == *"work@example.com"* ]]
  [[ "$output" == *"GIT_IDENTITY_CHECK=0"* ]]
  run git -C "$repo" rev-parse --verify HEAD
  [ "$status" -ne 0 ]
}

@test "pre-commit: the account's own email passes; the check is case-insensitive and honours --author" {
  repo=$(make_repo 'git@github-work:octo-work-org/some-repo.git')
  git -C "$repo" config user.email WORK@example.com
  run git -C "$repo" commit -q -m init
  [ "$status" -eq 0 ]
  # A --author override that is wrong is still caught (author is checked,
  # not just user.email); a right one with a wrong committer is caught too.
  echo y >> "$repo/f"; git -C "$repo" add f
  run git -C "$repo" commit -q -m two --author='Someone <personal@example.org>'
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to commit as personal@example.org"* ]]
  run env GIT_COMMITTER_EMAIL=personal@example.org git -C "$repo" commit -q -m two
  [ "$status" -ne 0 ]
}

@test "pre-commit: any of several declared emails is accepted (noreply and real)" {
  repo=$(make_repo 'https://github.com/Octo-Personal/some-repo')
  run git -C "$repo" commit -q -m init
  [ "$status" -eq 0 ]
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" config user.email 12345+personal@example.net
  run git -C "$repo" commit -q -m two
  [ "$status" -eq 0 ]
}

@test "pre-commit: a per-repo identity pin outranks the owner's account emails" {
  # A side project hosted under the personal account but committed under its
  # own identity: identity.<owner>/<repo>.email wins, mirroring wrangler's pin.
  git config --file "$GIT_CONFIG_GLOBAL" identity.octo-personal/side-project.email side@example.com
  repo=$(make_repo 'git@github.com:Octo-Personal/Side-Project.git')
  run git -C "$repo" commit -q -m init            # personal@example.org — the account's email — is now wrong here
  [ "$status" -ne 0 ]
  [[ "$output" == *"pinned to repo 'octo-personal/side-project'"* ]]
  [[ "$output" == *"side@example.com"* ]]
  git -C "$repo" config user.email side@example.com
  run git -C "$repo" commit -q -m init
  [ "$status" -eq 0 ]
  DOTFUNCTIONS="$BATS_TEST_DIRNAME/../dot_functions"
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; git-doctor"
  [[ "$output" == *"gate:    on — 'side@example.com' is an identity.octo-personal/side-project.email (per-repo pin); commits pass"* ]]
}

@test "pre-commit: no origin, unpinned owner, or non-GitHub-shaped remote means no opinion" {
  repo=$(make_repo '')
  run git -C "$repo" commit -q -m init
  [ "$status" -eq 0 ]
  repo=$(make_repo 'git@github.com:someone-else/some-repo.git')
  run git -C "$repo" commit -q -m init
  [ "$status" -eq 0 ]
  repo=$(make_repo '/srv/git/some-repo.git')
  run git -C "$repo" commit -q -m init
  [ "$status" -eq 0 ]
}

@test "pre-commit: pinned account with no declared email warns and lets the commit through" {
  repo=$(make_repo 'git@github.com:octo-nomail/some-repo.git')
  run git -C "$repo" commit -q -m init
  [ "$status" -eq 0 ]
  [[ "$output" == *"no identity.nomail-account.email is declared"* ]]
}

@test "pre-commit: GIT_IDENTITY_CHECK=0 bypasses the gate for one commit" {
  repo=$(make_repo 'git@github-work:octo-work-org/some-repo.git')
  run env GIT_IDENTITY_CHECK=0 git -C "$repo" commit -q -m init
  [ "$status" -eq 0 ]
}

@test "hooks chain to the repo's own .git/hooks/<name>, and a failing local hook still blocks" {
  repo=$(make_repo 'git@github-work:octo-work-org/some-repo.git')
  git -C "$repo" config user.email work@example.com
  local_hooks="$repo/.git/hooks"   # absolute — never let this land in the cwd's .git
  mkdir -p "$local_hooks"
  printf '#!/bin/sh\necho LOCAL-PRE-COMMIT-RAN >&2\nexit 0\n' > "$local_hooks/pre-commit"
  printf '#!/bin/sh\necho LOCAL-COMMIT-MSG-RAN >&2\nexit 1\n' > "$local_hooks/commit-msg"
  chmod +x "$local_hooks/pre-commit" "$local_hooks/commit-msg"
  run git -C "$repo" commit -q -m init
  [ "$status" -ne 0 ]
  [[ "$output" == *"LOCAL-PRE-COMMIT-RAN"* ]]
  [[ "$output" == *"LOCAL-COMMIT-MSG-RAN"* ]]
  rm "$local_hooks/commit-msg"
  run git -C "$repo" commit -q -m init
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOCAL-PRE-COMMIT-RAN"* ]]
}

@test "git-doctor: reports the gate's verdict for the cwd" {
  repo=$(make_repo 'git@github-work:octo-work-org/some-repo.git')
  DOTFUNCTIONS="$BATS_TEST_DIRNAME/../dot_functions"
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; git-doctor"
  [[ "$output" == *"gate:    on — WOULD REFUSE: 'personal@example.org' is not one of identity.work-account.email (work@example.com)"* ]]
  git -C "$repo" config user.email work@example.com
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; git-doctor"
  [[ "$output" == *"gate:    on — 'work@example.com' is an identity.work-account.email; commits pass"* ]]
  repo=$(make_repo 'git@github.com:someone-else/some-repo.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; git-doctor"
  [[ "$output" == *"gate:    on, no opinion here (owner unpinned)"* ]]
  git config --file "$GIT_CONFIG_GLOBAL" --unset core.hooksPath
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; git-doctor"
  [[ "$output" == *"gate:    OFF — core.hooksPath unset"* ]]
}

@test "a local pre-commit that runs git itself does not see HOOK_NAME leak into nested hooks" {
  # The pre-commit framework stashes and `git checkout -- .`s inside the
  # pre-commit hook; that nested checkout fires post-checkout, which must
  # resolve to the repo's post-checkout (with checkout args), not to
  # pre-commit again because HOOK_NAME was still in the environment.
  repo=$(make_repo 'git@github.com:someone-else/some-repo.git')
  local_hooks="$repo/.git/hooks"; mkdir -p "$local_hooks"
  printf '#!/bin/sh\necho "LOCAL-PRE-COMMIT args=$#" >&2\ngit checkout -q -- . \n' > "$local_hooks/pre-commit"
  printf '#!/bin/sh\necho "LOCAL-POST-CHECKOUT args=$#" >&2\n' > "$local_hooks/post-checkout"
  chmod +x "$local_hooks/pre-commit" "$local_hooks/post-checkout"
  run git -C "$repo" commit -q -m init
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOCAL-PRE-COMMIT args=0"* ]]
  [[ "$output" == *"LOCAL-POST-CHECKOUT args=3"* ]]
  # exactly one pre-commit run — never re-entered by the nested checkout
  [ "$(printf '%s\n' "$output" | grep -c LOCAL-PRE-COMMIT)" -eq 1 ]
}

@test "hook.<name>.run: repo-local config commands run from the repo root before the local hook, and block on failure" {
  repo=$(make_repo 'git@github.com:someone-else/some-repo.git')
  git -C "$repo" config --add hook.pre-commit.run 'echo "RUN1 in $(pwd)" >&2'
  git -C "$repo" config --add hook.pre-commit.run 'test -f f'   # relative to the repo root
  run git -C "$repo" commit -q -m init
  [ "$status" -eq 0 ]
  [[ "$output" == *"RUN1 in $(cd "$repo" && pwd -P)"* ]]
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" config --add hook.pre-commit.run 'echo NOPE >&2; false'
  run git -C "$repo" commit -q -m two
  [ "$status" -ne 0 ]
  [[ "$output" == *"NOPE"* ]]
  [[ "$output" == *"pre-commit: hook.pre-commit.run command failed: echo NOPE >&2; false"* ]]
  # A pre-push command runs too (git feeds pre-push refs on stdin; the
  # command gets /dev/null so it cannot eat them).
  bare="$BATS_TEST_TMPDIR/bare.git"; git init -q --bare "$bare"
  git -C "$repo" config --unset-all hook.pre-commit.run
  git -C "$repo" commit -q -m two
  git -C "$repo" remote add pushtarget "$bare"
  git -C "$repo" config --add hook.pre-push.run 'echo PREPUSH-RAN >&2; false'
  run git -C "$repo" push -q pushtarget HEAD
  [ "$status" -ne 0 ]
  [[ "$output" == *"PREPUSH-RAN"* ]]
  git -C "$repo" config --unset-all hook.pre-push.run
  run git -C "$repo" push -q pushtarget HEAD
  [ "$status" -eq 0 ]
}
