#!/usr/bin/env bats

# ~/bin/claude-peer: make or reuse a worktree for a slot or a branch under
# <repo>/.claude/worktrees/<name>, cd into it and run claude through the shell as
# a child, with a claim that lasts as long as the session. A stub shell stands in
# for $SHELL so nothing starts a real claude.
# Everything runs in a sandboxed HOME against fixture repos with invented names.

bats_require_minimum_version 1.5.0

setup() {
  BIN="$BATS_TEST_DIRNAME/../bin/executable_claude-peer"
  # Pin python3 while HOME is still real: an asdf shim first on PATH finds no
  # version under the fake HOME and exits 126 instead of running.
  if py="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)"; then
    mkdir -p "$BATS_TEST_TMPDIR/pybin" && ln -s "$py" "$BATS_TEST_TMPDIR/pybin/python3"
    export PATH="$BATS_TEST_TMPDIR/pybin:$PATH"
  fi
  # Run inside a peer slot or a Claude session, the suite must not inherit either.
  unset CLAUDE_PEER_WORKTREE CLAUDE_PEER_SELF CLAUDE_PID CLAUDE_CODE_SESSION_ID
  export HOME="$BATS_TEST_TMPDIR/home"
  # a runner or a shell that exports XDG_CONFIG_HOME would put the script's
  # config root outside the sandbox
  unset XDG_CONFIG_HOME
  export XDG_STATE_HOME="$HOME/.local/state"
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR"
  export CLAUDE_PEER_SETTLE=0
  git config --global user.name octo
  git config --global user.email octo@example.com
  git config --global init.defaultBranch main
  git config --global claude-peer.picker off
  # the restored-pane tests turn it on; the rest open panes no workgroup entry made
  git config --global claude-peer.restore-check false
  cat >"$BATS_TEST_TMPDIR/bin/fakeshell" <<'STUB'
#!/bin/sh
echo "pwd=$PWD"
echo "peer=${CLAUDE_PEER_WORKTREE-unset}"
echo "hermeswait=${CLAUDE_PEER_HERMES_WAIT-unset}"
echo "args=$*"
[ -z "${FAKE_SHELL_LOG-}" ] || echo "pwd=$PWD args=$*" >>"$FAKE_SHELL_LOG"
[ -z "${FAKE_SHELL_PID-}" ] || echo $$ >"$FAKE_SHELL_PID"
[ -z "${FAKE_SHELL_LAST-}" ] || { for last; do :; done; printf '%s' "$last" >"$FAKE_SHELL_LAST"; echo $# >"$FAKE_SHELL_LAST.n"; }
[ -z "${FAKE_SHELL_NOTERM-}" ] || trap '' TERM
[ -z "${FAKE_SHELL_SLEEP-}" ] || sleep "$FAKE_SHELL_SLEEP"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/fakeshell"
  export SHELL="$BATS_TEST_TMPDIR/bin/fakeshell"
  export FAKE_SHELL_LOG="$BATS_TEST_TMPDIR/shell.log"
  PANES=
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  REPO=$(cd "$BATS_TEST_TMPDIR/proj" && pwd -P)
  git -C "$REPO" init -q
  echo one >"$REPO/tracked.txt"
  git -C "$REPO" add .
  git -C "$REPO" commit -qm 'initial commit'
  cd "$REPO"
}

teardown() {
  local p
  for p in $PANES; do kill "$p" 2>/dev/null || true; done
}

@test "run: creates the worktree, cd's into it, execs an interactive shell" {
  run sh "$BIN" run feat/x
  [ "$status" -eq 0 ]
  [[ "$output" == *"feat/x"$'\t'"$REPO/.claude/worktrees/feat-x"$'\t'"created"* ]]
  [[ "$output" == *"pwd=$REPO/.claude/worktrees/feat-x"* ]]
  [[ "$output" == *'args=-i -c n=$1; shift; claude -n "$n" "$@" claude-peer proj-feat-x'* ]]
  git worktree list | grep -F "$REPO/.claude/worktrees/feat-x" | grep -F '[feat/x]'
  [ "$(grep -cxF '**/.claude/worktrees/' "$REPO/.git/info/exclude")" -eq 1 ]
}

@test "run: arguments after -- reach claude" {
  run sh "$BIN" run feat/x -- --continue
  [ "$status" -eq 0 ]
  [[ "$output" == *'claude -n "$n" "$@" claude-peer proj-feat-x --continue' ]]
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

# --- slots: claim, lock, soft landing, peers ----------------------------------------

# claim_of <worktree>: the claim file inside the worktree's git directory
claim_of() { echo "$(git -C "$1" rev-parse --absolute-git-dir)/claude-peer.claim"; }

# wait_claim <worktree>: until a backgrounded run has written its claim
wait_claim() {
  local i
  for i in $(seq 1 $((100 * ${TESTS_WAIT_SCALE:-1}))); do
    [ -f "$(claim_of "$1" 2>/dev/null)" ] && return 0
    sleep 0.1
  done
  return 1
}

# remote_head: an origin whose HEAD differs from the local one
remote_head() {
  git clone -q --bare "$REPO" "$BATS_TEST_TMPDIR/remote.git"
  git remote add origin "$BATS_TEST_TMPDIR/remote.git"
  git fetch -q origin
  git remote set-head origin -a >/dev/null
  echo two >"$REPO/tracked.txt"
  git commit -qam 'local only'
}

@test "run --as: a new slot is a detached worktree at origin/HEAD, the session is named for it" {
  remote_head
  run sh "$BIN" run --as alpha </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"$'\t'"$REPO/.claude/worktrees/alpha"$'\t'"created"* ]]
  [[ "$output" == *"pwd=$REPO/.claude/worktrees/alpha"* ]]
  [[ "$output" == *"peer=$REPO/.claude/worktrees/alpha"* ]]
  [[ "$output" == *'claude -n "$n" "$@" claude-peer proj-alpha' ]]
  ! git -C "$REPO/.claude/worktrees/alpha" symbolic-ref -q HEAD
  [ "$(git -C "$REPO/.claude/worktrees/alpha" rev-parse HEAD)" = "$(git rev-parse origin/HEAD)" ]
  [ "$(git branch --list | wc -l)" -eq 1 ]
  [ "$(grep -cxF '**/.claude/worktrees/' "$REPO/.git/info/exclude")" -eq 1 ]
}

@test "run --as: a new slot records its base beside the claim, outside the tree" {
  remote_head
  run --separate-stderr sh "$BIN" run --as alpha </dev/null
  [ "$status" -eq 0 ]
  wt=$REPO/.claude/worktrees/alpha
  [ "$(cat "$REPO/.git/worktrees/alpha/claude-peer.base")" = $'main\nrefs/remotes/origin/main' ]
  [ -z "$(git -C "$wt" status --porcelain)" ]
  [[ "$stderr" != *base* ]]
  run sh "$BATS_TEST_DIRNAME/../bin/executable_branchname" --state "$wt"
  [ "$output" = "base"$'\t'"(main)"$'\t'"refs/remotes/origin/main"$'\t'"main" ]
}

@test "run --as: with no remote the base is the main checkout's branch; detached, no record" {
  git switch -qc trunk
  sh "$BIN" run --as alpha >/dev/null
  [ "$(cat "$REPO/.git/worktrees/alpha/claude-peer.base")" = $'trunk\nrefs/heads/trunk' ]
  git switch -q --detach
  run sh "$BIN" run --as beta
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.git/worktrees/beta/claude-peer.base" ]
}

@test "run --as: a reused slot records from origin/HEAD only, and never rewrites a record" {
  sh "$BIN" run --as alpha >/dev/null
  rec=$REPO/.git/worktrees/alpha/claude-peer.base
  rm "$rec"
  sh "$BIN" run --as alpha >/dev/null
  [ ! -e "$rec" ]
  remote_head
  sh "$BIN" run --as alpha >/dev/null
  [ "$(cat "$rec")" = $'main\nrefs/remotes/origin/main' ]
  printf 'sentinel\nkept' >"$rec"
  sh "$BIN" run --as alpha >/dev/null
  [ "$(cat "$rec")" = $'sentinel\nkept' ]
}

@test "run <branch>: a branch peer gets no base record" {
  remote_head
  sh "$BIN" run feat/x >/dev/null
  [ ! -e "$REPO/.git/worktrees/feat-x/claude-peer.base" ]
}

@test "run --as: a record that cannot be written is one line on stderr, and the slot still starts" {
  remote_head
  sh "$BIN" run --as alpha >/dev/null
  rec=$REPO/.git/worktrees/alpha/claude-peer.base
  rm "$rec"; mkdir "$rec"
  run --separate-stderr sh "$BIN" run --as alpha
  [ "$status" -eq 0 ]
  [[ "$output" == *"pwd=$REPO/.claude/worktrees/alpha"* ]]
  [ "$stderr" = "claude-peer: alpha: could not record the base; the status line will show the commit" ]
}

@test "run --as: arguments after -- reach claude, after the session name" {
  run sh "$BIN" run --as alpha -- --continue
  [ "$status" -eq 0 ]
  [[ "$output" == *'claude-peer proj-alpha --continue' ]]
}

@test "run --as: a slot is reused in whatever state it was left" {
  sh "$BIN" run --as alpha >/dev/null
  wt=$REPO/.claude/worktrees/alpha
  echo dirty >"$wt/tracked.txt"
  run sh "$BIN" run --as alpha
  [[ "$output" == *"alpha"$'\t'"$wt"$'\t'"reused"* ]]
  [[ "$output" == *"pwd=$wt"* ]]
  [ "$(cat "$wt/tracked.txt")" = dirty ]
  git -C "$wt" stash -q
  git -C "$wt" checkout -q -b feat/mine
  echo more >"$wt/untracked.txt"
  run sh "$BIN" run --as alpha
  [[ "$output" == *"reused"* ]]
  [ "$(git -C "$wt" symbolic-ref --short HEAD)" = feat/mine ]
  [ -f "$wt/untracked.txt" ]
}

@test "run --as: the claim has three lines while the session runs and is gone after" {
  FAKE_SHELL_SLEEP=2 sh "$BIN" run --as alpha >/dev/null &
  rpid=$!
  wt=$REPO/.claude/worktrees/alpha
  wait_claim "$wt"
  c=$(claim_of "$wt")
  [ "$(sed -n 1p "$c")" = "$rpid" ]
  [ "$(sed -n 2p "$c")" = "$REPO" ]
  [ "$(sed -n 3p "$c")" = Alpha ]
  [ "$(wc -l <"$c" | tr -d ' ')" -eq 3 ]
  run sh "$BIN" peers
  [ "$output" = "$wt"$'\t'"$rpid"$'\t'"$REPO"$'\t'"Alpha" ]
  wait "$rpid"
  [ ! -e "$c" ]
  run sh "$BIN" peers
  [ -z "$output" ]
}

@test "run <branch>: the claim carries the slug and the directory it was started from" {
  mkdir "$REPO/sub"
  cd "$REPO/sub"
  FAKE_SHELL_SLEEP=2 sh "$BIN" run feat/x >/dev/null &
  rpid=$!
  wt=$REPO/.claude/worktrees/feat-x
  wait_claim "$wt"
  c=$(claim_of "$wt")
  [ "$(sed -n 1p "$c")" = "$rpid" ]
  [ "$(sed -n 2p "$c")" = "$(pwd -P)" ]
  [ "$(sed -n 3p "$c")" = feat-x ]
  wait "$rpid"
  [ ! -e "$c" ]
}

@test "run: exports CLAUDE_PEER_WORKTREE, on the slot path and on the branch path" {
  run sh "$BIN" run --as alpha
  [[ "$output" == *"peer=$REPO/.claude/worktrees/alpha"* ]]
  run sh "$BIN" run feat/x
  [[ "$output" == *"peer=$REPO/.claude/worktrees/feat-x"* ]]
}

@test "run --as: a slot with a live claim exits 3 and starts nothing" {
  FAKE_SHELL_SLEEP=2 sh "$BIN" run --as alpha >/dev/null &
  rpid=$!
  wait_claim "$REPO/.claude/worktrees/alpha"
  run sh "$BIN" run --as alpha
  [ "$status" -eq 3 ]
  [[ "$output" == *"in use by the peers of $REPO (pid $rpid)"* ]]
  [[ "$output" != *"pwd="* ]]
  [ "$(git worktree list | grep -c alpha)" -eq 1 ]
  wait "$rpid"
}

@test "run --as: two different slots started together get one worktree each" {
  FAKE_SHELL_SLEEP=1 sh "$BIN" run --as alpha >"$BATS_TEST_TMPDIR/out1" 2>&1 &
  p1=$!
  FAKE_SHELL_SLEEP=1 sh "$BIN" run --as beta >"$BATS_TEST_TMPDIR/out2" 2>&1 &
  p2=$!
  wait "$p1"; wait "$p2"
  grep -q "alpha"$'\t'"$REPO/.claude/worktrees/alpha"$'\t'"created" "$BATS_TEST_TMPDIR/out1"
  grep -q "beta"$'\t'"$REPO/.claude/worktrees/beta"$'\t'"created" "$BATS_TEST_TMPDIR/out2"
  [ "$(git worktree list | grep -c -e '/alpha ' -e '/beta ')" -eq 2 ]
  [ ! -e "$REPO/.git/claude-peer.lock" ]
}

@test "run --as: a registered worktree whose directory is gone, and a plain directory, are refused" {
  sh "$BIN" run --as alpha >/dev/null
  rm -rf "$REPO/.claude/worktrees/alpha"
  run sh "$BIN" run --as alpha
  [ "$status" -eq 1 ]
  [[ "$output" == *"registered but missing"* ]]
  [[ "$output" == *"git worktree prune"* ]]
  [[ "$output" != *"pwd="* ]]
  git worktree prune
  run sh "$BIN" run --as alpha
  [[ "$output" == *"alpha"$'\t'*$'\t'"created"* ]]
  mkdir -p "$REPO/.claude/worktrees/gamma"
  run sh "$BIN" run --as gamma
  [ "$status" -eq 1 ]
  [[ "$output" == *"exists but is not a git worktree"* ]]
}

@test "run --as: a bad slot name, and a slot with a branch, are refused, nothing created" {
  run sh "$BIN" run --as 'Bad Slot'
  [ "$status" -eq 1 ]
  [[ "$output" == *"'Bad Slot' is not a slot name"* ]]
  run sh "$BIN" run --as Alpha
  [ "$status" -eq 1 ]
  run sh "$BIN" run --as alpha feat/x
  [ "$status" -eq 2 ]
  run sh "$BIN" run --as
  [ "$status" -eq 2 ]
  [[ "$output" != *"pwd="* ]]
  [ ! -e "$REPO/.claude/worktrees" ]
}

@test "run: bare, in a repository or not, is one line and a plain shell, nothing created" {
  run sh "$BIN" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"predates named slots; quit iTerm2 and run claude-peer install. Plain shell."* ]]
  [[ "$output" == *'args=-i' ]]
  [[ "$output" == *"peer=unset"* ]]
  [ ! -e "$REPO/.claude/worktrees" ]
  mkdir "$BATS_TEST_TMPDIR/norepo"
  cd "$BATS_TEST_TMPDIR/norepo"
  run sh "$BIN" run --
  [ "$status" -eq 0 ]
  [[ "$output" == *"predates named slots"* ]]
  [[ "$output" == *'args=-i' ]]
}

@test "run --as: a lock left by a dead pid is broken; one held by a live pid times out" {
  ln -s 2147483646 "$REPO/.git/claude-peer.lock"
  run sh "$BIN" run --as alpha
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"$'\t'*$'\t'"created"* ]]
  [ ! -e "$REPO/.git/claude-peer.lock" ]
  ln -s "$$" "$REPO/.git/claude-peer.lock"
  CLAUDE_PEER_LOCK_WAIT=1 run sh "$BIN" run --as beta
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not lock"*"held by pid $$"* ]]
  [[ "$output" != *"pwd="* ]]
}

@test "run --as: from inside a slot worktree the next slot lands under the main checkout" {
  sh "$BIN" run --as alpha >/dev/null
  cd "$REPO/.claude/worktrees/alpha"
  run sh "$BIN" run --as beta
  [ "$status" -eq 0 ]
  [[ "$output" == *"pwd=$REPO/.claude/worktrees/beta"* ]]
  [ ! -e "$REPO/.claude/worktrees/alpha/.claude" ]
}

@test "peers: lists live claims with labels, drops dead ones, filters by leader, silent outside a repository" {
  sh "$BIN" run --as alpha >/dev/null
  sh "$BIN" run feat/x >/dev/null
  run sh "$BIN" peers
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  sleep 300 & s1=$!
  sleep 300 & s2=$!
  mkdir "$BATS_TEST_TMPDIR/lead"
  printf '%s\n%s\n%s\n' "$s1" "$REPO" Alpha >"$(claim_of "$REPO/.claude/worktrees/alpha")"
  printf '%s\n%s\n' "$s2" "$BATS_TEST_TMPDIR/lead" >"$(claim_of "$REPO/.claude/worktrees/feat-x")"
  run sh "$BIN" peers
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO/.claude/worktrees/alpha	$s1	$REPO	Alpha"$'\n'"$REPO/.claude/worktrees/feat-x	$s2	$BATS_TEST_TMPDIR/lead	-" ]
  run sh "$BIN" peers --leader "$REPO"
  [ "$output" = "$REPO/.claude/worktrees/alpha	$s1	$REPO	Alpha" ]
  run sh "$BIN" peers --leader "$BATS_TEST_TMPDIR/nonexistent"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  kill "$s1"; wait "$s1" 2>/dev/null || true
  run sh "$BIN" peers "$REPO/.claude/worktrees/feat-x"
  [ "$output" = "$REPO/.claude/worktrees/feat-x	$s2	$BATS_TEST_TMPDIR/lead	-" ]
  kill "$s2"
  cd "$BATS_TEST_TMPDIR"
  mkdir norepo; cd norepo
  run sh "$BIN" peers
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "status: the peers line counts running slots and waiting panes; leftover names peer-N worktrees from the old layout" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/domain.plist"
  export FAKE_DOMAIN="$BATS_TEST_TMPDIR/domain.plist" FAKE_LOAD=0
  run sh "$BIN" status
  [[ "$output" == *"peers: 0 running, 0 waiting in $REPO"* ]]
  [[ "$output" != *"leftover:"* ]]
  git worktree add -q --detach "$REPO/.claude/worktrees/peer-1"
  git worktree add -q --detach "$REPO/.claude/worktrees/peer-2"
  run sh "$BIN" status
  [[ "$output" == *"leftover: 2 peer-N worktrees from the retired scratch layout (peer-1, peer-2); git worktree remove <path> for each"* ]]
  git worktree remove "$REPO/.claude/worktrees/peer-1"
  git worktree remove "$REPO/.claude/worktrees/peer-2"
  FAKE_SHELL_SLEEP=3 sh "$BIN" run --as alpha >/dev/null &
  rpid=$!
  wait_claim "$REPO/.claude/worktrees/alpha"
  run sh "$BIN" status
  [[ "$output" == *"peers: 1 running, 0 waiting in $REPO: Alpha (alpha)"* ]]
  [[ "$output" != *"leftover:"* ]]
  wait "$rpid"
  pane beta
  run sh "$BIN" status
  [[ "$output" == *"peers: 0 running, 1 waiting in $REPO"* ]]
  cd "$BATS_TEST_TMPDIR"; mkdir norepo; cd norepo
  run sh "$BIN" status
  [[ "$output" != *"peers:"* ]]
}

# --- waiting panes, start, stop, slots ------------------------------------------------
# A pane runs in the background with a FIFO for its terminal; `press` types a line
# into it. The stub shell logs to $FAKE_SHELL_LOG and sleeps FAKE_SHELL_SLEEP, so a
# session lasts long enough for `start` to see its claim.

# until_ok '<command>': retry for ten seconds (times TESTS_WAIT_SCALE, which the
# parallel CI jobs set: a loaded runner starts processes late)
until_ok() {
  local i
  for i in $(seq 1 $((100 * ${TESTS_WAIT_SCALE:-1}))); do
    eval "$1" && return 0
    sleep 0.1
  done
  return 1
}

# pane <slot> [<dir> [<tag>]]: a waiting pane started in <dir> (default $REPO);
# its terminal is the FIFO tty-<tag> (tag defaults to the slot), or $PANE_TTY.
pane() {
  local s=$1 d=${2:-$REPO} t=${3:-$1}
  local tty=$BATS_TEST_TMPDIR/tty-$t
  [ -p "$tty" ] || mkfifo "$tty"
  ( cd "$d" && export CLAUDE_PEER_TTY="${PANE_TTY:-$tty}" &&
    exec sh "$BIN" run --as "$s" --wait >"$BATS_TEST_TMPDIR/pane-$t.out" 2>&1 3>&- ) &
  LAST_PANE=$!
  PANES="$PANES $LAST_PANE"
  until_ok "[ -f '$(git -C "$d" rev-parse --path-format=absolute --git-common-dir)/claude-peer.wait/$s.$LAST_PANE' ]"
}

# press <tag> <text>: type a line into that pane's terminal
press() {
  ( printf '%s\n' "$2" >"$BATS_TEST_TMPDIR/tty-$1" ) 3>&- &
  PANES="$PANES $!"
}

shell_runs() { [ -f "$FAKE_SHELL_LOG" ] && grep -c . "$FAKE_SHELL_LOG" || echo 0; }

# hold <slot> [<dir>]: a session in <slot> from another leader, for a while
hold() {
  mkdir -p "${2:-$REPO/sub}"
  ( cd "${2:-$REPO/sub}" && FAKE_SHELL_LOG=/dev/null FAKE_SHELL_SLEEP=${HOLD:-8} exec sh "$BIN" run --as "$1" >/dev/null 2>&1 3>&- ) &
  PANES="$PANES $!"
  wait_claim "$REPO/.claude/worktrees/$1"
}

@test "run --as --wait: a waiting pane makes no worktree, claim, lock or shell" {
  pane alpha
  run sh "$BIN" slots
  [ "$status" -eq 0 ]
  [ "$output" = "alpha"$'\t'"waiting"$'\t'"$REPO/.claude/worktrees/alpha"$'\t'"$LAST_PANE"$'\t'"$REPO"$'\t'"proj-alpha" ]
  [ ! -e "$REPO/.claude/worktrees" ]
  [ ! -e "$REPO/.git/claude-peer.lock" ]
  [ "$(shell_runs)" -eq 0 ]
  run sh "$BIN" peers
  [ -z "$output" ]
  grep -q "^Alpha: Return starts a Claude here, c continues the last session, q leaves a shell$" "$BATS_TEST_TMPDIR/pane-alpha.out"
}

@test "run --as --wait: Return starts a session, and the pane waits again when it ends" {
  FAKE_SHELL_SLEEP=1 pane alpha
  press alpha ''
  until_ok 'grep -q "pwd=$REPO/.claude/worktrees/alpha args=.*claude-peer proj-alpha\$" "$FAKE_SHELL_LOG"'
  run sh "$BIN" slots
  [[ "$output" == "alpha"$'\t'"running"$'\t'* ]]
  until_ok '[ "$(sh "$BIN" slots | cut -f2)" = waiting ]'
  [ -z "$(sh "$BIN" peers)" ]
  [ "$(find "$REPO/.git" -name claude-peer.claim | wc -l | tr -d ' ')" -eq 0 ]
  [ "$(grep -c "Return starts a Claude here" "$BATS_TEST_TMPDIR/pane-alpha.out")" -eq 2 ]
  grep -qx "Alpha" "$BATS_TEST_TMPDIR/pane-alpha.out"
}

@test "run --as: a slot's first checkout prints nothing of git's, direct or in a pane" {
  run --separate-stderr sh "$BIN" run --as alpha
  [ "$status" -eq 0 ]
  [[ "$output" == "alpha"$'\t'"$REPO/.claude/worktrees/alpha"$'\t'"created"* ]]
  [[ "$stderr" != *"Preparing worktree"* ]]
  [[ "$stderr" != *"HEAD is now at"* ]]
  FAKE_SHELL_SLEEP=1 pane beta
  press beta ''
  until_ok 'grep -qx "Beta" "$BATS_TEST_TMPDIR/pane-beta.out"'
  [ "$(grep -c "Preparing worktree" "$BATS_TEST_TMPDIR/pane-beta.out")" -eq 0 ]
}

@test "run --as: a checkout git refuses still shows git's own reason" {
  git init -q "$BATS_TEST_TMPDIR/empty"
  cd "$BATS_TEST_TMPDIR/empty"
  run sh "$BIN" run --as alpha
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q '^fatal: '
  printf '%s\n' "$output" | grep -qx 'claude-peer: alpha: git worktree add failed'
  [[ "$output" != *"pwd="* ]]
}

@test "run --as --wait: c continues, q leaves a shell, anything else asks again" {
  FAKE_SHELL_SLEEP=1 pane alpha
  press alpha c
  until_ok 'grep -q "claude-peer proj-alpha --continue\$" "$FAKE_SHELL_LOG"'
  until_ok '[ "$(sh "$BIN" slots | cut -f2)" = waiting ]'
  press alpha x
  until_ok '[ "$(grep -c "Return starts a Claude here" "$BATS_TEST_TMPDIR/pane-alpha.out")" -eq 3 ]'
  [ "$(shell_runs)" -eq 1 ]
  press alpha q
  until_ok '[ "$(tail -n 1 "$FAKE_SHELL_LOG")" = "pwd=$REPO args=-i" ]'
  [ -z "$(sh "$BIN" slots)" ]
  ! ls "$REPO/.git/claude-peer.wait/" | grep .
}

@test "run --as --wait: outside a repository it is one line and a plain shell" {
  mkdir "$BATS_TEST_TMPDIR/norepo"
  cd "$BATS_TEST_TMPDIR/norepo"
  run sh "$BIN" run --as alpha --wait
  [ "$status" -eq 0 ]
  [[ "$output" == *"not in a git repository, so there is no worktree to give this peer; plain shell"* ]]
  [[ "$output" == *'args=-i' ]]
}

# The restored-pane check. claude() records each workgroup entry as
# $XDG_STATE_HOME/claude-peer/entered/<epoch>.<pid>, "<epoch><TAB><directory>"; a
# pane with no record for its leader in the last minute asks before it serves.

# enter_record <seconds ago> [<dir>]: a record as claude() writes it
enter_record() {
  local e=$(( $(date +%s) - $1 ))
  mkdir -p "$XDG_STATE_HOME/claude-peer/entered"
  printf '%s\t%s\n' "$e" "${2:-$REPO}" >"$XDG_STATE_HOME/claude-peer/entered/$e.$RANDOM"
}

