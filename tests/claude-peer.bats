#!/usr/bin/env bats

# ~/bin/claude-peer: make or reuse a worktree for a branch under
# <repo>/.claude/worktrees/<slug>, cd into it and start claude through the
# shell. A stub shell stands in for $SHELL so nothing starts a real claude.
# Everything runs in a sandboxed HOME against fixture repos with invented names.

setup() {
  BIN="$BATS_TEST_DIRNAME/../bin/executable_claude-peer"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR"
  git config --global user.name octo
  git config --global user.email octo@example.com
  git config --global init.defaultBranch main
  cat >"$BATS_TEST_TMPDIR/bin/fakeshell" <<'STUB'
#!/bin/sh
echo "pwd=$PWD"
echo "args=$*"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/fakeshell"
  export SHELL="$BATS_TEST_TMPDIR/bin/fakeshell"
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  REPO=$(cd "$BATS_TEST_TMPDIR/proj" && pwd -P)
  git -C "$REPO" init -q
  echo one >"$REPO/tracked.txt"
  git -C "$REPO" add .
  git -C "$REPO" commit -qm 'initial commit'
  cd "$REPO"
}

@test "run: creates the worktree, cd's into it, execs an interactive shell" {
  run sh "$BIN" run feat/x
  [ "$status" -eq 0 ]
  [[ "$output" == *"feat/x"$'\t'"$REPO/.claude/worktrees/feat-x"$'\t'"created"* ]]
  [[ "$output" == *"pwd=$REPO/.claude/worktrees/feat-x"* ]]
  [[ "$output" == *'args=-i -c claude "$@" claude-peer'* ]]
  git worktree list | grep -F "$REPO/.claude/worktrees/feat-x" | grep -F '[feat/x]'
  [ "$(grep -cxF '**/.claude/worktrees/' "$REPO/.git/info/exclude")" -eq 1 ]
}

@test "run: arguments after -- reach claude" {
  run sh "$BIN" run feat/x -- --continue
  [ "$status" -eq 0 ]
  [[ "$output" == *'args=-i -c claude "$@" claude-peer --continue' ]]
}

@test "run: a second run reuses the worktree and still execs in it" {
  sh "$BIN" run feat/x >/dev/null
  run sh "$BIN" run feat/x
  [ "$status" -eq 0 ]
  [[ "$output" == *"feat/x"$'\t'"$REPO/.claude/worktrees/feat-x"$'\t'"reused"* ]]
  [[ "$output" == *"pwd=$REPO/.claude/worktrees/feat-x"* ]]
  [ "$(git worktree list | grep -c 'feat-x')" -eq 1 ]
  [ "$(grep -cxF '**/.claude/worktrees/' "$REPO/.git/info/exclude")" -eq 1 ]
}

@test "run: from a linked worktree, the new worktree lands under the main checkout" {
  git worktree add -q -b side "$BATS_TEST_TMPDIR/linked"
  cd "$BATS_TEST_TMPDIR/linked"
  run sh "$BIN" run fix/y
  [ "$status" -eq 0 ]
  [[ "$output" == *"pwd=$REPO/.claude/worktrees/fix-y"* ]]
  [ -d "$REPO/.claude/worktrees/fix-y" ]
  [ ! -e "$BATS_TEST_TMPDIR/linked/.claude" ]
}

@test "run: a branch checked out in the main checkout is refused, nothing created" {
  run sh "$BIN" run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"already checked out at $REPO"* ]]
  [[ "$output" != *"pwd="* ]]
  [ ! -e "$REPO/.claude/worktrees" ]
}

@test "run: a bad branch name and a non-repo are refused" {
  run sh "$BIN" run 'bad..name'
  [ "$status" -eq 1 ]
  [[ "$output" == *"'bad..name' is not a branch name"* ]]
  [[ "$output" != *"pwd="* ]]
  mkdir "$BATS_TEST_TMPDIR/norepo"
  cd "$BATS_TEST_TMPDIR/norepo"
  run sh "$BIN" run feat/x
  [ "$status" -eq 1 ]
  [[ "$output" == *"not inside a non-bare git repository"* ]]
}

@test "run: no branch and no terminal is refused" {
  if ( : < /dev/tty ) 2>/dev/null; then skip "the bats runner has a controlling terminal"; fi
  run sh "$BIN" run </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"no terminal to ask on"* ]]
  [[ "$output" != *"pwd="* ]]
}

@test "path prints the worktree path; plan flags a conflict and exits 1" {
  run sh "$BIN" path feat/x
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO/.claude/worktrees/feat-x" ]
  [ ! -e "$REPO/.claude" ]
  run sh "$BIN" plan feat/x main
  [ "$status" -eq 1 ]
  [[ "$output" == *"feat/x"$'\t'"$REPO/.claude/worktrees/feat-x"$'\t'"create"* ]]
  [[ "$output" == *"main"$'\t'*$'\t'"conflict:"* ]]
  [ ! -e "$REPO/.claude" ]
}

@test "run: a new branch is cut from origin/HEAD when there is one, else HEAD" {
  sh "$BIN" run feat/a >/dev/null
  [ "$(git rev-parse feat/a)" = "$(git rev-parse HEAD)" ]

  git clone -q --bare "$REPO" "$BATS_TEST_TMPDIR/remote.git"
  git remote add origin "$BATS_TEST_TMPDIR/remote.git"
  git fetch -q origin
  git remote set-head origin -a >/dev/null
  echo two >"$REPO/tracked.txt"
  git commit -qam 'local only'
  sh "$BIN" run feat/b >/dev/null
  [ "$(git rev-parse feat/b)" = "$(git rev-parse origin/HEAD)" ]
  [ "$(git rev-parse feat/b)" != "$(git rev-parse HEAD)" ]
}
