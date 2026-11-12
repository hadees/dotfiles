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
  unset WORKTABS_GROUP
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

# precmd sets the terminal title to the working directory. `worktabs` opens its
# tabs with WORKTABS_GROUP exported, and the group is prefixed here rather than
# by the launcher: precmd runs on every prompt and would overwrite anything the
# launcher wrote, and iTerm2's own Custom Tab Title renders once at session
# creation, before the session carries the group at all.
# Calls the real precmd out of the prompt file — not a copy of its escape —
# so a change to the title logic cannot pass here by being reimplemented.
title_of() { # cwd [group]
  zsh -fc "
    source ${PROMPT_FILE@Q} >/dev/null 2>&1 || true
    cd ${1@Q}
    ${2+export WORKTABS_GROUP=${2@Q}}
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

# --- detached slots: bin/branchname and the commit glyph ---------------------

# A claude-peer slot is a worktree made with --detach. With a claude-peer.base
# record and ~/bin/branchname the prompt shows the base marked: "(trunk)",
# behind U+F417 where glyphs are on. Glyph bytes are written as octal
# escapes, never \u (locale-dependent) or a pasted literal (invisible).
F417=$'\357\220\227'
E0A0=$'\356\202\240'

run_prompt_git_in() { # dir [VAR=value…]
  local dir=$1; shift
  run env "$@" zsh -c "unset SSH_TTY LC_TERMINAL; source '$PROMPT_FILE' >/dev/null 2>&1; cd '$dir' && prompt_git"
}

# A has-glyphs stub that logs each call and fails for any code point listed
# in $HAS_GLYPHS_MISSING.
glyph_stub() {
  mkdir -p "$HOME/bin"
  cat >"$HOME/bin/has-glyphs" <<'STUB'
#!/bin/sh
echo "$*" >>"$HOME/has-glyphs.log"
for a; do case " ${HAS_GLYPHS_MISSING:-} " in *" $a "*) exit 1 ;; esac; done
STUB
  chmod +x "$HOME/bin/has-glyphs"
}

# zsh stops at a \U escape under the C locale, so glyph tests need UTF-8.
utf8_locale() {
  local l
  for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    locale -a 2>/dev/null | grep -qx "$l" && { echo "$l"; return; }
  done
}
need_utf8() {
  LOC=$(utf8_locale)
  [ -n "$LOC" ] || skip 'no UTF-8 locale on this box'
}

# The fixture repo with a bare remote, plus a --detach worktree at $SLOT.
detached_slot() {
  make_repo
  git -c init.defaultBranch=trunk init -q --bare "$BATS_TEST_TMPDIR/remote.git"
  git -C "$REPO" remote add origin "$BATS_TEST_TMPDIR/remote.git"
  git -C "$REPO" push -q origin trunk
  git -C "$REPO" remote set-head origin -a >/dev/null
  SLOT="$BATS_TEST_TMPDIR/slot"
  git -C "$REPO" worktree add -q --detach "$SLOT" origin/trunk
  SHA=$(git -C "$SLOT" rev-parse --short HEAD)
}
record() { printf 'trunk\nrefs/remotes/origin/trunk\n' >"$(git -C "$SLOT" rev-parse --absolute-git-dir)/claude-peer.base"; }
helper() { mkdir -p "$HOME/bin"; cp "$BATS_TEST_DIRNAME/../bin/executable_branchname" "$HOME/bin/branchname"; }

# Without glyphs: no has-glyphs in the sandbox HOME.

@test "detached slot: the recorded base shows as (trunk), no sha, no glyph" {
  detached_slot; record; helper
  run_prompt_git_in "$SLOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'(trunk)'* ]]
  [[ "$output" != *"$SHA"* ]]
  [[ "$output" != *"$F417"* && "$output" != *"$E0A0"* ]]
}

@test "detached slot: arrows count against the recorded ref" {
  detached_slot; record; helper
  echo more >"$SLOT/tracked.txt"
  git -C "$SLOT" commit -qam ahead
  run_prompt_git_in "$SLOT"
  [[ "$output" == *'(trunk)'* && "$output" == *'↑1'* ]]
  git -C "$REPO" switch -q -c moved trunk
  echo remote >"$REPO/other.txt"
  git -C "$REPO" commit -qam behind
  git -C "$REPO" push -q origin moved:trunk
  git -C "$SLOT" fetch -q origin
  run_prompt_git_in "$SLOT"
  [[ "$output" == *'↓1'* ]]
}