# restored_pane: a pane with the check on, no wait for its wait file; its terminal is tty-alpha
restored_pane() {
  git config --global --unset claude-peer.restore-check
  mkfifo "$BATS_TEST_TMPDIR/tty-alpha"
  ( cd "$REPO" && export CLAUDE_PEER_TTY="$BATS_TEST_TMPDIR/tty-alpha" &&
    exec sh "$BIN" run --as alpha --wait >"$BATS_TEST_TMPDIR/pane-alpha.out" 2>&1 3>&- ) &
  PANES="$PANES $!"
}

no_wait_files() { [ -z "$(ls "$REPO/.git/claude-peer.wait" 2>/dev/null)" ]; }

@test "restore check: a fresh record for the leader makes a normal waiting pane" {
  git config --global --unset claude-peer.restore-check
  enter_record 5
  pane alpha
  ! grep -q "restored" "$BATS_TEST_TMPDIR/pane-alpha.out"
  [ "$(sh "$BIN" slots | cut -f2)" = waiting ]
}

@test "restore check: no record asks first, writes no wait file, start finds nothing; Return makes a pane" {
  restored_pane
  until_ok 'grep -q "Return if this tab is proj" "$BATS_TEST_TMPDIR/pane-alpha.out"'
  [ "$(sed -n 1p "$BATS_TEST_TMPDIR/pane-alpha.out")" = "Alpha: iTerm2 restored this pane; it would serve proj." ]
  [ "$(sed -n 2p "$BATS_TEST_TMPDIR/pane-alpha.out")" = "Return if this tab is proj's, q for a shell." ]
  no_wait_files
  run sh "$BIN" start alpha
  [ "$status" -eq 4 ]
  press alpha 'x'
  until_ok '[ "$(grep -c "Return if this tab" "$BATS_TEST_TMPDIR/pane-alpha.out")" -eq 2 ]'
  no_wait_files
  press alpha ''
  until_ok '[ "$(sh "$BIN" slots | cut -f2)" = waiting ]'
  [ "$(shell_runs)" -eq 0 ]
}

@test "restore check: q leaves a plain shell and no wait file" {
  restored_pane
  until_ok 'grep -q "restored this pane" "$BATS_TEST_TMPDIR/pane-alpha.out"'
  press alpha q
  until_ok '[ "$(tail -n 1 "$FAKE_SHELL_LOG")" = "pwd=$REPO args=-i" ]'
  no_wait_files
}

@test "restore check: end of input leaves a plain shell" {
  restored_pane
  until_ok 'grep -q "restored this pane" "$BATS_TEST_TMPDIR/pane-alpha.out"'
  ( : >"$BATS_TEST_TMPDIR/tty-alpha" ) 3>&-   # a writer that closes with nothing written
  until_ok '[ "$(tail -n 1 "$FAKE_SHELL_LOG")" = "pwd=$REPO args=-i" ]'
  no_wait_files
}

@test "restore check: a record for another directory, or older than the window, does not count" {
  enter_record 5 "$REPO/sub"
  enter_record 120
  restored_pane
  until_ok 'grep -q "restored this pane" "$BATS_TEST_TMPDIR/pane-alpha.out"'
  no_wait_files
}

@test "restore check: records more than a day old are deleted, others are left" {
  enter_record 90000
  enter_record 5
  d=$XDG_STATE_HOME/claude-peer/entered
  echo junk >"$d/junk"
  [ "$(ls "$d" | wc -l)" -eq 3 ]
  git config --global --unset claude-peer.restore-check
  pane alpha
  [ "$(ls "$d" | wc -l)" -eq 2 ]
  [ -f "$d/junk" ]
}

@test "start: wakes the pane; the prompt arrives as one final argument" {
  FAKE_SHELL_SLEEP=2 FAKE_SHELL_LAST="$BATS_TEST_TMPDIR/last" pane alpha
  run sh "$BIN" start alpha fix the thing
  [ "$status" -eq 0 ]
  [ "$output" = "alpha"$'\t'"$REPO/.claude/worktrees/alpha"$'\t'"started"$'\t'"proj-alpha" ]
  # the claim exists a moment before the shell has run
  until_ok '[ -s "$BATS_TEST_TMPDIR/last.n" ]'
  [ "$(cat "$BATS_TEST_TMPDIR/last")" = "fix the thing" ]
  [ "$(cat "$BATS_TEST_TMPDIR/last.n")" -eq 6 ]
  grep -q "claude-peer proj-alpha fix the thing\$" "$FAKE_SHELL_LOG"
}

@test "start: a prompt from stdin arrives byte for byte" {
  FAKE_SHELL_SLEEP=2 FAKE_SHELL_LAST="$BATS_TEST_TMPDIR/last" pane alpha
  want=$'say "hi" $HOME `x` \'y\' \\n\nsecond line'
  run sh -c 'printf "%s" "$1" | sh "$2" start alpha -' _ "$want" "$BIN"
  [ "$status" -eq 0 ]
  until_ok '[ -s "$BATS_TEST_TMPDIR/last.n" ]'
  [ "$(cat "$BATS_TEST_TMPDIR/last")" = "$want" ]
  [ "$(cat "$BATS_TEST_TMPDIR/last.n")" -eq 6 ]
}

@test "start: --continue goes before the prompt; with no prompt it is the only extra argument" {
  FAKE_SHELL_SLEEP=2 FAKE_SHELL_LAST="$BATS_TEST_TMPDIR/last" pane alpha
  run sh "$BIN" start alpha --continue go on
  [ "$status" -eq 0 ]
  until_ok 'grep -q "claude-peer proj-alpha --continue go on\$" "$FAKE_SHELL_LOG"'
  until_ok '[ "$(sh "$BIN" slots | cut -f2)" = waiting ]'
  : >"$FAKE_SHELL_LOG"; rm -f "$BATS_TEST_TMPDIR/last.n"
  run sh "$BIN" start alpha --continue
  [ "$status" -eq 0 ]
  until_ok '[ -s "$BATS_TEST_TMPDIR/last.n" ]'
  grep -q "claude-peer proj-alpha --continue\$" "$FAKE_SHELL_LOG"
  [ "$(cat "$BATS_TEST_TMPDIR/last")" = "--continue" ]
}

@test "start: no waiting pane is 4, a running slot is 3, a prompt that begins with - is 2" {
  run sh "$BIN" start alpha
  [ "$status" -eq 4 ]
  [[ "$output" == *"no pane is waiting in this repository"* ]]
  hold alpha
  run sh "$BIN" start alpha
  [ "$status" -eq 3 ]
  [ "$output" = "alpha"$'\t'"$REPO/.claude/worktrees/alpha"$'\t'"running"$'\t'"proj-alpha" ]
  run sh "$BIN" start beta -- -x
  [ "$status" -eq 2 ]
  run sh "$BIN" start beta -x
  [ "$status" -eq 2 ]
  run sh "$BIN" start 'Bad Slot'
  [ "$status" -eq 1 ]
  [ "$(shell_runs)" -eq 0 ]
}

@test "start: two leaders' panes for one slot, --leader picks one, an unrelated directory neither" {
  FAKE_SHELL_SLEEP=2 pane alpha "$REPO" a
  mkdir "$REPO/sub" "$REPO/other"
  FAKE_SHELL_SLEEP=2 pane alpha "$REPO/sub" b
  pb=$LAST_PANE
  cd "$REPO/other"
  run sh "$BIN" start alpha
  [ "$status" -eq 4 ]
  [[ "$output" == *"$REPO"*"$REPO/sub"* ]]
  [ "$(sh "$BIN" slots | grep -c waiting)" -eq 2 ]
  run sh "$BIN" start alpha --leader "$REPO/sub"
  [ "$status" -eq 0 ]
  run sh "$BIN" peers
  [ "$(printf '%s' "$output" | cut -f2,3)" = "$pb"$'\t'"$REPO/sub" ]
  [ "$(sh "$BIN" slots | grep -c waiting)" -eq 1 ]
}

@test "start: a pane with no terminal still starts on a request" {
  FAKE_SHELL_SLEEP=2 PANE_TTY=/nonexistent pane alpha
  run sh "$BIN" start alpha
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\t'"started"$'\t'"proj-alpha" ]]
}

@test "start: a slot the pane did not start with is still started in it" {
  FAKE_SHELL_SLEEP=2 pane alpha
  run sh "$BIN" start beta
  [ "$status" -eq 0 ]
  [ "$output" = "beta"$'\t'"$REPO/.claude/worktrees/beta"$'\t'"started"$'\t'"proj-beta" ]
  [ ! -e "$REPO/.claude/worktrees/alpha" ]
}

@test "stop: TERMs an idle session, refuses a busy one, --force stops anything under the claim" {
  cfg=$BATS_TEST_TMPDIR/cfg
  mkdir -p "$cfg/sessions"
  export CLAUDE_CONFIG_DIR=$cfg
  run sh "$BIN" stop alpha
  [ "$status" -eq 3 ]
  [ "$output" = "alpha"$'\t'"$REPO/.claude/worktrees/alpha"$'\t'"not-running" ]
  FAKE_SHELL_SLEEP=30 FAKE_SHELL_PID="$BATS_TEST_TMPDIR/shpid" pane alpha
  sh "$BIN" start alpha >/dev/null
  until_ok '[ -s "$BATS_TEST_TMPDIR/shpid" ]'
  sp=$(cat "$BATS_TEST_TMPDIR/shpid")
  run sh "$BIN" stop alpha
  [ "$status" -eq 5 ]
  [[ "$output" == *"alpha is unknown; stop --force to stop it anyway"* ]]
  printf '{"pid": %s, "status": "busy"}\n' "$sp" >"$cfg/sessions/$sp.json"
  run sh "$BIN" stop alpha
  [ "$status" -eq 5 ]
  [[ "$output" == *"alpha is busy; stop --force"* ]]
  kill -0 "$sp"
  printf '{"pid": %s, "status": "idle"}\n' "$sp" >"$cfg/sessions/$sp.json"
  run sh "$BIN" stop alpha
  [ "$status" -eq 0 ]
  [ "$output" = "alpha"$'\t'"$REPO/.claude/worktrees/alpha"$'\t'"stopped" ]
  ! kill -0 "$sp" 2>/dev/null
  until_ok '[ "$(sh "$BIN" slots | cut -f2)" = waiting ]'
  [ -d "$REPO/.claude/worktrees/alpha" ]
}

@test "stop: the default config directory is searched with no CLAUDE_CONFIG_DIR and no profile mapping" {
  unset CLAUDE_CONFIG_DIR
  mkdir -p "$HOME/.claude/sessions"
  FAKE_SHELL_SLEEP=30 FAKE_SHELL_PID="$BATS_TEST_TMPDIR/shpid" pane alpha
  sh "$BIN" start alpha >/dev/null
  until_ok '[ -s "$BATS_TEST_TMPDIR/shpid" ]'
  sp=$(cat "$BATS_TEST_TMPDIR/shpid")
  printf '{"pid": %s, "status": "idle"}\n' "$sp" >"$HOME/.claude/sessions/$sp.json"
  run sh "$BIN" stop alpha
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\t'"stopped" ]]
  ! kill -0 "$sp" 2>/dev/null
}

@test "stop --force: no registry record, every process under the claim is stopped" {
  export CLAUDE_CONFIG_DIR=$BATS_TEST_TMPDIR/empty
  FAKE_SHELL_SLEEP=30 FAKE_SHELL_PID="$BATS_TEST_TMPDIR/shpid" pane alpha
  sh "$BIN" start alpha >/dev/null
  until_ok '[ -s "$BATS_TEST_TMPDIR/shpid" ]'
  sp=$(cat "$BATS_TEST_TMPDIR/shpid")
  run sh "$BIN" stop alpha --force
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\t'"stopped" ]]
  ! kill -0 "$sp" 2>/dev/null
}

@test "claude-peer.start = auto: the pane starts a session after the settle delay, then waits" {
  git config claude-peer.start auto
  mkfifo "$BATS_TEST_TMPDIR/tty-alpha"
  CLAUDE_PEER_SETTLE=2 FAKE_SHELL_SLEEP=1 CLAUDE_PEER_TTY="$BATS_TEST_TMPDIR/tty-alpha" \
    sh "$BIN" run --as alpha --wait >"$BATS_TEST_TMPDIR/pane-alpha.out" 2>&1 3>&- &
  PANES="$PANES $!"
  sleep 0.5
  [ "$(shell_runs)" -eq 0 ]
  until_ok 'grep -q "claude-peer proj-alpha\$" "$FAKE_SHELL_LOG"'
  until_ok '[ "$(sh "$BIN" slots | cut -f2)" = waiting ]'
  [ "$(shell_runs)" -eq 1 ]
}

@test "the pool: a taken name sends the pane to the pool's sixth, and says so" {
  hold alpha
  pane alpha
  press alpha ''
  until_ok 'grep -q "claude-peer proj-zeta\$" "$FAKE_SHELL_LOG"'
  grep -qF "Zeta (this pane's Alpha is in use by the peers of $REPO/sub)" "$BATS_TEST_TMPDIR/pane-alpha.out"
  [ ! -e "$REPO/.claude/worktrees/beta" ]
}

@test "the pool: a pane takes its own slot when free, whatever order the panes start in" {
  FAKE_SHELL_SLEEP=3 pane gamma
  press gamma ''
  until_ok 'grep -q "claude-peer proj-gamma\$" "$FAKE_SHELL_LOG"'
  ! grep -q "Gamma (" "$BATS_TEST_TMPDIR/pane-gamma.out"
}

@test "the pool: with every name held the pane says so and goes on waiting" {
  git config claude-peer.slots 'alpha beta'
  hold alpha
  hold beta
  pane alpha
  press alpha ''
  until_ok 'grep -q "all 2 slots are in use in $REPO" "$BATS_TEST_TMPDIR/pane-alpha.out"'
  until_ok '[ "$(grep -c "Return tries again" "$BATS_TEST_TMPDIR/pane-alpha.out")" -eq 1 ]'
  [ "$(sh "$BIN" slots | grep -c waiting)" -eq 1 ]
  [ "$(shell_runs)" -eq 0 ]
  ! grep -q "	end	" "$REPO/$LOG" 2>/dev/null
}

@test "the pool: a configured pool falls back to a free one of the first five" {
  git config claude-peer.slots 'alpha beta gamma delta epsilon zeta'
  hold alpha
  hold zeta
  pane alpha
  press alpha ''
  until_ok 'grep -q "claude-peer proj-beta\$" "$FAKE_SHELL_LOG"'
}

@test "start next: the pane's own slot when free, else by the pool; all held is 3" {
  FAKE_SHELL_SLEEP=2 pane alpha
  run sh "$BIN" start next
  [ "$status" -eq 0 ]
  [ "$output" = "alpha"$'\t'"$REPO/.claude/worktrees/alpha"$'\t'"started"$'\t'"proj-alpha" ]
  until_ok '[ "$(sh "$BIN" slots | cut -f2)" = waiting ]'
  git config claude-peer.slots 'alpha beta'
  hold alpha
  hold beta
  run sh "$BIN" start next
  [ "$status" -eq 3 ]
  [[ "$output" == *"all 2 slots are in use"* ]]
}

@test "a waiting pane's stale files are cleared by the next pane that registers" {
  mkdir -p "$REPO/.git/claude-peer.wait"
  w=$REPO/.git/claude-peer.wait
  : >"$w/alpha.2147483646"; : >"$w/alpha.2147483646.key"; : >"$w/beta.2147483646.start"
  pane gamma
  ! ls "$w" | grep 2147483646
  [ "$(sh "$BIN" slots | cut -f1)" = gamma ]
}

@test "a killed pane takes its reader and its wait file with it" {
  pane alpha
  pp=$LAST_PANE
  kids=$(ps -Ao pid=,ppid= | awk -v p="$pp" '$2 == p { print $1 }')
  [ -n "$kids" ]
  kill "$pp"
  until_ok '! kill -0 $pp 2>/dev/null'
  for k in $kids; do until_ok "! kill -0 $k 2>/dev/null"; done
  [ -z "$(ls "$REPO/.git/claude-peer.wait")" ]
}

# panes and the terminal file a pane records beside its wait file

term_of() { cat "$REPO/.git/claude-peer.wait/$1.$2.term"; }

@test "a pane records its terminal: the session id without its w0t0p0 prefix, and the suite" {
  unset IT2_SUITE
  ITERM_SESSION_ID=w1t2p3:ABCD-1234 pane alpha
  [ "$(term_of alpha "$LAST_PANE")" = "ABCD-1234"$'\n'"-" ]
  IT2_SUITE=bench ITERM_SESSION_ID=w0t0p1:EF56 pane beta
  [ "$(term_of beta "$LAST_PANE")" = "EF56"$'\n'"bench" ]
}

@test "outside iTerm2 the pane records - and waits as before" {
  unset ITERM_SESSION_ID IT2_SUITE
  pane alpha
  [ "$(term_of alpha "$LAST_PANE")" = "-"$'\n'"-" ]
  ITERM_SESSION_ID= pane beta
  [ "$(term_of beta "$LAST_PANE")" = "-"$'\n'"-" ]
  run sh "$BIN" slots
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f1,2)" = "alpha"$'\t'"waiting"$'\n'"beta"$'\t'"waiting" ]
}

@test "panes: a waiting pane and a running one, each with its id" {
  unset IT2_SUITE
  ITERM_SESSION_ID=w0t0p1:AAAA pane alpha
  wp=$LAST_PANE
  ITERM_SESSION_ID=w0t0p2:BBBB IT2_SUITE=bench FAKE_SHELL_SLEEP=8 pane beta
  rp=$LAST_PANE
  press beta ''
  wait_claim "$REPO/.claude/worktrees/beta"
  run sh "$BIN" panes
  [ "$status" -eq 0 ]
  [ "$output" = "alpha"$'\t'"waiting"$'\t'"$wp"$'\t'"$REPO"$'\t'"$REPO/.claude/worktrees/alpha"$'\t'"AAAA"$'\t'"-"$'\n'"beta"$'\t'"running"$'\t'"$rp"$'\t'"$REPO"$'\t'"$REPO/.claude/worktrees/beta"$'\t'"BBBB"$'\t'"bench" ]
  cd "$BATS_TEST_TMPDIR"
  run sh "$BIN" panes "$REPO"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "panes: a pane without the file prints - and -" {
  pane alpha
  rm "$REPO/.git/claude-peer.wait/alpha.$LAST_PANE.term"
  run sh "$BIN" panes
  [ "$status" -eq 0 ]
  [ "$output" = "alpha"$'\t'"waiting"$'\t'"$LAST_PANE"$'\t'"$REPO"$'\t'"$REPO/.claude/worktrees/alpha"$'\t'"-"$'\t'"-" ]
}

@test "the terminal file stays while a session runs and goes when the pane ends" {
  ITERM_SESSION_ID=w0t0p1:AAAA FAKE_SHELL_SLEEP=8 pane alpha
  pp=$LAST_PANE
  press alpha ''
  wait_claim "$REPO/.claude/worktrees/alpha"
  [ ! -e "$REPO/.git/claude-peer.wait/alpha.$pp" ]
  [ "$(term_of alpha "$pp" | sed -n 1p)" = AAAA ]
  kill "$pp"
  until_ok '! kill -0 $pp 2>/dev/null'
  [ -z "$(ls "$REPO/.git/claude-peer.wait")" ]
}

@test "slots, peers and waiters do not list the terminal file" {
  pane alpha
  [ -f "$REPO/.git/claude-peer.wait/alpha.$LAST_PANE.term" ]
  : >"$REPO/.git/claude-peer.wait/beta.$LAST_PANE.term"
  run sh "$BIN" slots
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ -z "$(sh "$BIN" peers)" ]
  [ "$(sh "$BIN" panes | wc -l | tr -d ' ')" -eq 1 ]
}

@test "panes outside a repository prints nothing and exits 0" {
  mkdir "$BATS_TEST_TMPDIR/plain"
  cd "$BATS_TEST_TMPDIR/plain"
  run sh "$BIN" panes
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run sh "$BIN" panes "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run sh "$BIN" panes a b
  [ "$status" -eq 2 ]
}

@test "hermes --wait: asks hermes_peer to wait for Return, unless claude-peer.start is auto" {
  run sh "$BIN" hermes --wait
  [ "$status" -eq 0 ]
  [[ "$output" == *"hermeswait=1"* ]]
  run sh "$BIN" hermes
  [[ "$output" == *"hermeswait=unset"* ]]
  git config claude-peer.start auto
  run sh "$BIN" hermes --wait -- --foo
  [[ "$output" == *"hermeswait=unset"* ]]
  [[ "$output" == *' claude-peer --foo' ]]
}

# --- the coordination log ---------------------------------------------------------

# slot_wt <slot> <Label>: a slot worktree with a live claim (the test's own pid),
# led from $REPO
slot_wt() {
  git worktree add -q --detach "$REPO/.claude/worktrees/$1" HEAD
  printf '%s\n%s\n%s\n' "$$" "$REPO" "$2" >"$(claim_of "$REPO/.claude/worktrees/$1")"
}

LOG=.git/claude-peer.log

