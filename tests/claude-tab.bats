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
  # osascript: logs its arguments, keeps the script it was fed, and answers by
  # which script it was (the listing, or the focus). FAKE_OSA_FAIL is the
  # Automation-denied failure.
  export OSA_LOG="$BATS_TEST_TMPDIR/osa-log" OSA_SCRIPT="$BATS_TEST_TMPDIR/osa-script"
  : > "$OSA_LOG"
  cat > "$BIN/osascript" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$OSA_LOG"
cat > "$OSA_SCRIPT"
if [ -n "${FAKE_OSA_FAIL:-}" ]; then
  echo "execution error: Not authorised to send Apple events to iTerm2. (-1743)" >&2
  exit 1
fi
if grep -q 'return out' "$OSA_SCRIPT"; then printf '%s\n' "${FAKE_TABS:-}"
elif grep -q 'select w' "$OSA_SCRIPT"; then printf '%s\n' "${FAKE_FOCUS-ok}"
fi
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
  FAKE_PROCS="" run sh "$CT" list
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

@test "tabs prints iTerm2's sessions; nothing when iTerm2 is not running or off macOS" {
  export FAKE_TABS=$'42\t/dev/ttys003\talpha\n43\t/dev/ttys004\t✳ Some topic (claude)'
  run sh "$CT" tabs
  [ "$status" -eq 0 ]
  [ "$output" = "$FAKE_TABS" ]
  FAKE_PROCS="" run sh "$CT" tabs
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  : > "$OSA_LOG"
  FAKE_OS=Linux run sh "$CT" tabs
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$OSA_LOG" ]
}

@test "tabs reports a denied Automation grant" {
  FAKE_OSA_FAIL=1 run --separate-stderr sh "$CT" tabs
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"-1743"* ]]
}

@test "list joins on tty: iterm2, other, unknown; one listing for all rows" {
  a=$(make_repo alpha)
  live_pid; p1=$LIVE; make_session "$HOME/.claude" "$p1" "$a"
  live_pid; p2=$LIVE; make_session "$HOME/.claude" "$p2" "$a"
  live_pid; p3=$LIVE; make_session "$HOME/.claude" "$p3" "$a"
  cat > "$PS_TABLE" <<EOF_TABLE
$p1 500 ttys003
$p2 501 ttys009
$p3 502 ??
502 1 ??
EOF_TABLE
  export FAKE_TABS=$'42\t/dev/ttys003\t✳ Some topic (claude)'
  run sh "$CT" list
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | awk -F'\t' -v p="$p1" '$1 == p { print $8 "|" $9 "|" $10 }')" = "iterm2|42|✳ Some topic (claude)" ]
  [ "$(printf '%s\n' "$output" | awk -F'\t' -v p="$p2" '$1 == p { print $8 "|" $9 "|" $10 }')" = "other|-|-" ]
  [ "$(printf '%s\n' "$output" | awk -F'\t' -v p="$p3" '$1 == p { print $8 }')" = headless ]
  [ "$(wc -l < "$OSA_LOG" | tr -d ' ')" -eq 1 ]
  FAKE_PROCS="" run sh "$CT" list
  [ "$(printf '%s\n' "$output" | awk -F'\t' -v p="$p1" '$1 == p { print $8 }')" = unknown ]
  FAKE_OSA_FAIL=1 run sh "$CT" list
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | awk -F'\t' -v p="$p1" '$1 == p { print $8 }')" = unknown ]
}

# focus_session <tty> : one live session on that tty; sets PID.
focus_session() {
  a=$(make_repo alpha)
  live_pid; PID=$LIVE
  make_session "$HOME/.claude" "$PID" "$a"
  printf '%s 500 %s\n' "$PID" "${1#/dev/}" > "$PS_TABLE"
}

@test "focus selects the session, tab and window, then activates" {
  focus_session /dev/ttys003
  run sh "$CT" focus "$PID"
  [ "$status" -eq 0 ]
  grep -q 'is "/dev/ttys003"' "$OSA_SCRIPT"
  grep -q 'select s' "$OSA_SCRIPT"
  grep -q 'select t' "$OSA_SCRIPT"
  grep -q 'select w' "$OSA_SCRIPT"
  grep -q 'activate' "$OSA_SCRIPT"
}

@test "focus failures name the cause and exit 1; misuse exits 2" {
  focus_session /dev/ttys003
  run --separate-stderr sh "$CT" focus "$(dead_pid)"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "claude-tab: no live session with pid "* ]]

  : > "$PS_TABLE"
  run --separate-stderr sh "$CT" focus "$PID"
  [ "$status" -eq 1 ]
  [ "$stderr" = "claude-tab: pid $PID has no terminal (headless)" ]

  printf '%s 500 ttys003\n' "$PID" > "$PS_TABLE"
  FAKE_FOCUS="" run --separate-stderr sh "$CT" focus "$PID"
  [ "$status" -eq 1 ]
  [ "$stderr" = "claude-tab: pid $PID is on /dev/ttys003, which is not an iTerm2 tab" ]

  FAKE_PROCS="" run --separate-stderr sh "$CT" focus "$PID"
  [ "$status" -eq 1 ]
  [ "$stderr" = "claude-tab: iTerm2 is not running" ]

  : > "$OSA_LOG"
  FAKE_OSA_FAIL=1 run --separate-stderr sh "$CT" focus "$PID"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"claude-tab: osascript could not drive iTerm2 — if macOS asked for Automation permission and was denied, grant it in System Settings > Privacy & Security > Automation" ]]
  [ "$(wc -l < "$OSA_LOG" | tr -d ' ')" -eq 3 ]

  run sh "$CT" focus
  [ "$status" -eq 2 ]
  FAKE_OS=Linux run sh "$CT" focus "$PID"
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs macOS"* ]]
}

@test "focus escapes the tty into the AppleScript" {
  focus_session '/dev/ttys"3'
  run sh "$CT" focus "$PID"
  [ "$status" -eq 0 ]
  grep -qF 'is "/dev/ttys\"3"' "$OSA_SCRIPT"
}

@test "unbuilt and unknown commands fail; no command is a usage error" {
  run sh "$CT"
  [ "$status" -eq 2 ]
  run sh "$CT" bogus
  [ "$status" -eq 1 ]
}
