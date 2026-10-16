#!/usr/bin/env bats

# ~/bin/tabname prints the label a tab shows for a directory: the repo's name,
# "<repo>@<worktree>" for a linked worktree, nothing and exit 1 outside a git
# work tree. Everything runs in a sandboxed HOME against fixture repos with
# invented names.

setup() {
  BIN="$BATS_TEST_DIRNAME/../bin/executable_tabname"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  git config --global user.name octo
  git config --global user.email octo@example.com
  REPO="$BATS_TEST_TMPDIR/proj"
  make_repo "$REPO"
}

# A repo at $1 with one commit.
make_repo() {
  mkdir -p "$1"
  git -C "$1" -c init.defaultBranch=trunk init -q
  echo one >"$1/tracked.txt"
  git -C "$1" add .
  git -C "$1" commit -qm 'initial commit'
}

@test "main checkout: the repo's name" {
  cd "$REPO"
  run sh "$BIN"
  [ "$status" -eq 0 ]
  [ "$output" = proj ]
}

@test "a subdirectory of the checkout gives the same name" {
  mkdir "$REPO/sub"
  cd "$REPO/sub"
  run sh "$BIN"
  [ "$status" -eq 0 ]
  [ "$output" = proj ]
}

@test "an explicit directory argument is honoured from an unrelated cwd" {
  cd "$BATS_TEST_TMPDIR"
  run sh "$BIN" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = proj ]
}

@test "a linked worktree is repo@worktree" {
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/feat-x" -b feat-x
  cd "$REPO/.claude/worktrees/feat-x"
  run sh "$BIN"
  [ "$status" -eq 0 ]
  [ "$output" = proj@feat-x ]
}

@test "a worktree outside the repo is still repo@worktree" {
  git -C "$REPO" worktree add -q "$BATS_TEST_TMPDIR/elsewhere" -b other
  cd "$BATS_TEST_TMPDIR/elsewhere"
  run sh "$BIN"
  [ "$status" -eq 0 ]
  [ "$output" = proj@elsewhere ]
}

@test "tabname.worktree-format changes the worktree label, non-ASCII included" {
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/feat-x" -b feat-x
  git config --global tabname.worktree-format '{repo} ⎇ {worktree}'
  run sh "$BIN" "$REPO/.claude/worktrees/feat-x"
  [ "$status" -eq 0 ]
  [ "$output" = 'proj ⎇ feat-x' ]
}

@test "an empty tabname.worktree-format falls back to the default" {
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/feat-x" -b feat-x
  git config --global tabname.worktree-format ''
  run sh "$BIN" "$REPO/.claude/worktrees/feat-x"
  [ "$status" -eq 0 ]
  [ "$output" = proj@feat-x ]
}

@test "outside any repo: nothing, exit 1" {
  mkdir "$BATS_TEST_TMPDIR/plain"
  cd "$BATS_TEST_TMPDIR/plain"
  run sh "$BIN"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "inside the .git directory: nothing, exit 1" {
  cd "$REPO/.git"
  run sh "$BIN"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "no git on PATH: nothing, exit 1" {
  mkdir "$BATS_TEST_TMPDIR/empty"
  cd "$REPO"
  PATH="$BATS_TEST_TMPDIR/empty" run /bin/sh "$BIN"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "a control character in a directory name is stripped" {
  make_repo "$BATS_TEST_TMPDIR/we"$'\t'"ird"
  run sh "$BIN" "$BATS_TEST_TMPDIR/we"$'\t'"ird"
  [ "$status" -eq 0 ]
  [ "$output" = weird ]
}
