#!/usr/bin/env bats

# ~/bin/branchname prints what a prompt or status line shows where a branch
# name goes: the branch; for a detached slot with a claude-peer.base record,
# the base it was cut from, marked; otherwise the short sha. Everything runs in
# a sandboxed HOME against fixture repos with invented names.

setup() {
  BIN="$BATS_TEST_DIRNAME/../bin/executable_branchname"
  ROOT="$BATS_TEST_DIRNAME/.."
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  git config --global user.name octo
  git config --global user.email octo@example.com
  T=$'\t'
  REPO="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$REPO"
  git -C "$REPO" -c init.defaultBranch=trunk init -q
  echo one >"$REPO/tracked.txt"
  git -C "$REPO" add .
  git -C "$REPO" commit -qm 'initial commit'
  git -c init.defaultBranch=trunk init -q --bare "$BATS_TEST_TMPDIR/remote.git"
  git -C "$REPO" remote add origin "$BATS_TEST_TMPDIR/remote.git"
  git -C "$REPO" push -q origin trunk
  git -C "$REPO" remote set-head origin -a >/dev/null
  SLOT="$BATS_TEST_TMPDIR/slot"
}

# A detached linked worktree at $SLOT, cut from origin/trunk.
make_slot() {
  git -C "$REPO" worktree add -q --detach "$SLOT" origin/trunk
  SHA=$(git -C "$SLOT" rev-parse --short HEAD)
  SLOTGIT=$(git -C "$SLOT" rev-parse --absolute-git-dir)
}

# record <gitdir> <content>: write a claude-peer.base record.
record() { printf '%s' "$2" >"$1/claude-peer.base"; }

@test "on a branch: the branch, one shape for --state (unborn too)" {
  run sh "$BIN" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = trunk ]
  run sh "$BIN" --state "$REPO"
  [ "$output" = "branch${T}trunk${T}refs/heads/trunk${T}trunk" ]
  git -C "$REPO" switch -q --orphan fresh
  run sh "$BIN" --state "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "branch${T}fresh${T}refs/heads/fresh${T}fresh" ]
}

@test "a detached worktree with no record: the short sha" {
  make_slot
  run sh "$BIN" "$SLOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$SHA" ]
  run sh "$BIN" --state "$SLOT"
  [ "$output" = "detached${T}${SHA}${T}-${T}${SHA}" ]
}

@test "a detached worktree with a record: the base, marked" {
  make_slot
  record "$SLOTGIT" $'trunk\nrefs/remotes/origin/trunk\n'
  run sh "$BIN" "$SLOT"
  [ "$status" -eq 0 ]
  [ "$output" = "(trunk)" ]
  run sh "$BIN" --state "$SLOT"
  [ "$output" = "base${T}(trunk)${T}refs/remotes/origin/trunk${T}trunk" ]
}

@test "a commit keeps the base; a branch replaces it; detaching brings it back" {
  make_slot
  record "$SLOTGIT" $'trunk\nrefs/remotes/origin/trunk\n'
  echo two >"$SLOT/tracked.txt"
  git -C "$SLOT" commit -qam second
  run sh "$BIN" --state "$SLOT"
  [ "$output" = "base${T}(trunk)${T}refs/remotes/origin/trunk${T}trunk" ]
  git -C "$SLOT" switch -q -c feat/x
  run sh "$BIN" --state "$SLOT"
  [ "$output" = "branch${T}feat/x${T}refs/heads/feat/x${T}feat/x" ]
  git -C "$SLOT" switch -q --detach
  run sh "$BIN" --state "$SLOT"
  [ "$output" = "base${T}(trunk)${T}refs/remotes/origin/trunk${T}trunk" ]
}

@test "branchname.detached-format shapes the name, never the mark" {
  make_slot
  record "$SLOTGIT" $'trunk\nrefs/remotes/origin/trunk\n'
  git config --global branchname.detached-format '{worktree} : {base}'
  run sh "$BIN" --state "$SLOT"
  [ "$output" = "base${T}(slot : trunk)${T}refs/remotes/origin/trunk${T}slot : trunk" ]
  git config --global branchname.detached-format '{base}'
  run sh "$BIN" "$SLOT"
  [ "$output" = "(trunk)" ]
  git config --global branchname.detached-format ''
  run sh "$BIN" "$SLOT"
  [ "$output" = "(trunk)" ]
}

