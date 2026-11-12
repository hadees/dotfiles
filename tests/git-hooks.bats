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
  unset GIT_IDENTITY_CHECK GIT_PUSH_CHECK GIT_AUTHOR_EMAIL GIT_COMMITTER_EMAIL GIT_AUTHOR_NAME GIT_COMMITTER_NAME

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
  [ -x "$HOOKS/pre-push" ]
  for h in commit-msg prepare-commit-msg post-commit post-checkout post-merge pre-rebase post-rewrite pre-merge-commit; do
    [ "$(readlink "$HOOKS/$h")" = run-local-hook ]
    [ -x "$HOOKS/$h" ]
  done
  sh -n "$HOOKS/pre-commit"
  sh -n "$HOOKS/pre-push"
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
  # A pre-push command runs too, and sees what git gave the hook: the
  # remote name in $1 and the ref list on stdin (a guard that cannot read
  # that list can only grep the checkout it stands in, not the push).
  bare="$BATS_TEST_TMPDIR/bare.git"; git init -q --bare "$bare"
  git -C "$repo" config --unset-all hook.pre-commit.run
  git -C "$repo" commit -q -m two
  git -C "$repo" remote add pushtarget "$bare"
  git -C "$repo" config --add hook.pre-push.run 'echo "PREPUSH-RAN to $1: $(cat)" >&2; false'
  run git -C "$repo" push -q pushtarget HEAD
  [ "$status" -ne 0 ]
  [[ "$output" == *"PREPUSH-RAN to pushtarget: HEAD $(git -C "$repo" rev-parse HEAD) refs/heads/main 0000000000000000000000000000000000000000"* ]]
  git -C "$repo" config --unset-all hook.pre-push.run
  run git -C "$repo" push -q pushtarget HEAD
  [ "$status" -eq 0 ]
}

@test "hook.<name>.run: every command and then the local hook each get their own copy of the hook's stdin" {
  repo=$(make_repo 'git@github.com:someone-else/some-repo.git')
  git -C "$repo" commit -q -m init
  bare="$BATS_TEST_TMPDIR/bare.git"; git init -q --bare "$bare"
  git -C "$repo" remote add pushtarget "$bare"
  # Two commands that both read stdin to exhaustion, then a repo-local
  # pre-push that does the same: none may starve the next.
  git -C "$repo" config --add hook.pre-push.run 'echo "ONE $(wc -l < /dev/stdin | tr -d " ")" >&2'
  git -C "$repo" config --add hook.pre-push.run 'echo "TWO $(wc -l < /dev/stdin | tr -d " ")" >&2'
  printf '#!/bin/sh\necho "LOCAL $1 $(wc -l < /dev/stdin | tr -d " ")" >&2\nexit 3\n' > "$repo/.git/hooks/pre-push"
  chmod +x "$repo/.git/hooks/pre-push"
  run git -C "$repo" push -q pushtarget HEAD
  [ "$status" -ne 0 ]
  [[ "$output" == *"ONE 1"* ]]
  [[ "$output" == *"TWO 1"* ]]
  [[ "$output" == *"LOCAL pushtarget 1"* ]]
  # A hook git hands no input (pre-commit) sees an empty stdin, never a
  # blocking one.
  rm "$repo/.git/hooks/pre-push"
  git -C "$repo" config --unset-all hook.pre-push.run
  git -C "$repo" config --add hook.pre-commit.run 'echo "COMMIT $(wc -l < /dev/stdin | tr -d " ")" >&2'
  echo y >> "$repo/f"; git -C "$repo" add f
  run git -C "$repo" commit -q -m two
  [ "$status" -eq 0 ]
  [[ "$output" == *"COMMIT 0"* ]]
}

# --- pre-push: WIP commits and force-pushed default branches -----------------
#
# Every fixture here pushes to a bare repo on disk, so the identity gate has
# no opinion (a local path has no owner) and nothing touches the network.

push_repo() {
  local repo="$BATS_TEST_TMPDIR/pushrepo" bare="$BATS_TEST_TMPDIR/pushbare.git"
  rm -rf "$repo" "$bare"
  git init -q --bare "$bare"
  git init -q "$repo"
  echo x > "$repo/f"; git -C "$repo" add f; git -C "$repo" commit -q -m "init"
  git -C "$repo" remote add origin "$bare"
  git -C "$repo" push -q origin main
  echo "$repo"
}

