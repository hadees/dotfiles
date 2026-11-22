#!/usr/bin/env bats

# `claude-tab panel tick`, the model of the needs-you list. Each test drives the
# real script under a sandboxed HOME with a stub ps and fixture registries,
# passing the clock (--now) and the focus (--focus) itself, so what is pinned is
# the rules: when a row appears, when it goes, what counts as seen. The state
# file lives under BATS_TEST_TMPDIR. All names here are fixtures (see CLAUDE.md).

bats_require_minimum_version 1.5.0

setup() {
  # python3 is resolved to its real interpreter before HOME is sandboxed (an asdf
  # shim resolves relative to $HOME and exits 126 once that is overridden).
  REAL_PYTHON3=''
  REAL_PYTHON3="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)" || REAL_PYTHON3=''
  [ -n "$REAL_PYTHON3" ] || skip "python3 not installed"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/bin"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  unset CLAUDE_CONFIG_DIR CLAUDE_PROFILE XDG_STATE_HOME
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.work-account '~/.claude'
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.personal-account '~/.claude-personal'

  CT="$BATS_TEST_DIRNAME/../bin/executable_claude-tab"
  STATE="$BATS_TEST_TMPDIR/panel-state.json"

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_PYTHON3" > "$BIN/python3"
  # ps: `-o tty= -p <pid>` answers the tty column of the PS_TABLE file ("pid ppid
  # tty" per line); `eww -p <pid>` answers the file $PS_TABLE.env.<pid> (a start-up
  # environment), if there is one; anything else answers nothing.
  export PS_TABLE="$BATS_TEST_TMPDIR/ps-table"
  : > "$PS_TABLE"
  cat > "$BIN/ps" <<'STUB'
#!/bin/sh
case "$*" in
  *-Ao*) cat "$PROCS_FILE" 2>/dev/null; exit 0;;
  *eww*) ;;
  *"-o command="*) exec /bin/ps "$@";;