@test "log claim: a shared path is one overlap line, the exit is 0, and the claim is in the log" {
  slot_wt alpha Alpha; slot_wt beta Beta
  mkdir -p "$REPO/lib/sub"
  cd "$REPO/.claude/worktrees/alpha"
  run sh "$BIN" log claim rework the lib -- lib/sub
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cd "$REPO/.claude/worktrees/beta"
  run sh "$BIN" log claim tidy the helpers -- lib/sub/x.sh docs
  [ "$status" -eq 0 ]
  [ "$output" = "overlap"$'\t'"Alpha"$'\t'"lib/sub"$'\t'"rework the lib" ]
  [ "$(wc -l <"$REPO/$LOG" | tr -d ' ')" -eq 2 ]
  [ "$(cut -f2,3,4,5 "$REPO/$LOG" | sed -n 2p)" = "Beta"$'\t'"claim"$'\t'"tidy the helpers"$'\t'"lib/sub/x.sh" ]
  [[ "$(cut -f1 "$REPO/$LOG" | sed -n 1p)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "log claim: a directory overlaps what is under it, both ways; paths are taken from the cwd or absolute; the top overlaps all" {
  slot_wt alpha Alpha; slot_wt beta Beta
  cd "$REPO/.claude/worktrees/alpha"
  mkdir -p bin
  sh "$BIN" log claim a -- bin/tool
  cd "$REPO/.claude/worktrees/beta"
  run sh "$BIN" log claim b -- bin/
  [ "$output" = "overlap"$'\t'"Alpha"$'\t'"bin/tool"$'\t'"a" ]
  run sh "$BIN" log claim c -- bin/tool2
  [ -z "$output" ]
  mkdir -p bin; cd bin
  run sh "$BIN" log claim d -- tool
  [ "$output" = "overlap"$'\t'"Alpha"$'\t'"bin/tool"$'\t'"a" ]
  run sh "$BIN" log claim e -- "$REPO/.claude/worktrees/beta/bin/tool"
  [[ "$output" == *"overlap"$'\t'"Alpha"$'\t'"bin/tool"* ]]
  cd "$REPO/.claude/worktrees/beta"
  run sh "$BIN" log claim f -- .
  [ "$output" = "overlap"$'\t'"Alpha"$'\t'"bin/tool"$'\t'"a" ]
  run sh "$BIN" log claim no paths at all
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "log: done closes the caller's claims, a stop line closes that label's, claims of nobody else are touched" {
  slot_wt alpha Alpha; slot_wt beta Beta
  cd "$REPO/.claude/worktrees/alpha"
  sh "$BIN" log claim a -- lib
  cd "$REPO/.claude/worktrees/beta"
  sh "$BIN" log claim b -- other
  run sh "$BIN" log claim c -- lib
  [ "$(printf '%s\n' "$output" | grep -c '^overlap')" -eq 1 ]
  cd "$REPO/.claude/worktrees/alpha"
  sh "$BIN" log done finished
  cd "$REPO/.claude/worktrees/beta"
  run sh "$BIN" log claim d -- lib
  [ -z "$output" ]
  # a stop line for Beta closes Beta's claims, whoever wrote it
  cd "$REPO"
  sh "$BIN" log --as Gamma claim g -- other
  printf '2000-01-01T00:00:00Z\tLead\tstop\tBeta by Lead\n' >>"$REPO/$LOG"
  run sh "$BIN" log --as Gamma claim h -- lib
  [ -z "$output" ]
  run sh "$BIN" log show
  [ "$(printf '%s\n' "$output" | cut -f2,3 | sort | tr '\n' ' ')" = "Gamma"$'\t'"claim Gamma"$'\t'"claim " ]
}

@test "log: who is the slot's label in a claimed worktree, Lead where a live claim names the cwd, the directory name elsewhere, and --as wins" {
  slot_wt alpha Alpha
  cd "$REPO/.claude/worktrees/alpha"
  mkdir sub; cd sub
  sh "$BIN" log note from a slot
  cd "$REPO"
  sh "$BIN" log note from the leader
  mkdir "$BATS_TEST_TMPDIR/elsewhere"; git -C "$REPO" worktree add -q --detach "$BATS_TEST_TMPDIR/elsewhere/other" HEAD
  cd "$BATS_TEST_TMPDIR/elsewhere/other"
  sh "$BIN" log note from nowhere
  sh "$BIN" log --as Zed note overridden
  [ "$(cut -f2,3,4 "$REPO/$LOG")" = "Alpha"$'\t'"note"$'\t'"from a slot"$'\n'"Lead"$'\t'"note"$'\t'"from the leader"$'\n'"other"$'\t'"note"$'\t'"from nowhere"$'\n'"Zed"$'\t'"note"$'\t'"overridden" ]
}

@test "log: a tab or newline in text or a path is written as a space, one line per entry" {
  cd "$REPO"
  sh "$BIN" log --as X note "$(printf 'one\ttwo\nthree')"
  sh "$BIN" log --as X claim "$(printf 'a\tb\nc')" -- "$(printf 'p\tq')"
  [ "$(wc -l <"$REPO/$LOG" | tr -d ' ')" -eq 2 ]
  [ "$(sed -n 1p "$REPO/$LOG" | cut -f4)" = "one two three" ]
  [ "$(sed -n 2p "$REPO/$LOG" | cut -f4,5 | tr '\t' '|')" = "a b c|p q" ]
}

@test "log show: open claims and the last day's notes; --all is the file; outside a repository nothing, exit 0" {
  cd "$REPO"
  printf '2000-01-01T00:00:00Z\tOld\tnote\tancient\n2000-01-01T00:00:00Z\tOld\tclaim\tstill open\tlib\n' >"$REPO/$LOG"
  sh "$BIN" log --as New note recent
  run sh "$BIN" log show
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f2,3,4 | tr '\t' '|')" = "Old|claim|still open"$'\n'"New|note|recent" ]
  run sh "$BIN" log show --all
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 3 ]
  cd "$BATS_TEST_TMPDIR"; mkdir -p norepo; cd norepo
  run sh "$BIN" log show
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run sh "$BIN" log note x
  [ "$status" -eq 1 ]
}

# A postbox stub that records each call; the call is detached, so wait for it.
pb_stub() {
  export CLAUDE_PEER_POSTBOX="$BATS_TEST_TMPDIR/bin/postbox" PB_CALLS="$BATS_TEST_TMPDIR/pb.calls"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$PB_CALLS"\n' >"$CLAUDE_PEER_POSTBOX"
  chmod +x "$CLAUDE_PEER_POSTBOX"
}
pb_wait() { # count
  local i
  for i in $(seq 1 40); do [ "$(grep -c . "$PB_CALLS" 2>/dev/null || echo 0)" -ge "$1" ] && return 0; sleep 0.05; done
  return 1
}

@test "log: a tab's claim, note and done each call postbox lead-news for its claim's leader" {
  pb_stub; slot_wt alpha Alpha
  cd "$REPO/.claude/worktrees/alpha"
  sh "$BIN" log claim fix thing -- lib; pb_wait 1
  sh "$BIN" log note halfway; pb_wait 2
  sh "$BIN" log done; pb_wait 3
  [ "$(cat "$PB_CALLS")" = "lead-news $REPO - -"$'\n'"lead-news $REPO - -"$'\n'"lead-news $REPO - -" ]
}

@test "log: Lead's lines, the leader directory's while a tab runs, and log show call nothing" {
  pb_stub; slot_wt alpha Alpha
  cd "$REPO"
  sh "$BIN" log --as Lead note mine
  sh "$BIN" log note from the leader
  sh "$BIN" log show >/dev/null
  cd "$REPO/.claude/worktrees/alpha"
  sh "$BIN" log --as Lead note also mine
  sleep 0.5
  [ ! -e "$PB_CALLS" ]
}

@test "log: Hermes from a directory with no claim passes the main checkout" {
  pb_stub
  mkdir "$BATS_TEST_TMPDIR/elsewhere"; git -C "$REPO" worktree add -q --detach "$BATS_TEST_TMPDIR/elsewhere/h" HEAD
  cd "$BATS_TEST_TMPDIR/elsewhere/h"
  sh "$BIN" log --as Hermes note x; pb_wait 1
  [ "$(cat "$PB_CALLS")" = "lead-news $REPO - -" ]
}

@test "log: without an executable postbox, claim exits 0 and prints exactly its overlap lines" {
  export CLAUDE_PEER_POSTBOX="$BATS_TEST_TMPDIR/nope"
  slot_wt alpha Alpha; slot_wt beta Beta
  cd "$REPO/.claude/worktrees/alpha"; sh "$BIN" log claim a -- lib
  cd "$REPO/.claude/worktrees/beta"
  run sh "$BIN" log claim b -- lib
  [ "$status" -eq 0 ]
  [ "$output" = "overlap"$'\t'"Alpha"$'\t'"lib"$'\t'"a" ]
}

@test "log: every worktree reads the one file in the common git directory; a bad verb is usage" {
  slot_wt alpha Alpha
  cd "$REPO/.claude/worktrees/alpha"
  sh "$BIN" log note hello
  [ ! -e "$(git rev-parse --absolute-git-dir)/claude-peer.log" ]
  [ -f "$REPO/$LOG" ]
  run sh "$BIN" log bogus
  [ "$status" -eq 2 ]
  run sh "$BIN" log claim
  [ "$status" -eq 2 ]
}

@test "start and stop each append their line, and the prompt is passed on untouched" {
  cfg=$BATS_TEST_TMPDIR/cfg
  mkdir -p "$cfg/sessions"
  export CLAUDE_CONFIG_DIR=$cfg
  FAKE_SHELL_SLEEP=30 FAKE_SHELL_PID="$BATS_TEST_TMPDIR/shpid" FAKE_SHELL_LAST="$BATS_TEST_TMPDIR/last" pane alpha
  sh "$BIN" start alpha some words >/dev/null
  until_ok '[ -s "$BATS_TEST_TMPDIR/last.n" ]'
  [ "$(cat "$BATS_TEST_TMPDIR/last")" = "some words" ]
  sp=$(cat "$BATS_TEST_TMPDIR/shpid")
  [ "$(cut -f2,3,4 "$REPO/$LOG")" = "Lead"$'\t'"start"$'\t'"Alpha by Lead" ]
  printf '{"pid": %s, "status": "idle"}\n' "$sp" >"$cfg/sessions/$sp.json"
  sh "$BIN" stop alpha >/dev/null
  # the pane's `end` races `stop`'s line; both are there, in either order
  until_ok '[ "$(grep -c . "$REPO/$LOG")" -eq 3 ]'
  grep -qx "Lead"$'\t'"stop"$'\t'"Alpha by Lead" <(cut -f2,3,4 "$REPO/$LOG")
  grep -Eqx "Alpha"$'\t'"end"$'\t'"Alpha ended after [0-9]+s \(some words\) \(stopped by Lead\)" <(cut -f2,3,4 "$REPO/$LOG")
}

@test "end: a session that ends logs one end line, which closes its label's claims" {
  FAKE_SHELL_SLEEP=1 pane alpha
  sh "$BIN" log --as Alpha claim fixing -- some/file >/dev/null
  sh "$BIN" start alpha the task >/dev/null
  until_ok 'grep -q "	end	" "$REPO/$LOG"'
  [ "$(grep -c "	end	" "$REPO/$LOG")" -eq 1 ]
  [[ "$(grep "	end	" "$REPO/$LOG" | cut -f2,3,4)" =~ ^Alpha$'\t'end$'\t'Alpha\ ended\ after\ [0-9]+s\ \(the\ task\)$ ]]
  run sh "$BIN" log --as Beta claim other -- some
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ! sh "$BIN" log show | grep -q "	Alpha	claim	"
}

# --- workgroup / install / status ----------------------------------------------
# Stubs stand in for ps, uname and defaults; the fixture plist is built with
# plistlib and holds a builtin workgroup plus a sentinel key.

stubs() {
  local b="$BATS_TEST_TMPDIR/bin"
  cat >"$b/uname" <<'STUB'
#!/bin/sh
printf '%s\n' "${FAKE_OS:-Darwin}"
STUB
  cat >"$b/ps" <<'STUB'
#!/bin/sh
for p in ${FAKE_PROCS:-}; do printf '%s\n' "$p"; done
STUB
  cat >"$b/defaults" <<'STUB'
#!/bin/sh
case $1 in
  read) case $3 in
          LoadPrefsFromCustomFolder) [ -n "${FAKE_LOAD-}" ] && printf '%s\n' "$FAKE_LOAD" || exit 1;;
          PrefsCustomFolder) printf '%s\n' "$FAKE_FOLDER";;
        esac;;
  export) cat "$FAKE_DOMAIN";;
  import) cat >"$FAKE_DOMAIN";;
esac
STUB
  chmod +x "$b"/uname "$b"/ps "$b"/defaults
  export PATH="$b:$PATH"
}

# mkprefs <path> [xml|binary|empty|junk]
mkprefs() {
  python3 -I - "$1" "${2:-xml}" <<'PY'
import json, plistlib, sys
path, kind = sys.argv[1:3]
builtin = [{"uniqueIdentifier": "builtin.claudeCode", "name": "Fixture Builtin", "sessions": [
    {"uniqueIdentifier": "builtin.claudeCode.main", "kind": {"kind": "root"}, "displayName": "Main",
     "command": "", "perFileCommand": "", "urlString": "", "mode": "regular",
     "toolbarItems": [{"kind": "modeSwitcher"}, {"kind": "gitStatus"}, {"kind": "fixtureItem"}]},
    {"uniqueIdentifier": "builtin.claudeCode.diff", "parentID": "builtin.claudeCode.main",
     "kind": {"kind": "peer"}, "displayName": "Review", "command": "fixture-diff \\(gitBase)",
     "perFileCommand": "fixture-diff \\(gitBase) -- \\(file)", "urlString": "", "mode": "diff",
     "toolbarItems": [{"kind": "modeSwitcher"}, {"kind": "navigation",
                      "reloadShortcut": {"serialized": "0x1-0x2-0x3"}}]}]}]
pl = {"Ponies": "sentinel"}
if kind == "junk":
    pl["Workgroups"] = b"not json"
elif kind != "empty":
    pl["Workgroups"] = json.dumps(builtin).encode()
with open(path, "wb") as f:
    plistlib.dump(pl, f, fmt=plistlib.FMT_BINARY if kind == "binary" else plistlib.FMT_XML)
PY
}

# groups <path>: the decoded Workgroups of a plist, one JSON document
groups() {
  python3 -I -c 'import json, plistlib, sys; print(json.dumps(json.loads(plistlib.load(open(sys.argv[1], "rb"))["Workgroups"])))' "$1"
}

# pyget <json> <python expression over g>
pyget() { python3 -I -c 'import json, sys; g = json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"; }

@test "workgroup: Claude Peers is six sessions in order, Lead the root, no Diff, no Hermes" {
  mkprefs "$BATS_TEST_TMPDIR/prefs.plist"
  CLAUDE_PEER_PREFS="$BATS_TEST_TMPDIR/prefs.plist" run sh "$BIN" workgroup
  [ "$status" -eq 0 ]
  [ "$(pyget "$output" '[g["uniqueIdentifier"], g["name"]]')" = "['claudePeer.workgroup', 'Claude Peers']" ]
  [ "$(pyget "$output" '[s["uniqueIdentifier"] for s in g["sessions"]]')" = "['claudePeer.main', 'claudePeer.alpha', 'claudePeer.beta', 'claudePeer.gamma', 'claudePeer.delta', 'claudePeer.epsilon']" ]
  [ "$(pyget "$output" '[s["displayName"] for s in g["sessions"]]')" = "['Lead', 'Alpha', 'Beta', 'Gamma', 'Delta', 'Epsilon']" ]
  [ "$(pyget "$output" 'g["sessions"][0]["kind"]')" = "{'kind': 'root'}" ]
  [ "$(pyget "$output" '[s["command"] for s in g["sessions"]]')" = "['', 'claude-peer run --as alpha --wait', 'claude-peer run --as beta --wait', 'claude-peer run --as gamma --wait', 'claude-peer run --as delta --wait', 'claude-peer run --as epsilon --wait']" ]
  # the fixture builtin's root has a third item; nothing is copied from it
  [ "$(pyget "$output" '[i["kind"] for i in g["sessions"][0]["toolbarItems"]]')" = "['modeSwitcher', 'gitStatus']" ]
  [ "$(pyget "$output" '[s["toolbarItems"] for s in g["sessions"][1:]]')" = "[[{'kind': 'modeSwitcher'}], [{'kind': 'modeSwitcher'}], [{'kind': 'modeSwitcher'}], [{'kind': 'modeSwitcher'}], [{'kind': 'modeSwitcher'}]]" ]
  [ "$(pyget "$output" '[s["kind"]["kind"] for s in g["sessions"][1:]]')" = "['peer', 'peer', 'peer', 'peer', 'peer']" ]
  [ "$(pyget "$output" '[s["parentID"] for s in g["sessions"][1:]]')" = "['claudePeer.main', 'claudePeer.main', 'claudePeer.main', 'claudePeer.main', 'claudePeer.main']" ]
  [ "$(pyget "$output" 'any(s["mode"] != "regular" or "profileGUID" in s or s["urlString"] or s["perFileCommand"] or "hermes" in s["command"] for s in g["sessions"])')" = False ]
}

@test "workgroup: reads no store, so none needs to exist" {
  CLAUDE_PEER_PREFS="$BATS_TEST_TMPDIR/absent.plist" run sh "$BIN" workgroup
  [ "$status" -eq 0 ]
  [ "$(pyget "$output" '[s["displayName"] for s in g["sessions"]]')" = "['Lead', 'Alpha', 'Beta', 'Gamma', 'Delta', 'Epsilon']" ]
}

@test "install: Claude Peers + Hermes is the same six under claudePeer.h plus Hermes last" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/prefs.plist"
  CLAUDE_PEER_PREFS="$BATS_TEST_TMPDIR/prefs.plist" sh "$BIN" install >/dev/null
  g=$(groups "$BATS_TEST_TMPDIR/prefs.plist")
  h=$(python3 -I -c 'import json, sys; print(json.dumps(json.loads(sys.argv[1])[2]))' "$g")
  [ "$(pyget "$h" '[g["uniqueIdentifier"], g["name"]]')" = "['claudePeer.h', 'Claude Peers + Hermes']" ]
  [ "$(pyget "$h" '[s["uniqueIdentifier"] for s in g["sessions"]]')" = "['claudePeer.h.main', 'claudePeer.h.alpha', 'claudePeer.h.beta', 'claudePeer.h.gamma', 'claudePeer.h.delta', 'claudePeer.h.epsilon', 'claudePeer.h.hermes']" ]
  [ "$(pyget "$h" '[s["displayName"] for s in g["sessions"]]')" = "['Lead', 'Alpha', 'Beta', 'Gamma', 'Delta', 'Epsilon', 'Hermes']" ]
  [ "$(pyget "$h" 'set(s["parentID"] for s in g["sessions"][1:])')" = "{'claudePeer.h.main'}" ]
  [ "$(pyget "$h" 'g["sessions"][-1]["command"]')" = "claude-peer hermes --wait" ]
  [ "$(pyget "$h" '[s["command"] for s in g["sessions"][1:6]]')" = "['claude-peer run --as alpha --wait', 'claude-peer run --as beta --wait', 'claude-peer run --as gamma --wait', 'claude-peer run --as delta --wait', 'claude-peer run --as epsilon --wait']" ]
  [ "$(pyget "$h" 'g["sessions"][0]["kind"]')" = "{'kind': 'root'}" ]
}

@test "install: refused while iTerm2 runs, the store untouched" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/prefs.plist"
  cp "$BATS_TEST_TMPDIR/prefs.plist" "$BATS_TEST_TMPDIR/before.plist"
  FAKE_PROCS="iTerm2" CLAUDE_PEER_PREFS="$BATS_TEST_TMPDIR/prefs.plist" run sh "$BIN" install
  [ "$status" -eq 1 ]
  [[ "$output" == *"quit iTerm2 first"* ]]
  cmp "$BATS_TEST_TMPDIR/prefs.plist" "$BATS_TEST_TMPDIR/before.plist"
}

@test "install: folder store gains both workgroups after the builtin, which is untouched; a second run replaces them" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/prefs.plist"
  export CLAUDE_PEER_PREFS="$BATS_TEST_TMPDIR/prefs.plist"
  before=$(pyget "$(groups "$CLAUDE_PEER_PREFS")" 'json.dumps(g[0], sort_keys=True)')
  run sh "$BIN" install
  [ "$status" -eq 0 ]
  [[ "$output" == *'"Claude Peers" written and "Claude Peers + Hermes" written in '"$CLAUDE_PEER_PREFS"* ]]
  g=$(groups "$CLAUDE_PEER_PREFS")
  [ "$(pyget "$g" '[x["uniqueIdentifier"] for x in g]')" = "['builtin.claudeCode', 'claudePeer.workgroup', 'claudePeer.h']" ]
  [ "$(pyget "$g" 'json.dumps(g[0], sort_keys=True)')" = "$before" ]
  grep -q '<?xml' "$CLAUDE_PEER_PREFS"
  [ "$(python3 -I -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["Ponies"])' "$CLAUDE_PEER_PREFS")" = sentinel ]
  run sh "$BIN" install
  [ "$status" -eq 0 ]
  [[ "$output" == *'"Claude Peers" replaced and "Claude Peers + Hermes" replaced'* ]]
  [ "$(pyget "$(groups "$CLAUDE_PEER_PREFS")" 'len(g)')" = 3 ]
  # a binary plist stays binary
  mkprefs "$BATS_TEST_TMPDIR/bin.plist" binary
  CLAUDE_PEER_PREFS="$BATS_TEST_TMPDIR/bin.plist" run sh "$BIN" install
  [ "$status" -eq 0 ]
  [ "$(head -c 6 "$BATS_TEST_TMPDIR/bin.plist")" = bplist ]
}

@test "install: domain store is exported, edited and imported back" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/domain.plist"
  export FAKE_DOMAIN="$BATS_TEST_TMPDIR/domain.plist" FAKE_LOAD=0
  run sh "$BIN" install
  [ "$status" -eq 0 ]
  [[ "$output" == *"written in the com.googlecode.iterm2 domain"* ]]
  [ "$(pyget "$(groups "$FAKE_DOMAIN")" '[x["uniqueIdentifier"] for x in g]')" = "['builtin.claudeCode', 'claudePeer.workgroup', 'claudePeer.h']" ]
}

@test "install: a Workgroups value that is not JSON is refused, nothing written" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/prefs.plist" junk
  cp "$BATS_TEST_TMPDIR/prefs.plist" "$BATS_TEST_TMPDIR/before.plist"
  CLAUDE_PEER_PREFS="$BATS_TEST_TMPDIR/prefs.plist" run sh "$BIN" install
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a JSON list"* ]]
  cmp "$BATS_TEST_TMPDIR/prefs.plist" "$BATS_TEST_TMPDIR/before.plist"
}

@test "status: store, iTerm2, workgroup and hermes lines, no builtin line; off macOS it refuses" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/domain.plist"
  mkdir "$BATS_TEST_TMPDIR/prefsdir"
  mkprefs "$BATS_TEST_TMPDIR/prefsdir/com.googlecode.iterm2.plist"
  export FAKE_DOMAIN="$BATS_TEST_TMPDIR/domain.plist" FAKE_LOAD=1 FAKE_FOLDER="$BATS_TEST_TMPDIR/prefsdir"
  run sh "$BIN" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"store: folder $BATS_TEST_TMPDIR/prefsdir/com.googlecode.iterm2.plist"* ]]
  [[ "$output" == *"iterm2: not running (install allowed)"* ]]
  [[ "$output" == *"workgroup: not installed"* ]]
  [[ "$output" == *"hermes: not installed"* ]]
  [[ "$output" != *"builtin:"* ]]
  FAKE_PROCS=iTerm2 run sh "$BIN" status
  [[ "$output" == *"iterm2: running"* ]]
  sh "$BIN" install >/dev/null
  run sh "$BIN" status
  [[ "$output" == *"workgroup: installed (6 sessions: Lead, Alpha, Beta, Gamma, Delta, Epsilon)"* ]]
  [[ "$output" == *"hermes: installed (7 sessions: Lead, Alpha, Beta, Gamma, Delta, Epsilon, Hermes)"* ]]
  FAKE_OS=Linux run sh "$BIN" status
  [[ "$output" == *"status needs macOS"* ]]
  FAKE_OS=Linux run sh "$BIN" install
  [ "$status" -eq 2 ]
}

@test "status: the six-session definition of v3 says out of date and hermes not installed; install clears both" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/domain.plist"
  export FAKE_DOMAIN="$BATS_TEST_TMPDIR/domain.plist"
  python3 -I - "$FAKE_DOMAIN" <<'PY'
import json, plistlib, sys
pl = plistlib.load(open(sys.argv[1], "rb"))
groups = json.loads(pl["Workgroups"])
names = ["Chat", "Diff", "Chat 2", "Chat 3", "Chat 4", "Hermes"]
groups.append({"uniqueIdentifier": "claudePeer.workgroup", "name": "Claude Peers", "sessions": [
    {"uniqueIdentifier": "claudePeer.s%d" % i, "displayName": n, "command": "claude-peer run"}
    for i, n in enumerate(names)]})
pl["Workgroups"] = json.dumps(groups).encode()
plistlib.dump(pl, open(sys.argv[1], "wb"))
PY
  run sh "$BIN" status
  [[ "$output" == *"workgroup: installed, out of date (6 sessions: Chat, Diff, Chat 2, Chat 3, Chat 4, Hermes); this version defines 6 (Lead, Alpha, Beta, Gamma, Delta, Epsilon)"* ]]
  [[ "$output" == *"hermes: not installed"* ]]
  CLAUDE_PEER_PREFS="$FAKE_DOMAIN" sh "$BIN" install >/dev/null
  run sh "$BIN" status
  [[ "$output" == *"workgroup: installed (6 sessions: "* ]]
  [[ "$output" == *"hermes: installed (7 sessions: "* ]]
  [[ "$output" != *"out of date"* ]]
}

@test "status: reads the store that is true: the folder while iTerm2 is quit, the domain while it runs" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/domain.plist"
  mkdir "$BATS_TEST_TMPDIR/prefsdir"
  mkprefs "$BATS_TEST_TMPDIR/prefsdir/com.googlecode.iterm2.plist"
  export FAKE_DOMAIN="$BATS_TEST_TMPDIR/domain.plist" FAKE_LOAD=1 FAKE_FOLDER="$BATS_TEST_TMPDIR/prefsdir"
  # install into the folder with iTerm2 quit; the domain stays as it was
  sh "$BIN" install >/dev/null
  run sh "$BIN" status
  [[ "$output" == *"workgroup: installed (6 sessions: Lead, Alpha, Beta, Gamma, Delta, Epsilon)"* ]]
  FAKE_PROCS=iTerm2 run sh "$BIN" status
  [[ "$output" == *"workgroup: not installed"* ]]
  [[ "$output" == *"hermes: not installed"* ]]
}

# --- hermes ----------------------------------------------------------------------

@test "hermes: execs an interactive shell that runs hermes_peer, with or without a repository" {
  run sh "$BIN" hermes
  [ "$status" -eq 0 ]
  [[ "$output" == *'args=-i -c '*'hermes_peer "$@"'*'exec "${SHELL:-/bin/sh}" -i'*' claude-peer' ]]
  [[ "$output" == *"peer=unset"* ]]
  run sh "$BIN" hermes -- --foo
  [ "$status" -eq 0 ]
  [[ "$output" == *' claude-peer --foo' ]]
  mkdir "$BATS_TEST_TMPDIR/norepo"
  cd "$BATS_TEST_TMPDIR/norepo"
  run sh "$BIN" hermes
  [ "$status" -eq 0 ]
  [[ "$output" == *"hermes_peer"* ]]
  [ -z "$(find "$REPO/.git" -name claude-peer.claim)" ]
}

@test "hermes: a stray argument without -- is a usage error; the settle delay applies" {
  run sh "$BIN" hermes --foo
  [ "$status" -eq 2 ]
  cat >"$BATS_TEST_TMPDIR/bin/sleep" <<'STUB'
#!/bin/sh
echo "$*" >>"$SLEEP_LOG"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/sleep"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" SLEEP_LOG="$BATS_TEST_TMPDIR/sleep.log"
  CLAUDE_PEER_SETTLE=3 sh "$BIN" hermes >/dev/null
  [ "$(cat "$SLEEP_LOG")" = 3 ]
}

@test "hermes: the snippet runs hermes_peer when defined and says so when not" {
  # run the real snippet under sh, standing in for the login shell
  real_sh=$(command -v sh)
  cat >"$BATS_TEST_TMPDIR/bin/fakeshell" <<STUB
#!/bin/sh
[ "\${2-}" = -c ] || { echo interactive; exit 0; }
snippet=\$3; shift 3
exec $real_sh -c "\$snippet" "\$@"
STUB
  run sh "$BIN" hermes
  [[ "$output" == *"hermes_peer is not defined in this shell; plain shell (chezmoi apply)"* ]]
  [[ "$output" == *"interactive"* ]]
}

# --- default --------------------------------------------------------------------

# addprofiles <path>: two profiles whose Enter Workgroup trigger aims at the
# builtin, plus a third whose trigger enters some other workgroup.
addprofiles() {
  python3 -I - "$1" <<'PY'
import plistlib, sys
p = sys.argv[1]
raw = open(p, "rb").read()
pl = plistlib.loads(raw)
def prof(name, param):
    return {"Name": name, "Triggers": [
        {"action": "iTermEnterWorkgroupTrigger", "regex": "", "parameter": param},
        {"action": "iTermExitWorkgroupTrigger", "regex": "", "parameter": ""}]}
pl["New Bookmarks"] = [prof("One", "builtin.claudeCode"), prof("Two", "builtin.claudeCode"),
                       prof("Other", "someone.else")]
open(p, "wb").write(plistlib.dumps(pl, fmt=plistlib.FMT_BINARY if raw.startswith(b"bplist") else plistlib.FMT_XML))
PY
}

# params <path>: each profile's Enter Workgroup triggers as name:parameter:state
# (j = the job trigger, v = a variable trigger; * = disabled), space separated
params() {
  python3 -I -c '
import plistlib, sys
pl = plistlib.load(open(sys.argv[1], "rb"))
out = []
for b in pl["New Bookmarks"]:
    for t in b["Triggers"]:
        if t["action"] == "iTermEnterWorkgroupTrigger":
            v = "variableName" in (t.get("eventParams") or {})
            out.append("%s:%s:%s%s" % (b["Name"], t["parameter"], "v" if v else "j", "*" if t.get("disabled") else ""))
print(" ".join(out))' "$1"
}

enter_file() { echo "$XDG_STATE_HOME/claude-peer/enter"; }

@test "default: peers disables the job trigger and adds one variable trigger per workgroup; builtin restores the starting state" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/prefs.plist"
  addprofiles "$BATS_TEST_TMPDIR/prefs.plist"
  export CLAUDE_PEER_PREFS="$BATS_TEST_TMPDIR/prefs.plist"
  before=$(params "$CLAUDE_PEER_PREFS")
  sh "$BIN" install >/dev/null
  [ ! -e "$(enter_file)" ]
  run sh "$BIN" default peers
  [ "$status" -eq 0 ]
  [[ "$output" == *"picks the workgroup of each tab"*"2 of 2 profiles changed"* ]]
  [ "$(cat "$(enter_file)")" = peers ]
  [ "$(params "$CLAUDE_PEER_PREFS")" = "One:builtin.claudeCode:j* One:claudePeer.workgroup:v One:claudePeer.h:v Two:builtin.claudeCode:j* Two:claudePeer.workgroup:v Two:claudePeer.h:v Other:someone.else:j" ]
  # the trigger as iTerm2 holds it (L9)
  python3 -I - "$CLAUDE_PEER_PREFS" <<'PY'
import plistlib, sys
pl = plistlib.load(open(sys.argv[1], "rb"))
vs = [t for b in pl["New Bookmarks"][:1] for t in b["Triggers"] if "eventParams" in t]
assert vs[0] == {"action": "iTermEnterWorkgroupTrigger", "matchType": 115, "parameter": "claudePeer.workgroup",
    "eventParams": {"variableName": "user.claudePeerEnter", "variableValueRegex": "^base:"},
    "disabled": 0, "regex": "", "contentregex": "", "partial": False}, vs[0]
