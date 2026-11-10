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
  # ps: `-Ao` lists process names (FAKE_PROCS); `-t <tty>` answers "stat ucomm"
  # rows from the file PS_TTY_DIR/<tty>; `-p a,b` answers from the PS_TABLE
  # file ("pid ppid tty" per line), padded the way real ps pads. A parent-walk
  # query for a pid with no row answers FAKE_OWN_TTY, the tty restore runs on.
  export PS_TTY_DIR="$BATS_TEST_TMPDIR/ps-tty"
  mkdir -p "$PS_TTY_DIR"
  cat > "$BIN/ps" <<'STUB'
#!/bin/sh
case "$*" in
  *-Ao*) for p in ${FAKE_PROCS:-}; do printf '%s\n' "$p"; done; exit 0;;
esac
fmt=3
case "$*" in *"-o ppid=,tty="*) fmt=2;; esac
while [ $# -gt 0 ]; do case $1 in -p) ids=$2; shift 2;; -t) tt=$2; shift 2;; *) shift;; esac; done
if [ -n "${tt:-}" ]; then cat "$PS_TTY_DIR/$(printf '%s' "$tt" | tr / _)" 2>/dev/null; exit 0; fi
for id in $(printf '%s' "$ids" | tr ',' ' '); do
  found=0
  while read -r pid ppid tty; do
    [ "$pid" = "$id" ] || continue
    found=1
    if [ "$fmt" = 2 ]; then printf '%5s %-7s\n' "$ppid" "$tty"
    else printf '%5s %5s %-7s\n' "$pid" "$ppid" "$tty"; fi
  done < "$PS_TABLE"
  if [ "$found" = 0 ] && [ "$fmt" = 2 ] && [ -n "${FAKE_OWN_TTY:-}" ]; then
    printf '%5s %-7s\n' 1 "$FAKE_OWN_TTY"
  fi
done
exit 0
STUB
  # osascript: logs its arguments, keeps the script it was fed, and answers by
  # which script it was (the listing, or the focus). FAKE_OSA_FAIL is the
  # Automation-denied failure.
  export OSA_LOG="$BATS_TEST_TMPDIR/osa-log" OSA_SCRIPT="$BATS_TEST_TMPDIR/osa-script"
  export OSA_ALL="$BATS_TEST_TMPDIR/osa-all"
  : > "$OSA_LOG"; : > "$OSA_ALL"
  cat > "$BIN/osascript" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$OSA_LOG"
cat > "$OSA_SCRIPT"
cat "$OSA_SCRIPT" >> "$OSA_ALL"
if [ -n "${FAKE_OSA_FAIL:-}" ]; then
  echo "execution error: Not authorised to send Apple events to iTerm2. (-1743)" >&2
  exit 1
fi
if grep -q '^-- restore:' "$OSA_SCRIPT"; then printf '%s\n' "${FAKE_RESTORE_TABS:-}"
elif grep -q 'return out' "$OSA_SCRIPT"; then printf '%s\n' "${FAKE_TABS:-}"
elif grep -q 'write text' "$OSA_SCRIPT"; then printf '%s\n' "${FAKE_WRITE-ok}"
elif grep -q 'select w' "$OSA_SCRIPT"; then printf '%s\n' "${FAKE_FOCUS-ok}"
fi
exit 0
STUB
  # sleep: logs short sleeps and returns at once; the 300 s sleepers live_pid
  # starts go to the real one.
  export SLEEP_LOG="$BATS_TEST_TMPDIR/sleep-log"
  : > "$SLEEP_LOG"
  printf '#!/bin/sh\ncase "${1:-0}" in 300) exec %s 300;; esac\nprintf "%%s\\n" "$*" >> "$SLEEP_LOG"\n' "$(command -v sleep)" > "$BIN/sleep"
  chmod +x "$BIN"/*
  export PATH="$BIN:$PATH"
}

# make_session <profile dir> <pid> <cwd> [name] [status] [sessionId] [kind]
make_session() {
  mkdir -p "$1/sessions"
  printf '{"pid":%s,"sessionId":"%s","cwd":"%s","kind":"%s","name":"%s","status":"%s"}\n' \
    "$2" "${6:-fixture}" "$3" "${7:-interactive}" "${4:-fixture-session}" "${5:-idle}" > "$1/sessions/$2.json"
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

# --- save --------------------------------------------------------------------

# tty_of <pid> <tty> : the ps table row for a session's claude process.
tty_of() { printf '%s 500 %s\n' "$1" "$2" >> "$PS_TABLE"; }

# stub_peer : a claude-peer that answers `peers` with $FAKE_PEERS.
stub_peer() {
  printf '#!/bin/sh\nprintf "%%s\\n" "${FAKE_PEERS:-}"\n' > "$BATS_TEST_TMPDIR/claude-peer"
  chmod +x "$BATS_TEST_TMPDIR/claude-peer"
  export CLAUDE_TAB_PEER="$BATS_TEST_TMPDIR/claude-peer"
}

@test "save writes live sessions in iTerm2 tab order and leaves out what cannot be resumed" {
  a=$(make_repo alpha); b=$(make_repo beta); g=$(make_repo gamma); o=$(make_repo omega)
  peer=$(make_repo peerdir)
  stub_peer
  export FAKE_PEERS="$peer	123	$a"
  live_pid; pa=$LIVE; make_session "$HOME/.claude" "$pa" "$a" na idle sid-a; tty_of "$pa" ttys001
  live_pid; pb=$LIVE; make_session "$HOME/.claude" "$pb" "$b" nb idle sid-b; tty_of "$pb" ttys002
  live_pid; pg=$LIVE; make_session "$HOME/.claude-personal" "$pg" "$g" ng idle sid-g; tty_of "$pg" ttys003
  live_pid; po=$LIVE; make_session "$HOME/.claude" "$po" "$o" no idle sid-o; tty_of "$po" ttys009
  # left out: peer, headless, non-interactive, cwd gone, bad session id
  live_pid; make_session "$HOME/.claude" "$LIVE" "$peer" np idle sid-p; tty_of "$LIVE" ttys004
  live_pid; make_session "$HOME/.claude" "$LIVE" "$a" nh idle sid-h; tty_of "$LIVE" '??'
  live_pid; make_session "$HOME/.claude" "$LIVE" "$a" nk idle sid-k sdk; tty_of "$LIVE" ttys005
  live_pid; make_session "$HOME/.claude" "$LIVE" "$BATS_TEST_TMPDIR/gone" ng2 idle sid-x; tty_of "$LIVE" ttys006
  live_pid; make_session "$HOME/.claude" "$LIVE" "$a" ni idle 'bad id'; tty_of "$LIVE" ttys007
  export FAKE_TABS=$'8\t/dev/ttys003\tg\n7\t/dev/ttys002\tb\n7\t/dev/ttys001\ta'
  f="$BATS_TEST_TMPDIR/out/saved.tsv"
  run --separate-stderr sh "$CT" save "$f"
  [ "$status" -eq 0 ]
  [ "$stderr" = "claude-tab: saved 4 sessions to $f (left out: 1 peers, 1 headless, 3 other)" ]
  [[ "$(head -1 "$f")" =~ ^'# claude-tab save '[0-9T:Z-]+' 4 sessions'$ ]]
  [ "$(tail -n +2 "$f" | cut -f2,4,6,7,8 | tr '\t' ' ')" = "sid-g gamma /dev/ttys003 iterm2 8
sid-b beta /dev/ttys002 iterm2 7
sid-a alpha /dev/ttys001 iterm2 7
sid-o omega /dev/ttys009 other -" ]
  [ "$(sed -n 2p "$f" | cut -f1,3)" = "$(printf '%s\t%s' "$HOME/.claude-personal" "$g")" ]
}

@test "save recognises a peer by its worktree name when claude-peer is absent" {
  a=$(make_repo alpha); mkdir -p "$a/.claude/worktrees/peer-2"
  export CLAUDE_TAB_PEER="$BATS_TEST_TMPDIR/nowhere"
  live_pid; make_session "$HOME/.claude" "$LIVE" "$a" n1 idle sid-1; tty_of "$LIVE" ttys001
  live_pid; make_session "$HOME/.claude" "$LIVE" "$a/.claude/worktrees/peer-2" n2 idle sid-2; tty_of "$LIVE" ttys002
  f="$BATS_TEST_TMPDIR/saved.tsv"
  run --separate-stderr sh "$CT" save "$f"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"saved 1 sessions"*"1 peers"* ]]
  [ "$(tail -n +2 "$f" | cut -f2)" = sid-1 ]
}

@test "save defaults to the XDG state file, rotates the old one to .prev, and works off macOS" {
  a=$(make_repo alpha)
  live_pid; make_session "$HOME/.claude" "$LIVE" "$a" n1 idle sid-1; tty_of "$LIVE" ttys001
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  FAKE_OS=Linux FAKE_PROCS="" run sh "$CT" save
  [ "$status" -eq 0 ]
  f="$XDG_STATE_HOME/claude-tab/saved.tsv"
  [ "$(tail -n +2 "$f" | cut -f2,6,7,8 | tr '\t' ' ')" = "sid-1 /dev/ttys001 - -" ]
  cp "$f" "$BATS_TEST_TMPDIR/first"
  run sh "$CT" save
  [ "$status" -eq 0 ]
  [ "$(tail -n +2 "$f.prev")" = "$(tail -n +2 "$BATS_TEST_TMPDIR/first")" ]
}

@test "save with nothing to save exits 1 and leaves the existing file byte-identical" {
  f="$BATS_TEST_TMPDIR/saved.tsv"
  printf '# claude-tab save old 1 sessions\nrow\n' > "$f"
  cp "$f" "$BATS_TEST_TMPDIR/before"
  run --separate-stderr sh "$CT" save "$f"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no sessions to save"*"$f left untouched" ]]
  cmp "$f" "$BATS_TEST_TMPDIR/before"
  [ ! -e "$f.prev" ]
}

# --- restore -----------------------------------------------------------------

# saved_row <profile dir> <session id> <cwd> <label> : one row of $SAVED.
saved_row() {
  printf '%s\t%s\t%s\t%s\tname\t/dev/ttys099\titerm2\t7\n' "$1" "$2" "$3" "$4" >> "$SAVED"
}

# idle_tty <tty> [extra "stat ucomm" row] : a tty sitting at a shell prompt.
idle_tty() {
  printf 'Ss+ -zsh\n' > "$PS_TTY_DIR/$1"
  [ -z "${2-}" ] || printf '%s\n' "$2" >> "$PS_TTY_DIR/$1"
}

# restore_world : window 7 (current) holds the caller (ttys001), two empty tabs
# (ttys002, ttys007), a tab running vim (ttys003) and a two-session tab
# (ttys004, ttys005); window 8 holds one more empty tab (ttys006).
restore_world() {
  SAVED="$BATS_TEST_TMPDIR/saved.tsv"
  printf '# claude-tab save fixture\n' > "$SAVED"
  export FAKE_OWN_TTY=ttys001
  export FAKE_RESTORE_TABS=$'7\t1\t1\t/dev/ttys001\t1\n7\t2\t1\t/dev/ttys002\t1\n7\t3\t1\t/dev/ttys003\t1\n7\t4\t2\t/dev/ttys004\t1\n7\t4\t2\t/dev/ttys005\t1\n7\t5\t1\t/dev/ttys007\t1\n8\t1\t1\t/dev/ttys006\t0'
  for t in ttys001 ttys002 ttys004 ttys005 ttys006 ttys007; do idle_tty $t; done
  idle_tty ttys003 'S+ vim'
  mkdir -p "$HOME/.claude-personal"
}

@test "restore --dry-run fills empty tabs of the current window first, then makes new tabs" {
  restore_world
  a=$(make_repo alpha); b=$(make_repo beta); c=$(make_repo gamma)
  saved_row "$HOME/.claude-personal" sid-a "$a" alpha
  saved_row "$HOME/.claude-personal" sid-b "$b" beta
  saved_row "$HOME/.claude-personal" sid-c "$c" gamma
  run --separate-stderr sh "$CT" restore --dry-run "$SAVED"
  [ "$status" -eq 0 ]
  [ "$(col 1,2,3 | tr '\t' ' ')" = "fill /dev/ttys002 alpha
fill /dev/ttys007 beta
new - gamma" ]
  [ "$(col 4 | head -1)" = "cd -- '$a' && CLAUDE_PROFILE='$HOME/.claude-personal' claude --resume sid-a" ]
  # a dry run asks iTerm2 for its tabs once and nothing else
  [ "$(wc -l < "$OSA_LOG" | tr -d ' ')" -eq 1 ]
}

@test "restore never uses the caller's tab, a busy tab, a shared tab or another window's tab" {
  restore_world
  for i in 1 2 3 4 5; do
    r=$(make_repo "r$i"); saved_row "$HOME/.claude-personal" "sid-$i" "$r" "r$i"
  done
  run sh "$CT" restore --dry-run "$SAVED"
  [ "$status" -eq 0 ]
  [ "$(col 1,2 | tr '\t' ' ')" = "fill /dev/ttys002
fill /dev/ttys007
new -
new -
new -" ]
}

@test "restore --window picks the window, and counts the empty tabs it leaves in others" {
  restore_world
  a=$(make_repo alpha); saved_row "$HOME/.claude-personal" sid-a "$a" alpha
  run sh "$CT" restore --dry-run --window 8 "$SAVED"
  [ "$status" -eq 0 ]
  [ "$(col 1,2 | tr '\t' ' ')" = "fill /dev/ttys006" ]
  # no current window and no --window: refuse, never open one
  FAKE_RESTORE_TABS=$'7\t1\t1\t/dev/ttys002\t0' run --separate-stderr sh "$CT" restore --dry-run "$SAVED"
  [ "$status" -eq 1 ]
  [ "$stderr" = "claude-tab: no iTerm2 window to restore into (open one, or pass --window)" ]
}

@test "restore skips what is live (by session id or cwd), what is gone, and a missing profile" {
  restore_world
  a=$(make_repo alpha); b=$(make_repo beta); c=$(make_repo gamma); d=$(make_repo delta)
  live_pid; make_session "$HOME/.claude-personal" "$LIVE" "$a" n idle sid-a
  live_pid; make_session "$HOME/.claude-personal" "$LIVE" "$b" n idle other-id
  saved_row "$HOME/.claude-personal" sid-a "$a" alpha
  saved_row "$HOME/.claude-personal" sid-b "$b" beta
  saved_row "$HOME/.claude-personal" sid-c "$BATS_TEST_TMPDIR/gone" gone
  saved_row "$BATS_TEST_TMPDIR/no-profile" sid-d "$d" nodir
  # live in a different profile does not count: sessions are per profile
  live_pid; make_session "$HOME/.claude" "$LIVE" "$c" n idle sid-c2
  saved_row "$HOME/.claude-personal" sid-c2 "$c" gamma
  run sh "$CT" restore --dry-run "$SAVED"
  [ "$status" -eq 0 ]
  [ "$(col 1,3 | tr '\t' ' ')" = "skip:live alpha
skip:live beta
skip:cwd-gone gone
skip:profile-gone nodir
fill gamma" ]
}

@test "the typed command survives a cwd with a space and a quote" {
  restore_world
  r=$(make_repo "it's here")
  printf '#!/bin/sh\nprintf "%%s|%%s\\n" "$PWD" "$*"\n' > "$BIN/claude"
  chmod +x "$BIN/claude"
  saved_row "$HOME/.claude-personal" sid-q "$r" quoted
  run sh "$CT" restore --dry-run "$SAVED"
  [ "$status" -eq 0 ]
  cmd=$(col 4)
  run sh -c "$cmd"
  [ "$status" -eq 0 ]
  [ "$output" = "$r|--resume sid-q" ]
}

@test "restore types into fills and new tabs, delays between them, and never makes a window" {
  restore_world
  for i in 1 2 3; do
    r=$(make_repo "r$i"); saved_row "$HOME/.claude-personal" "sid-$i" "$r" "r$i"
  done
  r4=$(make_repo "r\"4"); saved_row "$HOME/.claude-personal" sid-4 "$r4" r4
  run --separate-stderr sh "$CT" restore --delay 2 "$SAVED"
  [ "$status" -eq 0 ]
  [ "$stderr" = "claude-tab: restored 2 into empty tabs, 2 in new tabs, 0 skipped; 1 empty tabs in other windows left alone" ]
  [ "$(grep -c 'write text' "$OSA_ALL")" -eq 4 ]
  grep -qF "write text \"cd -- '$BATS_TEST_TMPDIR/r1' && CLAUDE_PROFILE='$HOME/.claude-personal' claude --resume sid-1\"" "$OSA_ALL"
  grep -qF "write text \"cd -- '$BATS_TEST_TMPDIR/r\\\"4' &&" "$OSA_ALL"
  grep -qF 'is "/dev/ttys002"' "$OSA_ALL"
  grep -qF 'is "/dev/ttys007"' "$OSA_ALL"
  [ "$(grep -c 'create tab with default profile' "$OSA_ALL")" -eq 2 ]
  [ "$(grep -c 'whose id is 7' "$OSA_ALL")" -eq 4 ]
  ! grep -q 'create window' "$OSA_ALL"
  [ "$(grep -cx 2 "$SLEEP_LOG")" -eq 3 ]
}

@test "restore refuses cleanly: off macOS, no iTerm2, no file, Automation denied" {
  restore_world
  a=$(make_repo alpha); saved_row "$HOME/.claude-personal" sid-a "$a" alpha
  FAKE_OS=Linux run sh "$CT" restore "$SAVED"
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs macOS"* ]]
  FAKE_PROCS="" run --separate-stderr sh "$CT" restore "$SAVED"
  [ "$status" -eq 1 ]
  [ "$stderr" = "claude-tab: iTerm2 is not running" ]
  run --separate-stderr sh "$CT" restore "$BATS_TEST_TMPDIR/missing.tsv"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "claude-tab: no saved sessions at $BATS_TEST_TMPDIR/missing.tsv"* ]]
  FAKE_OSA_FAIL=1 run --separate-stderr sh "$CT" restore "$SAVED"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"claude-tab: osascript could not drive iTerm2 — if macOS asked for Automation permission and was denied, grant it in System Settings > Privacy & Security > Automation" ]]
  run sh "$CT" restore --bogus
  [ "$status" -eq 2 ]
}

@test "AppleScript separators are a real tab character, never the tab keyword" {
  # Inside `tell application "iTerm2"`, `tab` is iTerm2's tab class: the
  # listing came back with the literal word, and restore found no window.
  # The stubbed osascript in these tests cannot see that, so pin the source.
  ! grep -n '& tab &' "$BATS_TEST_DIRNAME/../bin/executable_claude-tab" "$BATS_TEST_DIRNAME/../bin/executable_worktabs"
  grep -q 'set sep to (character id 9)' "$BATS_TEST_DIRNAME/../bin/executable_claude-tab"
}
