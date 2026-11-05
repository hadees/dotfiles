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

@test "workgroup: five sessions in order, the builtin Diff copied, chat peers run claude-peer" {
  mkprefs "$BATS_TEST_TMPDIR/prefs.plist"
  CLAUDE_PEER_PREFS="$BATS_TEST_TMPDIR/prefs.plist" run sh "$BIN" workgroup
  [ "$status" -eq 0 ]
  [ "$(pyget "$output" '[g["uniqueIdentifier"], g["name"]]')" = "['claudePeer.workgroup', 'Claude Peers']" ]
  [ "$(pyget "$output" '[s["uniqueIdentifier"] for s in g["sessions"]]')" = "['claudePeer.main', 'claudePeer.diff', 'claudePeer.chat2', 'claudePeer.chat3', 'claudePeer.chat4']" ]
  [ "$(pyget "$output" 'g["sessions"][0]["kind"]')" = "{'kind': 'root'}" ]
  [ "$(pyget "$output" '[i["kind"] for i in g["sessions"][0]["toolbarItems"]]')" = "['modeSwitcher', 'gitStatus', 'fixtureItem']" ]
  [ "$(pyget "$output" 'g["sessions"][1]["command"]')" = 'fixture-diff \(gitBase)' ]
  [ "$(pyget "$output" 'g["sessions"][1]["parentID"]')" = "claudePeer.main" ]
  [ "$(pyget "$output" 'g["sessions"][1]["toolbarItems"][1]["reloadShortcut"]["serialized"]')" = "0x1-0x2-0x3" ]
  [ "$(pyget "$output" '[s["command"] for s in g["sessions"][2:]]')" = "['claude-peer run', 'claude-peer run', 'claude-peer run']" ]
  [ "$(pyget "$output" '[s["toolbarItems"] for s in g["sessions"][2:]][0]')" = "[{'kind': 'modeSwitcher'}]" ]
  [ "$(pyget "$output" '[s["displayName"] for s in g["sessions"][2:]]')" = "['Chat 2', 'Chat 3', 'Chat 4']" ]
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
  [[ "$output" == *"workgroup: installed (5 sessions: Chat, Review, Chat 2, Chat 3, Chat 4)"* ]]
  FAKE_OS=Linux run sh "$BIN" status
  [[ "$output" == *"status needs macOS"* ]]
  FAKE_OS=Linux run sh "$BIN" install
  [ "$status" -eq 2 ]
}