assert vs[1]["eventParams"]["variableValueRegex"] == "^base/hermes:", vs[1]
assert pl["Ponies"] == "sentinel"
PY
  run sh "$BIN" default peers
  [[ "$output" == *"0 of 2 profiles changed"* ]]
  [ "$(params "$CLAUDE_PEER_PREFS" | wc -w)" -eq 7 ]
  run sh "$BIN" default builtin
  [ "$status" -eq 0 ]
  [ ! -e "$(enter_file)" ]
  [ "$(params "$CLAUDE_PEER_PREFS")" = "$before" ]
}

@test "default: a trigger it did not write survives both directions, and a job trigger left at Claude Peers by the old default goes back to the builtin" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/prefs.plist"
  addprofiles "$BATS_TEST_TMPDIR/prefs.plist"
  export CLAUDE_PEER_PREFS="$BATS_TEST_TMPDIR/prefs.plist"
  python3 -I - "$CLAUDE_PEER_PREFS" <<'PY'
import plistlib, sys
p = sys.argv[1]; pl = plistlib.load(open(p, "rb"))
pl["New Bookmarks"][0]["Triggers"].append({"action": "iTermEnterWorkgroupTrigger", "matchType": 115, "parameter": "someone.else",
    "eventParams": {"variableName": "user.somethingElse", "variableValueRegex": "^x"}, "disabled": 0, "regex": ""})
pl["New Bookmarks"][1]["Triggers"][0]["parameter"] = "claudePeer.workgroup"
plistlib.dump(pl, open(p, "wb"))
PY
  sh "$BIN" install >/dev/null
  sh "$BIN" default peers >/dev/null
  [[ "$(params "$CLAUDE_PEER_PREFS")" == *"One:someone.else:v "* ]]
  sh "$BIN" default builtin >/dev/null
  [ "$(params "$CLAUDE_PEER_PREFS")" = "One:builtin.claudeCode:j One:someone.else:v Two:builtin.claudeCode:j Other:someone.else:j" ]
}

@test "install: with the enter file present it adds the trigger of a new workgroup and removes that of a pruned one" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/prefs.plist"
  addprofiles "$BATS_TEST_TMPDIR/prefs.plist"
  export CLAUDE_PEER_PREFS="$BATS_TEST_TMPDIR/prefs.plist"
  sh "$BIN" install >/dev/null
  sh "$BIN" default peers >/dev/null
  python3 -I - "$CLAUDE_PEER_PREFS" <<'PY'
import json, plistlib, sys
p = sys.argv[1]; pl = plistlib.load(open(p, "rb"))
g = json.loads(pl["Workgroups"])
g.append({"uniqueIdentifier": "claudePeer.v.web", "name": "Claude Peers: web", "sessions": []})
g = [x for x in g if x["uniqueIdentifier"] != "claudePeer.h"]
pl["Workgroups"] = json.dumps(g).encode()
plistlib.dump(pl, open(p, "wb"))
PY
  python3 -I - "$CLAUDE_PEER_PREFS" <<'PY'
import plistlib, sys
p = sys.argv[1]; pl = plistlib.load(open(p, "rb"))
for b in pl["New Bookmarks"]:
    b["Triggers"] = [t for t in b["Triggers"] if (t.get("eventParams") or {}).get("variableValueRegex") != "^base/hermes:"] + [
        {"action": "iTermEnterWorkgroupTrigger", "matchType": 115, "parameter": "claudePeer.gone",
         "eventParams": {"variableName": "user.claudePeerEnter", "variableValueRegex": "^gone:"}, "disabled": 0, "regex": ""}] if b["Name"] != "Other" else b["Triggers"]
plistlib.dump(pl, open(p, "wb"))
PY
  run sh "$BIN" install
  [ "$status" -eq 0 ]
  [[ "$output" == *"variable triggers changed in 2 profiles"* ]]
  [ "$(params "$CLAUDE_PEER_PREFS")" = "One:builtin.claudeCode:j* One:claudePeer.workgroup:v One:claudePeer.v.web:v One:claudePeer.h:v Two:builtin.claudeCode:j* Two:claudePeer.workgroup:v Two:claudePeer.v.web:v Two:claudePeer.h:v Other:someone.else:j" ]
}

@test "install: without the enter file it touches no trigger" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/prefs.plist"
  addprofiles "$BATS_TEST_TMPDIR/prefs.plist"
  export CLAUDE_PEER_PREFS="$BATS_TEST_TMPDIR/prefs.plist"
  before=$(params "$CLAUDE_PEER_PREFS")
  run sh "$BIN" install
  [[ "$output" != *"variable triggers"* ]]
  [ "$(params "$CLAUDE_PEER_PREFS")" = "$before" ]
}

@test "default: refused while iTerm2 runs, before install, without triggers, or with a bad argument" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/prefs.plist"
  addprofiles "$BATS_TEST_TMPDIR/prefs.plist"
  cp "$BATS_TEST_TMPDIR/prefs.plist" "$BATS_TEST_TMPDIR/before.plist"
  export CLAUDE_PEER_PREFS="$BATS_TEST_TMPDIR/prefs.plist"
  FAKE_PROCS="iTerm2" run sh "$BIN" default peers
  [ "$status" -eq 1 ]; [[ "$output" == *"quit iTerm2 first"* ]]
  run sh "$BIN" default peers
  [ "$status" -eq 1 ]; [[ "$output" == *"not installed"* ]]
  cmp "$BATS_TEST_TMPDIR/prefs.plist" "$BATS_TEST_TMPDIR/before.plist"
  [ ! -e "$(enter_file)" ]
  run sh "$BIN" default sideways
  [ "$status" -eq 2 ]
  mkprefs "$BATS_TEST_TMPDIR/bare.plist"
  CLAUDE_PEER_PREFS="$BATS_TEST_TMPDIR/bare.plist" run sh "$BIN" default builtin
  [ "$status" -eq 1 ]; [[ "$output" == *"no profile has an Enter Workgroup trigger"* ]]
}

@test "here: prints the key for the base workgroup" {
  run sh "$BIN" here
  [ "$status" -eq 0 ]
  [ "$output" = base ]
  run sh "$BIN" here extra
  [ "$status" -eq 2 ]
}

@test "status: the default line reads builtin, peers or mixed from the profiles, and says when the enter file disagrees" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/domain.plist"
  addprofiles "$BATS_TEST_TMPDIR/domain.plist"
  export FAKE_DOMAIN="$BATS_TEST_TMPDIR/domain.plist" FAKE_LOAD=0
  run sh "$BIN" status
  [[ "$output" == *"default: builtin (2 profiles enter Claude Code)"* ]]
  [[ "$output" != *"enter file"* ]]
  sh "$BIN" install >/dev/null
  sh "$BIN" default peers >/dev/null
  run sh "$BIN" status
  [[ "$output" == *"default: peers (2 profiles, 2 workgroups by variable)"* ]]
  [[ "$output" != *"enter file"* ]]
  rm "$(enter_file)"
  run sh "$BIN" status
  [[ "$output" == *"the triggers say peers but the enter file is missing"* ]]
  printf 'peers\n' >"$(enter_file)"
  python3 -I - "$FAKE_DOMAIN" <<'PY'
import plistlib, sys
p = sys.argv[1]; pl = plistlib.load(open(p, "rb"))
pl["New Bookmarks"][0]["Triggers"][0]["disabled"] = 0
plistlib.dump(pl, open(p, "wb"))
PY
  run sh "$BIN" status
  [[ "$output" == *"default: mixed (1 of 2 profiles enter by variable)"* ]]
}

# --- contexts -----------------------------------------------------------------

ctxfix() { # three fixture repositories and a context tree
  export CLAUDE_PEER_CONTEXTS="$BATS_TEST_TMPDIR/ctx"
  git remote add origin git@example.invalid:octo/proj.git
  mkdir -p "$BATS_TEST_TMPDIR/other" "$BATS_TEST_TMPDIR/bare"
  git -C "$BATS_TEST_TMPDIR/other" init -q
  git -C "$BATS_TEST_TMPDIR/other" remote add origin https://example.invalid/Octo/Other
  git -C "$BATS_TEST_TMPDIR/bare" init -q
  mkdir -p "$CLAUDE_PEER_CONTEXTS/octo/proj" "$CLAUDE_PEER_CONTEXTS/octo/other"
  printf 'title: Greet\nask: Who\nmodel: sonnet\neffort: low\nsystem: be brief\n\nHello {input}, again {input}.\nKeep {owner}.\n\n\n' >"$CLAUDE_PEER_CONTEXTS/20-greet.ctx"
  printf 'title: Plain\n\nJust this.\n' >"$CLAUDE_PEER_CONTEXTS/10-plain.ctx"
  printf 'title: Owner level\n\nowner\n' >"$CLAUDE_PEER_CONTEXTS/octo/30-mine.ctx"
  printf 'title: Greet for octo\nagent: plan-fable\nmode: continue\n\nowner greet\n' >"$CLAUDE_PEER_CONTEXTS/octo/05-greet.ctx"
  printf 'title: Deploy proj\n\nproj\n' >"$CLAUDE_PEER_CONTEXTS/octo/proj/10-deploy.ctx"
  printf 'title: Deploy other\n\nother\n' >"$CLAUDE_PEER_CONTEXTS/octo/other/10-deploy.ctx"
}

names() { printf '%s\n' "$output" | cut -f1 | tr '\n' ' '; }

@test "context list: the three levels in order, a deeper same-name file replaces and takes the later place" {
  ctxfix
  run sh "$BIN" context list
  [ "$status" -eq 0 ]
  [ "$(names)" = "plain greet mine deploy " ]
  [[ "$output" == *"greet"$'\t'"Greet for octo"$'\t'"-"$'\t'"agent=plan-fable mode=continue"$'\t'"$CLAUDE_PEER_CONTEXTS/octo/05-greet.ctx"* ]]
  [[ "$output" == *"deploy"$'\t'"Deploy proj"* ]]
}

@test "context list: a capitalised origin folds, another repository's directory is never read, a linked worktree gives its leader's rows" {
  ctxfix
  cd "$BATS_TEST_TMPDIR/other"
  run sh "$BIN" context list
  [ "$(names)" = "plain greet mine deploy " ]
  [[ "$output" == *"Deploy other"* ]]
  [[ "$output" != *"Deploy proj"* ]]
  cd "$REPO"
  sh "$BIN" context list >"$BATS_TEST_TMPDIR/main.rows"
  git worktree add -q "$REPO/.claude/worktrees/alpha" -b alpha
  cd "$REPO/.claude/worktrees/alpha"
  run sh "$BIN" context list
  [ "$output" = "$(cat "$BATS_TEST_TMPDIR/main.rows")" ]
}

@test "context list: no origin reads the top level only with a silent stderr; a missing root is empty and exit 0" {
  ctxfix
  cd "$BATS_TEST_TMPDIR/bare"
  run --separate-stderr sh "$BIN" context list
  [ "$status" -eq 0 ]
  [ "$(names)" = "plain greet " ]
  [ -z "$stderr" ]
  CLAUDE_PEER_CONTEXTS="$BATS_TEST_TMPDIR/none" run --separate-stderr sh "$BIN" context list
  [ "$status" -eq 0 ]
  [ -z "$output$stderr" ]
}

@test "context list: an origin without owner/repo reads the top level and says so once" {
  ctxfix
  git remote set-url origin 'host:../../etc'
  run --separate-stderr sh "$BIN" context list
  [ "$status" -eq 0 ]
  [ "$(names)" = "plain greet " ]
  [ "$stderr" = "claude-peer: origin 'host:../../etc' gives no owner/repo; only the general contexts apply" ]
}

@test "context list --all: every file once, no override; an invalid file is skipped with a stderr line" {
  ctxfix
  printf 'title: Bad\nrepo: octo/proj\n\nx\n' >"$CLAUDE_PEER_CONTEXTS/40-bad.ctx"
  printf 'title: Not a context\n' >"$CLAUDE_PEER_CONTEXTS/notes.txt"
  printf 'title: Bad name\n\nx\n' >"$CLAUDE_PEER_CONTEXTS/Bad.ctx"
  run --separate-stderr sh "$BIN" context list --all
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 6 ]
  [ "$(printf '%s\n' "$output" | grep -c "	greet	\|^greet	")" -eq 2 ]
  [ "$stderr" = "claude-peer: $CLAUDE_PEER_CONTEXTS/40-bad.ctx: repo: is not a key (a per-repository context goes in <owner>/<repo>/)" ]
}

@test "context list: an invalid file is left out with a stderr line" {
  ctxfix
  printf 'title: Bad\nmodel: --evil\n\nx\n' >"$CLAUDE_PEER_CONTEXTS/40-bad.ctx"
  run --separate-stderr sh "$BIN" context list
  [ "$(names)" = "plain greet mine deploy " ]
  [[ "$stderr" == *"40-bad.ctx: model: '--evil' is not a plain value" ]]
}

@test "context show: header, scope, flags in start's order, and the prompt with the value substituted everywhere" {
  ctxfix
  run sh "$BIN" context show plain
  [ "$status" -eq 0 ]
  [ "$output" = "plain — Plain"$'\n'"file: $CLAUDE_PEER_CONTEXTS/10-plain.ctx"$'\n'"scope: everywhere"$'\n\n'"Just this." ]
  run sh "$BIN" context show deploy
  [[ "$output" == *"scope: octo/proj"* ]]
  run sh "$BIN" context show mine
  [[ "$output" == *"scope: octo"$'\n'* ]]
  run sh "$BIN" context show greet w
  [[ "$output" == *$'flag: --continue\nflag: --agent plan-fable\n\nowner greet'* ]]
  cd "$BATS_TEST_TMPDIR/bare"
  run sh "$BIN" context show greet w
  [[ "$output" == *$'asks: Who\nflag: --model sonnet\nflag: --effort low\nflag: --append-system-prompt be brief\n\nHello w, again w.'* ]]
  cd "$REPO"
  run sh "$BIN" context show 20-greet
  [ "$status" -eq 1 ]
  [[ "$output" == *"no context '20-greet' here (claude-peer context list)"* ]]
}

@test "context show: the value arrives byte for byte; {owner} is left alone; a body without {input} gets it appended; no value leaves {input} visible" {
  ctxfix
  rm "$CLAUDE_PEER_CONTEXTS/octo/05-greet.ctx"
  v=$'a & b \\1 \\n "q" \'s\'\nline two'
  run sh "$BIN" context show greet "$v"
  [ "$status" -eq 0 ]
  want="Hello $v, again $v."$'\n'"Keep {owner}."
  [[ "$output" == *$'\n\n'"$want" ]]
  [ "${output##*$'\n\n'}" = "$want" ]
  run sh "$BIN" context show greet
  [[ "$output" == *"Hello {input}, again {input}."* ]]
  run sh "$BIN" context show plain extra words
  [[ "$output" == *$'\n\nJust this.\n\nextra words' ]]
}

@test "context show: @ names describe the built-in rows; an invalid file fails with its reason" {
  ctxfix
  run sh "$BIN" context show @resume
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "@resume — Resume a session" ]
  [ "${#lines[@]}" -eq 2 ]
  printf 'title: Bad\nrepo: octo/proj\n\nx\n' >"$CLAUDE_PEER_CONTEXTS/octo/proj/20-bad.ctx"
  run --separate-stderr sh "$BIN" context show bad
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"repo: is not a key (a per-repository context goes in <owner>/<repo>/)" ]]
  printf 'title: Bad\nbogus: 1\n\nx\n' >"$CLAUDE_PEER_CONTEXTS/octo/proj/20-bad.ctx"
  run --separate-stderr sh "$BIN" context show bad
  [[ "$stderr" == *"unknown key 'bogus'" ]]
  printf 'title: Bad\nmode: sideways\n\nx\n' >"$CLAUDE_PEER_CONTEXTS/octo/proj/20-bad.ctx"
  run --separate-stderr sh "$BIN" context show bad
  [ "$status" -eq 1 ]
  printf 'title Bad\n\nx\n' >"$CLAUDE_PEER_CONTEXTS/octo/proj/20-bad.ctx"
  run --separate-stderr sh "$BIN" context show bad
  [[ "$stderr" == *"header line without ': ': title Bad" ]]
}

@test "context dir: the root, and with --repo the repository's directory; no origin is exit 1" {
  ctxfix
  run sh "$BIN" context dir
  [ "$output" = "$CLAUDE_PEER_CONTEXTS" ]
  run sh "$BIN" context dir --repo
  [ "$status" -eq 0 ]
  [ "$output" = "$CLAUDE_PEER_CONTEXTS/octo/proj" ]
  run sh "$BIN" context dir --repo "$BATS_TEST_TMPDIR/other"
  [ "$output" = "$CLAUDE_PEER_CONTEXTS/octo/other" ]
  run sh "$BIN" context dir --repo "$BATS_TEST_TMPDIR/bare"
  [ "$status" -eq 1 ]
  [[ "$output" == *"this repository has no origin remote, so it has no context directory" ]]
}

@test "context: the root defaults under XDG_CONFIG_HOME, else HOME/.config" {
  run sh "$BIN" context dir
  [ "$output" = "$HOME/.config/claude-peer/contexts" ]
  XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg" run sh "$BIN" context dir
  [ "$output" = "$BATS_TEST_TMPDIR/xdg/claude-peer/contexts" ]
}

@test "context: the shipped catalogue lists seven rows, shows the value last, keeps {owner}, and audit carries its system line" {
  export CLAUDE_PEER_CONTEXTS="$BATS_TEST_DIRNAME/../dot_config/claude-peer/contexts"
  run --separate-stderr sh "$BIN" context list --all
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 7 ]
  [ -z "$stderr" ]
  run sh "$BIN" context show prs 12 13
  [[ "$output" == *"12 13" ]]
  [[ "$output" == *"repos/{owner}/{repo}/rules/branches/"* ]]
  run sh "$BIN" context show audit
  [[ "$output" == *"flag: --append-system-prompt"* ]]
}

# --- start --context ---------------------------------------------------------------

# hello: every flag a context can set, and a body that takes the value
hellofix() {
  ctxfix
  printf 'title: Hello\nask: Who\nagent: plan-fable\nmodel: sonnet\neffort: low\nsystem: be brief\n\nHello {input}.\n' >"$CLAUDE_PEER_CONTEXTS/30-hello.ctx"
  printf 'title: Say\n\nSay: {input}!\n' >"$CLAUDE_PEER_CONTEXTS/40-say.ctx"
}

@test "start --context: the flags go in the fixed order before the prompt, the claim has ten lines, the pane says who and what" {
  hellofix
  FAKE_SHELL_SLEEP=2 pane alpha
  run sh "$BIN" start alpha --context hello World
  [ "$status" -eq 0 ]
  until_ok 'grep -q "claude-peer proj-alpha --agent plan-fable --model sonnet --effort low --append-system-prompt be brief Hello World\.\$" "$FAKE_SHELL_LOG"'
  cl=$(claim_of "$REPO/.claude/worktrees/alpha")
  [ "$(wc -l <"$cl" | tr -d ' ')" -eq 10 ]
  [ "$(sed -n 4p "$cl")" = Lead ]
  [ "$(sed -n 5p "$cl")" = hello ]
  [ "$(sed -n 6p "$cl")" = "hello: World" ]
  [[ "$(sed -n 7p "$cl")" =~ ^[0-9]+$ ]]
  run sh "$BIN" peers
  [ "$(printf '%s' "$output" | awk -F'\t' '{ print NF }')" -eq 4 ]
  grep -qx "Alpha · started by Lead · hello: World" "$BATS_TEST_TMPDIR/pane-alpha.out"
  until_ok '[ "$(sh "$BIN" slots | cut -f2)" = waiting ]'
  [ ! -e "$REPO/.git/claude-peer.wait/alpha.$LAST_PANE.meta" ]
}

@test "start --context: a multi-line value from stdin arrives byte for byte inside the prompt; a plain start still names its prompt" {
  hellofix
  FAKE_SHELL_SLEEP=2 FAKE_SHELL_LAST="$BATS_TEST_TMPDIR/last" pane alpha
  want=$'a & \\ "q" $HOME\nsecond line'
  run sh -c 'printf "%s" "$1" | sh "$2" start alpha --context say -' _ "$want" "$BIN"
  [ "$status" -eq 0 ]
  until_ok '[ -s "$BATS_TEST_TMPDIR/last.n" ]'
  [ "$(cat "$BATS_TEST_TMPDIR/last")" = "Say: $want!" ]
  [ "$(cat "$BATS_TEST_TMPDIR/last.n")" -eq 6 ]
  until_ok '[ "$(sh "$BIN" slots | cut -f2)" = waiting ]'
  run sh "$BIN" start alpha fix the thing
  [ "$status" -eq 0 ]
  until_ok 'grep -qx "Alpha · started by Lead · fix the thing" "$BATS_TEST_TMPDIR/pane-alpha.out"'
}

@test "start --context: a context with mode continue puts --continue first" {
  hellofix
  FAKE_SHELL_SLEEP=2 pane alpha
  run sh "$BIN" start alpha --context greet
  [ "$status" -eq 0 ]
  until_ok 'grep -q "claude-peer proj-alpha --continue --agent plan-fable owner greet\$" "$FAKE_SHELL_LOG"'
}

@test "start --context: --continue with it is 2, an unknown context 1, a missing value 2; none wakes the pane" {
  hellofix
  pane alpha
  run sh "$BIN" start alpha --continue --context hello World
  [ "$status" -eq 2 ]
  run sh "$BIN" start alpha --context nope World
  [ "$status" -eq 1 ]
  [[ "$output" == *"no context 'nope' here"* ]]
  run sh "$BIN" start alpha --context hello
  [ "$status" -eq 2 ]
  [[ "$output" == *"context hello needs a value: Who"* ]]
  [ "$(shell_runs)" -eq 0 ]
  [ "$(sh "$BIN" slots | cut -f2)" = waiting ]
  [ ! -e "$REPO/.git/claude-peer.wait/alpha.$LAST_PANE.start" ]
  [ ! -e "$REPO/.git/claude-peer.wait/alpha.$LAST_PANE.meta" ]
}

@test "start --context: a pane whose wait file has no line 2 predates contexts, exit 4; a plain start still works" {
  hellofix
  FAKE_SHELL_SLEEP=2 pane alpha
  printf '%s\n' "$REPO" >"$REPO/.git/claude-peer.wait/alpha.$LAST_PANE"
  run sh "$BIN" start alpha --context hello World
  [ "$status" -eq 4 ]
  [[ "$output" == *"the waiting pane (pid $LAST_PANE) predates contexts; reopen its tab"* ]]
  [ "$(shell_runs)" -eq 0 ]
  run sh "$BIN" start alpha fix it
  [ "$status" -eq 0 ]
}

# --- the picker in the waiting pane -------------------------------------------------

# A stand-in fzf. `--version` prints FAKE_FZF_VERSION and notes the call. Otherwise
# it logs its arguments (one per line) and the FZF_DEFAULT_OPTS it got, keeps the
# rows, counts its calls, and on the first call ends as FAKE_FZF_OUT / FAKE_FZF_RC
# say (after FAKE_FZF_SLEEP seconds when set); a later call waits like a real fzf
# (FAKE_FZF_SLEEP2, default 30) and ends as FAKE_FZF_OUT2 / FAKE_FZF_RC2 (130).
# A TERM while it waits is noted.
fzfstub() {
  mkdir -p "$BATS_TEST_TMPDIR/fzfbin"
  cat >"$BATS_TEST_TMPDIR/fzfbin/fzf" <<'STUB'
#!/bin/sh
if [ "${1-}" = --version ]; then
  echo x >>"$FAKE_FZF_LOG.version"
  echo "${FAKE_FZF_VERSION:-0.75.0 (stub)}"
  exit 0
fi
printf '%s\n' "$@" >"$FAKE_FZF_LOG"
printf '%s\n' "${FZF_DEFAULT_OPTS-unset}" >"$FAKE_FZF_LOG.opts"
echo x >>"$FAKE_FZF_LOG.calls"
cat >"$FAKE_FZF_LOG.rows"
out=${FAKE_FZF_OUT-} rc=${FAKE_FZF_RC-0} sl=${FAKE_FZF_SLEEP-}
if [ "$(wc -l <"$FAKE_FZF_LOG.calls")" -gt 1 ]; then
  out=${FAKE_FZF_OUT2-} rc=${FAKE_FZF_RC2-130} sl=${FAKE_FZF_SLEEP2-30}
fi
if [ -n "$sl" ]; then
  trap 'echo TERM >>"$FAKE_FZF_LOG.term"; kill $sp 2>/dev/null; exit 143' TERM
  sleep "$sl" & sp=$!
  wait $sp
fi
printf '%s' "$out"
exit "$rc"
STUB
  chmod +x "$BATS_TEST_TMPDIR/fzfbin/fzf"
  export PATH="$BATS_TEST_TMPDIR/fzfbin:$PATH"
  export FAKE_FZF_LOG="$BATS_TEST_TMPDIR/fzf.log"
  unset FZF_DEFAULT_OPTS
}

fzf_calls() { [ -f "$FAKE_FZF_LOG.calls" ] && wc -l <"$FAKE_FZF_LOG.calls" | tr -d ' ' || echo 0; }

# typeline <tag> <text>: press, and return once the pane has read the line, so
# the next line cannot overtake it
typeline() { press "$1" "$2"; until_ok "! kill -0 $! 2>/dev/null"; }

# pane_count <tag> <text>: how many times the pane's output has that text (a prompt
# has no newline after it, so lines are not anchored)
pane_count() { grep -oF -- "$2" "$BATS_TEST_TMPDIR/pane-$1.out" | wc -l | tr -d ' '; }

# pane_says <slot-tag> <text>: wait until the pane's output has that text on a line
pane_says() { until_ok "grep -qF -- '$2' '$BATS_TEST_TMPDIR/pane-$1.out'"; }

LISTHINT='c continue · r resume · n task · s task, saved · q shell'

@test "picker list: with no setting and no terminal the list is open at once, titles in one column; one Return is a blank session" {
  hellofix
  git config --global --unset claude-peer.picker
  FAKE_SHELL_SLEEP=2 pane alpha
  pane_says alpha "$LISTHINT"
  o=$BATS_TEST_TMPDIR/pane-alpha.out
  ! grep -q 'Return picks' "$o"
  ! grep -qF ' (asks:' "$o"
  [ "$(grep -E '^ ?[0-9]+  ' "$o" | sed -E 's/^ ?[0-9]+  ([a-z]+) +.*/\1/' | tr '\n' ' ')" = "fresh plain hello say greet mine deploy continue resume task shell " ]
  grep -qx ' 1  fresh     A new session, no prompt' "$o"
  grep -qx ' 3  hello     Hello' "$o"
  grep -qx ' 8  continue  Pick up the last conversation' "$o"
  grep -qx ' 9  resume    Choose an earlier conversation' "$o"
  grep -qx '10  task      Type a task and start it' "$o"
  grep -qx '11  shell     Drop to a shell' "$o"
  typeline alpha ''
  until_ok 'grep -q "claude-peer proj-alpha\$" "$FAKE_SHELL_LOG"'
  cl=$(claim_of "$REPO/.claude/worktrees/alpha")
  [ "$(sed -n 4p "$cl")" = pane ]
  [ "$(sed -n 5p "$cl")" = - ]
}

