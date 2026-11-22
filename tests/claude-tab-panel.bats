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
  # tty" per line); anything else answers nothing.
  export PS_TABLE="$BATS_TEST_TMPDIR/ps-table"
  : > "$PS_TABLE"
  cat > "$BIN/ps" <<'STUB'
#!/bin/sh
case "$*" in
  *"-o tty="*)
    while [ $# -gt 0 ]; do case $1 in -p) pid=$2; shift 2;; *) shift;; esac; done
    awk -v p="$pid" '$1 == p { print $3 }' "$PS_TABLE"
    exit 0;;
esac
exit 0
STUB
  chmod +x "$BIN"/*
  export PATH="$BIN:$PATH"
}

teardown() {
  [ ! -f "$BATS_TEST_TMPDIR/sleepers" ] || xargs kill < "$BATS_TEST_TMPDIR/sleepers" 2>/dev/null || true
}

# live_pid : sets LIVE to a pid that is alive until teardown.
live_pid() {
  sleep 300 >/dev/null 2>&1 </dev/null 3>&- &
  LIVE=$!
  printf '%s\n' "$LIVE" >> "$BATS_TEST_TMPDIR/sleepers"
}

# rec <pid> <status> <since seconds or ""> [waitingFor] [kind] [profile dir]: a
# registry record; the session id is s<pid>, an empty since leaves the field out.
rec() {
  d=${6:-$HOME/.claude}
  mkdir -p "$d/sessions"
  printf '{"pid":%s,"sessionId":"s%s","cwd":"/work/proj","kind":"%s","status":"%s"%s%s}\n' \
    "$1" "$1" "${5:-interactive}" "$2" "${3:+,\"statusUpdatedAt\":$(($3 * 1000))}" \
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
  [ "$(val 'sorted(d["health"])')" = "['focus', 'headless', 'life_unknown', 'profiles', 'sessions', 'turn_records', 'unreadable', 'want_focus']" ]
  [ "$(val 'sorted(d["tally"])')" = "['entered', 'focus_failures', 'focus_reads', 'hidden_prompts', 'left', 'seen_click', 'seen_focus', 'ticks', 'transitions']" ]
  [ "$(val 'sorted(d["needs"][0])')" = "['group', 'kind', 'label', 'pid', 'profile', 'reason', 'role', 'seen', 'since', 'tty']" ]
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
