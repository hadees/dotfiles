#!/usr/bin/env bats

# ~/bin/claude-peer: make or reuse a worktree for a slot or a branch under
# <repo>/.claude/worktrees/<name>, cd into it and run claude through the shell as
# a child, with a claim that lasts as long as the session. A stub shell stands in
# for $SHELL so nothing starts a real claude.
# Everything runs in a sandboxed HOME against fixture repos with invented names.

setup() {
  BIN="$BATS_TEST_DIRNAME/../bin/executable_claude-peer"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR"
  export CLAUDE_PEER_SETTLE=0
  git config --global user.name octo
  git config --global user.email octo@example.com
  git config --global init.defaultBranch main
  cat >"$BATS_TEST_TMPDIR/bin/fakeshell" <<'STUB'
#!/bin/sh
echo "pwd=$PWD"
echo "peer=${CLAUDE_PEER_WORKTREE-unset}"
echo "args=$*"
[ -z "${FAKE_SHELL_SLEEP-}" ] || sleep "$FAKE_SHELL_SLEEP"
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
  for i in $(seq 1 100); do
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

@test "status: the peers line counts running slots; leftover names peer-N worktrees from the old layout" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/domain.plist"
  export FAKE_DOMAIN="$BATS_TEST_TMPDIR/domain.plist" FAKE_LOAD=0
  run sh "$BIN" status
  [[ "$output" == *"peers: 0 running in $REPO"* ]]
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
  [[ "$output" == *"peers: 1 running in $REPO: Alpha (alpha)"* ]]
  [[ "$output" != *"leftover:"* ]]
  wait "$rpid"
  cd "$BATS_TEST_TMPDIR"; mkdir norepo; cd norepo
  run sh "$BIN" status
  [[ "$output" != *"peers:"* ]]
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

@test "workgroup: six sessions in order, the builtin Diff copied, chat peers run claude-peer, Hermes last" {
  mkprefs "$BATS_TEST_TMPDIR/prefs.plist"
  CLAUDE_PEER_PREFS="$BATS_TEST_TMPDIR/prefs.plist" run sh "$BIN" workgroup
  [ "$status" -eq 0 ]
  [ "$(pyget "$output" '[g["uniqueIdentifier"], g["name"]]')" = "['claudePeer.workgroup', 'Claude Peers']" ]
  [ "$(pyget "$output" '[s["uniqueIdentifier"] for s in g["sessions"]]')" = "['claudePeer.main', 'claudePeer.diff', 'claudePeer.chat2', 'claudePeer.chat3', 'claudePeer.chat4', 'claudePeer.hermes']" ]
  [ "$(pyget "$output" 'g["sessions"][0]["kind"]')" = "{'kind': 'root'}" ]
  [ "$(pyget "$output" '[i["kind"] for i in g["sessions"][0]["toolbarItems"]]')" = "['modeSwitcher', 'gitStatus', 'fixtureItem']" ]
  [ "$(pyget "$output" 'g["sessions"][1]["command"]')" = 'fixture-diff \(gitBase)' ]
  [ "$(pyget "$output" 'g["sessions"][1]["parentID"]')" = "claudePeer.main" ]
  [ "$(pyget "$output" 'g["sessions"][1]["toolbarItems"][1]["reloadShortcut"]["serialized"]')" = "0x1-0x2-0x3" ]
  [ "$(pyget "$output" '[s["command"] for s in g["sessions"][2:5]]')" = "['claude-peer run', 'claude-peer run', 'claude-peer run']" ]
  [ "$(pyget "$output" '[s["toolbarItems"] for s in g["sessions"][2:]][0]')" = "[{'kind': 'modeSwitcher'}]" ]
  [ "$(pyget "$output" '[s["displayName"] for s in g["sessions"][2:5]]')" = "['Chat 2', 'Chat 3', 'Chat 4']" ]
  [ "$(pyget "$output" '[g["sessions"][5][k] for k in ("uniqueIdentifier", "displayName", "command", "parentID", "toolbarItems")]')" = "['claudePeer.hermes', 'Hermes', 'claude-peer hermes', 'claudePeer.main', [{'kind': 'modeSwitcher'}]]" ]
  [ "$(pyget "$output" 'g["sessions"][5]["kind"]')" = "{'kind': 'peer'}" ]
}

@test "workgroup: with no builtin in the store the templates stand in" {
  mkprefs "$BATS_TEST_TMPDIR/prefs.plist" empty
  CLAUDE_PEER_PREFS="$BATS_TEST_TMPDIR/prefs.plist" run sh "$BIN" workgroup
  [ "$status" -eq 0 ]
  [ "$(pyget "$output" 'g["sessions"][1]["command"]')" = 'git difftool -y -x vimdiff \(gitBase)' ]
  [ "$(pyget "$output" 'g["sessions"][1]["mode"]')" = "diff" ]
  [ "$(pyget "$output" '[i["kind"] for i in g["sessions"][0]["toolbarItems"]]')" = "['modeSwitcher', 'gitStatus']" ]
  [ "$(pyget "$output" '[i["kind"] for i in g["sessions"][1]["toolbarItems"]]')" = "['modeSwitcher', 'changedFileSelector', 'gitBaseSelector', 'navigation']" ]
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

@test "install: folder store gains the workgroup after the builtin; a second run replaces it" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/prefs.plist"
  export CLAUDE_PEER_PREFS="$BATS_TEST_TMPDIR/prefs.plist"
  run sh "$BIN" install
  [ "$status" -eq 0 ]
  [[ "$output" == *"claudePeer.workgroup) written in $CLAUDE_PEER_PREFS"* ]]
  g=$(groups "$CLAUDE_PEER_PREFS")
  [ "$(pyget "$g" '[x["uniqueIdentifier"] for x in g]')" = "['builtin.claudeCode', 'claudePeer.workgroup']" ]
  grep -q '<?xml' "$CLAUDE_PEER_PREFS"
  [ "$(python3 -I -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["Ponies"])' "$CLAUDE_PEER_PREFS")" = sentinel ]
  run sh "$BIN" install
  [ "$status" -eq 0 ]
  [[ "$output" == *"replaced"* ]]
  [ "$(pyget "$(groups "$CLAUDE_PEER_PREFS")" 'len(g)')" = 2 ]
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
  [ "$(pyget "$(groups "$FAKE_DOMAIN")" '[x["uniqueIdentifier"] for x in g]')" = "['builtin.claudeCode', 'claudePeer.workgroup']" ]
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

@test "status: store, iTerm2, workgroup and builtin lines; off macOS it refuses" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/domain.plist"
  mkdir "$BATS_TEST_TMPDIR/prefsdir"
  export FAKE_DOMAIN="$BATS_TEST_TMPDIR/domain.plist" FAKE_LOAD=1 FAKE_FOLDER="$BATS_TEST_TMPDIR/prefsdir"
  run sh "$BIN" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"store: folder $BATS_TEST_TMPDIR/prefsdir/com.googlecode.iterm2.plist"* ]]
  [[ "$output" == *"iterm2: not running (install allowed)"* ]]
  [[ "$output" == *"workgroup: not installed"* ]]
  [[ "$output" == *"builtin: builtin.claudeCode present"* ]]
  FAKE_PROCS=iTerm2 run sh "$BIN" status
  [[ "$output" == *"iterm2: running"* ]]
  CLAUDE_PEER_PREFS="$FAKE_DOMAIN" sh "$BIN" install >/dev/null
  run sh "$BIN" status
  [[ "$output" == *"workgroup: installed (6 sessions: Chat, Review, Chat 2, Chat 3, Chat 4, Hermes)"* ]]
  FAKE_OS=Linux run sh "$BIN" status
  [[ "$output" == *"status needs macOS"* ]]
  FAKE_OS=Linux run sh "$BIN" install
  [ "$status" -eq 2 ]
}