@test "picker list: a number starts that context and asks for its value; a context name, continue and c work; an empty answer is the list again" {
  hellofix
  git config --global claude-peer.picker list
  FAKE_SHELL_SLEEP=2 pane alpha
  pane_says alpha "$LISTHINT"
  typeline alpha 3
  pane_says alpha 'Who: '
  typeline alpha World
  until_ok 'grep -q "claude-peer proj-alpha --agent plan-fable --model sonnet --effort low --append-system-prompt be brief Hello World\.\$" "$FAKE_SHELL_LOG"'
  cl=$(claim_of "$REPO/.claude/worktrees/alpha")
  [ "$(sed -n 4p "$cl")" = pane ]
  [ "$(sed -n 5p "$cl")" = hello ]
  [ "$(sed -n 6p "$cl")" = "hello: World" ]
  # the session ends: the list is open again
  until_ok '[ "$(sh "$BIN" slots | cut -f2)" = waiting ]'
  until_ok '[ "$(pane_count alpha "$LISTHINT")" -eq 2 ]'
  typeline alpha hello
  typeline alpha ''
  until_ok '[ "$(pane_count alpha "$LISTHINT")" -eq 3 ]'
  typeline alpha hello
  typeline alpha Again
  until_ok 'grep -q "append-system-prompt be brief Hello Again\.\$" "$FAKE_SHELL_LOG"'
  [ "$(shell_runs)" -eq 2 ]
  until_ok '[ "$(sh "$BIN" slots | cut -f2)" = waiting ]'
  typeline alpha nosuch
  typeline alpha continue
  until_ok 'grep -q "claude-peer proj-alpha --continue\$" "$FAKE_SHELL_LOG"'
  until_ok '[ "$(sh "$BIN" slots | cut -f2)" = waiting ]'
  typeline alpha c
  until_ok '[ "$(grep -c "claude-peer proj-alpha --continue\$" "$FAKE_SHELL_LOG")" -eq 2 ]'
}

@test "picker list: r ends the argument list with --resume and nothing after it" {
  hellofix
  git config --global claude-peer.picker list
  FAKE_SHELL_SLEEP=2 FAKE_SHELL_LAST="$BATS_TEST_TMPDIR/last" pane alpha
  pane_says alpha "$LISTHINT"
  typeline alpha r
  until_ok '[ -s "$BATS_TEST_TMPDIR/last.n" ]'
  [ "$(cat "$BATS_TEST_TMPDIR/last")" = --resume ]
  [ "$(cat "$BATS_TEST_TMPDIR/last.n")" -eq 6 ]
  grep -q "claude-peer proj-alpha --resume\$" "$FAKE_SHELL_LOG"
}

@test "picker list: n takes the typed task as the prompt; an empty task and an unknown answer show the list again" {
  hellofix
  git config --global claude-peer.picker list
  FAKE_SHELL_SLEEP=2 FAKE_SHELL_LAST="$BATS_TEST_TMPDIR/last" pane alpha
  pane_says alpha "$LISTHINT"
  typeline alpha zzz
  until_ok '[ "$(pane_count alpha "$LISTHINT")" -eq 2 ]'
  typeline alpha n
  pane_says alpha 'Task: '
  typeline alpha ''
  until_ok '[ "$(pane_count alpha "$LISTHINT")" -eq 3 ]'
  [ "$(shell_runs)" -eq 0 ]
  typeline alpha n
  typeline alpha 'fix the thing'
  until_ok '[ -s "$BATS_TEST_TMPDIR/last.n" ]'
  [ "$(cat "$BATS_TEST_TMPDIR/last")" = "fix the thing" ]
  cl=$(claim_of "$REPO/.claude/worktrees/alpha")
  [ "$(sed -n 4p "$cl")" = pane ]
  [ "$(sed -n 6p "$cl")" = "fix the thing" ]
  # the FIFO echoes no Return, so an answered question and the header share a
  # line here; on a terminal they are two lines
  grep -q 'Task: Alpha · fix the thing$' "$BATS_TEST_TMPDIR/pane-alpha.out"
}

@test "picker list: q, and the number of the shell row, leave a shell and the wait file" {
  hellofix
  git config --global claude-peer.picker list
  pane alpha
  pp=$LAST_PANE
  pane_says alpha "$LISTHINT"
  typeline alpha q
  until_ok '! kill -0 $pp 2>/dev/null'
  grep -qx "pwd=$REPO args=-i" "$FAKE_SHELL_LOG"
  [ -z "$(ls "$REPO/.git/claude-peer.wait")" ]
  pane alpha
  pp=$LAST_PANE
  pane_says alpha "$LISTHINT"
  typeline alpha 11
  until_ok '! kill -0 $pp 2>/dev/null'
  [ "$(grep -cx "pwd=$REPO args=-i" "$FAKE_SHELL_LOG")" -eq 2 ]
  [ -z "$(ls "$REPO/.git/claude-peer.wait")" ]
}

@test "picker list: s saves the task as 90-<name>.ctx for this repository; the same name again, and a bad name, are refused and the task still starts" {
  hellofix
  git config --global claude-peer.picker list
  FAKE_SHELL_SLEEP=2 pane alpha
  pane_says alpha "$LISTHINT"
  typeline alpha s
  typeline alpha 'fix ci please'
  pane_says alpha 'Save as (a name like fix-ci, Return skips): '
  typeline alpha fix-ci
  until_ok 'grep -q "claude-peer proj-alpha fix ci please\$" "$FAKE_SHELL_LOG"'
  f=$CLAUDE_PEER_CONTEXTS/octo/proj/90-fix-ci.ctx
  [ "$(cat "$f")" = $'title: fix ci please\n\nfix ci please' ]
  grep -qF "saved as fix-ci ($f)" "$BATS_TEST_TMPDIR/pane-alpha.out"
  run sh "$BIN" context list
  [[ "$output" == *"fix-ci"$'\t'"fix ci please"* ]]
  until_ok '[ "$(sh "$BIN" slots | cut -f2)" = waiting ]'
  typeline alpha s
  typeline alpha 'second try'
  typeline alpha fix-ci
  until_ok 'grep -q "claude-peer proj-alpha second try\$" "$FAKE_SHELL_LOG"'
  grep -qF "not saved: fix-ci already exists in $CLAUDE_PEER_CONTEXTS/octo/proj" "$BATS_TEST_TMPDIR/pane-alpha.out"
  [ "$(cat "$f")" = $'title: fix ci please\n\nfix ci please' ]
  until_ok '[ "$(sh "$BIN" slots | cut -f2)" = waiting ]'
  # a name another file of the directory already has, and a bad name
  typeline alpha s
  typeline alpha 'third'
  typeline alpha deploy
  until_ok 'grep -q "claude-peer proj-alpha third\$" "$FAKE_SHELL_LOG"'
  grep -qF "not saved: deploy already exists in " "$BATS_TEST_TMPDIR/pane-alpha.out"
  [ ! -e "$CLAUDE_PEER_CONTEXTS/octo/proj/90-deploy.ctx" ]
  until_ok '[ "$(sh "$BIN" slots | cut -f2)" = waiting ]'
  typeline alpha s
  typeline alpha 'fourth'
  typeline alpha 'Bad Name'
  until_ok 'grep -q "claude-peer proj-alpha fourth\$" "$FAKE_SHELL_LOG"'
  grep -qF "not saved: 'Bad Name' is not a name" "$BATS_TEST_TMPDIR/pane-alpha.out"
  [ "$(ls "$CLAUDE_PEER_CONTEXTS/octo/proj" | wc -l | tr -d ' ')" -eq 2 ]
  # a long task: the saved title is its first 40 characters
  until_ok '[ "$(sh "$BIN" slots | cut -f2)" = waiting ]'
  typeline alpha s
  typeline alpha 'a task whose first line runs well past forty characters'
  typeline alpha longone
  until_ok '[ "$(sed -n 1p "$CLAUDE_PEER_CONTEXTS/octo/proj/90-longone.ctx" 2>/dev/null)" = "title: a task whose first line runs well past f" ]'
}

@test "picker list: the same name saved from a pane in one repository and one in another lands in each repository's own directory" {
  hellofix
  git config --global claude-peer.picker list
  git -C "$BATS_TEST_TMPDIR/other" commit -q --allow-empty -m init
  FAKE_SHELL_SLEEP=2 pane alpha
  FAKE_SHELL_SLEEP=2 pane alpha "$BATS_TEST_TMPDIR/other" o
  pane_says alpha "$LISTHINT"
  pane_says o "$LISTHINT"
  typeline alpha s
  typeline o s
  typeline alpha 'in proj'
  typeline o 'in other'
  typeline alpha same
  typeline o same
  until_ok '[ -f "$CLAUDE_PEER_CONTEXTS/octo/proj/90-same.ctx" ] && [ -f "$CLAUDE_PEER_CONTEXTS/octo/other/90-same.ctx" ]'
  until_ok 'grep -q "args=.*in other\$" "$FAKE_SHELL_LOG" && grep -q "args=.*in proj\$" "$FAKE_SHELL_LOG"'
  ! grep -qF 'not saved' "$BATS_TEST_TMPDIR/pane-alpha.out" "$BATS_TEST_TMPDIR/pane-o.out"
  run sh "$BIN" context list
  [[ "$output" == *"same"$'\t'"in proj"* ]]
  [[ "$output" != *"in other"* ]]
  cd "$BATS_TEST_TMPDIR/other"
  run sh "$BIN" context list
  [[ "$output" == *"same"$'\t'"in other"* ]]
  [[ "$output" != *"in proj"* ]]
}

@test "picker list: a save in a repository with no origin says so, asks no name, and the task still starts" {
  hellofix
  git config --global claude-peer.picker list
  git -C "$BATS_TEST_TMPDIR/bare" commit -q --allow-empty -m init
  FAKE_SHELL_SLEEP=2 FAKE_SHELL_LAST="$BATS_TEST_TMPDIR/last" pane alpha "$BATS_TEST_TMPDIR/bare" b
  pane_says b "$LISTHINT"
  typeline b s
  typeline b 'no home for this'
  until_ok '[ -s "$BATS_TEST_TMPDIR/last.n" ]'
  [ "$(cat "$BATS_TEST_TMPDIR/last")" = "no home for this" ]
  grep -qF "not saved: this repository has no origin remote, so it has no context directory" "$BATS_TEST_TMPDIR/pane-b.out"
  ! grep -q 'Save as' "$BATS_TEST_TMPDIR/pane-b.out"
  [ ! -e "$CLAUDE_PEER_CONTEXTS/90-no-home-for-this.ctx" ]
}

@test "picker list: a start from outside interrupts the list and the question after it" {
  hellofix
  git config --global claude-peer.picker list
  FAKE_SHELL_SLEEP=2 FAKE_SHELL_LAST="$BATS_TEST_TMPDIR/last" pane alpha
  pane_says alpha "$LISTHINT"
  CLAUDE_PEER_START_WAIT=10 run sh "$BIN" start alpha first
  [ "$status" -eq 0 ]
  o=$BATS_TEST_TMPDIR/pane-alpha.out
  until_ok 'grep -qx "Alpha · started by Lead · first" "$o"'
  until_ok '[ "$(cat "$BATS_TEST_TMPDIR/last" 2>/dev/null)" = first ]'
  until_ok '[ "$(sh "$BIN" slots | cut -f2)" = waiting ]'
  until_ok '[ "$(pane_count alpha "$LISTHINT")" -eq 2 ]'
  typeline alpha 3
  pane_says alpha 'Who: '
  CLAUDE_PEER_START_WAIT=10 run sh "$BIN" start alpha hello
  [ "$status" -eq 0 ]
  until_ok '[ "$(cat "$BATS_TEST_TMPDIR/last")" = hello ]'
  until_ok 'grep -qx "Alpha · started by Lead · hello" "$o"'
  grep -qx 'Alpha ▸ Who: ' "$o"
  [ "$(grep -c "Preparing worktree" "$o")" -eq 0 ]
  [ "$(grep -cx '' "$o")" -eq 0 ]
}

@test "picker fzf: open with no key pressed, small and flat: the call's flags, the rows in order, and a canned pick starts that context" {
  hellofix
  fzfstub
  git config --global claude-peer.picker fzf
  FAKE_FZF_OUT=$'\n\nhello\thello     Hello\n' FAKE_SHELL_SLEEP=2 pane alpha
  until_ok '[ -f "$FAKE_FZF_LOG.rows" ]'
  ! grep -q 'Return picks' "$BATS_TEST_TMPDIR/pane-alpha.out"
  for a in --expect=ctrl-t,ctrl-s --print-query --no-multi --no-sort --no-mouse --layout=reverse \
      --header-first --info=hidden --no-separator '--delimiter=\t' --with-nth=2 '--prompt=Alpha ▸ ' \
      --height=13 --margin=0,0,0,0 --color=header:-1 '--pointer=▸' '--gutter= '; do
    grep -qxF -- "$a" "$FAKE_FZF_LOG"
  done
  grep -F -- '--header=' "$FAKE_FZF_LOG" | grep -qF 'esc hide'
  grep -F -- '--header=' "$FAKE_FZF_LOG" | grep -qF '^S …and save it'
  ! grep -q -- '--preview' "$FAKE_FZF_LOG"
  ! grep -qxF -- '--height=100%' "$FAKE_FZF_LOG"
  [ "$(cut -f1 "$FAKE_FZF_LOG.rows" | tr '\n' ' ')" = "@fresh plain hello say greet mine deploy @continue @resume @task @shell " ]
  [ "$(sed -n 3p "$FAKE_FZF_LOG.rows")" = $'hello\thello     Hello' ]
  pane_says alpha 'Who: '
  typeline alpha World
  until_ok 'grep -q "append-system-prompt be brief Hello World\.\$" "$FAKE_SHELL_LOG"'
  # the session ends and the picker is open again, with no key pressed
  until_ok '[ "$(fzf_calls)" -eq 2 ]'
  [ "$(shell_runs)" -eq 1 ]
}

# fzfsize <size>: a pane at that CLAUDE_PEER_SIZE; returns once fzf was called
fzfsize() {
  rm -f "$FAKE_FZF_LOG" "$FAKE_FZF_LOG.calls"
  CLAUDE_PEER_SIZE=$1 FAKE_FZF_SLEEP=30 pane alpha
  until_ok '[ -f "$FAKE_FZF_LOG.calls" ]'
  kill "$LAST_PANE"; wait "$LAST_PANE" 2>/dev/null || true
}

@test "picker fzf: centred from 80 columns, at most the pane's height, the short hint under 56" {
  hellofix
  fzfstub
  git config --global claude-peer.picker fzf
  git config --global claude-peer.art false   # C4b's geometry; the sleeper's is tested below
  fzfsize '40 120'
  grep -qxF -- --margin=0,31,0,31 "$FAKE_FZF_LOG"
  grep -qxF -- --height=13 "$FAKE_FZF_LOG"
  fzfsize '40 70'
  grep -qxF -- --margin=0,0,0,0 "$FAKE_FZF_LOG"
  fzfsize '10 120'
  grep -qxF -- --height=10 "$FAKE_FZF_LOG"
  fzfsize '40 50'
  grep -F -- '--header=' "$FAKE_FZF_LOG" | grep -qF 'esc hide'
  ! grep -F -- '--header=' "$FAKE_FZF_LOG" | grep -qF '^S'
}

@test "picker fzf: the short hint under 56 columns, and a block wide enough for the widest row" {
  hellofix
  fzfstub
  git config --global claude-peer.picker fzf
  git config --global claude-peer.art false   # C4b's geometry; the sleeper's is tested below
  fzfsize '40 55'
  [ "$(grep -F -- '--header=' "$FAKE_FZF_LOG" | grep -cF '^S')" -eq 0 ]
  fzfsize '40 56'
  grep -F -- '--header=' "$FAKE_FZF_LOG" | grep -qF '^S …and save it'
  printf 'title: A title that is exactly forty chars long\n\nWide.\n' >"$CLAUDE_PEER_CONTEXTS/50-sixteen-chars-nm.ctx"
  fzfsize '40 120'
  grep -qxF -- --margin=0,30,0,29 "$FAKE_FZF_LOG"
}

@test "picker fzf: only the colour words of FZF_DEFAULT_OPTS reach fzf, and the variable does not" {
  hellofix
  fzfstub
  git config --global claude-peer.picker fzf
  export FZF_DEFAULT_OPTS='--height 40% --border --color=bg:#1a1a1a --color $(id) --preview x'
  FAKE_FZF_SLEEP=30 pane alpha
  until_ok '[ -f "$FAKE_FZF_LOG.calls" ]'
  [ "$(cat "$FAKE_FZF_LOG.opts")" = unset ]
  grep -qxF -- '--color=bg:#1a1a1a' "$FAKE_FZF_LOG"
  ! grep -qxF -- '--border' "$FAKE_FZF_LOG"
  ! grep -q -- '--preview' "$FAKE_FZF_LOG"
  ! grep -qF '$(' "$FAKE_FZF_LOG"
  ! grep -qxF -- '40%' "$FAKE_FZF_LOG"
}

@test "picker fzf: older than 0.75 is the list, said once; list and off never run fzf at all" {
  hellofix
  fzfstub
  git config --global claude-peer.picker fzf
  FAKE_FZF_VERSION='0.44.1 (debian)' pane alpha
  pane_says alpha "$LISTHINT"
  [ "$(pane_count alpha "claude-peer: fzf 0.44.1 is older than 0.75; using the list")" -eq 1 ]
  [ ! -e "$FAKE_FZF_LOG.calls" ]
  [ -s "$FAKE_FZF_LOG.version" ]
  kill "$LAST_PANE"; wait "$LAST_PANE" 2>/dev/null || true
  rm -f "$FAKE_FZF_LOG.version"
  git config --global claude-peer.picker list
  pane alpha
  pane_says alpha "$LISTHINT"
  kill "$LAST_PANE"; wait "$LAST_PANE" 2>/dev/null || true
  git config --global claude-peer.picker off
  pane alpha
  pane_says alpha 'Alpha: Return starts a Claude here'
  [ ! -e "$FAKE_FZF_LOG.version" ]
  [ ! -e "$FAKE_FZF_LOG.calls" ]
}

@test "picker fzf: Esc (130), an empty exit 0 and an empty exit 1 go quiet and stay there; Return opens the picker again" {
  hellofix
  fzfstub
  git config --global claude-peer.picker fzf
  for o in 'FAKE_FZF_RC=130' 'FAKE_FZF_RC=0' "FAKE_FZF_RC=1 FAKE_FZF_OUT=$'\n\n'"; do
    rm -f "$FAKE_FZF_LOG.calls"
    eval "$o pane alpha"
    pane_says alpha 'Alpha: Return picks a context, c continues the last session, q leaves a shell'
    sleep 2
    [ "$(fzf_calls)" -eq 1 ]
    [ "$(pane_count alpha "Alpha: Return picks")" -eq 1 ]
    typeline alpha ''
    until_ok '[ "$(fzf_calls)" -eq 2 ]'
    kill "$LAST_PANE"; wait "$LAST_PANE" 2>/dev/null || true
  done
  [ "$(shell_runs)" -eq 0 ]
}

@test "picker fzf: the shell row leaves a shell; a context row, ctrl-t, exit 1 with a query and ctrl-s behave as before; ctrl-t with nothing typed opens it again" {
  hellofix
  fzfstub
  git config --global claude-peer.picker fzf
  FAKE_FZF_SLEEP=1 FAKE_FZF_OUT=$'\n\n@shell\tshell     Drop to a shell\n' pane alpha
  pp=$LAST_PANE
  until_ok '! kill -0 $pp 2>/dev/null'
  grep -qx "pwd=$REPO args=-i" "$FAKE_SHELL_LOG"
  [ -z "$(ls "$REPO/.git/claude-peer.wait")" ]
  rm -f "$FAKE_FZF_LOG.calls"
  FAKE_FZF_OUT=$'\n\n@continue\tcontinue\n' FAKE_SHELL_SLEEP=2 pane alpha
  until_ok 'grep -q "claude-peer proj-alpha --continue\$" "$FAKE_SHELL_LOG"'
  until_ok '[ "$(fzf_calls)" -eq 2 ]'
  kill "$LAST_PANE"; wait "$LAST_PANE" 2>/dev/null || true
  rm -f "$FAKE_FZF_LOG.calls"
  FAKE_FZF_OUT=$'use this\nctrl-t\n@fresh\tfresh\n' FAKE_SHELL_SLEEP=2 pane alpha
  until_ok 'grep -q "claude-peer proj-alpha use this\$" "$FAKE_SHELL_LOG"'
  until_ok '[ "$(fzf_calls)" -eq 2 ]'
  kill "$LAST_PANE"; wait "$LAST_PANE" 2>/dev/null || true
  rm -f "$FAKE_FZF_LOG.calls"
  FAKE_FZF_RC=1 FAKE_FZF_OUT=$'typed and unmatched\n\n' FAKE_SHELL_SLEEP=2 pane alpha
  until_ok 'grep -q "claude-peer proj-alpha typed and unmatched\$" "$FAKE_SHELL_LOG"'
  until_ok '[ "$(fzf_calls)" -eq 2 ]'
  kill "$LAST_PANE"; wait "$LAST_PANE" 2>/dev/null || true
  rm -f "$FAKE_FZF_LOG.calls"
  FAKE_FZF_RC=1 FAKE_FZF_OUT=$'save me\nctrl-s\n' FAKE_SHELL_SLEEP=2 pane alpha
  pane_says alpha 'Save as (a name like fix-ci, Return skips): '
  typeline alpha keeper
  until_ok 'grep -q "claude-peer proj-alpha save me\$" "$FAKE_SHELL_LOG"'
  [ "$(cat "$CLAUDE_PEER_CONTEXTS/octo/proj/90-keeper.ctx")" = $'title: save me\n\nsave me' ]
  until_ok '[ "$(fzf_calls)" -eq 2 ]'
  kill "$LAST_PANE"; wait "$LAST_PANE" 2>/dev/null || true
  [ "$(shell_runs)" -eq 5 ]
  rm -f "$FAKE_FZF_LOG.calls"
  FAKE_FZF_RC=1 FAKE_FZF_OUT=$'\nctrl-t\n' pane alpha
  until_ok '[ "$(fzf_calls)" -eq 2 ]'
  [ "$(shell_runs)" -eq 5 ]
}

@test "picker fzf: exit 2 says so once and uses the list from then on" {
  hellofix
  fzfstub
  git config --global claude-peer.picker fzf
  FAKE_FZF_RC=2 FAKE_SHELL_SLEEP=1 pane alpha
  pane_says alpha "$LISTHINT"
  grep -qF "claude-peer: fzf failed (exit 2); using the list" "$BATS_TEST_TMPDIR/pane-alpha.out"
  typeline alpha r
  until_ok 'grep -q "claude-peer proj-alpha --resume\$" "$FAKE_SHELL_LOG"'
  until_ok '[ "$(pane_count alpha "$LISTHINT")" -eq 2 ]'
  [ "$(pane_count alpha "fzf failed")" -eq 1 ]
  [ "$(fzf_calls)" -eq 1 ]
}

@test "picker fzf: a start from outside while fzf is open closes it with TERM at once and the session gets the prompt" {
  hellofix
  fzfstub
  git config --global claude-peer.picker fzf
  FAKE_FZF_SLEEP=30 FAKE_SHELL_SLEEP=2 FAKE_SHELL_LAST="$BATS_TEST_TMPDIR/last" pane alpha
  until_ok '[ -f "$FAKE_FZF_LOG.calls" ]'
  [ "$(sh "$BIN" slots | cut -f2)" = waiting ]
  CLAUDE_PEER_START_WAIT=10 run sh "$BIN" start alpha hello
  [ "$status" -eq 0 ]
  until_ok '[ -s "$BATS_TEST_TMPDIR/last.n" ]'
  [ "$(cat "$BATS_TEST_TMPDIR/last")" = hello ]
  until_ok '[ -f "$FAKE_FZF_LOG.term" ]'
  grep -qx "Alpha · started by Lead · hello" "$BATS_TEST_TMPDIR/pane-alpha.out"
  ! grep -q "picker closed" "$BATS_TEST_TMPDIR/pane-alpha.out"
  [ "$(grep -c "Preparing worktree" "$BATS_TEST_TMPDIR/pane-alpha.out")" -eq 0 ]
  [ "$(grep -cx '' "$BATS_TEST_TMPDIR/pane-alpha.out")" -eq 0 ]
}

@test "picker fzf: a start from outside cuts into the question a picked row asks, and its line starts a line" {
  hellofix
  fzfstub
  git config --global claude-peer.picker fzf
  git -C "$REPO" worktree add -q --detach "$REPO/.claude/worktrees/alpha" HEAD
  FAKE_FZF_OUT=$'\n\nhello\thello     Hello\n' FAKE_SHELL_SLEEP=2 pane alpha
  pane_says alpha 'Who: '
  CLAUDE_PEER_START_WAIT=10 run sh "$BIN" start alpha hi
  [ "$status" -eq 0 ]
  o=$BATS_TEST_TMPDIR/pane-alpha.out
  until_ok 'grep -qx "Alpha · started by Lead · hi" "$o"'
  grep -qx 'Who: ' "$o"
  [ "$(grep -cx '' "$o")" -eq 0 ]
}

@test "picker fzf: a killed pane takes its fzf and its wait file with it" {
  hellofix
  fzfstub
  git config --global claude-peer.picker fzf
  FAKE_FZF_SLEEP=30 pane alpha
  pp=$LAST_PANE
  until_ok '[ -f "$FAKE_FZF_LOG.calls" ]'
  kids=$(ps -Ao pid=,ppid= | awk -v p="$pp" '$2 == p { print $1 }')
  [ -n "$kids" ]
  kill "$pp"
  until_ok '! kill -0 $pp 2>/dev/null'
  for k in $kids; do until_ok "! kill -0 $k 2>/dev/null"; done
  until_ok '[ -f "$FAKE_FZF_LOG.term" ]'
  [ -z "$(ls "$REPO/.git/claude-peer.wait")" ]
}