@test "pre-push: a commit whose subject carries the marker is refused, and named" {
  repo=$(push_repo)
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "WIP: half the backfill"
  run git -C "$repo" push -q origin main
  [ "$status" -ne 0 ]
  [[ "$output" == *"still carries unfinished commits"* ]]
  [[ "$output" == *"WIP: half the backfill"* ]]
}

@test "pre-push: WIP is matched case-insensitively and anywhere in the subject" {
  repo=$(push_repo)
  # This repo's subjects lead with an emoji and a Conventional Commits type,
  # so anchoring the match at the start would never fire on a real one.
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "feat: wip guard, do not ship"
  run git -C "$repo" push -q origin main
  [ "$status" -ne 0 ]
  [[ "$output" == *"still carries unfinished commits"* ]]
}

@test "pre-push: a word merely containing wip is not a WIP commit" {
  repo=$(push_repo)
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "fix: stop the swipe handler wiping state"
  run git -C "$repo" push -q origin main
  [ "$status" -eq 0 ]
}

@test "pre-push: only the commits being pushed are examined" {
  repo=$(push_repo)
  # A WIP commit that is already on the remote is somebody else's problem;
  # this push publishes nothing new about it.
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "WIP: already out there"
  GIT_PUSH_CHECK=0 git -C "$repo" push -q origin main
  echo z >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "feat: a finished thing"
  run git -C "$repo" push -q origin main
  [ "$status" -eq 0 ]
}

@test "pre-push: a new branch is scanned without walking the whole history" {
  repo=$(push_repo)
  git -C "$repo" checkout -q -b topic
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "WIP: on a fresh branch"
  run git -C "$repo" push -q origin topic
  [ "$status" -ne 0 ]
  [[ "$output" == *"still carries unfinished commits"* ]]
}

@test "pre-push: GIT_PUSH_CHECK=0 bypasses the gate for one push" {
  repo=$(push_repo)
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "WIP: deliberate"
  run env GIT_PUSH_CHECK=0 git -C "$repo" push -q origin main
  [ "$status" -eq 0 ]
}

@test "pre-push: deleting a ref pushes no commits and is not judged" {
  repo=$(push_repo)
  git -C "$repo" checkout -q -b topic
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "feat: fine"
  git -C "$repo" push -q origin topic
  run git -C "$repo" push -q origin --delete topic
  [ "$status" -eq 0 ]
}

@test "pre-push: a non-fast-forward push of the default branch is refused" {
  repo=$(push_repo)
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "feat: one"
  git -C "$repo" push -q origin main
  git -C "$repo" reset -q --hard HEAD~1
  echo z >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "feat: a different one"
  run git -C "$repo" push -q --force origin main
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-fast-forward push of main"* ]]
  run env GIT_PUSH_CHECK=0 git -C "$repo" push -q --force origin main
  [ "$status" -eq 0 ]
}

@test "pre-push: force-pushing a topic branch is ordinary work" {
  repo=$(push_repo)
  git -C "$repo" checkout -q -b topic
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "feat: one"
  git -C "$repo" push -q origin topic
  git -C "$repo" commit -q --amend -m "feat: one, reworded"
  run git -C "$repo" push -q --force origin topic
  [ "$status" -eq 0 ]
}

@test "pre-push: the gate still chains to hook.pre-push.run and the repo's own hook" {
  repo=$(push_repo)
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "feat: fine"
  git -C "$repo" config --add hook.pre-push.run 'echo "RAN $(wc -l < /dev/stdin | tr -d " ")" >&2'
  printf '#!/bin/sh\necho "LOCAL $(wc -l < /dev/stdin | tr -d " ")" >&2\n' > "$repo/.git/hooks/pre-push"
  chmod +x "$repo/.git/hooks/pre-push"
  run git -C "$repo" push -q origin main
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN 1"* ]]
  [[ "$output" == *"LOCAL 1"* ]]
}

