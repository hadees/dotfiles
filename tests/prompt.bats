#!/usr/bin/env bats

# The git-status segment of the zsh prompt (prompt_git in dot_zsh_prompt)
# renders the branch name plus per-state indicators: + staged (green),
# ! unstaged (yellow), ? untracked (blue), $ stashed (magenta). These tests
# source the real prompt file under zsh in a sandboxed HOME — no
# ~/bin/has-glyphs helper there, so glyph detection deterministically falls
# back to the plain-text path — and call prompt_git directly against fixture
# repos (PROMPT itself needs prompt_subst and an interactive shell; the
# underlying function does not). The fixture repo has no origin remote, so
# the gh-backed open-PR segment never fires.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  # A test run from inside a workspace tab inherits its group, which would
  # prefix every "ordinary shell" title under test.
  unset WORKSPACE_GROUP
  export XDG_CONFIG_HOME="$HOME/.config"
  export XDG_DATA_HOME="$HOME/.local/share"
  git config --global user.name octo
  git config --global user.email octo@example.com
  PROMPT_FILE="$BATS_TEST_DIRNAME/../dot_zsh_prompt"
  REPO="$BATS_TEST_TMPDIR/repo"
}

# A repo on branch "trunk" with one clean commit of two files.
make_repo() {
  mkdir -p "$REPO"
  git -C "$REPO" -c init.defaultBranch=trunk init -q
  echo one >"$REPO/tracked.txt"
  echo two >"$REPO/other.txt"
  git -C "$REPO" add .
  git -C "$REPO" commit -qm 'initial commit'
}

# Source the prompt file (SSH_TTY/LC_TERMINAL cleared so glyph detection
# takes the local has-glyphs path, absent in the sandbox HOME), cd into the
# fixture repo, and run the git segment function alone.
run_prompt_git() {
  run zsh -c "unset SSH_TTY LC_TERMINAL; source '$PROMPT_FILE' >/dev/null 2>&1; cd '$REPO' && prompt_git"
}

@test "dirty repo: branch plus +, !, ? and stash indicators" {
  make_repo
  # Stash first so the stashed change doesn't take the other states with it.
  echo change >"$REPO/other.txt"
  git -C "$REPO" stash -q
  echo new >"$REPO/staged.txt"
  git -C "$REPO" add staged.txt              # staged  -> +
  echo change >"$REPO/tracked.txt"           # unstaged -> !
  echo stray >"$REPO/untracked.txt"          # untracked -> ?

  run_prompt_git
  [ "$status" -eq 0 ]
  [[ "$output" == *trunk* ]]
  [[ "$output" == *'+%f'* ]]
  [[ "$output" == *'!%f'* ]]
  [[ "$output" == *'?%f'* ]]
  [[ "$output" == *'$%f'* ]]
}

@test "clean repo: branch shown, no status indicators" {
  make_repo

  run_prompt_git
  [ "$status" -eq 0 ]
  [[ "$output" == *trunk* ]]
  # git_status stays empty, so the bracketed indicator block never renders.
  [[ "$output" != *'['* ]]
  [[ "$output" != *'+%f'* ]]
  [[ "$output" != *'!%f'* ]]
  [[ "$output" != *'?%f'* ]]
  [[ "$output" != *'$%f'* ]]
}

@test "glyphs degrade to plain text when the has-glyphs helper is absent" {
  [ ! -e "$HOME/bin/has-glyphs" ]
  run zsh -c "unset SSH_TTY LC_TERMINAL; source '$PROMPT_FILE' >/dev/null 2>&1; print -r -- \"on=[\$nf_on] branch=[\$nf_branch] github=[\$nf_github] pr=[\$nf_pr]\""
  [ "$status" -eq 0 ]
  [[ "$output" == *'on=[] branch=[] github=[@] pr=[pr ]'* ]]
}

# --- terminal title -----------------------------------------------------------

# precmd sets the terminal title to the working directory. `workspace` opens its
# tabs with WORKSPACE_GROUP exported, and the group is prefixed here rather than
# by the launcher: precmd runs on every prompt and would overwrite anything the
# launcher wrote, and iTerm2's own Custom Tab Title renders once at session
# creation, before the session carries the group at all.
# Calls the real precmd out of the prompt file — not a copy of its escape —
# so a change to the title logic cannot pass here by being reimplemented.
title_of() { # cwd [group]
  zsh -fc "
    source ${PROMPT_FILE@Q} >/dev/null 2>&1 || true
    cd ${1@Q}
    ${2+export WORKSPACE_GROUP=${2@Q}}
    precmd
  " | tr -d '\001-\010\013\014\016-\037'
}

@test "title: an ordinary shell titles the tab with the directory alone" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run title_of "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0;"*"/plain"* ]]
  [[ "$output" != *"["*"]"* ]]
}

@test "title: a workspace tab is prefixed with its group" {
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  run title_of "$BATS_TEST_TMPDIR/proj" personal
  [ "$status" -eq 0 ]
  [[ "$output" == *"[personal] "*"/proj"* ]]
}

@test "title: an empty group adds no empty brackets" {
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  run title_of "$BATS_TEST_TMPDIR/proj" ""
  [ "$status" -eq 0 ]
  [[ "$output" != *"[]"* ]]
}