@test "status: a workgroup older than this version says out of date; install clears it" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/domain.plist"
  export FAKE_DOMAIN="$BATS_TEST_TMPDIR/domain.plist"
  CLAUDE_PEER_PREFS="$FAKE_DOMAIN" sh "$BIN" install >/dev/null
  python3 -I - "$FAKE_DOMAIN" <<'PY'
import json, plistlib, sys
pl = plistlib.load(open(sys.argv[1], "rb"))
groups = json.loads(pl["Workgroups"])
next(g for g in groups if g["uniqueIdentifier"] == "claudePeer.workgroup")["sessions"].pop()
pl["Workgroups"] = json.dumps(groups).encode()
plistlib.dump(pl, open(sys.argv[1], "wb"))
PY
  run sh "$BIN" status
  [[ "$output" == *"workgroup: installed, out of date (5 sessions: Chat, Review, Chat 2, Chat 3, Chat 4)"* ]]
  [[ "$output" == *"this version defines 6 (Chat, Review, Chat 2, Chat 3, Chat 4, Hermes)"* ]]
  CLAUDE_PEER_PREFS="$FAKE_DOMAIN" sh "$BIN" install >/dev/null
  run sh "$BIN" status
  [[ "$output" == *"workgroup: installed (6 sessions: "* ]]
  [[ "$output" != *"out of date"* ]]
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