@test "pre-push: the gate stays armed when the remote's commit is not in this clone" {
  # git reads the remote sha over the push connection, so it runs ahead of
  # the tracking ref whenever a collaborator has pushed. Scanning must not
  # degrade into an empty, silently passing range there.
  repo=$(push_repo)
  other="$BATS_TEST_TMPDIR/other"
  git clone -q "$BATS_TEST_TMPDIR/pushbare.git" "$other"
  echo o >> "$other/f"; git -C "$other" add f
  git -C "$other" -c user.email=personal@example.org commit -q -m "feat: theirs"
  git -C "$other" push -q origin main
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "WIP: mine"
  run git -C "$repo" push -q origin main
  [ "$status" -ne 0 ]
  # Refused for the marker, not merely rejected as non-fast-forward by git.
  [[ "$output" == *"still carries unfinished commits"* ]]
}

@test "pre-push: forcing the default branch over a remote tip this clone never fetched is refused" {
  # The stale-clone-then-force sequence: git hands the hook the remote's live
  # sha, it is not in this clone, and until 2026-11-11 that meant "no
  # verdict" — the push went through and the other clone's commit was gone.
  repo=$(push_repo)
  bare="$BATS_TEST_TMPDIR/pushbare.git"
  other="$BATS_TEST_TMPDIR/other"
  git clone -q "$bare" "$other"
  echo o >> "$other/f"; git -C "$other" add f
  git -C "$other" -c user.email=personal@example.org commit -q -m "feat: theirs"
  git -C "$other" push -q origin main
  theirs=$(git -C "$other" rev-parse HEAD)
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "feat: mine"
  run git -C "$repo" push -q --force origin main
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not in this clone"* ]]
  [[ "$output" == *"Fetch origin and retry, or bypass once with GIT_PUSH_CHECK=0."* ]]
  [ "$(git -C "$bare" rev-parse refs/heads/main)" = "$theirs" ]
  # Fetching is the remedy it names: after it the tip is known and the same
  # push gets the ordinary verdict.
  git -C "$repo" fetch -q origin
  run git -C "$repo" push -q --force origin main
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-fast-forward push of main"* ]]
  [ "$(git -C "$bare" rev-parse refs/heads/main)" = "$theirs" ]
}

@test "pre-push: a plain push onto an unfetched tip gets the same fetch advice" {
  # git runs the hook before it reports its own "fetch first" rejection, and
  # the hook cannot tell this from the forced case — both need the fetch.
  repo=$(push_repo)
  bare="$BATS_TEST_TMPDIR/pushbare.git"
  other="$BATS_TEST_TMPDIR/other"
  git clone -q "$bare" "$other"
  echo o >> "$other/f"; git -C "$other" add f
  git -C "$other" -c user.email=personal@example.org commit -q -m "feat: theirs"
  git -C "$other" push -q origin main
  theirs=$(git -C "$other" rev-parse HEAD)
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "feat: mine"
  run git -C "$repo" push -q origin main
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not in this clone"* ]]
  [ "$(git -C "$bare" rev-parse refs/heads/main)" = "$theirs" ]
}

@test "pre-push: GIT_PUSH_CHECK=0 still forces over an unfetched tip, and still chains" {
  repo=$(push_repo)
  bare="$BATS_TEST_TMPDIR/pushbare.git"
  other="$BATS_TEST_TMPDIR/other"
  git clone -q "$bare" "$other"
  echo o >> "$other/f"; git -C "$other" add f
  git -C "$other" -c user.email=personal@example.org commit -q -m "feat: theirs"
  git -C "$other" push -q origin main
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "feat: mine"
  git -C "$repo" config --add hook.pre-push.run 'echo "GUARD $(wc -l < /dev/stdin | tr -d " ")" >&2'
  run env GIT_PUSH_CHECK=0 git -C "$repo" push -q --force origin main
  [ "$status" -eq 0 ]
  [[ "$output" == *"GUARD 1"* ]]
  [ "$(git -C "$bare" rev-parse refs/heads/main)" = "$(git -C "$repo" rev-parse HEAD)" ]
}

@test "pre-push: force-pushing a topic branch over an unfetched tip is still ordinary work" {
  repo=$(push_repo)
  git -C "$repo" checkout -q -b topic
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "feat: one"
  git -C "$repo" push -q origin topic
  other="$BATS_TEST_TMPDIR/other"
  git clone -q "$BATS_TEST_TMPDIR/pushbare.git" "$other"
  git -C "$other" checkout -q -b topic origin/topic
  echo o >> "$other/f"; git -C "$other" add f
  git -C "$other" -c user.email=personal@example.org commit -q -m "feat: theirs"
  git -C "$other" push -q origin topic
  git -C "$repo" commit -q --amend -m "feat: one, reworded"
  run git -C "$repo" push -q --force origin topic
  [ "$status" -eq 0 ]
}