@test "contexts: every shipped title is at most 40 characters" {
  for f in "$BATS_TEST_DIRNAME"/../dot_config/claude-peer/contexts/*.ctx; do
    t=$(sed -n 's/^title: //p' "$f" | sed -n 1p)
    [ -n "$t" ]
    [ "${#t}" -le 40 ] || { echo "$f: ${#t}"; false; }
  done
}

@test "picker off: Return is a blank session and the hint is today's line; a context name is not special" {
  hellofix
  FAKE_SHELL_SLEEP=2 pane alpha
  until_ok 'grep -qx "Alpha: Return starts a Claude here, c continues the last session, q leaves a shell" "$BATS_TEST_TMPDIR/pane-alpha.out"'
  typeline alpha hello
  until_ok '[ "$(pane_count alpha "Alpha: Return starts")" -eq 2 ]'
  [ "$(shell_runs)" -eq 0 ]
  typeline alpha ''
  until_ok 'grep -q "claude-peer proj-alpha\$" "$FAKE_SHELL_LOG"'
}

# --- the sleeper --------------------------------------------------------------------

ESC=$'\033'

# fzf_header: the --header= argument the stub got (it spans lines: one per header line)
fzf_header() { sed -n '/^--header=/,/^--print-query$/p' "$FAKE_FZF_LOG" | sed '$d'; }

@test "art: nine lines, four eyes, the reference colours and the three z's; --z, --256, the slot's cap" {
  run sh "$BIN" art --slot beta --truecolor
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 9 ]
  [ "$(printf '%s' "$output" | grep -o '▬' | wc -l | tr -d ' ')" -eq 4 ]
  [[ "$output" == *'48;2;90;120;200'* && "$output" == *'48;2;217;119;87'* ]]
  [[ "$output" == *"${ESC}[1mZ"* && "$output" == *"${ESC}[38;5;250mz"* && "$output" == *"${ESC}[2mz"* ]]
  run sh "$BIN" art --slot beta --truecolor --z none
  [[ "$output" != *z* && "$output" != *Z* ]]
  run sh "$BIN" art --slot alpha --truecolor
  [[ "$output" != *'90;120;200'* && "$output" == *'153;204;153'* ]]
  run sh "$BIN" art --slot beta --256
  [[ "$output" != *'38;2;'* && "$output" != *'48;2;'* ]]
  git config --global claude-peer.beta.cap '#102030'
  run sh "$BIN" art --slot beta --truecolor
  [[ "$output" == *'48;2;16;32;48'* && "$output" == *'11;22;33'* && "$output" != *'90;120;200'* ]]
}

@test "art: claude-peer.art-file replaces the figure; one that does not parse says why and the built-in is drawn" {
  printf 'palette X 1 2 3\nmargin 1\nframe asleep\n.XX\n.XX\n' >"$BATS_TEST_TMPDIR/one.art"
  git config --global claude-peer.art-file "$BATS_TEST_TMPDIR/one.art"
  run sh "$BIN" art --truecolor
  [ "$status" -eq 0 ]
  [ "$output" = "  ${ESC}[48;2;1;2;3m ${ESC}[0m${ESC}[48;2;1;2;3m ${ESC}[0m" ]
  printf 'palette X 1 2 3\nframe asleep\nXX\nX\n' >"$BATS_TEST_TMPDIR/bad.art"
  git config --global claude-peer.art-file "$BATS_TEST_TMPDIR/bad.art"
  run --separate-stderr sh "$BIN" art --truecolor
  [ "$status" -eq 0 ]
  [ "$stderr" = "claude-peer: $BATS_TEST_TMPDIR/bad.art: line 4: frame asleep has rows of unequal width" ]
  [ "${#lines[@]}" -eq 9 ]
  [ "$(printf '%s' "$output" | grep -o '▬' | wc -l | tr -d ' ')" -eq 4 ]
}

@test "sleeper in fzf: beside at 120 columns, under at 60, none at 15 rows or with claude-peer.art false" {
  hellofix
  fzfstub
  git config --global claude-peer.picker fzf
  fzfsize '40 120'
  [ "$(fzf_header | grep -o '▬' | wc -l | tr -d ' ')" -eq 4 ]
  fzf_header | grep -qF '✻ '
  fzf_header | grep -F '✻ ' | grep -F Alpha | grep -qF proj
  fzf_header | grep -qF 'waiting · ⏎ pick a context'
  fzf_header | grep -qF 'esc hide'
  grep -qxF -- --height=23 "$FAKE_FZF_LOG"
  grep -qxF -- --margin=0,31,0,31 "$FAKE_FZF_LOG"
  fzfsize '17 120'
  grep -qxF -- --height=17 "$FAKE_FZF_LOG"
  fzfsize '15 120'
  ! fzf_header | grep -qF '▬'
  grep -qxF -- --height=13 "$FAKE_FZF_LOG"
  fzfsize '40 60'
  [ "$(fzf_header | wc -l | tr -d ' ')" -eq 13 ]
  fzf_header | sed -n 10p | grep -qF '✻ '
  fzf_header | sed -n 11p | grep -qF 'waiting · ⏎ pick a context'
  [ -z "$(fzf_header | sed -n 12p)" ]
  grep -qxF -- --margin=0,0,0,0 "$FAKE_FZF_LOG"
  git config --global claude-peer.art false
  fzfsize '40 120'
  ! fzf_header | grep -qF '▬'
  grep -qxF -- --height=13 "$FAKE_FZF_LOG"
}

@test "sleeper: the selector takes the hat's colour while the sleeper shows, and fzf keeps its own without it" {
  hellofix
  fzfstub
  git config --global claude-peer.picker fzf
  COLORTERM=truecolor fzfsize '40 120'
  grep -qxF -- '--color=pointer:#99cc99,prompt:#99cc99' "$FAKE_FZF_LOG"
  COLORTERM= fzfsize '40 120'
  grep -qxF -- '--color=pointer:114,prompt:114' "$FAKE_FZF_LOG"
  git config --global claude-peer.alpha.cap '#f2777a'
  COLORTERM=truecolor fzfsize '40 120'
  grep -qxF -- '--color=pointer:#f2777a,prompt:#f2777a' "$FAKE_FZF_LOG"
  COLORTERM=truecolor fzfsize '15 120'
  [ "$(grep -c -- '--color=pointer' "$FAKE_FZF_LOG")" -eq 0 ]
  git config --global claude-peer.art false
  COLORTERM=truecolor fzfsize '40 120'
  [ "$(grep -c -- '--color=pointer' "$FAKE_FZF_LOG")" -eq 0 ]
}

@test "sleeper above the list: the prompt takes the hat's colour; without the sleeper it is plain" {
  hellofix
  git config --global claude-peer.picker list
  COLORTERM=truecolor CLAUDE_PEER_SIZE='40 120' pane alpha
  pane_says alpha "$LISTHINT"
  grep -qF $'\033[38;2;153;204;153mAlpha ▸\033[0m ' "$BATS_TEST_TMPDIR/pane-alpha.out"
  COLORTERM=truecolor pane beta
  pane_says beta "$LISTHINT"
  grep -qF 'Beta ▸ ' "$BATS_TEST_TMPDIR/pane-beta.out"
  [ "$(grep -c $'\033\\[38;' "$BATS_TEST_TMPDIR/pane-beta.out")" -eq 0 ]
}

# tick_of: the timer's script, cut out of the logged fzf arguments (it is the last one)
tick_of() { sed -n '/^--bind=every(1):bg-transform:/,$p' "$FAKE_FZF_LOG" | sed '1s/^--bind=every(1):bg-transform://'; }

@test "sleeper moves: the timer's arguments come last, five frame files, and the tick picks the pose" {
  hellofix
  fzfstub
  git config --global claude-peer.picker fzf
  CLAUDE_PEER_SIZE='40 120' FAKE_FZF_SLEEP=30 pane alpha
  until_ok '[ -f "$FAKE_FZF_LOG.calls" ]'
  grep -qxF -- '--with-shell=sh -c' "$FAKE_FZF_LOG"
  grep -qxF -- '--bind=change,focus:rebind(every(1))' "$FAKE_FZF_LOG"
  [ "$(grep -c '^--bind=every(1):bg-transform:' "$FAKE_FZF_LOG")" -eq 1 ]
  [ "$(tick_of | sed 1d | grep -c '^--')" -eq 0 ]
  f=$REPO/.git/claude-peer.wait/alpha.$LAST_PANE.frame
  for k in 0 1 2 3 still; do
    [ "$(grep -o '▬' "$f.$k" | wc -l | tr -d ' ')" -eq 4 ]
  done
  [ "$(cat "$f.0")" != "$(cat "$f.2")" ]
  [ "$(grep -c $'\033\\[1mZ\\|\033\\[38;5;250mz\\|\033\\[2mz' "$f.3")" -eq 0 ]
  [ "$(fzf_header | sed '1s/^--header=//')" = "$(cat "$f.0")" ]
  tick=$(tick_of)
  export CLAUDE_PEER_FRAMES=$f CLAUDE_PEER_ART_SECONDS=20
  [ "$(FZF_IDLE_TIME_MS=1200 sh -c "$tick")" = "change-header:$(cat "$f.1")" ]
  [ "$(FZF_IDLE_TIME_MS=6700 sh -c "$tick")" = "change-header:$(cat "$f.3")" ]
  [ "$(FZF_IDLE_TIME_MS=25000 sh -c "$tick")" = "unbind(every(1))+change-header:$(cat "$f.still")" ]
  still=$(cat "$f.still")
  kill "$LAST_PANE"; wait "$LAST_PANE" 2>/dev/null || true
  # the still frame is A1's header: what the pane shows when it never moves
  git config --global claude-peer.art-seconds 0
  fzfsize '40 120'
  [ "$(fzf_header | sed '1s/^--header=//')" = "$still" ]
}

@test "sleeper moves: with art-seconds 0, with the art off, and at 15 rows there is no timer and no frame file" {
  hellofix
  fzfstub
  git config --global claude-peer.picker fzf
  local how
  for how in 'seconds 40 120' 'off 40 120' 'small 15 120'; do
    set -- $how
    git config --global --unset claude-peer.art-seconds || true
    git config --global --unset claude-peer.art || true
    case $1 in seconds) git config --global claude-peer.art-seconds 0;; off) git config --global claude-peer.art false;; esac
    rm -f "$FAKE_FZF_LOG" "$FAKE_FZF_LOG.calls"
    CLAUDE_PEER_SIZE="$2 $3" FAKE_FZF_SLEEP=30 pane alpha
    until_ok '[ -f "$FAKE_FZF_LOG.calls" ]'
    [ "$(grep -c 'every(1)' "$FAKE_FZF_LOG")" -eq 0 ]
    [ "$(grep -c -- '--with-shell' "$FAKE_FZF_LOG")" -eq 0 ]
    [ "$(ls "$REPO/.git/claude-peer.wait" | grep -c frame)" -eq 0 ]
    kill "$LAST_PANE"; wait "$LAST_PANE" 2>/dev/null || true
  done
}

# before <file> <fixed-a> <fixed-b>: a's first line comes before b's
before() {
  local x y
  x=$(grep -nF -- "$2" "$1" | sed -n '1s/:.*//p'); y=$(grep -nF -- "$3" "$1" | sed -n '1s/:.*//p')
  [ -n "$x" ] && [ -n "$y" ] && [ "$x" -lt "$y" ]
}

@test "wake: a canned pick opens the eyes above the pane's header, which stays alone on its line" {
  hellofix
  fzfstub
  git config --global claude-peer.picker fzf
  COLORTERM=truecolor CLAUDE_PEER_SIZE='40 120' FAKE_FZF_OUT=$'\n\nhello\thello     Hello\n' FAKE_SHELL_SLEEP=2 pane alpha
  pane_says alpha 'Who: '
  typeline alpha World
  o=$BATS_TEST_TMPDIR/pane-alpha.out
  until_ok 'grep -qx "Alpha · hello: World" "$o"'
  grep -qF $'48;2;15;15;15' "$o"
  before "$o" $'\033[9A' 'Alpha · hello: World'
}

@test "wake: a start from outside while fzf is open wakes the same way" {
  hellofix
  fzfstub
  git config --global claude-peer.picker fzf
  COLORTERM=truecolor CLAUDE_PEER_SIZE='40 120' FAKE_FZF_SLEEP=30 FAKE_SHELL_SLEEP=2 pane alpha
  until_ok '[ -f "$FAKE_FZF_LOG.calls" ]'
  CLAUDE_PEER_START_WAIT=10 run sh "$BIN" start alpha hello
  [ "$status" -eq 0 ]
  o=$BATS_TEST_TMPDIR/pane-alpha.out
  until_ok 'grep -qx "Alpha · started by Lead · hello" "$o"'
  grep -qF $'48;2;15;15;15' "$o"
  before "$o" $'\033[9A' 'Alpha · started by Lead · hello'
}

@test "wake: not with the list, not at an unknown size, and not for a refused slot" {
  hellofix
  fzfstub
  git config --global claude-peer.picker list
  COLORTERM=truecolor CLAUDE_PEER_SIZE='40 120' FAKE_SHELL_SLEEP=1 pane alpha
  pane_says alpha "$LISTHINT"
  typeline alpha ''
  # the FIFO echoes no Return: the header shares the prompt's line, so wait for the session
  until_ok 'grep -q "^args=" "$BATS_TEST_TMPDIR/pane-alpha.out"'
  [ "$(grep -c '48;2;15;15;15' "$BATS_TEST_TMPDIR/pane-alpha.out")" -eq 0 ]
  git config --global claude-peer.picker fzf
  COLORTERM=truecolor FAKE_FZF_OUT=$'\n\n@fresh\tfresh     A new session, no prompt\n' FAKE_SHELL_SLEEP=1 pane beta
  until_ok 'grep -qx "Beta" "$BATS_TEST_TMPDIR/pane-beta.out"'
  [ "$(grep -c '48;2;15;15;15' "$BATS_TEST_TMPDIR/pane-beta.out")" -eq 0 ]
  # that pane opens its picker again when its session ends, a second from now: it
  # goes first, or its fzf call can be the stub's first below and take the canned pick
  kill "$LAST_PANE"; wait "$LAST_PANE" 2>/dev/null || true
  # one slot in the pool, held by another leader: the pick is refused and nothing wakes
  git config --global claude-peer.slots gamma
  hold gamma
  rm -f "$FAKE_FZF_LOG.calls"
  COLORTERM=truecolor CLAUDE_PEER_SIZE='40 120' FAKE_FZF_OUT=$'\n\n@fresh\tfresh     A new session, no prompt\n' pane gamma "$REPO" g2
  until_ok 'grep -q "slots are in use" "$BATS_TEST_TMPDIR/pane-g2.out"'
  [ "$(grep -c '48;2;15;15;15' "$BATS_TEST_TMPDIR/pane-g2.out")" -eq 0 ]
}

@test "sleeper moves: a killed pane takes its fzf, its frame files and its wait file with it" {
  hellofix
  fzfstub
  git config --global claude-peer.picker fzf
  CLAUDE_PEER_SIZE='40 120' FAKE_FZF_SLEEP=30 pane alpha
  pp=$LAST_PANE
  until_ok '[ -f "$FAKE_FZF_LOG.calls" ]'
  [ -f "$REPO/.git/claude-peer.wait/alpha.$pp.frame.still" ]
  kids=$(ps -Ao pid=,ppid= | awk -v p="$pp" '$2 == p { print $1 }')
  [ -n "$kids" ]
  kill "$pp"
  until_ok '! kill -0 $pp 2>/dev/null'
  for k in $kids; do until_ok "! kill -0 $k 2>/dev/null"; done
  [ -z "$(ls "$REPO/.git/claude-peer.wait")" ]
}

@test "sleeper: a repository name too long for the block is cut, the label never" {
  local long=a-repository-name-of-forty-characters-x
  long=${long}y
  [ "${#long}" -eq 40 ]
  mkdir -p "$BATS_TEST_TMPDIR/$long"
  git -C "$BATS_TEST_TMPDIR/$long" init -q
  git -C "$BATS_TEST_TMPDIR/$long" commit -q --allow-empty -m init
  fzfstub
  git config --global claude-peer.picker fzf
  rm -f "$FAKE_FZF_LOG.calls"
  CLAUDE_PEER_SIZE='40 80' FAKE_FZF_SLEEP=30 pane alpha "$BATS_TEST_TMPDIR/$long"
  until_ok '[ -f "$FAKE_FZF_LOG.calls" ]'
  # 78 wide, 75 of header, 46 beside the figure: `✻ Alpha · ` and 36 of the name
  fzf_header | grep -F '✻ ' | grep -qF "Alpha${ESC}[0m · ${long:0:36}"
  ! fzf_header | grep -qF "${long:0:37}"
}

@test "sleeper above the list: the figure's lines start at the block's text, then an empty line, then row 1" {
  hellofix
  git config --global claude-peer.picker list
  CLAUDE_PEER_SIZE='40 120' pane alpha
  pane_says alpha "$LISTHINT"
  local out="$BATS_TEST_TMPDIR/pane-alpha.out"
  [ "$(sed -n 1,9p "$out" | grep -c "^$(printf '%33s' '')")" -eq 9 ]
  [ "$(sed -n 1,9p "$out" | grep -o '▬' | wc -l | tr -d ' ')" -eq 4 ]
  [ -z "$(sed -n 10p "$out")" ]
  sed -n 11p "$out" | grep -q "^$(printf '%31s' '') 1  fresh"
}

@test "sleeper quiet: Esc prints the figure with the quiet hint, no old line, and art --screen prints the same" {
  hellofix
  fzfstub
  git config --global claude-peer.picker fzf
  CLAUDE_PEER_SIZE='40 120' FAKE_FZF_RC=130 pane alpha
  pane_says alpha '⏎ picker · c continue · q shell'
  local out="$BATS_TEST_TMPDIR/pane-alpha.out"
  [ "$(grep -o '▬' "$out" | wc -l | tr -d ' ')" -eq 4 ]
  ! grep -q 'Alpha: Return picks' "$out"
  [ "$(CLAUDE_PEER_SIZE='40 120' sh "$BIN" art --screen --slot alpha)" = "$(cat "$out")" ]
}

# quiet_erases <size> <lines…>: Esc at that size, then each line typed; prints the output
quiet_erases() {
  local size=$1; shift
  rm -f "$FAKE_FZF_LOG.calls"
  CLAUDE_PEER_SIZE=$size FAKE_FZF_RC=130 pane alpha
  until_ok '[ "$(fzf_calls)" -eq 1 ]'
  sleep 1
  local l
  for l; do typeline alpha "$l"; done
  until_ok '[ "$(fzf_calls)" -eq 2 ]'
  kill "$LAST_PANE"; wait "$LAST_PANE" 2>/dev/null || true
}