# params <path>: each profile's Enter Workgroup parameter, space separated
params() {
  python3 -I -c 'import plistlib, sys; pl = plistlib.load(open(sys.argv[1], "rb")); print(" ".join(t["parameter"] for b in pl["New Bookmarks"] for t in b["Triggers"] if t["action"] == "iTermEnterWorkgroupTrigger"))' "$1"
}

@test "default: peers moves every builtin trigger, leaves other workgroups alone; builtin moves them back" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/prefs.plist"
  addprofiles "$BATS_TEST_TMPDIR/prefs.plist"
  export CLAUDE_PEER_PREFS="$BATS_TEST_TMPDIR/prefs.plist"
  sh "$BIN" install >/dev/null
  run sh "$BIN" default peers
  [ "$status" -eq 0 ]
  [[ "$output" == *"enters Claude Peers"*"2 of 2 profiles changed"* ]]
  [ "$(params "$CLAUDE_PEER_PREFS")" = "claudePeer.workgroup claudePeer.workgroup someone.else" ]
  [ "$(python3 -I -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["Ponies"])' "$CLAUDE_PEER_PREFS")" = sentinel ]
  run sh "$BIN" default peers
  [[ "$output" == *"0 of 2 profiles changed"* ]]
  run sh "$BIN" default builtin
  [ "$status" -eq 0 ]
  [ "$(params "$CLAUDE_PEER_PREFS")" = "builtin.claudeCode builtin.claudeCode someone.else" ]
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
  run sh "$BIN" default sideways
  [ "$status" -eq 2 ]
  mkprefs "$BATS_TEST_TMPDIR/bare.plist"
  CLAUDE_PEER_PREFS="$BATS_TEST_TMPDIR/bare.plist" run sh "$BIN" default builtin
  [ "$status" -eq 1 ]; [[ "$output" == *"no profile has an Enter Workgroup trigger"* ]]
}

@test "status: the default line reads builtin, peers or mixed from the profiles" {
  stubs
  mkprefs "$BATS_TEST_TMPDIR/domain.plist"
  addprofiles "$BATS_TEST_TMPDIR/domain.plist"
  export FAKE_DOMAIN="$BATS_TEST_TMPDIR/domain.plist" FAKE_LOAD=0
  run sh "$BIN" status
  [[ "$output" == *"default: builtin (2 profiles enter Claude Code)"* ]]
  sh "$BIN" install >/dev/null
  sh "$BIN" default peers >/dev/null
  run sh "$BIN" status
  [[ "$output" == *"default: peers (2 profiles enter Claude Peers)"* ]]
  python3 -I - "$FAKE_DOMAIN" <<'PY'
import plistlib, sys
p = sys.argv[1]; pl = plistlib.load(open(p, "rb"))
pl["New Bookmarks"][0]["Triggers"][0]["parameter"] = "builtin.claudeCode"
plistlib.dump(pl, open(p, "wb"))
PY
  run sh "$BIN" status
  [[ "$output" == *"default: mixed (1 of 2 profiles enter Claude Peers)"* ]]
}