@test "pre-push: the bypass still chains, so the overlay leak guard is never switched off with it" {
  repo=$(push_repo)
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "WIP: deliberate"
  git -C "$repo" config --add hook.pre-push.run 'echo "GUARD $(wc -l < /dev/stdin | tr -d " ")" >&2'
  run env GIT_PUSH_CHECK=0 git -C "$repo" push -q origin main
  [ "$status" -eq 0 ]
  [[ "$output" == *"GUARD 1"* ]]
}

@test "pre-push: a failing hook.pre-push.run still blocks a bypassed push" {
  repo=$(push_repo)
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "WIP: deliberate"
  git -C "$repo" config --add hook.pre-push.run 'echo LEAK >&2; false'
  run env GIT_PUSH_CHECK=0 git -C "$repo" push -q origin main
  [ "$status" -ne 0 ]
  [[ "$output" == *"LEAK"* ]]
}

@test "pre-push: the ref list is not left behind in TMPDIR" {
  # An EXIT trap does not survive exec, and this hook runs on every push of
  # every repo on the machine, so a leak here is unbounded.
  repo=$(push_repo)
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "feat: fine"
  git -C "$repo" push -q origin main
  run sh -c 'ls "$TMPDIR" | grep -c "^pre-push-refs\." || true'
  [ "$output" = 0 ]
}

@test "pre-push: hook.pre-push.wip=false turns the marker gate off and leaves force protection on" {
  repo=$(push_repo)
  git -C "$repo" config hook.pre-push.wip false
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "WIP: allowed here"
  run git -C "$repo" push -q origin main
  [ "$status" -eq 0 ]
  git -C "$repo" reset -q --hard HEAD~1
  echo z >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "feat: divergent"
  run git -C "$repo" push -q --force origin main
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-fast-forward push of main"* ]]
}

@test "pre-push: hook.pre-push.protect replaces the default branch list" {
  repo=$(push_repo)
  git -C "$repo" config --add hook.pre-push.protect trunk
  # main is no longer protected once the list is stated.
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "feat: one"
  git -C "$repo" push -q origin main
  git -C "$repo" reset -q --hard HEAD~1
  echo z >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "feat: other"
  run git -C "$repo" push -q --force origin main
  [ "$status" -eq 0 ]
  # trunk is.
  git -C "$repo" checkout -q -b trunk
  git -C "$repo" push -q origin trunk
  git -C "$repo" reset -q --hard HEAD~1
  echo w >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "feat: rewritten"
  run git -C "$repo" push -q --force origin trunk
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-fast-forward push of trunk"* ]]
}

@test "pre-push: a tag is named as itself, not as a branch" {
  repo=$(push_repo)
  echo y >> "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "WIP: tagged"
  git -C "$repo" tag v1
  run git -C "$repo" push -q origin v1
  [ "$status" -ne 0 ]
  [[ "$output" == *"push v1"* ]]
}

# The branch gate: a claude-peer slot (a linked worktree, detached, with a
# claude-peer.base record) takes no commit until it has a branch. The helper
# is deployed to $HOME/bin the way chezmoi would, and found first on PATH.
slot_repo() {
  repo=$(make_repo "${1:-}")
  GIT_IDENTITY_CHECK=0 git -C "$repo" commit -q -m init
  SLOT="$BATS_TEST_TMPDIR/slot"
  git -C "$repo" worktree add -q --detach "$SLOT"
  SLOTGIT=$(git -C "$SLOT" rev-parse --absolute-git-dir)
  printf 'main\nrefs/heads/main\n' > "$SLOTGIT/claude-peer.base"
  echo y >> "$SLOT/f"; git -C "$SLOT" add f
  mkdir -p "$HOME/bin"
  cp "$BATS_TEST_DIRNAME/../bin/executable_branchname" "$HOME/bin/branchname"
  chmod +x "$HOME/bin/branchname"
  export PATH="$HOME/bin:$PATH"
}

@test "pre-commit: a slot with no branch is refused, with the fix; a branch lets it through" {
  slot_repo
  before=$(git -C "$SLOT" rev-parse HEAD)
  run git -C "$SLOT" commit -q -m "feat: x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no branch yet"* ]]
  [[ "$output" == *"detached at main"* ]]
  [[ "$output" == *"git switch -c"* ]]
  [ "$(git -C "$SLOT" rev-parse HEAD)" = "$before" ]
  git -C "$SLOT" switch -q -c feat/x
  run git -C "$SLOT" commit -q -m "feat: x"
  [ "$status" -eq 0 ]
}