esac
case "$*" in
  *eww*)
    while [ $# -gt 0 ]; do case $1 in -p) pid=$2; shift 2;; *) shift;; esac; done
    cat "$PS_TABLE.env.$pid" 2>/dev/null
    exit 0;;
  *"-o tty="*)
    while [ $# -gt 0 ]; do case $1 in -p) pid=$2; shift 2;; *) shift;; esac; done
    awk -v p="$pid" '$1 == p { print $3 }' "$PS_TABLE"
    exit 0;;
esac
exit 0
STUB
  # uname answers Darwin, and ps lists the processes in PROCS_FILE, so the serve
  # verbs run as on a Mac with iTerm2 up; emptying the file is iTerm2 quitting.
  export PROCS_FILE="$BATS_TEST_TMPDIR/procs"
  echo iTerm2 > "$PROCS_FILE"
  printf '#!/bin/sh\necho Darwin\n' > "$BIN/uname"
  # osascript: logs each call, answers the file `front` ("-" without one), or
  # fails when FAKE_OSA_FAIL is set.
  export OSA_LOG="$BATS_TEST_TMPDIR/osa-log"
  : > "$OSA_LOG"
  cat > "$BIN/osascript" <<'STUB'
#!/bin/sh
echo call >> "$OSA_LOG"
cat > /dev/null
[ -z "${FAKE_OSA_FAIL:-}" ] || exit 1
cat "$BATS_TEST_TMPDIR/front" 2>/dev/null || echo -
STUB
  chmod +x "$BIN"/*
  export PATH="$BIN:$PATH"
}

teardown() {
  pf=$HOME/.local/state/claude-tab/panel.pid
  [ ! -f "$pf" ] || kill "$(cut -d' ' -f1 "$pf")" 2>/dev/null || true
  [ ! -f "$BATS_TEST_TMPDIR/sleepers" ] || xargs kill < "$BATS_TEST_TMPDIR/sleepers" 2>/dev/null || true
  # A server whose start gave up before panel.pid was written is found by the
  # port this test gave it; none may survive the test.
  port=$(git config --file "$GIT_CONFIG_GLOBAL" claude-tab.panel-port 2>/dev/null) || port=
  if [ -n "$port" ]; then
    pkill -f -- "serve --port $port( |$)" 2>/dev/null || true
    i=0
    while pgrep -f -- "serve --port $port( |$)" >/dev/null && [ "$i" -lt 30 ]; do
      i=$((i + 1))
      sleep 0.1
    done
    ! pgrep -f -- "serve --port $port( |$)" >/dev/null || { echo "a panel server on port $port outlived its test"; false; }
  fi
}

# live_pid : sets LIVE to a pid that is alive until teardown.
live_pid() {
  sleep 300 >/dev/null 2>&1 </dev/null 3>&- &
  LIVE=$!
  printf '%s\n' "$LIVE" >> "$BATS_TEST_TMPDIR/sleepers"
}

# rec <pid> <status> <since seconds or ""> [waitingFor] [kind] [profile dir] [cwd]: a
# registry record; the session id is s<pid>, an empty since leaves the field out.
rec() {
  d=${6:-$HOME/.claude}
  mkdir -p "$d/sessions"
  printf '{"pid":%s,"sessionId":"s%s","cwd":"%s","kind":"%s","status":"%s"%s%s}\n' \
    "$1" "$1" "${7:-/work/proj}" "${5:-interactive}" "$2" "${3:+,\"statusUpdatedAt\":$(($3 * 1000))}" \
    "${4:+,\"waitingFor\":\"$4\"}" > "$d/sessions/$1.json"
}

# turn <pid> <at> <end>: the turn record of session s<pid>.
turn() {
  mkdir -p "$HOME/.local/state/tabstatus"
  printf '{"at": %s, "end": "%s", "active": 0, "quiet": 0}\n' "$2" "$3" > "$HOME/.local/state/tabstatus/s$1.turn"
}

# tick <now> [focus] [more args]: one pass; the snapshot is $output.
tick() {
  now=$1 focus=${2:-?}
  if [ $# -ge 2 ]; then shift 2; else shift; fi
  run sh "$CT" panel tick --state "$STATE" --now "$now" --focus "$focus" "$@"
  [ "$status" -eq 0 ]
}

# seed : the first pass with nothing live, so what appears later is news.
seed() { tick 100; }

# val <python expression over the snapshot d>
val() { printf '%s' "$output" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

kinds() { val '" ".join(r["kind"] for r in d["needs"])'; }

state_val() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$STATE" "$1"; }

@test "panel with no verb or an unknown one is usage" {
  run sh "$CT" panel
  [ "$status" -eq 2 ]
  [[ "$output" == *"panel tick"* ]]
  run sh "$CT" panel nope
  [ "$status" -eq 2 ]
}

@test "a waiting record is not listed at 3 s and is blocked at 4 s with its reason" {
  live_pid
  seed
  rec "$LIVE" waiting 1000 "permission prompt"
  tick 1003
  [ -z "$(kinds)" ]
  tick 1004
  [ "$(kinds)" = blocked ]
  [ "$(val 'd["needs"][0]["reason"]')" = "permission prompt" ]
  [ "$(val 'd["needs"][0]["since"]')" = 1000 ]
  [ "$(val 'd["needs"][0]["pid"]')" = "$LIVE" ]
}

@test "a waiting record with no reason says waiting" {
  live_pid
  rec "$LIVE" waiting 1000
  tick 5000
  [ "$(val 'd["needs"][0]["reason"]')" = waiting ]
}

@test "a prompt answered within 4 s is never listed and is counted" {
  live_pid
  seed
  rec "$LIVE" waiting 1000
  tick 1003
  rec "$LIVE" busy 1003
  tick 1004
  [ -z "$(kinds)" ]
  [ "$(val 'd["tally"]["hidden_prompts"]')" = 1 ]
  [ "$(val 'd["tally"]["transitions"]')" = 1 ]
  [ "$(val 'd["tally"]["entered"]')" = 0 ]
}

@test "a first tick lists a prompt that has been open for an hour" {
  live_pid
  rec "$LIVE" waiting 100
  tick 3700
  [ "$(kinds)" = blocked ]
  [ "$(val 'd["needs"][0]["since"]')" = 100 ]
}

@test "a record without a status time is timed from when it was first seen" {
  live_pid
  rec "$LIVE" waiting ""
  tick 1000
  tick 1003
  [ -z "$(kinds)" ]
  tick 1004
  [ "$(kinds)" = blocked ]
  [ "$(val 'd["needs"][0]["since"]')" = 1000 ]
}

@test "an idle record is finished at 60 s and not at 59, and newer than the state" {
  live_pid
  seed
  rec "$LIVE" idle 1000
  tick 1059
  [ -z "$(kinds)" ]
  tick 1060
  [ "$(kinds)" = finished ]
  [ "$(val 'd["needs"][0]["reason"]')" = finished ]
}

@test "a shell record is finished-bg at 900 s and not at 899" {
  live_pid
  seed
  rec "$LIVE" shell 1000
  tick 1899
  [ -z "$(kinds)" ]
  tick 1900
  [ "$(kinds)" = finished-bg ]
  [ "$(val 'd["needs"][0]["reason"]')" = "finished, background task" ]
}

@test "the thresholds come from git config, and a bad value is the default" {
  git config --file "$GIT_CONFIG_GLOBAL" claude-tab.finished-seconds 10
  git config --file "$GIT_CONFIG_GLOBAL" tabstatus.quiet-minutes 1
  live_pid; a=$LIVE; live_pid; b=$LIVE
  seed
  rec "$a" idle 1000
  rec "$b" shell 1000
  tick 1010
  [ "$(kinds)" = finished ]
  tick 1060
  [ "$(kinds)" = "finished finished-bg" ]
  git config --file "$GIT_CONFIG_GLOBAL" claude-tab.finished-seconds abc
  git config --file "$GIT_CONFIG_GLOBAL" tabstatus.quiet-minutes 0
  rm -f "$STATE"
  seed
  rec "$a" idle 2000
  rec "$b" shell 2000
  tick 2059
  [ -z "$(kinds)" ]
  tick 2060
  [ "$(kinds)" = finished ]
}

@test "a turn record ending in a question makes the idle session asked at 4 s" {
  live_pid
  seed
  rec "$LIVE" idle 1000
  turn "$LIVE" 1000 question
  tick 1003
  [ -z "$(kinds)" ]
  tick 1004
  [ "$(kinds)" = asked ]
  [ "$(val 'd["health"]["turn_records"]')" = 1 ]
}

@test "a turn record ending in an error makes it failed" {
  live_pid
  seed
  rec "$LIVE" idle 1000
  turn "$LIVE" 1000 error
  tick 1004
  [ "$(kinds)" = failed ]
}

@test "a shell session with a question record is asked at 4 s, not finished-bg" {
  live_pid
  seed
  rec "$LIVE" shell 1000
  turn "$LIVE" 1000 question
  tick 1004
  [ "$(kinds)" = asked ]
}

@test "a turn record from before the status change is ignored, 15 s is not" {
  live_pid; a=$LIVE; live_pid; b=$LIVE
  seed
  rec "$a" idle 1000
  turn "$a" 984 question
  rec "$b" idle 1000
  turn "$b" 985 question
  tick 1004
  [ "$(kinds)" = asked ]
  [ "$(val 'd["needs"][0]["pid"]')" = "$b" ]
  [ "$(val 'd["health"]["turn_records"]')" = 1 ]
}

@test "a turn record for an id that is not a plain token is not read" {
  live_pid
  seed
  mkdir -p "$HOME/.claude/sessions"
  printf '{"pid":%s,"sessionId":"../x","cwd":"/work/proj","status":"idle","statusUpdatedAt":1000000}\n' \
    "$LIVE" > "$HOME/.claude/sessions/$LIVE.json"
  turn "$LIVE" 1000 question
  tick 1004
  [ -z "$(kinds)" ]
  [ "$(val 'd["health"]["turn_records"]')" = 0 ]
}

@test "two looks at a finished session remove it and count one seen by focus" {
  live_pid
  printf '%s 1 ttys004\n' "$LIVE" > "$PS_TABLE"
  seed
  rec "$LIVE" idle 1000
  tick 1060
  [ "$(kinds)" = finished ]
  tick 1061 /dev/ttys004
  [ -z "$(kinds)" ]
  tick 1062 /dev/ttys004
  [ -z "$(kinds)" ]
  [ "$(val 'd["tally"]["seen_focus"]')" = 1 ]
  tick 1063 -
  [ -z "$(kinds)" ]
  [ "$(val 'd["tally"]["left"]')" = 1 ]
}

@test "a blocked session stays listed once seen, dimmed, and is unlisted while in front" {
  live_pid
  printf '%s 1 ttys004\n' "$LIVE" > "$PS_TABLE"
  seed
  rec "$LIVE" waiting 1000
  tick 1010
  [ "$(val 'd["needs"][0]["seen"]')" = False ]
  tick 1011 /dev/ttys004
  [ -z "$(kinds)" ]
  tick 1012 /dev/ttys004
  [ -z "$(kinds)" ]
  tick 1013 -
  [ "$(kinds)" = blocked ]
  [ "$(val 'd["needs"][0]["seen"]')" = True ]
}

@test "a focus that could not be read never marks anything seen" {
  live_pid
  printf '%s 1 ttys004\n' "$LIVE" > "$PS_TABLE"
  seed
  rec "$LIVE" idle 1000
  tick 1060 '?'
  tick 1061 '?'
  tick 1062 '?'
  tick 1063 '?'
  [ "$(kinds)" = finished ]
  [ "$(val 'd["needs"][0]["seen"]')" = False ]
  [ "$(val 'd["health"]["focus"]')" = unknown ]
}

@test "a focus on another session resets the count" {
  live_pid; a=$LIVE; live_pid; b=$LIVE
  printf '%s 1 ttys004\n%s 1 ttys005\n' "$a" "$b" > "$PS_TABLE"
  seed
  rec "$a" idle 1000
  tick 1060
  tick 1061 /dev/ttys004
  tick 1062 /dev/ttys005
  tick 1063 /dev/ttys004
  tick 1064 -
  [ "$(kinds)" = finished ]
  [ "$(val 'd["tally"]["seen_focus"]')" = 0 ]
}

@test "a first tick with no state lists nothing already finished, but lists a prompt" {
  live_pid; a=$LIVE; live_pid; b=$LIVE; live_pid; c=$LIVE; live_pid; w=$LIVE
  rec "$a" idle 100
  rec "$b" idle 100
  rec "$c" shell 100
  rec "$w" waiting 100
  tick 5000
  [ "$(kinds)" = blocked ]
  [ "$(val 'd["tally"]["entered"]')" = 1 ]
}

@test "a state file of another version starts calm again" {
  live_pid
  printf '{"v": 2, "saved_at": 100, "sessions": {}, "tally": {}}\n' > "$STATE"
  rec "$LIVE" idle 150
  tick 5000
  [ -z "$(kinds)" ]
}

@test "a state file more than a day old starts calm again" {
  live_pid
  seed
  rec "$LIVE" idle 94930
  tick 95000
  [ -z "$(kinds)" ]
  rec "$LIVE" idle 95100
  tick 95160
  [ "$(kinds)" = finished ]
}

@test "busy with a sign of life 901 s old is quiet, without one it is not and is counted" {
  live_pid
  seed
  rec "$LIVE" busy 1000
  tick 3000 '?' --life "$LIVE=2099"
  [ "$(kinds)" = quiet ]
  [ "$(val 'd["health"]["life_unknown"]')" = 0 ]
  tick 3001 '?' --life "$LIVE=2102"
  [ -z "$(kinds)" ]
  rm -f "$STATE"
  seed
  tick 3000
  [ -z "$(kinds)" ]
  [ "$(val 'd["health"]["life_unknown"]')" = 1 ]
}

@test "a busy session recently started is not looked up for a sign of life" {
  live_pid
  seed
  rec "$LIVE" busy 2900
  tick 3000
  [ "$(val 'd["health"]["life_unknown"]')" = 0 ]
}

@test "a status word it does not know is unknown at 60 s" {
  live_pid
  seed
  rec "$LIVE" zzz 1000
  tick 1059
  [ -z "$(kinds)" ]
  tick 1060
  [ "$(kinds)" = unknown ]
  [ "$(val 'd["needs"][0]["reason"]')" = "unknown: zzz" ]
}

@test "the list is ordered by rank, then by when each row entered, however they arrived" {
  live_pid; u=$LIVE; live_pid; f=$LIVE; live_pid; q=$LIVE; live_pid; b=$LIVE
  seed
  rec "$u" zzz 1000
  rec "$f" idle 1010
  rec "$q" idle 1070
  turn "$q" 1070 question
  rec "$b" waiting 1080
  tick 1060
  tick 1070
  tick 1074
  tick 1084
  [ "$(val '" ".join("%s:%s" % (r["kind"], r["pid"]) for r in d["needs"])')" = "blocked:$b asked:$q finished:$f unknown:$u" ]
}

@test "two rows of one rank entered together are ordered by pid" {
  live_pid; a=$LIVE; live_pid; b=$LIVE
  seed
  rec "$b" waiting 1000
  rec "$a" waiting 1000
  tick 1010
  [ "$(val '" ".join(str(r["pid"]) for r in d["needs"])')" = "$a $b" ]
}

@test "a headless record is counted and is neither a row nor a session" {
  live_pid; a=$LIVE; live_pid; b=$LIVE
  rec "$a" waiting 100 "" headless
  rec "$b" waiting 100
  tick 5000
  [ "$(val 'd["health"]["headless"]')" = 1 ]
  [ "$(val 'd["health"]["sessions"]')" = 1 ]
  [ "$(val 'len(d["needs"])')" = 1 ]
  [ "$(val 'sum(len(g["rows"]) for g in d["others"])')" = 1 ]
}

@test "a file with broken JSON is counted as unreadable, a file not named by a pid is not" {
  live_pid
  rec "$LIVE" idle 100
  printf '{bad' > "$HOME/.claude/sessions/12345.json"
  printf '{bad' > "$HOME/.claude/sessions/notes.json"
  tick 5000
  [ "$(val 'd["health"]["unreadable"]')" = 1 ]
  [ "$(val 'd["health"]["sessions"]')" = 1 ]
}

@test "records of every profile are read, with its label" {
  live_pid; a=$LIVE; live_pid; b=$LIVE
  rec "$a" waiting 100
  rec "$b" waiting 100 "" interactive "$HOME/.claude-personal"
  tick 5000
  [ "$(val 'd["health"]["profiles"]')" = 2 ]
  [ "$(val '" ".join(sorted(r["profile"] for r in d["needs"]))')" = "default personal" ]
}

@test "a dead pid is not a session and is dropped from the state" {
  live_pid
  rec "$LIVE" idle 100
  tick 5000
  [ "$(state_val 'len(d["sessions"])')" = 1 ]
  kill "$LIVE"
  wait "$LIVE" 2>/dev/null || true
  tick 5001
  [ "$(val 'd["health"]["sessions"]')" = 0 ]
  [ "$(state_val 'len(d["sessions"])')" = 0 ]
}

@test "a listed row that goes away is counted as leaving" {
  live_pid
  rec "$LIVE" waiting 100
  tick 5000
  kill "$LIVE"
  wait "$LIVE" 2>/dev/null || true
  tick 5001
  [ "$(val 'd["tally"]["left"]')" = 1 ]
}

@test "a new status time on the same pid is a new instance, listed again after its delay" {
  live_pid
  printf '%s 1 ttys004\n' "$LIVE" > "$PS_TABLE"
  seed
  rec "$LIVE" idle 1000
  tick 1060
  tick 1061 /dev/ttys004
  tick 1062 /dev/ttys004
  tick 1063 -
  [ -z "$(kinds)" ]
  rec "$LIVE" idle 2000
  tick 2059
  [ -z "$(kinds)" ]
  tick 2060
  [ "$(kinds)" = finished ]
  [ "$(val 'd["needs"][0]["seen"]')" = False ]
}

@test "the others hold every session once, by group, with the listed ones counted" {
  live_pid; a=$LIVE; live_pid; b=$LIVE; live_pid; c=$LIVE
  seed
  rec "$a" waiting 1000
  rec "$b" busy 1000
  rec "$c" idle 1000
  tick 1010
  [ "$(val 'len(d["others"])')" = 1 ]
  [ "$(val 'd["others"][0]["group"]')" = proj ]
  [ "$(val '(d["others"][0]["needs"], d["others"][0]["working"], d["others"][0]["idle"])')" = "(1, 1, 1)" ]
  [ "$(val '" ".join(sorted(r["kind"] for r in d["others"][0]["rows"]))')" = "blocked idle working" ]
}

@test "the output is one line of JSON with every field of the snapshot" {
  live_pid
  rec "$LIVE" waiting 100
  tick 5000 /dev/ttys001 --build abc
  [ "${#lines[@]}" -eq 1 ]
  [ "$(val 'sorted(d)')" = "['build', 'generated_at', 'health', 'needs', 'others', 'tally', 'v']" ]
  [ "$(val 'sorted(d["health"])')" = "['focus', 'headless', 'life_unknown', 'peer_turns', 'profiles', 'sessions', 'turn_records', 'unreadable', 'want_focus']" ]
  [ "$(val 'sorted(d["tally"])')" = "['entered', 'focus_failures', 'focus_reads', 'hidden_prompts', 'left', 'seen_click', 'seen_focus', 'ticks', 'transitions']" ]
  [ "$(val 'sorted(d["needs"][0])')" = "['group', 'guid', 'kind', 'label', 'pid', 'profile', 'reason', 'role', 'seen', 'since', 'tty']" ]
  [ "$(val 'sorted(d["others"][0])')" = "['group', 'idle', 'needs', 'rows', 'working']" ]
  [ "$(val 'd["build"]')" = abc ]
  [ "$(val 'd["health"]["focus"]')" = ok ]
  [ "$(val 'd["needs"][0]["label"]')" = proj ]
  [ "$(val 'd["needs"][0]["role"]')" = plain ]
}

@test "focus is none for - and unknown for ?" {
  tick 100 -
  [ "$(val 'd["health"]["focus"]')" = none ]
  tick 101 '?'
  [ "$(val 'd["health"]["focus"]')" = unknown ]
}

@test "want_focus is true while an instance is unseen and false once all are" {
  live_pid
  seed
  [ "$(val 'd["health"]["want_focus"]')" = False ]
  rec "$LIVE" idle 1000
  tick 1010
  [ "$(val 'd["health"]["want_focus"]')" = True ]
  rec "$LIVE" busy 1011
  tick 1012
  [ "$(val 'd["health"]["want_focus"]')" = False ]
}

@test "the state file is private, and is written only when something changed or a minute passed" {
  STATE="$BATS_TEST_TMPDIR/st/panel-state.json"
  tick 100
  [ "$(python3 -I -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$STATE")" = 0o600 ]
  [ "$(python3 -I -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$(dirname "$STATE")")" = 0o700 ]
  [ -z "$(ls "$(dirname "$STATE")" | grep -v '^panel-state.json$')" ]
  tick 105
  [ "$(state_val 'd["saved_at"]')" = 100.0 ]
  tick 160
  [ "$(state_val 'd["saved_at"]')" = 160.0 ]
}

@test "a state file that cannot be written is a warning, not a failure" {
  mkdir -p "$BATS_TEST_TMPDIR/ro"
  : > "$BATS_TEST_TMPDIR/ro/file"
  STATE="$BATS_TEST_TMPDIR/ro/file/panel-state.json"
  run --separate-stderr sh "$CT" panel tick --state "$STATE" --now 100
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"cannot write"* ]]
  [ "$(printf '%s' "$output" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["v"])')" = 1 ]
}

# --- who each session is --------------------------------------------------------

# make_repo <dir>: a repository with one commit. use_tabname links the real tabname.
make_repo() {
  git -c init.defaultBranch=trunk init -q "$1"
  git -C "$1" -c user.name=octo -c user.email=octo@example.com commit -q --allow-empty -m one
}
use_tabname() { ln -s "$BATS_TEST_DIRNAME/../bin/executable_tabname" "$HOME/bin/tabname"; }

# claim <worktree> <leader> <label> <line 8>: a live claim (held by this test) in the worktree's git directory.
claim() {
  printf '%s\n%s\n%s\n-\n-\n-\n-\n%s\n-\n-\n' "$$" "$2" "$3" "$4" \
    > "$(git -C "$1" rev-parse --absolute-git-dir)/claude-peer.claim"
}

# peer_fixture <line 8>: REPO with a linked worktree WT that holds a live claim ending in it.
peer_fixture() {
  REPO="$BATS_TEST_TMPDIR/proj"
  WT="$REPO/.claude/worktrees/alpha"
  make_repo "$REPO"
  git -C "$REPO" worktree add -q --detach "$WT"
  use_tabname
  claim "$WT" "$REPO" Alpha "$1"
}

@test "a linked worktree groups with its main checkout and carries tabname's label" {
  live_pid; a=$LIVE; live_pid; b=$LIVE
  REPO="$BATS_TEST_TMPDIR/proj"
  make_repo "$REPO"
  git -C "$REPO" worktree add -q --detach "$REPO/.claude/worktrees/alpha"
  use_tabname
  rec "$a" waiting 100 "" interactive "$HOME/.claude" "$REPO"
  rec "$b" waiting 100 "" interactive "$HOME/.claude" "$REPO/.claude/worktrees/alpha"
  tick 5000
  [ "$(val 'len(d["others"])')" = 1 ]
  [ "$(val 'd["others"][0]["group"]')" = proj ]
  [ "$(val '" ".join(sorted(r["label"] for r in d["needs"]))')" = "proj proj@alpha" ]
  [ "$(val 'd["needs"][0]["role"]')" = plain ]
}

@test "without tabname the label is the directory's name and nothing fails" {
  live_pid
  REPO="$BATS_TEST_TMPDIR/proj"
  make_repo "$REPO"
  git -C "$REPO" worktree add -q --detach "$REPO/.claude/worktrees/alpha"
  rec "$LIVE" waiting 100 "" interactive "$HOME/.claude" "$REPO/.claude/worktrees/alpha"
  run --separate-stderr sh "$CT" panel tick --state "$STATE" --now 5000
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(val 'd["needs"][0]["label"]')" = alpha ]
  [ "$(val 'd["needs"][0]["group"]')" = proj ]
}

@test "a hand-off peer is not listed when idle for an hour, and is listed when blocked" {
  peer_fixture handoff
  live_pid
  seed
  rec "$LIVE" idle 1000 "" interactive "$HOME/.claude" "$WT"
  tick 5000
  [ -z "$(kinds)" ]
  [ "$(val 'd["others"][0]["rows"][0]["role"]')" = peer ]
  [ "$(val 'd["others"][0]["rows"][0]["kind"]')" = idle ]
  rec "$LIVE" waiting 5000 "permission prompt" interactive "$HOME/.claude" "$WT"
  tick 5010
  [ "$(kinds)" = blocked ]
  [ "$(val 'd["needs"][0]["label"]')" = "proj · Alpha" ]
}

@test "a peer whose claim line 8 is - is listed finished" {
  peer_fixture -
  live_pid
  seed
  rec "$LIVE" idle 1000 "" interactive "$HOME/.claude" "$WT"
  tick 5000
  [ "$(kinds)" = finished ]
  [ "$(val 'd["needs"][0]["role"]')" = peer ]
}

@test "a claim that is short or cannot be read lists" {
  peer_fixture handoff
  live_pid
  seed
  rec "$LIVE" idle 1000 "" interactive "$HOME/.claude" "$WT"
  cf="$(git -C "$WT" rev-parse --absolute-git-dir)/claude-peer.claim"
  printf '%s\n%s\n%s\n' "$$" "$REPO" Alpha > "$cf"
  tick 5000
  [ "$(kinds)" = finished ]
  claim "$WT" "$REPO" Alpha handoff
  # unreadable by any user, root included (chmod 000 is no barrier to the CI containers' root)
  rm "$cf"
  mkdir "$cf"
  tick 5001
  [ "$(kinds)" = finished ]
}

@test "the guid comes from the start-up environment and is null without one" {
  live_pid; a=$LIVE; live_pid; b=$LIVE
  rec "$a" waiting 100
  rec "$b" waiting 100
  printf 'claude --x HOME=/h ITERM_SESSION_ID=w0t1p2:G-1234 TERM=x\n' > "$PS_TABLE.env.$a"
  tick 5000
  [ "$(val '[r["guid"] for r in d["needs"] if r["pid"] == '"$a"'][0]')" = G-1234 ]
  [ "$(val '[r["guid"] for r in d["needs"] if r["pid"] == '"$b"'][0]')" = None ]
  [ "$(state_val 'sorted(e["guid"] or "-" for e in d["sessions"].values())')" = "['-', 'G-1234']" ]
}

# transcript <pid> <origin kind or ->: append to the session's transcript a user entry of that
# origin kind (- for none), then an assistant entry and a tool_result entry, as a turn leaves them.
transcript() {
  f="$HOME/.claude/projects/-work-proj/s$1.jsonl"
  mkdir -p "$(dirname "$f")"
  if [ "$2" = - ]; then o=''; else o=",\"origin\":{\"kind\":\"$2\"}"; fi
  {
    printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":"x"}%s}\n' "$o"
    printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":"y"}}\n'
    printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","content":"z"}]}}\n'
  } >> "$f"
}

@test "a turn another session started is not listed, a turn the operator started is" {
  live_pid; a=$LIVE; live_pid; b=$LIVE; live_pid; c=$LIVE
  seed
  for p in $a $b $c; do rec "$p" idle 1000; done
  transcript "$a" peer
  transcript "$b" human
  tick 5000
  [ "$(val 'd["health"]["peer_turns"]')" = 1 ]
  [ "$(val 'sorted(r["pid"] for r in d["needs"] if r["kind"] == "finished") == sorted(['"$b, $c"'])')" = True ]
  [ "$(val '[r["kind"] for g in d["others"] for r in g["rows"] if r["pid"] == '"$a"'][0]')" = idle ]
}

@test "the operator typing after a message from another session makes the turn theirs" {
  live_pid
  seed
  rec "$LIVE" idle 1000
  transcript "$LIVE" peer
  tick 5000
  [ -z "$(kinds)" ]
  transcript "$LIVE" human
  tick 5001
  [ "$(kinds)" = finished ]
  [ "$(val 'd["health"]["peer_turns"]')" = 0 ]
}

@test "a dialog on a session another session drove is still listed" {
  live_pid
  seed
  rec "$LIVE" waiting 5000 "permission prompt"
  transcript "$LIVE" peer
  tick 5010
  [ "$(kinds)" = blocked ]
}

@test "a transcript with no origin entry, or none at all, lists" {
  live_pid; a=$LIVE; live_pid; b=$LIVE
  seed
  rec "$a" idle 1000
  rec "$b" idle 1000
  transcript "$a" -
  tick 5000
  [ "$(val 'sorted(r["pid"] for r in d["needs"]) == sorted(['"$a, $b"'])')" = True ]
  [ "$(val 'd["health"]["peer_turns"]')" = 0 ]
}

@test "a peer's row carries its slot even when tabname.peer-format leaves it out" {
  peer_fixture -
  git config --file "$GIT_CONFIG_GLOBAL" tabname.peer-format '{repo}'
  live_pid
  seed
  rec "$LIVE" idle 1000 "" interactive "$HOME/.claude" "$WT"
  tick 5000
  [ "$(val 'd["needs"][0]["label"]')" = "proj · Alpha" ]
  [ "$(val 'd["others"][0]["rows"][0]["label"]')" = "proj · Alpha" ]
  git config --file "$GIT_CONFIG_GLOBAL" tabname.peer-format '{peer}'
  tick 5061
  [ "$(val 'd["needs"][0]["label"]')" = Alpha ]
}

# life <pid> <seconds> [file under the project directory]: that transcript file, its mtime set to <seconds>.
life() {
  prof="$HOME/.claude"
  f="$prof/projects/-work-proj/${3:-s$1.jsonl}"
  mkdir -p "$(dirname "$f")"
  : > "$f"
  python3 -I -c 'import os,sys; os.utime(sys.argv[1], (int(sys.argv[2]),) * 2)' "$f" "$2"
}

@test "a busy session with a transcript 901 s old is quiet, and a fresh subagent file keeps it working" {
  live_pid; a=$LIVE; live_pid; b=$LIVE
  seed
  rec "$a" busy 100
  rec "$b" busy 100
  life "$a" 1000
  life "$b" 1000
  life "$b" 1891 "s$b/subagents/agent-x.jsonl"
  tick 1901
  [ "$(kinds)" = quiet ]
  [ "$(val 'd["needs"][0]["pid"]')" = "$a" ]
  [ "$(val 'd["health"]["life_unknown"]')" = 0 ]
}

@test "a busy session with no transcript is never quiet and is counted" {
  live_pid
  seed
  rec "$LIVE" busy 100
  tick 5000
  [ -z "$(kinds)" ]
  [ "$(val 'd["health"]["life_unknown"]')" = 1 ]
}

# --- panel serve ------------------------------------------------------------

now_s() { date +%s; }

# wait_for <command...>: polls for up to ten seconds.
wait_for() {
  i=0
  while ! "$@" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 100 ] || return 1
    sleep 0.1
  done
}

free_port() {
  python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# serve [script]: starts the server in the background on a free port (PORT) and
# waits for its /health; the script defaults to the real one. A finished turn
# counts after one second here so a test need not wait a minute.
serve() {
  mkdir -p "$HOME/.claude/sessions"
  PORT=$(free_port)
  git config --file "$GIT_CONFIG_GLOBAL" claude-tab.panel-port "$PORT"
  git config --file "$GIT_CONFIG_GLOBAL" claude-tab.finished-seconds 1
  export CLAUDE_TAB_PANEL_TICK=0.1
  sh "${1:-$CT}" panel serve --port "$PORT" > "$BATS_TEST_TMPDIR/serve.out" 2>&1 3>&- &
  SERVER=$!
  echo "$SERVER" >> "$BATS_TEST_TMPDIR/sleepers"
  wait_for grep -q "panel on" "$BATS_TEST_TMPDIR/serve.out" || {
    echo "serve: no 'panel on' after 10 s; server pid $SERVER alive: $(kill -0 "$SERVER" 2>&1 && echo yes)" >&3
    echo "serve: health: $(curl -s --noproxy '*' -m 3 -w ' http %{http_code}' "http://127.0.0.1:$PORT/health" 2>&1)" >&3
    sed 's/^/serve.out: /' "$BATS_TEST_TMPDIR/serve.out" >&3
    ps -Ao pid,ppid,stat,etime,command | grep -E "claude-tab|python|sh " | grep -v grep | cut -c1-200 >&3
    for c in $(pgrep -P "$SERVER") $SERVER; do sample "$c" 1 2>&1 | head -60 >&3; done
    return 1
  }
}

# snap : the running server's snapshot, as $output (val reads it).
snap() { run curl -s --noproxy '*' "http://127.0.0.1:$PORT/snapshot.json"; }

# post <path> <body> [curl args...]: prints the status code, the body is in $BODY.
post() {
  p=$1 b=$2
  shift 2
  curl -s --noproxy '*' -o "$BATS_TEST_TMPDIR/body" -w '%{http_code}' -X POST -d "$b" "$@" "http://127.0.0.1:$PORT$p"
}

# needs_has <python condition over the snapshot d>
needs_has() { snap; [ "$(val "$1")" = True ]; }

# a_finished : a fresh idle session whose turn ended just now; sets LIVE.
a_finished() {
  live_pid
  rec "$LIVE" idle $(($(now_s) + 1))
}

@test "serve answers health and the snapshot with the fields of the tick, on 127.0.0.1 only" {
  serve
  [ "$(curl -s --noproxy '*' "http://127.0.0.1:$PORT/health" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d["ok"], d["pid"] == int(sys.argv[1]))' "$SERVER")" = "True True" ]
  grep -q "claude-tab: panel on http://127.0.0.1:$PORT/" "$BATS_TEST_TMPDIR/serve.out"
  snap
  [ "$(val 'sorted(d)')" = "['build', 'generated_at', 'health', 'needs', 'others', 'tally', 'v']" ]
  [ "$(val 'd["build"] != "-"')" = True ]
  # not on any other address of this machine
  ip=$(python3 -I -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(("192.0.2.1", 9)); print(s.getsockname()[0])' 2>/dev/null) || ip=''
  case $ip in ''|127.*) skip "no non-loopback address here";; esac
  run curl -s --noproxy '*' --max-time 3 "http://$ip:$PORT/health"
  [ -z "$output" ]
}

@test "a port in use is one line and exit 1" {
  serve
  run sh "$CT" panel serve --port "$PORT"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "a wrong Host is 403, and a path with .. is 404" {
  serve
  [ "$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' -H "Host: example.test:$PORT" "http://127.0.0.1:$PORT/health")" = 403 ]
  [ "$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' -H "Host: localhost:$PORT" "http://127.0.0.1:$PORT/health")" = 200 ]
  [ "$(curl -s --noproxy '*' --path-as-is -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/../etc/passwd")" = 404 ]
  [ "$(curl -s --noproxy '*' --path-as-is -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/snapshot.json/..")" = 404 ]
  [ "$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/nope")" = 404 ]
}

@test "every response carries no-store and nosniff, and the page carries its CSP" {
  printf '<p>x</p>' > "$BATS_TEST_TMPDIR/page.html"
  export CLAUDE_TAB_PANEL_HTML="$BATS_TEST_TMPDIR/page.html"
  serve
  run curl -si --noproxy '*' "http://127.0.0.1:$PORT/"
  out=$(printf '%s' "$output" | tr 'A-Z' 'a-z')
  [[ "$out" == *"200 ok"* ]]
  [[ "$out" == *"cache-control: no-store"* ]]
  [[ "$out" == *"x-content-type-options: nosniff"* ]]
  [[ "$out" == *"content-security-policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'"* ]]
  [[ "$out" == *"<p>x</p>"* ]]
  run curl -si --noproxy '*' "http://127.0.0.1:$PORT/health"
  out=$(printf '%s' "$output" | tr 'A-Z' 'a-z')
  [[ "$out" == *"cache-control: no-store"* ]]
}

@test "a missing page is 500 and names its path" {
  export CLAUDE_TAB_PANEL_HTML="$BATS_TEST_TMPDIR/none.html"
  serve
  [ "$(curl -s --noproxy '*' -o "$BATS_TEST_TMPDIR/body" -w '%{http_code}' "http://127.0.0.1:$PORT/")" = 500 ]
  grep -q "$BATS_TEST_TMPDIR/none.html" "$BATS_TEST_TMPDIR/body"
}

@test "a POST without the header is 403, a pid not in the snapshot is 404" {
  serve
  a_finished
  wait_for needs_has "any(r['pid'] == $LIVE for g in d['others'] for r in g['rows'])"
  [ "$(post /seen "pid=$LIVE")" = 403 ]
  [ "$(post /go "pid=$LIVE")" = 403 ]
  [ "$(post /seen "pid=999999" -H 'X-Claude-Tab: 1')" = 404 ]
  [ "$(post /seen "pid=abc" -H 'X-Claude-Tab: 1')" = 400 ]
  [ "$(post /seen "pid=$LIVE" -H 'X-Claude-Tab: 1')" = 200 ]
}

@test "/seen removes a listed finished row at the next tick and counts one click" {
  serve
  a_finished
  wait_for needs_has "[r['kind'] for r in d['needs']] == ['finished']"
  [ "$(post /seen "pid=$LIVE" -H 'X-Claude-Tab: 1')" = 200 ]
  wait_for needs_has "d['needs'] == []"
  [ "$(val 'd["tally"]["seen_click"]')" = 1 ]
}

@test "/seen on a blocked row leaves it listed and marks it seen" {
  serve
  live_pid
  rec "$LIVE" waiting $(($(now_s) - 100)) "permission prompt"
  wait_for needs_has "[r['kind'] for r in d['needs']] == ['blocked']"
  [ "$(post /seen "pid=$LIVE" -H 'X-Claude-Tab: 1')" = 200 ]
  wait_for needs_has "d['needs'][0]['seen']"
  [ "$(val 'd["tally"]["seen_click"]')" = 1 ]
}

# self_stub : CLAUDE_TAB_SELF logs its arguments, and fails when the file self-fail exists.
self_stub() {
  cat > "$BATS_TEST_TMPDIR/self" <<'STUB'
#!/bin/sh
echo "$*" >> "$BATS_TEST_TMPDIR/self-log"
if [ -e "$BATS_TEST_TMPDIR/self-fail" ]; then echo "first line" >&2; echo "refused: no tab" >&2; exit 1; fi
STUB
  chmod +x "$BATS_TEST_TMPDIR/self"
  export CLAUDE_TAB_SELF="$BATS_TEST_TMPDIR/self"
}

@test "/go runs focus with that pid and marks it seen" {
  self_stub
  serve
  a_finished
  wait_for needs_has "[r['kind'] for r in d['needs']] == ['finished']"
  [ "$(post /go "pid=$LIVE" -H 'X-Claude-Tab: 1')" = 200 ]
  [ "$(cat "$BATS_TEST_TMPDIR/body")" = '{"ok": true}' ]
  [ "$(cat "$BATS_TEST_TMPDIR/self-log")" = "focus $LIVE" ]
  wait_for needs_has "d['needs'] == []"
  [ "$(val 'd["tally"]["seen_click"]')" = 1 ]
}

@test "/go is 409 with the last line of stderr when focus fails" {
  self_stub
  : > "$BATS_TEST_TMPDIR/self-fail"
  serve
  a_finished
  wait_for needs_has "[r['kind'] for r in d['needs']] == ['finished']"
  [ "$(post /go "pid=$LIVE" -H 'X-Claude-Tab: 1')" = 409 ]
  [ "$(cat "$BATS_TEST_TMPDIR/body")" = '{"ok": false, "error": "refused: no tab"}' ]
}

@test "no osascript call while nothing is unseen, calls once a fresh idle record is" {
  serve
  sleep 1
  [ ! -s "$OSA_LOG" ]
  a_finished
  wait_for test -s "$OSA_LOG"
  wait_for needs_has "d['tally']['focus_reads'] >= 1"
  [ "$(val 'd["health"]["focus"]')" = none ]
}

@test "a read of the front tty that fails is focus unknown and counted" {
  export FAKE_OSA_FAIL=1
  serve
  a_finished
  wait_for needs_has "d['tally']['focus_failures'] >= 1"
  [ "$(val 'd["health"]["focus"]')" = unknown ]
}

@test "the session in front is not listed, and counts as seen once focus has stayed" {
  serve
  live_pid
  printf '%s 1 ttys009\n' "$LIVE" >> "$PS_TABLE"
  rec "$LIVE" idle $(($(now_s) + 1))
  echo /dev/ttys009 > "$BATS_TEST_TMPDIR/front"
  wait_for needs_has "d['tally']['seen_focus'] == 1"
  [ "$(val 'd["needs"]')" = "[]" ]
}

@test "touching the script changes build, and the server answers again under its pid" {
  mkdir -p "$BATS_TEST_TMPDIR/copy"
  cp "$CT" "$BATS_TEST_TMPDIR/copy/claude-tab"
  serve "$BATS_TEST_TMPDIR/copy/claude-tab"
  before=$(curl -s --noproxy '*' "http://127.0.0.1:$PORT/health")
  sleep 1
  touch "$BATS_TEST_TMPDIR/copy/claude-tab"
  changed() { c=$(curl -s --noproxy "*" "http://127.0.0.1:$PORT/health"); [ -n "$c" ] && [ "$c" != "$before" ]; }
  wait_for changed
  after=$(curl -s --noproxy '*' "http://127.0.0.1:$PORT/health")
  [ "$(printf '%s' "$before" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["pid"])')" = \
    "$(printf '%s' "$after" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["pid"])')" ]
}

@test "the server exits once iTerm2 has been gone for the (scaled) 30 seconds" {
  serve
  : > "$PROCS_FILE"
  gone() { ! kill -0 "$SERVER" 2>/dev/null; }
  wait_for gone
}

@test "start twice starts one process, stop ends it, a second stop is exit 3" {
  port=$(free_port)
  git config --file "$GIT_CONFIG_GLOBAL" claude-tab.panel-port "$port"
  export CLAUDE_TAB_PANEL_TICK=0.1
  run sh "$CT" panel start
  [ "$status" -eq 0 ]
  [ "$output" = "claude-tab: panel started on http://127.0.0.1:$port/" ]
  pid=$(cut -d' ' -f1 "$HOME/.local/state/claude-tab/panel.pid")
  run sh "$CT" panel start
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cut -d' ' -f1 "$HOME/.local/state/claude-tab/panel.pid")" = "$pid" ]
  [ "$(curl -s --noproxy '*' "http://127.0.0.1:$port/health" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["pid"])')" = "$pid" ]
  run sh "$CT" panel stop
  [ "$status" -eq 0 ]
  gone() { ! kill -0 "$pid" 2>/dev/null; }
  wait_for gone
  run sh "$CT" panel stop
  [ "$status" -eq 3 ]
}

@test "snapshot and status read the running server, and exit 3 with none" {
  git config --file "$GIT_CONFIG_GLOBAL" claude-tab.panel-port "$(free_port)"
  run sh "$CT" panel status
  [ "$status" -eq 3 ]
  [ "$output" = "server: not running${NL}tool: not installed" ]
  run sh "$CT" panel snapshot
  [ "$status" -eq 3 ]
  serve
  wait_for needs_has "d['tally']['ticks'] >= 1"
  run sh "$CT" panel snapshot
  [ "$status" -eq 0 ]
  [ "$(val 'd["v"]')" = 1 ]
  run sh "$CT" panel status
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 6 ]
  [ "${lines[0]}" = "server: pid $SERVER, port $PORT" ]
  [[ "${lines[1]}" == "data: "* ]]
  [[ "${lines[2]}" == "focus: "* ]]
  [ "${lines[3]}" = "needs: none" ]
  [[ "${lines[4]}" == "tally: "* ]]
  [ "${lines[5]}" = "tool: not installed" ]
}

# The page: panel.html is one self-contained file, checked as text.
page() { printf '%s' "$BATS_TEST_DIRNAME/../dot_local/share/claude-tab/panel.html"; }

@test "the page reaches nothing outside itself and writes text only through textContent" {
  PAGE=$(page)
  [ -f "$PAGE" ]
  ! grep -Eq 'https?:|//' "$PAGE" || { echo "the page loads or links something off-box"; false; }
  ! grep -Eq 'innerHTML|document\.write|eval' "$PAGE" || { echo "the page writes HTML from data"; false; }
  grep -q 'textContent' "$PAGE"
  run "$REAL_PYTHON3" -I -c '
import sys
t = open(sys.argv[1], encoding="utf-8").read()
sys.exit(1 if any(0xE000 <= ord(c) <= 0xF8FF for c in t) else 0)' "$PAGE"
  [ "$status" -eq 0 ]
}

@test "the page names all four endpoints and every kind of the snapshot" {
  PAGE=$(page)
  for w in /snapshot.json /health /seen /go X-Claude-Tab \
    blocked failed asked finished finished-bg quiet unknown working idle idle-bg; do
    grep -Fq -- "$w" "$PAGE" || { echo "panel.html lacks $w"; return 1; }
  done
}

@test "GET / serves the deployed page with the CSP" {
  export CLAUDE_TAB_PANEL_HTML
  CLAUDE_TAB_PANEL_HTML=$(page)
  serve
  run curl -si --noproxy '*' "http://127.0.0.1:$PORT/"
  out=$(printf '%s' "$output" | tr 'A-Z' 'a-z')
  [[ "$out" == *"content-security-policy: default-src 'none'"* ]]
  [[ "$out" == *"<title>needs you</title>"* ]]
}

# The Toolbelt tool. A stub interpreter on CLAUDE_TAB_PANEL_PYTHON logs the three
# arguments after -I -c <program>, the cookie it was handed and how much stdin it
# saw; cookie fresh|stale lays the API cookie file newer or older than iTerm2's socket.
NL='
'
reg_stub() {
  export CLAUDE_TAB_PANEL_PYTHON="$BATS_TEST_TMPDIR/regpy"
  REG_LOG="$BATS_TEST_TMPDIR/reg.log"
  cat > "$CLAUDE_TAB_PANEL_PYTHON" <<STUB
#!/bin/sh
shift 3
echo "\$* cookie=\${ITERM2_COOKIE-none} stdin=\$(cat | wc -c | tr -d ' ')" >> "$REG_LOG"
[ ! -e "$BATS_TEST_TMPDIR/reg.fail" ] || { echo "boom"; exit 1; }
STUB
  chmod +x "$CLAUDE_TAB_PANEL_PYTHON"
}

cookie() {
  sock="$HOME/Library/Application Support/iTerm2/private/socket"
  ck="$HOME/.local/state/iterm2/api-cookie"
  mkdir -p "$(dirname "$sock")" "$(dirname "$ck")"
  : > "$sock"
  echo "abc def" > "$ck"
  python3 -I -c 'import os,sys; os.utime(sys.argv[1], (1000,) * 2); os.utime(sys.argv[2], ((2000 if sys.argv[3] == "fresh" else 500),) * 2)' "$sock" "$ck" "$1"
}

lines_of() { wc -l < "$1" | tr -d ' '; }

@test "register hands the interpreter the name, identifier and URL with the port, and the cookie" {
  reg_stub
  cookie fresh
  git config --file "$GIT_CONFIG_GLOBAL" claude-tab.panel-port 51234
  run sh "$CT" panel register
  [ "$status" -eq 0 ]
  [ "$output" = 'claude-tab: Toolbelt tool "Needs You" registered (View > Toolbelt)' ]
  [ "$(cat "$REG_LOG")" = "Needs You local.claude-tab.panel http://127.0.0.1:51234/ cookie=abc stdin=0" ]
  git config --file "$GIT_CONFIG_GLOBAL" claude-tab.panel-name Panel
  run sh "$CT" panel register --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(tail -n 1 "$REG_LOG")" = "Panel local.claude-tab.panel http://127.0.0.1:51234/ cookie=abc stdin=0" ]
}

@test "register without a fresh cookie, or a runtime, exits 1 and never runs the library" {
  reg_stub
  run sh "$CT" panel register
  [ "$status" -eq 1 ]
  [ "$output" = "claude-tab: no fresh iTerm2 API cookie (run iterm2-cookie); the panel is not registered" ]
  cookie stale
  run sh "$CT" panel register
  [ "$status" -eq 1 ]
  [[ "$output" == *"no fresh iTerm2 API cookie"* ]]
  [ ! -e "$REG_LOG" ]
  unset CLAUDE_TAB_PANEL_PYTHON
  cookie fresh
  run sh "$CT" panel register
  [ "$status" -eq 1 ]
  [[ "$output" == *"Install Python Runtime"* ]]
}

@test "register says why the interpreter failed" {
  reg_stub
  cookie fresh
  : > "$BATS_TEST_TMPDIR/reg.fail"
  run sh "$CT" panel register
  [ "$status" -eq 1 ]
  [ "$output" = "claude-tab: could not register the panel: boom" ]
}

@test "install starts, registers and leaves the marker, uninstall stops and takes it away" {
  reg_stub
  cookie fresh
  port=$(free_port)
  git config --file "$GIT_CONFIG_GLOBAL" claude-tab.panel-port "$port"
  export CLAUDE_TAB_PANEL_TICK=0.1
  run sh "$CT" panel install
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.local/state/claude-tab/panel.installed")" = "$port" ]
  [ "$(lines_of "$REG_LOG")" = 1 ]
  [[ "$output" == *'the Toolbelt tool "Needs You", at http://127.0.0.1:'"$port"'/'* ]]
  [[ "$output" == *"View > Toolbelt > Show Toolbelt"* ]]
  tool_line() { sh "$CT" panel status | grep -q '^tool: installed'; }
  wait_for tool_line
  run sh "$CT" panel uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"untick the tool in View > Toolbelt"* ]]
  [ ! -e "$HOME/.local/state/claude-tab/panel.installed" ]
  run sh "$CT" panel stop
  [ "$status" -eq 3 ]
}

@test "install without a cookie leaves no marker" {
  reg_stub
  port=$(free_port)
  git config --file "$GIT_CONFIG_GLOBAL" claude-tab.panel-port "$port"
  export CLAUDE_TAB_PANEL_TICK=0.1
  run sh "$CT" panel install
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.local/state/claude-tab/panel.installed" ]
}

@test "ensure does nothing without the marker" {
  reg_stub
  cookie fresh
  git config --file "$GIT_CONFIG_GLOBAL" claude-tab.panel-port "$(free_port)"
  run sh "$CT" panel ensure
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$HOME/.local/state/claude-tab/panel.pid" ]
  [ ! -e "$REG_LOG" ]
}

@test "ensure with the marker and no server starts one and registers once, with a server it does neither" {
  reg_stub
  cookie fresh
  port=$(free_port)
  git config --file "$GIT_CONFIG_GLOBAL" claude-tab.panel-port "$port"
  export CLAUDE_TAB_PANEL_TICK=0.1
  mkdir -p "$HOME/.local/state/claude-tab"
  echo "$port" > "$HOME/.local/state/claude-tab/panel.installed"
  run sh "$CT" panel ensure
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$HOME/.local/state/claude-tab/panel.pid" ]
  [ "$(lines_of "$REG_LOG")" = 1 ]
  run sh "$CT" panel ensure
  [ "$status" -eq 0 ]
  [ "$(lines_of "$REG_LOG")" = 1 ]
}

@test "ensure that cannot register waits for the cookie, then leaves one line in the log" {
  reg_stub
  port=$(free_port)
  git config --file "$GIT_CONFIG_GLOBAL" claude-tab.panel-port "$port"
  export CLAUDE_TAB_PANEL_TICK=0.1 CLAUDE_TAB_PANEL_COOKIE_WAIT=0.01
  mkdir -p "$HOME/.local/state/claude-tab"
  echo "$port" > "$HOME/.local/state/claude-tab/panel.installed"
  run sh "$CT" panel ensure
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$REG_LOG" ]
  grep -Fq "claude-tab: no fresh iTerm2 API cookie" "$HOME/.local/state/claude-tab/panel.log"
}
