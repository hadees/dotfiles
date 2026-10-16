#!/usr/bin/env bats

# bin/claude-tab lists the live Claude Code sessions across every profile and
# brings the chosen one's iTerm2 tab forward. These tests drive the real script
# under a sandboxed HOME with stub ps/uname binaries and the REAL tabname, so
# the join between the two scripts (exit 1 means nogit, the format key flows
# through) is what is pinned. Sessions are registry fixtures; no window is
# ever touched. All names here are fixtures (see CLAUDE.md).

bats_require_minimum_version 1.5.0

setup() {
  # python3 is resolved to its real interpreter before HOME is sandboxed, and
  # re-exposed under a stub on PATH below: an asdf shim resolves relative to
  # $HOME and exits 126 the moment that is overridden.
  REAL_PYTHON3=''
  REAL_PYTHON3="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)" || REAL_PYTHON3=''
  [ -n "$REAL_PYTHON3" ] || skip "python3 not installed"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/bin"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  unset CLAUDE_CONFIG_DIR CLAUDE_PROFILE XDG_STATE_HOME CLAUDE_TAB_TABNAME
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.work-account '~/.claude'
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.personal-account '~/.claude-personal'

  CT="$BATS_TEST_DIRNAME/../bin/executable_claude-tab"
  ln -s "$BATS_TEST_DIRNAME/../bin/executable_tabname" "$HOME/bin/tabname"

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_PYTHON3" > "$BIN/python3"
  export FAKE_OS=Darwin
  export FAKE_PROCS="iTerm2"
  export PS_TABLE="$BATS_TEST_TMPDIR/ps-table"
  : > "$PS_TABLE"
  cat > "$BIN/uname" <<'STUB'
#!/bin/sh
printf '%s\n' "${FAKE_OS:-Darwin}"
STUB
  # ps: `-Ao` lists process names (FAKE_PROCS); `-p a,b` answers from the
  # PS_TABLE file ("pid ppid tty" per line), padded the way real ps pads.
  cat > "$BIN/ps" <<'STUB'
#!/bin/sh
case "$*" in
  *-Ao*) for p in ${FAKE_PROCS:-}; do printf '%s\n' "$p"; done; exit 0;;