@test "sleeper quiet: Return, and a mistyped line, erase the quiet block in place first; nothing is erased without it" {
  hellofix
  fzfstub
  git config --global claude-peer.picker fzf
  local out="$BATS_TEST_TMPDIR/pane-alpha.out" erase11="${ESC}[11A"$'\r'"${ESC}[J"
  quiet_erases '40 120' ''
  [ "$(pane_count alpha "$erase11")" -eq 1 ]
  # after the block and its empty line, and the last thing before the stub's second call
  [[ "$(cat "$out")" == *'q shell'*$'\n\n'"$erase11" ]]
  quiet_erases '40 120' x ''
  [ "$(pane_count alpha "$erase11")" -eq 2 ]
  quiet_erases '40 60' ''
  [ "$(pane_count alpha "${ESC}[13A"$'\r'"${ESC}[J")" -eq 1 ]
  quiet_erases '' ''
  ! grep -qE "${ESC}\[[0-9]+A" "$out"
  git config --global claude-peer.art false
  quiet_erases '40 120' ''
  ! grep -qE "${ESC}\[[0-9]+A" "$out"
}

# hermes_banner [body]: an installed Hermes whose banner holds a small invented
# figure (never the real one), in the shape Hermes writes it: rich colour tags,
# one triple-quoted string. With an argument, that is the file instead.
hermes_banner() {
  local d=$HOME/.hermes/hermes-agent/hermes_cli
  mkdir -p "$d"
  if [ $# -gt 0 ]; then printf '%s' "$1" >"$d/banner.py"; return; fi
  printf '%s\n' 'OTHER = """x"""' \
    'HERMES_CADUCEUS = """[#CD7F32]⢀⣿⡀[/]' \
    "[bold]⣿⣿⣿⣿[/]"$'\033[31m' \
    '⠈⣿⠁"""' 'def f(): pass' >"$d/banner.py"
}

plain() { sed $'s/\033\\[[0-9;?]*[A-Za-z]//g'; }

@test "art --hermes: the installed figure, tags and control bytes gone, dark bronze, the waiting line" {
  hermes_banner
  run --separate-stderr sh "$BIN" art --hermes --truecolor
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(printf '%s\n' "$output" | plain)" = "$(printf '  %s\n' '⢀⣿⡀' '⣿⣿⣿⣿' '⠈⣿⠁'; echo; printf '  waiting · ⏎ to start Hermes · q for a shell')" ]
  [[ "$output" == *'38;2;150;92;36'* ]]
  [[ "$output" != *'255;214;150'* ]]
  [[ "$output" != *$'\033[31m'* ]]
  [[ "$output" != *[Zz]* ]]
}

@test "art --hermes --at: the band's centre is the shine; --256 draws in 256 colours only" {
  hermes_banner
  run sh "$BIN" art --hermes --truecolor --at 6
  [[ "$output" == *'38;2;255;214;150m⢀'* ]]
  run sh "$BIN" art --hermes --256 --at 6
  [ "$status" -eq 0 ]
  [[ "$output" != *'38;2;'* ]]
  [[ "$output" == *'38;5;'* ]]
}

@test "art --hermes: no Hermes, no figure in it, or an empty one is status 3 and prints nothing" {
  run --separate-stderr sh "$BIN" art --hermes
  [ "$status" -eq 3 ] && [ -z "$output" ] && [ -z "$stderr" ]
  hermes_banner 'BANNER = """x"""'
  run --separate-stderr sh "$BIN" art --hermes
  [ "$status" -eq 3 ] && [ -z "$output" ] && [ -z "$stderr" ]
  hermes_banner 'HERMES_CADUCEUS = """[gold][/]
"""'
  run --separate-stderr sh "$BIN" art --hermes
  [ "$status" -eq 3 ] && [ -z "$output" ] && [ -z "$stderr" ]
}

@test "art --hermes --wait: off a terminal it is status 3 and silent" {
  hermes_banner
  run --separate-stderr sh "$BIN" art --hermes --wait </dev/null
  [ "$status" -eq 3 ] && [ -z "$output" ] && [ -z "$stderr" ]
}

# --- hand-offs: start --handoff, claim lines 8-10, the claim verb, log idle -------

NOTE_END='A report left only in this pane reaches nobody.'

@test "start --handoff: the prompt gains the note, the claim ends handoff, the pid and the session id" {
  FAKE_SHELL_SLEEP=2 FAKE_SHELL_LAST="$BATS_TEST_TMPDIR/last" pane alpha
  CLAUDE_PID=4242 CLAUDE_CODE_SESSION_ID=aaaa-bbbb run sh "$BIN" start alpha --handoff fix thing
  [ "$status" -eq 0 ]
  [ "$output" = "alpha"$'\t'"$REPO/.claude/worktrees/alpha"$'\t'"started"$'\t'"proj-alpha" ]
  until_ok '[ -s "$BATS_TEST_TMPDIR/last.n" ]'
  last=$(cat "$BATS_TEST_TMPDIR/last")
  [[ "$last" == "fix thing"$'\n\n'"Hand-off from Lead. "*"$NOTE_END" ]]
  [[ "$last" == *'${TMPDIR:-/tmp}/claude-reports/'* ]]
  cl=$(claim_of "$REPO/.claude/worktrees/alpha")
  [ "$(wc -l <"$cl" | tr -d ' ')" -eq 10 ]
  [ "$(sed -n '8,10p' "$cl" | tr '\n' ' ')" = "handoff 4242 aaaa-bbbb " ]
}

@test "start without --handoff: the prompt is untouched, the claim ends - pid sid, and stderr says nobody is told" {
  FAKE_SHELL_SLEEP=2 FAKE_SHELL_LAST="$BATS_TEST_TMPDIR/last" pane alpha
  CLAUDE_PID=4242 CLAUDE_CODE_SESSION_ID=aaaa-bbbb run sh "$BIN" start alpha fix thing
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "claude-peer: not a hand-off: nobody is told when Alpha finishes (--handoff)" ]
  until_ok '[ -s "$BATS_TEST_TMPDIR/last.n" ]'
  [ "$(cat "$BATS_TEST_TMPDIR/last")" = "fix thing" ]
  cl=$(claim_of "$REPO/.claude/worktrees/alpha")
  [ "$(sed -n '8,10p' "$cl" | tr '\n' ' ')" = "- 4242 aaaa-bbbb " ]
}

@test "start: a Return start in the pane writes - - - and no hand-off line" {
  FAKE_SHELL_SLEEP=2 pane alpha
  press alpha ''
  wait_claim "$REPO/.claude/worktrees/alpha"
  cl=$(claim_of "$REPO/.claude/worktrees/alpha")
  until_ok '[ "$(wc -l <"'"$cl"'" | tr -d " ")" -eq 10 ]'
  [ "$(sed -n '8,10p' "$cl" | tr '\n' ' ')" = "- - - " ]
  ! grep -q 'not a hand-off' "$BATS_TEST_TMPDIR/pane-alpha.out" || { echo "a Return start warned"; false; }
}

@test "start --handoff: no words, from a peer, or without CLAUDE_PID is 2, and none wakes the pane" {
  pane alpha
  CLAUDE_PID=4242 run sh "$BIN" start alpha --handoff
  [ "$status" -eq 2 ]
  [[ "$output" == *"--handoff needs something to hand over"* ]]
  CLAUDE_PID=4242 CLAUDE_PEER_WORKTREE=/x run sh "$BIN" start alpha --handoff fix
  [ "$status" -eq 2 ]
  [[ "$output" == *"--handoff is Lead's; a peer tells Lead with claude-peer log"* ]]
  run sh "$BIN" start alpha --handoff fix
  [ "$status" -eq 2 ]
  [[ "$output" == *"--handoff needs a Claude session to tell; run it from one"* ]]
  CLAUDE_PID=x run sh "$BIN" start alpha --handoff fix
  [ "$status" -eq 2 ]
  [ "$(shell_runs)" -eq 0 ]
  [ "$(sh "$BIN" slots | cut -f2)" = waiting ]
  [ ! -e "$REPO/.git/claude-peer.wait/alpha.$LAST_PANE.start" ]
}

@test "start --handoff: a pane of protocol 2 is 4, and still starts for --context" {
  hellofix
  FAKE_SHELL_SLEEP=2 pane alpha
  printf '%s\n2\n' "$REPO" >"$REPO/.git/claude-peer.wait/alpha.$LAST_PANE"
  CLAUDE_PID=4242 run sh "$BIN" start alpha --handoff fix it
  [ "$status" -eq 4 ]
  [[ "$output" == *"the waiting pane (pid $LAST_PANE) predates hand-offs; reopen its tab"* ]]
  [ "$(shell_runs)" -eq 0 ]
  run sh "$BIN" start alpha --context say World
  [ "$status" -eq 0 ]
}

@test "start --context --handoff: the note follows the substituted body" {
  hellofix
  FAKE_SHELL_SLEEP=2 FAKE_SHELL_LAST="$BATS_TEST_TMPDIR/last" pane alpha
  CLAUDE_PID=4242 run sh "$BIN" start alpha --context say --handoff World
  [ "$status" -eq 0 ]
  until_ok '[ -s "$BATS_TEST_TMPDIR/last.n" ]'
  [[ "$(cat "$BATS_TEST_TMPDIR/last")" == "Say: World!"$'\n\n'"Hand-off from Lead. "*"$NOTE_END" ]]
}

@test "claim: ten rows for a hand-off, - for a seven-line claim, exit 1 for a waiting slot; peers keeps four columns" {
  slot_wt alpha Alpha
  cl=$(claim_of "$REPO/.claude/worktrees/alpha")
  printf 'Lead\n-\nfix\n1700000000\nhandoff\n4242\naaaa-bbbb\n' >>"$cl"
  run sh "$BIN" claim "$REPO/.claude/worktrees/alpha"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 10 ]
  [ "${lines[1]}" = "leader"$'\t'"$REPO" ]
  [ "${lines[7]}" = "handoff"$'\t'"handoff" ]
  [ "${lines[9]}" = "lead-sid"$'\t'"aaaa-bbbb" ]
  printf '%s\n%s\nAlpha\nLead\n-\nfix\n1700000000\n' "$$" "$REPO" >"$cl"
  run sh "$BIN" claim "$REPO/.claude/worktrees/alpha"
  [ "$(printf '%s\n' "$output" | sed -n '8,10p' | cut -f2 | tr '\n' ' ')" = "- - - " ]
  run sh "$BIN" peers
  [ "$(printf '%s' "$output" | awk -F'\t' '{ print NF }')" -eq 4 ]
  pane beta
  run sh "$BIN" claim "$REPO/.claude/worktrees/beta"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "log idle: once per turn without a done, with the leader, pid and session id passed to postbox" {
  pb_stub; slot_wt alpha Alpha; slot_wt beta Beta
  printf 'Lead\n-\nfix\n%s\nhandoff\n4242\naaaa-bbbb\n' "$(($(date +%s) - 125))" >>"$(claim_of "$REPO/.claude/worktrees/alpha")"
  cd "$REPO/.claude/worktrees/alpha"
  sh "$BIN" log idle said-this; pb_wait 1
  [ "$(grep -c . "$REPO/$LOG")" -eq 1 ]
  [ "$(cut -f2,3,4 "$REPO/$LOG")" = "Alpha"$'\t'"idle"$'\t'"Alpha stopped after 2m without logging done: said-this" ]
  [ "$(cat "$PB_CALLS")" = "lead-news $REPO 4242 aaaa-bbbb" ]
  sleep 1
  sh "$BIN" log done x; pb_wait 2
  sh "$BIN" log idle; sleep 0.5
  [ "$(grep -c . "$REPO/$LOG")" -eq 2 ]
  [ "$(grep -c . "$PB_CALLS")" -eq 2 ]
  sleep 1
  sh "$BIN" log idle; pb_wait 3
  [ "$(cut -f3 "$REPO/$LOG" | tail -n 1)" = idle ]
  cd "$REPO/.claude/worktrees/beta"
  sh "$BIN" log idle
  [ "$(grep -c . "$REPO/$LOG")" -eq 3 ]
  cd "$REPO"
  sh "$BIN" log --as Alpha idle text
  [ "$(tail -n 1 "$REPO/$LOG" | cut -f2,3,4)" = "Alpha"$'\t'"idle"$'\t'"text" ]
  run sh "$BIN" log --as Alpha idle
  [ "$status" -eq 2 ]
}

@test "log idle: the turn mark goes when the session ends" {
  FAKE_SHELL_SLEEP=2 pane alpha
  CLAUDE_PID=4242 sh "$BIN" start alpha --handoff fix >/dev/null
  ( cd "$REPO/.claude/worktrees/alpha" && sh "$BIN" log idle )
  tf="$(git -C "$REPO/.claude/worktrees/alpha" rev-parse --absolute-git-dir)/claude-peer.turn"
  [ -s "$tf" ]
  until_ok '[ "$(sh "$BIN" slots | cut -f2)" = waiting ]'
  [ ! -e "$tf" ]
}

# --- how a handed-over session ended: gone, or end (stopped by …) -----------------

stopmark() { echo "$(git -C "$REPO/.claude/worktrees/alpha" rev-parse --absolute-git-dir)/claude-peer.stop"; }

@test "gone: a hand-off that ends by itself logs gone, closes its claims and tells Lead with both ids" {
  pb_stub
  FAKE_SHELL_SLEEP=1 pane alpha
  sh "$BIN" log --as Alpha claim fixing -- some/file >/dev/null
  CLAUDE_PID=4242 CLAUDE_CODE_SESSION_ID=aaaa-bbbb sh "$BIN" start alpha --handoff the task >/dev/null
  until_ok 'grep -q "	gone	" "$REPO/$LOG"'
  [[ "$(grep "	gone	" "$REPO/$LOG" | cut -f2,3,4)" =~ ^Alpha$'\t'gone$'\t'Alpha\ ended\ after\ [0-9]+s\ \(the\ task\)$ ]]
  ! grep -q "	end	" "$REPO/$LOG" || { echo "a hand-off logged end"; false; }
  pb_wait 2   # the fixture's own claim is one call
  [ "$(grep -cx "lead-news $REPO 4242 aaaa-bbbb" "$PB_CALLS")" -eq 1 ]
  ! sh "$BIN" log show | grep -q "	Alpha	claim	" || { echo "gone left Alpha's claim open"; false; }
}

@test "gone: stop on a hand-off logs end (stopped by Lead), tells nobody, and leaves no mark" {
  pb_stub
  cfg=$BATS_TEST_TMPDIR/cfg; mkdir -p "$cfg/sessions"; export CLAUDE_CONFIG_DIR=$cfg
  FAKE_SHELL_SLEEP=30 FAKE_SHELL_PID="$BATS_TEST_TMPDIR/shpid" pane alpha
  CLAUDE_PID=4242 sh "$BIN" start alpha --handoff the task >/dev/null
  until_ok '[ -s "$BATS_TEST_TMPDIR/shpid" ]'
  sp=$(cat "$BATS_TEST_TMPDIR/shpid")
  printf '{"pid": %s, "status": "idle"}\n' "$sp" >"$cfg/sessions/$sp.json"
  run sh "$BIN" stop alpha
  [ "$status" -eq 0 ]
  until_ok 'grep -q "	end	" "$REPO/$LOG"'
  [[ "$(grep "	end	" "$REPO/$LOG" | cut -f4)" == *"(the task) (stopped by Lead)" ]]
  ! grep -q "	gone	" "$REPO/$LOG" || { echo "a stopped hand-off logged gone"; false; }
  sleep 0.5
  ! grep -q lead-news "$PB_CALLS" 2>/dev/null || { echo "a requested stop told Lead"; false; }
  [ ! -e "$(stopmark)" ]
}

@test "gone: a plain session ends with the plain end line and no call, whatever stale mark was left" {
  pb_stub
  FAKE_SHELL_SLEEP=1 pane alpha
  git -C "$REPO" worktree add -q --detach "$REPO/.claude/worktrees/alpha" HEAD
  echo Ghost >"$(stopmark)"
  sh "$BIN" start alpha the task >/dev/null
  until_ok 'grep -q "	end	" "$REPO/$LOG"'
  [[ "$(grep "	end	" "$REPO/$LOG" | cut -f4)" =~ ^Alpha\ ended\ after\ [0-9]+s\ \(the\ task\)$ ]]
  sleep 0.5
  [ ! -e "$PB_CALLS" ]
}

@test "gone: a stop that times out leaves no mark" {
  export CLAUDE_CONFIG_DIR=$BATS_TEST_TMPDIR/empty CLAUDE_PEER_STOP_WAIT=1
  FAKE_SHELL_NOTERM=1 FAKE_SHELL_SLEEP=6 FAKE_SHELL_PID="$BATS_TEST_TMPDIR/shpid" pane alpha
  sh "$BIN" start alpha >/dev/null
  until_ok '[ -s "$BATS_TEST_TMPDIR/shpid" ]'
  run sh "$BIN" stop alpha --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not exit within 1s"* ]]
  [ ! -e "$(stopmark)" ]
}

@test "start --handoff starts the stall clock with the leader, worktree, pane pid and both ids; not when off or plain" {
  pb_stub
  FAKE_SHELL_SLEEP=3 pane alpha
  CLAUDE_PID=4242 CLAUDE_CODE_SESSION_ID=aaaa-bbbb sh "$BIN" start alpha --handoff fix >/dev/null
  pb_wait 1
  [ "$(grep handoff-check "$PB_CALLS")" = "handoff-check $REPO $REPO/.claude/worktrees/alpha $LAST_PANE 4242 aaaa-bbbb" ]
  until_ok '[ "$(sh "$BIN" slots | cut -f2)" = waiting ]'
  : >"$PB_CALLS"
  git config claude-peer.stall-minutes 0
  CLAUDE_PID=4242 sh "$BIN" start alpha --handoff fix >/dev/null
  until_ok '[ "$(sh "$BIN" slots | cut -f2)" = waiting ]'
  git config --unset claude-peer.stall-minutes
  CLAUDE_PID=4242 sh "$BIN" start alpha fix >/dev/null 2>&1
  sleep 0.5
  ! grep -q handoff-check "$PB_CALLS" || { echo "a clock started when off or plain"; false; }
}

@test "name: a slot is <repo>-<slot>; lead is <repo>-lead, <repo>-<worktree>-lead in a linked worktree; outside a repository 1" {
  run sh "$BIN" name alpha
  [ "$output" = proj-alpha ]
  run sh "$BIN" name lead
  [ "$output" = proj-lead ]
  git worktree add -q --detach "$REPO/.claude/worktrees/feat-a" HEAD
  run sh "$BIN" name lead "$REPO/.claude/worktrees/feat-a"
  [ "$output" = proj-feat-a-lead ]
  mkdir "$BATS_TEST_TMPDIR/norepo"
  run sh "$BIN" name lead "$BATS_TEST_TMPDIR/norepo"
  [ "$status" -eq 1 ]
}

@test "name: lead, claude and hermes are not slots, for run, start or a branch called lead" {
  for w in lead claude hermes; do
    run sh "$BIN" run --as "$w"
    [ "$status" -eq 1 ]
    [[ "$output" == *"'$w' is not a slot name"* ]]
    run sh "$BIN" start "$w" x
    [ "$status" -eq 1 ]
    [[ "$output" == *"'$w' is not a slot name"* ]]
  done
  run sh "$BIN" run lead
  [ "$status" -eq 1 ]
  [[ "$output" == *"lead is Lead's name"* ]]
}

# --- overlays ----------------------------------------------------------------------
# An overlay is a ~/.config/chezmoi/<name>.toml (other than chezmoi.toml) whose
# `chezmoi --config <cfg> source-path` is a git repository. A chezmoi stub answers
# from <cfg>.src, so nothing reads the real configs; fixtures are invented.

# overlay_stub: a chezmoi stub first on PATH. `--config <cfg> source-path` prints
# the content of <cfg>.src, a bare `source-path` prints $FAKE_CHEZMOI_SOURCE,
# $FAKE_CHEZMOI_FAIL makes every call fail; each call is logged.
overlay_stub() {
  cat >"$BATS_TEST_TMPDIR/bin/chezmoi" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/chezmoi.log"
[ -z "${FAKE_CHEZMOI_FAIL-}" ] || exit 1
case " $* " in
  *" source-path "*)
    cfg=
    while [ $# -gt 0 ]; do
      [ "$1" = --config ] && cfg=$2
      shift
    done
    if [ -n "$cfg" ]; then cat "$cfg.src" 2>/dev/null
    elif [ -n "${FAKE_CHEZMOI_SOURCE-}" ]; then printf '%s\n' "$FAKE_CHEZMOI_SOURCE"
    fi
    exit 0;;
esac
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/chezmoi"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# overlay_cfg <file> <dir>: ~/.config/chezmoi/<file>, whose source is <dir>
overlay_cfg() {
  mkdir -p "$HOME/.config/chezmoi"
  : >"$HOME/.config/chezmoi/$1"
  printf '%s\n' "$2" >"$HOME/.config/chezmoi/$1.src"
}

# overlay_repo <name>: a repository with one commit under the test directory; prints its physical path
overlay_repo() {
  mkdir -p "$BATS_TEST_TMPDIR/$1"
  git -C "$BATS_TEST_TMPDIR/$1" init -q
  git -C "$BATS_TEST_TMPDIR/$1" commit -q --allow-empty -m initial
  ( cd "$BATS_TEST_TMPDIR/$1" && pwd -P )
}

# ov_busy <repo> <leader>: a live claim in a linked worktree of <repo> and a live wait file, both led from <leader>
ov_busy() {
  git -C "$1" worktree add -q --detach "$1/.claude/worktrees/alpha"
  sleep 60 & OV_CLAIM=$!
  sleep 60 & OV_WAIT=$!
  PANES="$PANES $OV_CLAIM $OV_WAIT"
  if [ "${3-}" != wait-only ]; then
    printf '%s\n%s\nAlpha\n' "$OV_CLAIM" "$2" >"$(git -C "$1/.claude/worktrees/alpha" rev-parse --absolute-git-dir)/claude-peer.claim"
  fi
  mkdir -p "$1/.git/claude-peer.wait"
  printf '%s\n' "$2" >"$1/.git/claude-peer.wait/beta.$OV_WAIT"
}

@test "overlays: none configured prints nothing and never runs chezmoi" {
  overlay_stub
  run --separate-stderr sh "$BIN" overlays
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  # chezmoi.toml alone is no overlay either
  OV1=$(overlay_repo ov1)
  overlay_cfg chezmoi.toml "$OV1"
  run --separate-stderr sh "$BIN" overlays
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  [ ! -e "$BATS_TEST_TMPDIR/chezmoi.log" ]
}

@test "overlays: one overlay is a row, idle; chezmoi.toml is never a row" {
  overlay_stub
  OV1=$(overlay_repo ov1)
  overlay_cfg chezmoi.toml "$OV1"
  overlay_cfg fake1.toml "$OV1"
  run --separate-stderr sh "$BIN" overlays
  [ "$status" -eq 0 ]
  [ "$output" = "fake1"$'\t'"$OV1"$'\t'"idle"$'\t'"-"$'\t'"-" ]
  [ -z "$stderr" ]
  ! grep -qF "chezmoi.toml" "$BATS_TEST_TMPDIR/chezmoi.log" || { echo "chezmoi.toml was asked"; false; }
}

@test "overlays: two overlays list in name order, by C order not the locale's" {
  overlay_stub
  OV1=$(overlay_repo ov1); OV2=$(overlay_repo ov2)
  overlay_cfg fake_a.toml "$OV1"
  overlay_cfg fake-b.toml "$OV2"
  # A locale that sorts '-' after '_', so C order is what decides; skip where
  # none is installed (Rocky's minimal container has none).
  loc=$(locale -a 2>/dev/null | grep -ixE 'en_US\.utf-?8' | head -n 1)
  [ -n "$loc" ] || skip "no en_US UTF-8 locale installed"
  LC_ALL=$loc run --separate-stderr sh "$BIN" overlays
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f1 | paste -sd' ' -)" = "fake-b fake_a" ]
  [ "$(printf '%s\n' "$output" | cut -f2 | paste -sd' ' -)" = "$OV2 $OV1" ]
  [ -z "$stderr" ]
}

@test "overlays: a config name becomes a label name" {
  overlay_stub
  OV1=$(overlay_repo ov1); OV2=$(overlay_repo ov2)
  overlay_cfg Fake.Two.toml "$OV1"
  overlay_cfg 9x.toml "$OV2"
  run --separate-stderr sh "$BIN" overlays
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f1 | paste -sd' ' -)" = "fake-two o-9x" ]
}

@test "overlays: a linked worktree as the source resolves to its main checkout" {
  overlay_stub
  OV1=$(overlay_repo ov1)
  git -C "$OV1" worktree add -q --detach "$BATS_TEST_TMPDIR/ov1-linked"
  overlay_cfg fake1.toml "$BATS_TEST_TMPDIR/ov1-linked/"
  run --separate-stderr sh "$BIN" overlays
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f2)" = "$OV1" ]
}

@test "overlays: a candidate that cannot be one is named on stderr and left out" {
  overlay_stub
  OV1=$(overlay_repo ov1); OV2=$(overlay_repo ov2); OV3=$(overlay_repo ov3); OV4=$(overlay_repo ov4)
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  overlay_cfg fake1.toml "$OV1"
  overlay_cfg fake1b.toml "$OV1"
  overlay_cfg fake2.toml "$BATS_TEST_TMPDIR/missing"
  overlay_cfg fake3.toml "$BATS_TEST_TMPDIR/plain"
  overlay_cfg fake4.toml "$OV2"
  overlay_cfg Fake.Five.toml "$OV3"
  overlay_cfg fake-five.toml "$OV4"
  : >"$HOME/.config/chezmoi/fake6.toml"
  FAKE_CHEZMOI_SOURCE="$OV2" run --separate-stderr sh "$BIN" overlays
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f1,2 | paste -sd' ' -)" = "$(printf 'fake-five\t%s fake1\t%s' "$OV3" "$OV1")" ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 6 ]
  [[ "$stderr" == *"claude-peer: overlay config fake1b.toml: same repository as fake1.toml; skipped"* ]]
  [[ "$stderr" == *"claude-peer: overlay config fake2.toml: chezmoi names no source directory; skipped"* ]]
  [[ "$stderr" == *"claude-peer: overlay config fake3.toml: $BATS_TEST_TMPDIR/plain is not inside a non-bare git repository; skipped"* ]]
  [[ "$stderr" == *"claude-peer: overlay config fake4.toml: its source is the public source; skipped"* ]]
  [[ "$stderr" == *"claude-peer: overlay config fake-five.toml: the name 'fake-five' is already taken by Fake.Five.toml; skipped"* ]]
  [[ "$stderr" == *"claude-peer: overlay config fake6.toml: chezmoi names no source directory; skipped"* ]]
}

@test "overlays: candidates without chezmoi on PATH are one line and no rows" {
  local d="$BATS_TEST_TMPDIR/minimal" t
  mkdir -p "$d"
  for t in git sort tr awk sed cut uname; do ln -s "$(command -v $t)" "$d/$t"; done
  OV1=$(overlay_repo ov1)
  overlay_cfg fake1.toml "$OV1"
  run --separate-stderr env PATH="$d" /bin/sh "$BIN" overlays
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$stderr" = "claude-peer: chezmoi is not on PATH; overlays cannot be resolved" ]
}

@test "overlays: a pane of another repository's tab makes the state waiting or running" {
  overlay_stub
  OV1=$(overlay_repo ov1)
  overlay_cfg fake1.toml "$OV1"
  ov_busy "$OV1" "$REPO" wait-only
  run sh "$BIN" overlays
  [ "$status" -eq 0 ]
  [ "$output" = "fake1"$'\t'"$OV1"$'\t'"waiting"$'\t'"$REPO"$'\t'"$OV_WAIT" ]
  # a live claim beats a wait file
  printf '%s\n%s\nAlpha\n' "$OV_CLAIM" "$REPO" >"$(git -C "$OV1/.claude/worktrees/alpha" rev-parse --absolute-git-dir)/claude-peer.claim"
  run sh "$BIN" overlays
  [ "$output" = "fake1"$'\t'"$OV1"$'\t'"running"$'\t'"$REPO"$'\t'"$OV_CLAIM" ]
}

@test "overlays: a pane led from inside the overlay itself leaves it idle" {
  overlay_stub
  OV1=$(overlay_repo ov1)
  overlay_cfg fake1.toml "$OV1"
  mkdir -p "$OV1/sub"
  ov_busy "$OV1" "$OV1/sub"
  run sh "$BIN" overlays
  [ "$status" -eq 0 ]
  [ "$output" = "fake1"$'\t'"$OV1"$'\t'"idle"$'\t'"-"$'\t'"-" ]
  printf '%s\n' "$OV1" >"$OV1/.git/claude-peer.wait/beta.$OV_WAIT"
  run sh "$BIN" overlays
  [ "$output" = "fake1"$'\t'"$OV1"$'\t'"idle"$'\t'"-"$'\t'"-" ]
}

@test "overlays: arguments are usage, exit 2" {
  # an unknown verb is exit 2 as well, so the verb must also be known
  run sh "$BIN" overlays extra
  [ "$status" -eq 2 ]
  [[ "$output" != *"unknown command"* ]]
  [[ "$output" == *"Usage: claude-peer"* ]]
}

# opane <name> <root> [<leader dir> [<tag>]]: a waiting `overlay <name>` pane started in
# <leader dir> (default $REPO), waiting on the wait file in the OVERLAY's git directory;
# its terminal is the FIFO tty-<tag> (tag defaults to the name)
opane() {
  local n=$1 r=$2 d=${3:-$REPO} t=${4:-$1}
  local tty=$BATS_TEST_TMPDIR/tty-$t
  [ -p "$tty" ] || mkfifo "$tty"
  ( cd "$d" && export CLAUDE_PEER_TTY="$tty" &&
    exec sh "$BIN" overlay "$n" >"$BATS_TEST_TMPDIR/pane-$t.out" 2>&1 3>&- ) &
  LAST_PANE=$!
  PANES="$PANES $LAST_PANE"
  until_ok "[ -f '$r/.git/claude-peer.wait/overlay.$LAST_PANE' ]"
}

# obg <arg> <tag>: `overlay <arg>` in the background from $REPO, output in bg-<tag>.out, then
# wait for the plain shell (a version that wrongly makes it a waiting pane must fail the
# test, not hang it)
obg() {
  ( cd "$REPO" && exec sh "$BIN" overlay "$1" >"$BATS_TEST_TMPDIR/bg-$2.out" 2>&1 3>&- ) &
  PANES="$PANES $!"
  until_ok "grep -q '^args=-i\$' '$BATS_TEST_TMPDIR/bg-$2.out'"
}

@test "overlay: a waiting pane stands in the overlay and leaves the leader's repository alone" {
  overlay_stub
  OV1=$(overlay_repo ov1)
  overlay_cfg fake1.toml "$OV1"
  opane fake1 "$OV1"
  [ "$(sed -n 1p "$OV1/.git/claude-peer.wait/overlay.$LAST_PANE")" = "$REPO" ]
  [ ! -e "$OV1/.claude/worktrees/overlay" ]
  [ -z "$(find "$OV1/.git" -name 'claude-peer.claim' -o -name 'claude-peer.lock')" ]
  [ ! -e "$REPO/.claude" ]
  [ -z "$(find "$REPO/.git" -name 'claude-peer.*')" ]
  [ "$(shell_runs)" -eq 0 ]
  grep -q "^Fake1: Return starts a Claude here, c continues the last session, q leaves a shell$" "$BATS_TEST_TMPDIR/pane-fake1.out"
  run sh "$BIN" overlays
  [ "$output" = "fake1"$'\t'"$OV1"$'\t'"waiting"$'\t'"$REPO"$'\t'"$LAST_PANE" ]
}

@test "overlay: Return starts a session in the overlay's own slot, claimed for the leader" {
  overlay_stub
  OV1=$(overlay_repo ov1)
  overlay_cfg fake1.toml "$OV1"
  FAKE_SHELL_SLEEP=3 opane fake1 "$OV1"
  press fake1 ''
  until_ok 'grep -q "pwd=$OV1/.claude/worktrees/overlay args=.*claude-peer ov1-overlay\$" "$FAKE_SHELL_LOG"'
  local c; c=$(claim_of "$OV1/.claude/worktrees/overlay")
  [ "$(sed -n 2p "$c")" = "$REPO" ]
  [ "$(sed -n 3p "$c")" = "Overlay" ]
  [ "$(grep -cxF '**/.claude/worktrees/' "$OV1/.git/info/exclude")" -eq 1 ]
  [ ! -e "$REPO/.claude" ]
  [ -z "$(find "$REPO/.git" -name 'claude-peer.*')" ]
  grep -qx "Overlay" "$BATS_TEST_TMPDIR/pane-fake1.out"
}

@test "overlay: a new worktree is detached at origin/HEAD when the overlay has one" {
  overlay_stub
  OV1=$(overlay_repo ov1)
  overlay_cfg fake1.toml "$OV1"
  git clone -q --bare "$OV1" "$BATS_TEST_TMPDIR/ov1-remote.git"
  git -C "$OV1" remote add origin "$BATS_TEST_TMPDIR/ov1-remote.git"
  git -C "$OV1" fetch -q origin
  git -C "$OV1" remote set-head origin -a >/dev/null
  git -C "$OV1" commit -q --allow-empty -m 'local only'
  FAKE_SHELL_SLEEP=2 opane fake1 "$OV1"
  press fake1 ''
  until_ok 'grep -q "claude-peer ov1-overlay\$" "$FAKE_SHELL_LOG"'
  ! git -C "$OV1/.claude/worktrees/overlay" symbolic-ref -q HEAD
  [ "$(git -C "$OV1/.claude/worktrees/overlay" rev-parse HEAD)" = "$(git -C "$OV1" rev-parse origin/HEAD)" ]
  [ "$(git -C "$OV1" rev-parse HEAD)" != "$(git -C "$OV1" rev-parse origin/HEAD)" ]
}

@test "overlay: a slot left on a branch with a dirty file is reused untouched" {
  overlay_stub
  OV1=$(overlay_repo ov1)
  overlay_cfg fake1.toml "$OV1"
  git -C "$OV1" worktree add -q -b side "$OV1/.claude/worktrees/overlay"
  echo edit >"$OV1/.claude/worktrees/overlay/scratch.txt"
  git -C "$OV1/.claude/worktrees/overlay" add scratch.txt
  FAKE_SHELL_SLEEP=2 opane fake1 "$OV1"
  press fake1 ''
  until_ok 'grep -q "pwd=$OV1/.claude/worktrees/overlay args=.*claude-peer ov1-overlay\$" "$FAKE_SHELL_LOG"'
  [ "$(git -C "$OV1/.claude/worktrees/overlay" symbolic-ref --short HEAD)" = side ]
  [ "$(git -C "$OV1/.claude/worktrees/overlay" status --porcelain)" = "A  scratch.txt" ]
}

@test "overlay: a second leader's pane takes the overlay's pool and says the first is in use" {
  overlay_stub
  OV1=$(overlay_repo ov1)
  overlay_cfg fake1.toml "$OV1"
  mkdir "$REPO/sub"
  FAKE_SHELL_SLEEP=4 opane fake1 "$OV1" "$REPO" a
  press a ''
  until_ok 'grep -q "claude-peer ov1-overlay\$" "$FAKE_SHELL_LOG"'
  FAKE_SHELL_SLEEP=2 opane fake1 "$OV1" "$REPO/sub" b
  press b ''
  until_ok 'grep -q "claude-peer ov1-zeta\$" "$FAKE_SHELL_LOG"'
  grep -qF "Zeta (this pane's Fake1 is in use by the peers of $REPO)" "$BATS_TEST_TMPDIR/pane-b.out"
}

@test "overlay: an unknown name, and an overlay deleted after listing, are one line and a plain shell" {
  overlay_stub
  OV1=$(overlay_repo ov1)
  overlay_cfg fake1.toml "$OV1"
  run sh "$BIN" overlay nope
  [ "$status" -eq 0 ]
  [[ "$output" == "claude-peer: no overlay 'nope' on this machine (claude-peer overlays lists them; a changed set needs claude-peer install with iTerm2 quit); plain shell"$'\n'"pwd=$REPO"$'\n'* ]]
  [[ "$output" == *"args=-i" ]]
  run sh "$BIN" overlay 2
  [[ "$output" == *"no overlay pane 2 is installed on this machine"* ]]
  rm -rf "$OV1"
  run sh "$BIN" overlay fake1
  [ "$status" -eq 0 ]
  [[ "$output" == *"no overlay 'fake1' on this machine"* ]]
  [[ "$output" == *"pwd=$REPO"$'\n'* ]]
  [[ "$output" == *"args=-i" ]]
}

@test "overlay: no argument or two is usage, exit 2" {
  run sh "$BIN" overlay
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage: claude-peer"* ]]
  [[ "$output" != *"unknown command"* ]]
  run sh "$BIN" overlay fake1 fake2
  [ "$status" -eq 2 ]
}

@test "overlay: CLAUDE_PROFILE is unset for the session, and a number reaches the pane install wrote" {
  overlay_stub
  OV1=$(overlay_repo ov1); OV2=$(overlay_repo ov2)
  overlay_cfg fake_a.toml "$OV1"
  overlay_cfg fake-b.toml "$OV2"
  cat >"$BATS_TEST_TMPDIR/bin/profshell" <<'STUB'
#!/bin/sh
echo "pwd=$PWD profile=${CLAUDE_PROFILE-unset}" >>"$FAKE_SHELL_LOG"
sleep 1
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/profshell"
  export SHELL="$BATS_TEST_TMPDIR/bin/profshell"
  export CLAUDE_PROFILE=x
  # rows sort fake-b, fake_a; the state file says pane 1 is fake-b
  mkdir -p "$XDG_STATE_HOME/claude-peer"
  printf 'fake-b fake_a\n' >"$XDG_STATE_HOME/claude-peer/overlays"
  opane 1 "$OV2" "$REPO" one
  press one ''
  until_ok 'grep -q "^pwd=$OV2/.claude/worktrees/overlay profile=unset\$" "$FAKE_SHELL_LOG"'
  grep -q "^Fake-b: Return" "$BATS_TEST_TMPDIR/pane-one.out"
}

@test "overlay: a number is the pane install wrote, by the state file, not the row of overlays now" {
  overlay_stub
  OV1=$(overlay_repo ov1); OV2=$(overlay_repo ov2)
  overlay_cfg fake_a.toml "$OV1"
  overlay_cfg fake-b.toml "$OV2"
  mkdir -p "$XDG_STATE_HOME/claude-peer"
  printf 'fake_a\n' >"$XDG_STATE_HOME/claude-peer/overlays"
  # row 1 of `overlays` is fake-b; the pane install wrote as 1 is fake_a
  opane 1 "$OV1"
  # the pane writes its wait file before its first line
  until_ok 'grep -q "^Fake_a: Return" "$BATS_TEST_TMPDIR/pane-1.out"'
  [ ! -e "$OV2/.git/claude-peer.wait" ]
}

@test "overlay: a number with no pane behind it is one line and a plain shell" {
  overlay_stub
  overlay_cfg fake1.toml "$(overlay_repo ov1)"
  local f="$XDG_STATE_HOME/claude-peer/overlays" m
  obg 1 nofile
  mkdir -p "${f%/*}"
  printf 'fake1\n' >"$f"
  obg 2 past
  obg 0 zero
  for m in "nofile 1" "past 2" "zero 0"; do
    [ "$(sed -n 1p "$BATS_TEST_TMPDIR/bg-${m% *}.out")" = "claude-peer: no overlay pane ${m#* } is installed on this machine (claude-peer status says what is; claude-peer install with iTerm2 quit writes them); plain shell" ]
    grep -qx "pwd=$REPO" "$BATS_TEST_TMPDIR/bg-${m% *}.out"
  done
  # a name in the state file that this machine no longer has
  printf 'gone fake1\n' >"$f"
  obg 1 gone
  [ "$(sed -n 1p "$BATS_TEST_TMPDIR/bg-gone.out")" = "claude-peer: no overlay 'gone' on this machine (claude-peer overlays lists them; a changed set needs claude-peer install with iTerm2 quit); plain shell" ]
  grep -qx "pwd=$REPO" "$BATS_TEST_TMPDIR/bg-gone.out"
}

# ov_prefs: the stubs, a chezmoi stub and a fixture store with iTerm2 quit
ov_prefs() {
  stubs
  overlay_stub
  mkprefs "$BATS_TEST_TMPDIR/prefs.plist"
  export CLAUDE_PEER_PREFS="$BATS_TEST_TMPDIR/prefs.plist"
  OV_STATE="$XDG_STATE_HOME/claude-peer/overlays"
}

@test "install overlays: with none configured it is today's install, and no state file exists" {
  ov_prefs
  run sh "$BIN" install
  [ "$status" -eq 0 ]
  [ "$output" = "claude-peer: \"Claude Peers\" written and \"Claude Peers + Hermes\" written in $CLAUDE_PEER_PREFS; start iTerm2, then Shell > Workgroups > Claude Peers in a plain tab" ]
  [ "$(pyget "$(groups "$CLAUDE_PEER_PREFS")" '[x["uniqueIdentifier"] for x in g]')" = "['builtin.claudeCode', 'claudePeer.workgroup', 'claudePeer.h']" ]
  [ ! -e "$OV_STATE" ]
  [ ! -e "$BATS_TEST_TMPDIR/chezmoi.log" ]
}

@test "install overlays: two overlays add the pair, one pane each after the others, and a state file" {
  ov_prefs
  OV1=$(overlay_repo ov1); OV2=$(overlay_repo ov2)
  overlay_cfg fake2.toml "$OV2"
  overlay_cfg fake1.toml "$OV1"
  run sh "$BIN" install
  [ "$status" -eq 0 ]
  [[ "$output" == *'"Claude Peers + Overlays" written and "Claude Peers + Hermes + Overlays" written in '* ]]
  g=$(groups "$CLAUDE_PEER_PREFS")
  [ "$(pyget "$g" '[x["uniqueIdentifier"] for x in g]')" = "['builtin.claudeCode', 'claudePeer.workgroup', 'claudePeer.h', 'claudePeer.v.overlays', 'claudePeer.v.overlays.h']" ]
  o=$(pyget "$g" 'json.dumps(g[3])'); oh=$(pyget "$g" 'json.dumps(g[4])'); h=$(pyget "$g" 'json.dumps(g[2])')
  [ "$(pyget "$o" 'g["name"]')" = "Claude Peers + Overlays" ]
  [ "$(pyget "$oh" 'g["name"]')" = "Claude Peers + Hermes + Overlays" ]
  [ "$(pyget "$o" '[s["displayName"] for s in g["sessions"]]')" = "['Lead', 'Alpha', 'Beta', 'Gamma', 'Delta', 'Epsilon', 'Overlay 1', 'Overlay 2']" ]
  [ "$(pyget "$oh" '[s["displayName"] for s in g["sessions"]]')" = "['Lead', 'Alpha', 'Beta', 'Gamma', 'Delta', 'Epsilon', 'Hermes', 'Overlay 1', 'Overlay 2']" ]
  [ "$(pyget "$o" 'all(s["uniqueIdentifier"].startswith(g["uniqueIdentifier"] + ".") for s in g["sessions"])')" = True ]
  [ "$(pyget "$oh" 'all(s["uniqueIdentifier"].startswith(g["uniqueIdentifier"] + ".") for s in g["sessions"])')" = True ]
  [ "$(pyget "$o" 'set(s["parentID"] for s in g["sessions"][1:])')" = "{'claudePeer.v.overlays.main'}" ]
  [ "$(pyget "$oh" 'set(s["parentID"] for s in g["sessions"][1:])')" = "{'claudePeer.v.overlays.h.main'}" ]
  [ "$(pyget "$oh" '[s["uniqueIdentifier"] for s in g["sessions"]][6:]')" = "['claudePeer.v.overlays.h.hermes', 'claudePeer.v.overlays.h.o.1', 'claudePeer.v.overlays.h.o.2']" ]
  [ "$(pyget "$oh" '[s["command"] for s in g["sessions"]][:7]')" = "$(pyget "$h" '[s["command"] for s in g["sessions"]]')" ]
  [ "$(pyget "$o" '[s["command"] for s in g["sessions"]][6:]')" = "['claude-peer overlay 1', 'claude-peer overlay 2']" ]
  [ "$(pyget "$oh" '[s["command"] for s in g["sessions"]][7:]')" = "['claude-peer overlay 1', 'claude-peer overlay 2']" ]
  [ "$(pyget "$o" 'set(s["kind"]["kind"] for s in g["sessions"][1:])')" = "{'peer'}" ]
  [ "$(pyget "$o" 'g["sessions"][-1]["toolbarItems"]')" = "[{'kind': 'modeSwitcher'}]" ]
  [ "$(cat "$OV_STATE")" = "fake1 fake2" ]
  # a second install replaces the pair
  run sh "$BIN" install
  [ "$status" -eq 0 ]
  [[ "$output" == *'"Claude Peers + Overlays" replaced and "Claude Peers + Hermes + Overlays" replaced'* ]]
  [ "$(pyget "$(groups "$CLAUDE_PEER_PREFS")" 'len(g)')" = 5 ]
  # the plain definitions are what they were
  run sh "$BIN" workgroup
  [ "$(pyget "$output" '[s["displayName"] for s in g["sessions"]]')" = "['Lead', 'Alpha', 'Beta', 'Gamma', 'Delta', 'Epsilon']" ]
}

@test "install overlays: a smaller set rebuilds the pair, none removes it and the state file" {
  ov_prefs
  OV1=$(overlay_repo ov1); OV2=$(overlay_repo ov2)
  overlay_cfg fake1.toml "$OV1"
  overlay_cfg fake2.toml "$OV2"
  sh "$BIN" install >/dev/null
  rm "$HOME/.config/chezmoi/fake1.toml"
  run sh "$BIN" install
  [ "$status" -eq 0 ]
  [[ "$output" == *'"Claude Peers + Overlays" replaced'* ]]
  g=$(groups "$CLAUDE_PEER_PREFS")
  [ "$(pyget "$g" '[s["displayName"] for s in g[3]["sessions"]]')" = "['Lead', 'Alpha', 'Beta', 'Gamma', 'Delta', 'Epsilon', 'Overlay 1']" ]
  [ "$(cat "$OV_STATE")" = fake2 ]
  rm "$HOME/.config/chezmoi/fake2.toml"
  run sh "$BIN" install
  [ "$status" -eq 0 ]
  [[ "$output" == *'"Claude Peers + Overlays" removed and "Claude Peers + Hermes + Overlays" removed'* ]]
  [ "$(pyget "$(groups "$CLAUDE_PEER_PREFS")" '[x["uniqueIdentifier"] for x in g]')" = "['builtin.claudeCode', 'claudePeer.workgroup', 'claudePeer.h']" ]
  [ ! -e "$OV_STATE" ]
}

@test "install overlays: with the enter file the pair gets its triggers, and loses them with the overlays" {
  ov_prefs
  addprofiles "$CLAUDE_PEER_PREFS"
  OV1=$(overlay_repo ov1)
  sh "$BIN" install >/dev/null
  sh "$BIN" default peers >/dev/null
  before=$(params "$CLAUDE_PEER_PREFS")
  overlay_cfg fake1.toml "$OV1"
  run sh "$BIN" install
  [ "$status" -eq 0 ]
  [[ "$output" == *"variable triggers changed in 2 profiles"* ]]
  [ "$(params "$CLAUDE_PEER_PREFS")" = "One:builtin.claudeCode:j* One:claudePeer.workgroup:v One:claudePeer.h:v One:claudePeer.v.overlays:v One:claudePeer.v.overlays.h:v Two:builtin.claudeCode:j* Two:claudePeer.workgroup:v Two:claudePeer.h:v Two:claudePeer.v.overlays:v Two:claudePeer.v.overlays.h:v Other:someone.else:j" ]
  python3 -I - "$CLAUDE_PEER_PREFS" <<'PY'
import plistlib, sys
pl = plistlib.load(open(sys.argv[1], "rb"))
rx = {t["parameter"]: t["eventParams"]["variableValueRegex"] for t in pl["New Bookmarks"][0]["Triggers"] if "eventParams" in t}
assert rx["claudePeer.v.overlays"] == "^overlays:", rx
assert rx["claudePeer.v.overlays.h"] == "^overlays/hermes:", rx
PY
  rm "$HOME/.config/chezmoi/fake1.toml"
  run sh "$BIN" install
  [[ "$output" == *"variable triggers changed in 2 profiles"* ]]
  [ "$(params "$CLAUDE_PEER_PREFS")" = "$before" ]
}

@test "install overlays: a store that cannot be written leaves no state file" {
  ov_prefs
  mkprefs "$CLAUDE_PEER_PREFS" junk
  OV1=$(overlay_repo ov1)
  overlay_cfg fake1.toml "$OV1"
  run sh "$BIN" install
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a JSON list"* ]]
  [ ! -e "$OV_STATE" ]
}

@test "install overlays: a skipped config reaches the operator's stderr and gets no pane" {
  ov_prefs
  OV1=$(overlay_repo ov1)
  overlay_cfg fake1.toml "$OV1"
  overlay_cfg fake2.toml "$BATS_TEST_TMPDIR/nowhere"
  run --separate-stderr sh "$BIN" install
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"overlay config fake2.toml: chezmoi names no source directory; skipped"* ]]
  [ "$(cat "$OV_STATE")" = fake1 ]
}

# ov_store_strings <plist>: every string the store holds, one per line; data values are
# decoded and, where they are JSON, walked
ov_store_strings() {
  python3 -I - "$1" <<'PY'
import json, plistlib, sys
def walk(v):
    if isinstance(v, dict):
        for k, x in v.items():
            yield str(k)
            yield from walk(x)
    elif isinstance(v, (list, tuple)):
        for x in v:
            yield from walk(x)
    elif isinstance(v, bytes):
        t = v.decode("utf-8", "replace")
        yield t
        try:
            yield from walk(json.loads(t))
        except ValueError:
            pass
    elif isinstance(v, str):
        yield v
for s in walk(plistlib.load(open(sys.argv[1], "rb"))):
    print(s)
PY
}

@test "install overlays: the store holds positions and no overlay name, config name or path" {
  ov_prefs
  addprofiles "$CLAUDE_PEER_PREFS"
  OV1=$(overlay_repo ov1); OV2=$(overlay_repo ov2)
  overlay_cfg fake1.toml "$OV1"
  overlay_cfg Fake.Two.toml "$OV2"
  sh "$BIN" install >/dev/null
  sh "$BIN" default peers >/dev/null
  sh "$BIN" install >/dev/null
  local s; s=$(ov_store_strings "$CLAUDE_PEER_PREFS")
  [[ "$s" == *"claudePeer.v.overlays.h.o.2"* ]]
  [[ "$s" == *"claude-peer overlay 2"* ]]
  [[ "$s" == *"Overlay 2"* ]]
  [[ "${s,,}" != *fake* ]]
  [[ "$s" != *ov1* ]]
  [[ "$s" != *ov2* ]]
  [[ "$s" != *"$BATS_TEST_TMPDIR"* ]]
  [ "$(cat "$OV_STATE")" = "fake-two fake1" ]
}

@test "install overlays: the command install wrote reaches its overlay, and a new overlay does not re-point it" {
  ov_prefs
  OV1=$(overlay_repo ov1); OV2=$(overlay_repo ov2)
  overlay_cfg fake1.toml "$OV1"
  overlay_cfg fake2.toml "$OV2"
  sh "$BIN" install >/dev/null
  local g; g=$(groups "$CLAUDE_PEER_PREFS")
  [ "$(pyget "$g" 'g[3]["sessions"][-1]["command"]')" = "claude-peer overlay 2" ]
  overlay_cfg fake0.toml "$(overlay_repo ov0)"
  opane 2 "$OV2"
  until_ok 'grep -q "^Fake2: Return" "$BATS_TEST_TMPDIR/pane-2.out"'
  ov_status
  [[ "$output" == *"overlays: installed, out of date (Overlay 1 = Fake1, Overlay 2 = Fake2); this machine has 3 (Overlay 1 = Fake0, Overlay 2 = Fake1, Overlay 3 = Fake2) — claude-peer install (with iTerm2 quit)"* ]]
}

# --- overlays: status ---------------------------------------------------------------

# ov_status: status, from inside $REPO, with the public source at $REPO
ov_status() { FAKE_CHEZMOI_SOURCE="$REPO" run --separate-stderr sh "$BIN" status; }

@test "status overlays: a machine with none prints no overlay line at all" {
  ov_prefs
  run sh "$BIN" status
  [ "$status" -eq 0 ]
  [[ "$output" != *overlay* ]]
  [[ "$output" != *"out of date"* ]]
  sh "$BIN" install >/dev/null
  run sh "$BIN" status
  [[ "$output" == *"hermes: installed"* ]]
  [[ "$output" != *overlay* ]]
}

@test "status overlays: not installed says what this machine has" {
  ov_prefs
  overlay_cfg fake1.toml "$(overlay_repo ov1)"
  overlay_cfg fake2.toml "$(overlay_repo ov2)"
  ov_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"overlays: not installed — this machine has 2 (Fake1, Fake2); claude-peer install (with iTerm2 quit)"* ]]
  [[ "$output" != *"state file"* ]]
}

@test "status overlays: installed, then out of date when the set changes, then none now" {
  ov_prefs
  overlay_cfg fake1.toml "$(overlay_repo ov1)"
  overlay_cfg fake2.toml "$(overlay_repo ov2)"
  sh "$BIN" install >/dev/null
  ov_status
  [[ "$output" == *"overlays: installed (2 panes: Overlay 1 = Fake1, Overlay 2 = Fake2)"* ]]
  [[ "$output" != *"out of date"* ]]
  [[ "$output" != *"state file"* ]]
  overlay_cfg fake3.toml "$(overlay_repo ov3)"
  ov_status
  [[ "$output" == *"overlays: installed, out of date (Overlay 1 = Fake1, Overlay 2 = Fake2); this machine has 3 (Overlay 1 = Fake1, Overlay 2 = Fake2, Overlay 3 = Fake3) — claude-peer install (with iTerm2 quit)"* ]]
  rm "$HOME"/.config/chezmoi/fake*.toml
  ov_status
  [[ "$output" == *"overlays: installed (Overlay 1 = Fake1, Overlay 2 = Fake2), but this machine has none now — claude-peer install (with iTerm2 quit) removes them"* ]]
}

@test "status overlays: one group of the pair missing is out of date" {
  ov_prefs
  overlay_cfg fake1.toml "$(overlay_repo ov1)"
  sh "$BIN" install >/dev/null
  python3 -I - "$CLAUDE_PEER_PREFS" <<'PY'
import json, plistlib, sys
pl = plistlib.load(open(sys.argv[1], "rb"))
gs = [g for g in json.loads(pl["Workgroups"]) if g["uniqueIdentifier"] != "claudePeer.v.overlays.h"]
pl["Workgroups"] = json.dumps(gs).encode()
plistlib.dump(pl, open(sys.argv[1], "wb"))
PY
  ov_status
  [[ "$output" == *"overlays: installed, out of date (Overlay 1 = Fake1); this machine has 1 (Overlay 1 = Fake1)"* ]]
}

@test "status overlays: as many overlays under other names is out of date" {
  ov_prefs
  overlay_cfg fake1.toml "$(overlay_repo ov1)"
  sh "$BIN" install >/dev/null
  rm "$HOME/.config/chezmoi/fake1.toml" "$HOME/.config/chezmoi/fake1.toml.src"
  overlay_cfg fake9.toml "$(overlay_repo ov9)"
  ov_status
  [[ "$output" == *"overlays: installed, out of date (Overlay 1 = Fake1); this machine has 1 (Overlay 1 = Fake9) — claude-peer install (with iTerm2 quit)"* ]]
}

@test "status overlays: the state file and the store disagree in both directions" {
  ov_prefs
  overlay_cfg fake1.toml "$(overlay_repo ov1)"
  sh "$BIN" install >/dev/null
  rm "$OV_STATE"
  ov_status
  [[ "$output" == *"overlays: installed (1 panes: Overlay 1 = Fake1)"* ]]
  [[ "$output" == *"overlays: installed, but the state file is missing, so claude-peer here stays base and no overlay pane finds its overlay — claude-peer install (with iTerm2 quit)"* ]]
  mkdir -p "${OV_STATE%/*}"
  printf 'fake1 fake9\n' >"$OV_STATE"
  mkprefs "$CLAUDE_PEER_PREFS"
  ov_status
  [[ "$output" == *"overlays: not installed — this machine has 1 (Fake1)"* ]]
  [[ "$output" == *"overlays: the state file lists fake1 fake9 but no overlay workgroup is installed, so a claude tab in the chezmoi source enters no workgroup — claude-peer install (with iTerm2 quit)"* ]]
  # a state file alone, with no overlay on the machine and none installed, is still said
  rm "$HOME/.config/chezmoi/fake1.toml"
  ov_status
  [[ "$output" == *"overlays: the state file lists fake1 fake9 but no overlay workgroup"* ]]
}

@test "status overlays: while iTerm2 runs the domain is what is read, for the overlay lines too" {
  ov_prefs
  overlay_cfg fake1.toml "$(overlay_repo ov1)"
  sh "$BIN" install >/dev/null
  mkprefs "$BATS_TEST_TMPDIR/domain.plist"
  export FAKE_DOMAIN="$BATS_TEST_TMPDIR/domain.plist"
  ov_status
  [[ "$output" == *"overlays: installed (1 panes: Overlay 1 = Fake1)"* ]]
  FAKE_PROCS=iTerm2 ov_status
  [[ "$output" == *"overlays: not installed — this machine has 1 (Fake1)"* ]]
}

@test "status overlays: from the shell, where tabs enter from and who is in each pane" {
  ov_prefs
  OV1=$(overlay_repo ov1); OV2=$(overlay_repo ov2)
  overlay_cfg fake1.toml "$OV1"
  overlay_cfg fake2.toml "$OV2"
  ov_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"overlays: entered from $REPO"* ]]
  [[ "$output" == *"overlay: fake1 idle in $OV1"* ]]
  [[ "$output" == *"overlay: fake2 idle in $OV2"* ]]
  [[ "$output" == *"peers: 0 running, 0 waiting in $REPO"*"overlays: entered from"* ]]
  ov_busy "$OV2" "$REPO" wait-only
  ov_status
  [[ "$output" == *"overlay: fake2 waiting in $OV2 (tab of $REPO, pid $OV_WAIT)"* ]]
  printf '%s\n%s\nAlpha\n' "$OV_CLAIM" "$REPO" >"$(git -C "$OV2/.claude/worktrees/alpha" rev-parse --absolute-git-dir)/claude-peer.claim"
  ov_status
  [[ "$output" == *"overlay: fake2 running in $OV2 (tab of $REPO, pid $OV_CLAIM)"* ]]
  [[ "$output" == *"overlay: fake1 idle in $OV1"* ]]
  # no source directory for the public source
  run --separate-stderr sh "$BIN" status
  [[ "$output" == *"overlays: chezmoi names no source directory in a git repository, so no tab enters them"* ]]
}

# --- overlays: here ---------------------------------------------------------------

# ov_here: here, from the directory given, with the public source at $REPO
ov_here() { cd "${1:-$REPO}"; FAKE_CHEZMOI_SOURCE="$REPO" run --separate-stderr sh "$BIN" here; }

# ov_ready: one overlay and the state file install writes
ov_ready() {
  overlay_stub
  overlay_cfg fake1.toml "$(overlay_repo ov1)"
  mkdir -p "$XDG_STATE_HOME/claude-peer"
  echo fake1 >"$XDG_STATE_HOME/claude-peer/overlays"
}

@test "here overlays: the public source with an overlay and the state file enters the overlay workgroup" {
  ov_ready
  ov_here
  [ "$status" -eq 0 ]
  [ "$output" = overlays ]
  [ -z "$stderr" ]
  # a linked worktree of the public source is the public source
  git -C "$REPO" worktree add -q --detach "$BATS_TEST_TMPDIR/linked"
  ov_here "$BATS_TEST_TMPDIR/linked"
  [ "$output" = overlays ]
  [ -z "$stderr" ]
  # as is a subdirectory of it
  mkdir "$REPO/sub"
  ov_here "$REPO/sub"
  [ "$output" = overlays ]
}

@test "here overlays: every other case stays base, silently" {
  ov_ready
  # another repository
  OTHER=$(overlay_repo other)
  ov_here "$OTHER"
  [ "$status" -eq 0 ]; [ "$output" = base ]; [ -z "$stderr" ]
  # no repository
  mkdir "$BATS_TEST_TMPDIR/plain"
  ov_here "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 0 ]; [ "$output" = base ]; [ -z "$stderr" ]
  # chezmoi fails
  FAKE_CHEZMOI_FAIL=1 ov_here
  [ "$status" -eq 0 ]; [ "$output" = base ]; [ -z "$stderr" ]
  # no overlay now
  rm "$HOME/.config/chezmoi/fake1.toml" "$HOME/.config/chezmoi/fake1.toml.src"
  ov_here
  [ "$status" -eq 0 ]; [ "$output" = base ]; [ -z "$stderr" ]
  # an empty state file
  overlay_cfg fake1.toml "$(overlay_repo ov1b)"
  : >"$XDG_STATE_HOME/claude-peer/overlays"
  ov_here
  [ "$status" -eq 0 ]; [ "$output" = base ]; [ -z "$stderr" ]
}

@test "here overlays: without the state file a deployed script still answers base, and never asks chezmoi" {
  overlay_stub
  overlay_cfg fake1.toml "$(overlay_repo ov1)"
  ov_here
  [ "$status" -eq 0 ]; [ "$output" = base ]; [ -z "$stderr" ]
  [ ! -e "$BATS_TEST_TMPDIR/chezmoi.log" ]
  run sh "$BIN" here extra
  [ "$status" -eq 2 ]
}