@test "an unusable record falls back to the sha" {
  make_slot
  for content in $'trunk\nrefs/remotes/origin/gone\n' $'trunk\n' $'trunk\nHEAD\n'; do
    record "$SLOTGIT" "$content"
    run sh "$BIN" --state "$SLOT"
    [ "$output" = "detached${T}${SHA}${T}-${T}${SHA}" ]
  done
}

@test "a rebase or bisect in progress falls back to the sha" {
  make_slot
  record "$SLOTGIT" $'trunk\nrefs/remotes/origin/trunk\n'
  mkdir "$SLOTGIT/rebase-merge"
  run sh "$BIN" "$SLOT"
  [ "$output" = "$SHA" ]
  rmdir "$SLOTGIT/rebase-merge"
  mkdir "$SLOTGIT/rebase-apply"
  run sh "$BIN" "$SLOT"
  [ "$output" = "$SHA" ]
  rmdir "$SLOTGIT/rebase-apply"
  : >"$SLOTGIT/BISECT_LOG"
  run sh "$BIN" "$SLOT"
  [ "$output" = "$SHA" ]
}

@test "the main checkout detached with a record: base" {
  git -C "$REPO" switch -q --detach
  record "$REPO/.git" $'trunk\nrefs/remotes/origin/trunk\n'
  run sh "$BIN" --state "$REPO"
  [ "$output" = "base${T}(trunk)${T}refs/remotes/origin/trunk${T}trunk" ]
}

@test "outside a repository or with no git: nothing, exit 1; an explicit dir works from anywhere" {
  mkdir "$BATS_TEST_TMPDIR/plain"
  cd "$BATS_TEST_TMPDIR/plain"
  run sh "$BIN"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run env PATH=/nonexistent /bin/sh "$BIN" "$REPO"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run sh "$BIN" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = trunk ]
}

@test "control characters are stripped; a format that expands to nothing gives the base" {
  make_slot
  record "$SLOTGIT" $'tr\tun\001k\nrefs/remotes/origin/trunk\n'
  run sh "$BIN" --state "$SLOT"
  [ "$output" = "base${T}(trunk)${T}refs/remotes/origin/trunk${T}trunk" ]
  git config --global branchname.detached-format $'\001'
  run sh "$BIN" --state "$SLOT"
  [ "$output" = "base${T}(trunk)${T}refs/remotes/origin/trunk${T}trunk" ]
}

@test "only the renderers and the gate mention branchname" {
  allowed=" bin/executable_branchname bin/executable_claude-peer dot_zsh_prompt dot_git-hooks/executable_pre-commit dot_functions "
  # A container checkout is owned by another uid ("dubious ownership"); a
  # git error must fail here, not pass as a list of "files".
  git config --global safe.directory '*'
  run git -C "$ROOT" grep -lw branchname -- bin dot_git-hooks dot_local dot_functions dot_zsh_prompt
  [ "$status" -eq 0 ]
  for f in $output; do
    [[ "$allowed" == *" $f "* ]] || { echo "unexpected: $f"; return 1; }
  done
}

@test "--state is four non-empty fields of ASCII in every state" {
  make_slot
  check() {
    run sh "$BIN" --state "$1"
    [ "$status" -eq 0 ]
    IFS=$'\t' read -r -a fields <<<"$output"
    [ "${#fields[@]}" -eq 4 ]
    for x in "${fields[@]}"; do [ -n "$x" ]; done
    [[ "$output" != *"$T$T"* && "$output" != "$T"* && "$output" != *"$T" ]]
    [ -z "$(printf '%s' "${output//$T/ }" | LC_ALL=C grep '[^ -~]')" ]
  }
  check "$REPO"
  check "$SLOT"
  record "$SLOTGIT" $'trunk\nrefs/remotes/origin/trunk\n'
  check "$SLOT"
  run sh "$BIN" --state "$SLOT"
  [[ "$output" == base* ]]
}