esac
fmt=3
case "$*" in *"-o ppid=,tty="*) fmt=2;; esac
while [ $# -gt 0 ]; do case $1 in -p) ids=$2; shift 2;; *) shift;; esac; done
for id in $(printf '%s' "$ids" | tr ',' ' '); do
  while read -r pid ppid tty; do
    [ "$pid" = "$id" ] || continue
    if [ "$fmt" = 2 ]; then printf '%5s %-7s\n' "$ppid" "$tty"
    else printf '%5s %5s %-7s\n' "$pid" "$ppid" "$tty"; fi
  done < "$PS_TABLE"
done
exit 0
STUB
  chmod +x "$BIN"/*
  export PATH="$BIN:$PATH"
}

# make_session <profile dir> <pid> <cwd> [name] [status]
make_session() {
  mkdir -p "$1/sessions"
  printf '{"pid":%s,"sessionId":"fixture","cwd":"%s","kind":"interactive","name":"%s","status":"%s"}\n' \
    "$2" "$3" "${4:-fixture-session}" "${5:-idle}" > "$1/sessions/$2.json"
}

# make_repo <name> : a repo with one commit; prints its path.
make_repo() {
  r="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$r"
  git -C "$r" init -q
  git -C "$r" -c user.name=Fixture -c user.email=fixture@example.com commit -q --allow-empty -m init
  printf '%s\n' "$r"
}

# make_worktree <repo path> <name> : a linked worktree under .claude/worktrees.
make_worktree() {
  git -C "$1" worktree add -q "$1/.claude/worktrees/$2" -b "$2"
}

# live_pid : sets LIVE to a pid that is alive until teardown, so each fixture
# session can have a pid of its own.
live_pid() {
  sleep 300 >/dev/null 2>&1 </dev/null 3>&- &
  LIVE=$!
  printf '%s\n' "$LIVE" >> "$BATS_TEST_TMPDIR/sleepers"
}

teardown() {
  # a file, not a variable: label_place calls live_pid inside $(...)
  [ ! -f "$BATS_TEST_TMPDIR/sleepers" ] || xargs kill < "$BATS_TEST_TMPDIR/sleepers" 2>/dev/null || true
}

# A pid that certainly was, and no longer is.
dead_pid() {
  sh -c 'exit 0' &
  d=$!
  wait "$d"
  printf '%s\n' "$d"
}

# col <n> : column n of every line of $output.
col() { printf '%s\n' "$output" | cut -f"$1"; }

@test "list finds a session in every mapped profile" {
  a=$(make_repo alpha); b=$(make_repo beta)
  live_pid; pa=$LIVE; live_pid; pb=$LIVE
  make_session "$HOME/.claude" "$pa" "$a"
  make_session "$HOME/.claude-personal" "$pb" "$b"
  run sh "$CT" list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(col 1,2,3 | head -1)" = "$(printf '%s\tdefault\talpha' "$pa")" ]
  [ "$(col 1,2,3 | tail -1)" = "$(printf '%s\tpersonal\tbeta' "$pb")" ]
}

@test "list reads \$HOME/.claude with nothing mapped" {
  : > "$GIT_CONFIG_GLOBAL"
  a=$(make_repo alpha)
  live_pid
  make_session "$HOME/.claude" "$LIVE" "$a" one busy
  run sh "$CT" list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$(col 2,3,5,6)" = "$(printf 'default\talpha\tbusy\tone')" ]
}

@test "a dead pid is dropped; junk files are ignored silently" {
  a=$(make_repo alpha)
  live_pid
  make_session "$HOME/.claude" "$LIVE" "$a"
  make_session "$HOME/.claude" "$(dead_pid)" "$a"
  printf 'not json' > "$HOME/.claude/sessions/9999.json"
  printf '{"pid":%s}' "$LIVE" > "$HOME/.claude/sessions/x.json"
  run --separate-stderr sh "$CT" list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ -z "$stderr" ]
}

# label_place <cwd> : "label<TAB>place" of one session standing in cwd.
label_place() {
  rm -rf "$HOME/.claude/sessions"
  live_pid
  make_session "$HOME/.claude" "$LIVE" "$1"
  run sh "$CT" list
  [ "$status" -eq 0 ]
  col 3,4
}

@test "labels come from tabname: toplevel, subdir, worktree, subdir of a worktree" {
  a=$(make_repo alpha); make_worktree "$a" wt-one
  mkdir -p "$a/src" "$a/.claude/worktrees/wt-one/src"
  [ "$(label_place "$a")" = "$(printf 'alpha\t-')" ]
  [ "$(label_place "$a/src")" = "$(printf 'alpha\tsubdir=src')" ]
  [ "$(label_place "$a/.claude/worktrees/wt-one")" = "$(printf 'alpha@wt-one\t-')" ]
  [ "$(label_place "$a/.claude/worktrees/wt-one/src")" = "$(printf 'alpha@wt-one\tsubdir=src')" ]
}

@test "tabname's worktree format flows through untouched" {
  a=$(make_repo alpha); make_worktree "$a" wt-one
  git config --global tabname.worktree-format '{repo} ⎇ {worktree}'
  [ "$(label_place "$a/.claude/worktrees/wt-one")" = "$(printf 'alpha ⎇ wt-one\t-')" ]
}

@test "outside a work tree, or a vanished cwd, is nogit with the basename" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  [ "$(label_place "$BATS_TEST_TMPDIR/plain")" = "$(printf 'plain\tnogit')" ]
  gone=$(make_repo gone)
  rm -rf "$HOME/.claude/sessions"; live_pid
  make_session "$HOME/.claude" "$LIVE" "$gone"
  rm -rf "$gone"
  run sh "$CT" list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$(col 3,4)" = "$(printf 'gone\tnogit')" ]
}

@test "tabname absent: basename label, place nolabel, one warning for two rows" {
  a=$(make_repo alpha); b=$(make_repo beta)
  live_pid; make_session "$HOME/.claude" "$LIVE" "$a"
  live_pid; make_session "$HOME/.claude" "$LIVE" "$b"
  CLAUDE_TAB_TABNAME="$BATS_TEST_TMPDIR/nowhere" run --separate-stderr sh "$CT" list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(col 3,4 | sort -u)" = "$(printf 'alpha\tnolabel\nbeta\tnolabel')" ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
  [[ "$stderr" == "claude-tab: tabname not found at $BATS_TEST_TMPDIR/nowhere"* ]]
}

@test "tty: the claude process's own, the parent walk, and none at all" {
  a=$(make_repo alpha)
  live_pid; p1=$LIVE; make_session "$HOME/.claude" "$p1" "$a"
  live_pid; p2=$LIVE; make_session "$HOME/.claude" "$p2" "$a"
  live_pid; p3=$LIVE; make_session "$HOME/.claude" "$p3" "$a"
  cat > "$PS_TABLE" <<EOF_TABLE
$p1 500 ttys003
$p2 501 ??
501 502 ttys004
$p3 503 ??
503 504 ??
504 1 ??
EOF_TABLE
  run sh "$CT" list
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | awk -F'\t' -v p="$p1" '$1 == p { print $7 "|" $8 }')" = "/dev/ttys003|unknown" ]
  [ "$(printf '%s\n' "$output" | awk -F'\t' -v p="$p2" '$1 == p { print $7 "|" $8 }')" = "/dev/ttys004|unknown" ]
  [ "$(printf '%s\n' "$output" | awk -F'\t' -v p="$p3" '$1 == p { print $7 "|" $8 }')" = "-|headless" ]
}

@test "list sorts by label then pid, and the script parses" {
  a=$(make_repo alpha); b=$(make_repo beta)
  live_pid; make_session "$HOME/.claude" "$LIVE" "$b"
  live_pid; pa2=$LIVE; make_session "$HOME/.claude" "$pa2" "$a"
  live_pid; pa1=$LIVE; make_session "$HOME/.claude" "$pa1" "$a"
  run sh "$CT" list
  [ "$status" -eq 0 ]
  [ "$(col 3 | tr '\n' ' ')" = "alpha alpha beta " ]
  [ "$(col 1 | head -2 | tr '\n' ' ')" = "$(printf '%s\n%s\n' "$pa1" "$pa2" | sort -n | tr '\n' ' ')" ]
  run sh -n "$CT"
  [ "$status" -eq 0 ]
}

@test "unbuilt and unknown commands fail; no command is a usage error" {
  run sh "$CT"
  [ "$status" -eq 2 ]
  run sh "$CT" bogus
  [ "$status" -eq 1 ]
}