@test "pre-commit: GIT_BRANCH_CHECK=0 and GIT_IDENTITY_CHECK=0 bypass only their own gate" {
  slot_repo 'git@github-work:octo-work-org/some-repo.git'
  run env GIT_BRANCH_CHECK=0 git -C "$SLOT" commit -q -m "feat: x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to commit as"* ]]
  run env GIT_IDENTITY_CHECK=0 git -C "$SLOT" commit -q -m "feat: x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no branch yet"* ]]
  run env GIT_BRANCH_CHECK=0 GIT_IDENTITY_CHECK=0 git -C "$SLOT" commit -q -m "feat: x"
  [ "$status" -eq 0 ]
}

@test "pre-commit: the branch gate has no opinion when switched off, unrecorded, helperless or mid-rebase" {
  slot_repo
  git -C "$SLOT" config hook.pre-commit.branch false
  run git -C "$SLOT" commit -q -m "feat: off"
  [ "$status" -eq 0 ]
  git -C "$SLOT" config --unset hook.pre-commit.branch

  echo z >> "$SLOT/f"; git -C "$SLOT" add f
  mkdir "$SLOTGIT/rebase-merge"
  run git -C "$SLOT" commit -q -m "feat: mid-rebase"
  [ "$status" -eq 0 ]
  rmdir "$SLOTGIT/rebase-merge"

  echo z >> "$SLOT/f"; git -C "$SLOT" add f
  run env PATH="$(dirname "$(command -v git)"):/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/nohelper" git -C "$SLOT" commit -q -m "feat: helperless"
  [ "$status" -eq 0 ]

  rm "$SLOTGIT/claude-peer.base"
  echo z >> "$SLOT/f"; git -C "$SLOT" add f
  run git -C "$SLOT" commit -q -m "feat: unrecorded"
  [ "$status" -eq 0 ]
}

@test "pre-commit: a custom detached-format does not change what the gate says" {
  slot_repo
  git config --file "$GIT_CONFIG_GLOBAL" branchname.detached-format '{worktree} : {base}'
  run git -C "$SLOT" commit -q -m "feat: x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"detached at main"* ]]
}

@test "git-doctor: branch-gate reads off, on, would-refuse and inert" {
  slot_repo
  doctor() { run zsh -c "source '$BATS_TEST_DIRNAME/../dot_functions'; cd '$1'; git-doctor"; }
  doctor "$SLOT"
  [[ "$output" == *"branch-gate: on — WOULD REFUSE: detached at main with no branch"* ]]
  ! grep -qE '^(name|key|bg[a-z]*)=' <<<"$output"
  doctor "$repo"
  [[ "$output" == *$'\n'"branch-gate: on"$'\n'* ]]
  git -C "$SLOT" config hook.pre-commit.branch off
  doctor "$SLOT"
  [[ "$output" == *"branch-gate: off (hook.pre-commit.branch=off)"* ]]
  git -C "$SLOT" config --unset hook.pre-commit.branch
  rm "$HOME/bin/branchname"
  export PATH="$(dirname "$(command -v git)"):/usr/bin:/bin"
  doctor "$SLOT"
  [[ "$output" == *"branch-gate: inert (no ~/bin/branchname)"* ]]
}

@test "pre-commit: ~/bin/branchname wins over an unrelated branchname earlier on PATH" {
  slot_repo
  mkdir -p "$BATS_TEST_TMPDIR/other"
  printf '#!/bin/sh\necho ran > "%s/other/ran"\nexit 0\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/other/branchname"
  chmod +x "$BATS_TEST_TMPDIR/other/branchname"
  run env PATH="$BATS_TEST_TMPDIR/other:$PATH" git -C "$SLOT" commit -q -m "feat: x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"detached at main"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/other/ran" ]
  run env PATH="$BATS_TEST_TMPDIR/other:$PATH" zsh -c "source '$BATS_TEST_DIRNAME/../dot_functions'; cd '$SLOT'; git-doctor"
  [[ "$output" == *"WOULD REFUSE: detached at main"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/other/ran" ]
}