@test "detached slot: a branch switched to shows plain, no parentheses" {
  detached_slot; record; helper
  git -C "$SLOT" switch -q -c feat/x
  run_prompt_git_in "$SLOT"
  [[ "$output" == *feat/x* ]]
  [[ "$output" != *'('* ]]
}

@test "detached: no record, or no helper, shows the sha as before" {
  detached_slot; helper
  run_prompt_git_in "$SLOT"
  [[ "$output" == *"$SHA"* && "$output" != *'(trunk)'* ]]
  rm "$HOME/bin/branchname"; record
  run_prompt_git_in "$SLOT"
  [[ "$output" == *"$SHA"* && "$output" != *'(trunk)'* ]]
}

@test "detached slot: a % in the format is printed literally" {
  detached_slot; record; helper
  git -C "$SLOT" config branchname.detached-format '{base} 50%'
  run_prompt_git_in "$SLOT"
  [[ "$output" == *'(trunk 50%%)'* ]]
}

@test "nf_detached is empty without glyphs" {
  run zsh -c "unset SSH_TTY LC_TERMINAL; source '$PROMPT_FILE' >/dev/null 2>&1; print -r -- \"detached=[\$nf_detached]\""
  [[ "$output" == *'detached=[]'* ]]
}

# With glyphs: the stub, a UTF-8 locale.

@test "glyphs: detached slot shows the commit glyph and (trunk), no branch glyph" {
  need_utf8; glyph_stub; detached_slot; record; helper
  run_prompt_git_in "$SLOT" LC_ALL="$LOC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$F417 (trunk)"* ]]
  [[ "$output" != *"$E0A0"* ]]
  grep -qx f417 "$HOME/has-glyphs.log"
  grep -qx 'e0a0 f09b f08c0' "$HOME/has-glyphs.log"
}

@test "glyphs: a commit in the slot shows the glyph form and ↑1" {
  need_utf8; glyph_stub; detached_slot; record; helper
  echo more >"$SLOT/tracked.txt"
  git -C "$SLOT" commit -qam ahead
  run_prompt_git_in "$SLOT" LC_ALL="$LOC"
  [[ "$output" == *"$F417 (trunk)"* && "$output" == *'↑1'* ]]
}

@test "glyphs: on a branch, the branch glyph and no commit glyph" {
  need_utf8; glyph_stub; make_repo
  run_prompt_git_in "$REPO" LC_ALL="$LOC"
  [[ "$output" == *"$E0A0 trunk"* ]]
  [[ "$output" != *"$F417"* ]]
}

@test "glyphs: detached with no record keeps the branch glyph and the sha" {
  need_utf8; glyph_stub; detached_slot; helper
  run_prompt_git_in "$SLOT" LC_ALL="$LOC"
  [[ "$output" == *"$E0A0 $SHA"* ]]
  [[ "$output" != *"$F417"* ]]
}

@test "glyphs: a font without U+F417 falls back to (trunk), branch glyph kept elsewhere" {
  need_utf8; glyph_stub; detached_slot; record; helper
  run_prompt_git_in "$SLOT" LC_ALL="$LOC" HAS_GLYPHS_MISSING=f417
  [[ "$output" == *'(trunk)'* ]]
  [[ "$output" != *"$F417"* && "$output" != *"$E0A0"* ]]
  run_prompt_git_in "$REPO" LC_ALL="$LOC" HAS_GLYPHS_MISSING=f417
  [[ "$output" == *"$E0A0 trunk"* ]]
}

@test "glyphs: the format shapes the name inside the mark" {
  need_utf8; glyph_stub; detached_slot; record; helper
  git -C "$SLOT" config branchname.detached-format '{worktree} : {base}'
  run_prompt_git_in "$SLOT" LC_ALL="$LOC"
  [[ "$output" == *"$F417 (slot : trunk)"* ]]
}

@test "glyphs: over ssh from iTerm2 nf_detached is set without has-glyphs" {
  need_utf8
  run env LC_ALL="$LOC" SSH_TTY=/dev/ttys000 LC_TERMINAL=iTerm2 zsh -c "source '$PROMPT_FILE' >/dev/null 2>&1; print -r -- \"detached=[\$nf_detached]\""
  [[ "$output" == *"detached=[$F417 ]"* ]]
}

@test "dot_gitconfig names the status line's detached command" {
  run git config --file "$BATS_TEST_DIRNAME/../dot_gitconfig" --get statusline.detached-command
  [ "$output" = '~/bin/branchname' ]
}

@test "a UTF-8 locale exists on Darwin, so the glyph tests cannot all skip" {
  [ "$(uname)" = Darwin ] || skip 'not Darwin'
  [ -n "$(utf8_locale)" ]
}
