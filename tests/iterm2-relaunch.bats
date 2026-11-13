#!/usr/bin/env bats

# ~/bin/iterm2-relaunch: quit iTerm2, do work while it is down, start it again,
# bring the Claude sessions back. Everything runs in a sandboxed HOME against stubs
# (uname, ps, osascript, defaults, open, iterm2-prefs, claude-tab): no test can
# quit, start or script the developer's real iTerm2, and nothing is shown on screen.
# The ps stub reads a procs file and nothing else, so a CI container that reaps no
# orphans cannot make a dead process look alive. There is deliberately no sleep stub.

bats_require_minimum_version 1.5.0

setup() {
  BIN="$BATS_TEST_DIRNAME/../bin/executable_iterm2-relaunch"
  # Pin python3 while HOME is still real: an asdf shim first on PATH finds no
  # version under the fake HOME and exits 126 instead of running.
  if py="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)"; then
    mkdir -p "$BATS_TEST_TMPDIR/pybin" && ln -s "$py" "$BATS_TEST_TMPDIR/pybin/python3"
    export PATH="$BATS_TEST_TMPDIR/pybin:$PATH"
  fi
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_STATE_HOME="$HOME/.local/state"
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
  STATE="$XDG_STATE_HOME/iterm2-relaunch"
  LOG="$STATE/run.log"
  export FAKE_PROCS_FILE="$BATS_TEST_TMPDIR/procs"
  export OSA_LOG="$BATS_TEST_TMPDIR/osa.log" SEQ="$BATS_TEST_TMPDIR/seq.log"
  export PREFS_LOG="$BATS_TEST_TMPDIR/prefs.log" CT_LOG="$BATS_TEST_TMPDIR/ct.log"
  export OPEN_LOG="$BATS_TEST_TMPDIR/open.log" OPEN_ENV="$BATS_TEST_TMPDIR/open.env"
  : >"$FAKE_PROCS_FILE"
  export ITERM2_RELAUNCH_TICK=0.1
  export ITERM2_RELAUNCH_PREFS="$BATS_TEST_TMPDIR/bin/iterm2-prefs"
  export ITERM2_RELAUNCH_CLAUDE_TAB="$BATS_TEST_TMPDIR/bin/claude-tab"
  stubs
}

teardown() {
  if [ -f "$FAKE_PROCS_FILE" ]; then
    for p in $(cut -d' ' -f1 "$FAKE_PROCS_FILE"); do kill "$p" 2>/dev/null || true; done
  fi
  if [ -f "$STATE/run.pid" ]; then kill "$(cat "$STATE/run.pid")" 2>/dev/null || true; fi
}

stubs() {
  local b="$BATS_TEST_TMPDIR/bin"
  cat >"$b/uname" <<'STUB'
#!/bin/sh
printf '%s\n' "${FAKE_OS:-Darwin}"
STUB
  cat >"$b/ps" <<'STUB'
#!/bin/sh
[ ! -f "${FAKE_PROCS_FILE-}" ] || cat "$FAKE_PROCS_FILE"
STUB
  cat >"$b/osascript" <<'STUB'
#!/bin/sh
echo "$*" >>"$OSA_LOG"
case $* in
  *"get version"*) echo "osa-probe" >>"$SEQ"; exit "${FAKE_PROBE:-0}";;
  *quit*)
    echo "osa-quit" >>"$SEQ"
    [ "${FAKE_QUIT:-}" != ignore ] || exit 0
    /bin/sleep "${FAKE_QUIT_DELAY:-0}"
    for p in $(cut -d' ' -f1 "$FAKE_PROCS_FILE"); do kill "$p" 2>/dev/null; done
    : >"$FAKE_PROCS_FILE";;
esac
STUB
  cat >"$b/defaults" <<'STUB'
#!/bin/sh
case $1 in
  export) echo "defaults-export" >>"$SEQ"; echo '<plist version="1.0"><dict/></plist>' >"$3";;
  read) printf '%s\n' "${FAKE_CLEAN:-1}";;
esac
STUB
  # unquoted heredoc: clean_open hands the stub none of the test's variables, so the
  # paths are baked in
  cat >"$b/open" <<STUB
#!/bin/sh
echo "\$*" >>"$OPEN_LOG"
env >"$OPEN_ENV"
[ ! -e "$BATS_TEST_TMPDIR/open-fails" ] || exit 1
f="$BATS_TEST_TMPDIR/openfake.\$\$"
( /bin/sh -c '/bin/sleep 300 & echo \$! >"\$1"; wait' sh "\$f" >/dev/null 2>&1 3>&- & )
while [ ! -s "\$f" ]; do /bin/sleep 0.05; done
printf '%s iTerm2\n' "\$(cat "\$f")" >>"$FAKE_PROCS_FILE"
STUB
  cat >"$b/iterm2-prefs" <<'STUB'
#!/bin/sh
echo "$*" >>"$PREFS_LOG"
echo "prefs $*" >>"$SEQ"
case $1 in
  install) exit "${FAKE_INSTALL_RC:-${FAKE_PREFS_RC:-0}}";;
  compose) exit "${FAKE_PREFS_RC:-0}";;
esac
STUB
  cat >"$b/claude-tab" <<'STUB'
#!/bin/sh
if [ "$1" = restore ] && [ "${2-}" = --dry-run ]; then
  echo dry >>"$CT_LOG"
  [ -z "${FAKE_DRY_ROWS-}" ] || printf '%s\n' "$FAKE_DRY_ROWS"
  exit "${FAKE_RESTORE_DRY:-0}"
fi
printf '%s\n' "$@" >>"$CT_LOG"
if [ "$1" = restore ] && [ "${FAKE_RESTORE_CRASH:-0}" = 1 ]; then
  for p in $(cut -d' ' -f1 "$FAKE_PROCS_FILE"); do kill "$p" 2>/dev/null; done
  : >"$FAKE_PROCS_FILE"
fi
case $1 in save) exit "${FAKE_SAVE:-0}";; restore) exit "${FAKE_RESTORE:-0}";; esac
STUB
  chmod +x "$b"/uname "$b"/ps "$b"/osascript "$b"/defaults "$b"/open "$b"/iterm2-prefs "$b"/claude-tab
  export PATH="$b:$PATH"
}

# fake_iterm: a live process standing in for iTerm2; lists it and prints its pid. It
# is the child of a shell that waits for it, so killing it leaves no zombie and
# kill -0 tells the truth; fd 3 is closed or bats waits for it for ever.
fake_iterm() {
  local f="$BATS_TEST_TMPDIR/fake.$RANDOM"
  ( /bin/sh -c '/bin/sleep 300 & echo $! >"$1"; wait' sh "$f" >/dev/null 2>&1 3>&- & )
  while [ ! -s "$f" ]; do /bin/sleep 0.05; done
  printf '%s iTerm2\n' "$(cat "$f")" >>"$FAKE_PROCS_FILE"
  cat "$f"
}

# no <command>...: fails when the command succeeds. A bare `! cmd` never fails a bats
# test (errexit ignores a negated command).
no() { if "$@"; then return 1; fi; }

# in_order <text>...: each fixed string is in run.log, each after the one before
in_order() {
  local pos=0 n pat
  for pat in "$@"; do
    n=$(grep -n -F -- "$pat" "$LOG" | awk -F: -v p="$pos" '$1 > p { print $1; exit }')
    [ -n "$n" ] || { echo "not in order after line $pos: $pat" >&2; cat "$LOG" >&2; return 1; }
    pos=$n
  done
}

# runner <restore> <prompt> <caller> <item>...: the runner in the foreground
runner() {
  local r=$1 p=$2 c=$3
  shift 3
  run sh "$BIN" _run "${WAIT:-5}" "${GRACE:-1}" "$r" "$p" "$c" "$@"
}

@test "_run prefs: waits the grace, asks iTerm2 to quit, composes once it is gone, starts it again" {
  fake_iterm >/dev/null
  runner 0 0 - prefs
  [ "$status" -eq 0 ]
  in_order "start: items=prefs restore=0 prompt=0 caller=- pid=" "quit: in 1s" "quit: asked" \
    "quit: exited after" "quit: clean" "prefs: exit 0" "launch: started" \
    "done: 1 items, 0 failed, restore skipped"
  [ "$(cat "$PREFS_LOG")" = compose ]
  [ ! -e "$STATE/run.pid" ]
  grep -q "^[0-9T:Z-]* start:" "$LOG"
}

@test "_run prefs prefs-install: install runs before compose whatever the order given" {
  fake_iterm >/dev/null
  runner 0 0 - prefs prefs-install
  [ "$status" -eq 0 ]
  [ "$(cat "$PREFS_LOG")" = "install
compose" ]
  grep -q "items=prefs,prefs-install " "$LOG"
  in_order "prefs-install: exit 0" "prefs: exit 0" "done: 2 items, 0 failed"
}

@test "_run: an item it does not know is logged exit 2 and counted as failed" {
  fake_iterm >/dev/null
  runner 0 0 - nonsense prefs
  [ "$status" -eq 1 ]
  in_order "prefs: exit 0" "nonsense: exit 2" "launch: started" "done: 2 items, 1 failed"
}

@test "_run: an iTerm2 that does not quit within the wait is left alone, exit 3, no item runs" {
  pid=$(fake_iterm)
  FAKE_QUIT=ignore WAIT=3 runner 0 0 - prefs
  [ "$status" -eq 3 ]
  grep -q "aborted: iTerm2 still running after 3s; nothing done" "$LOG"
  [ ! -s "$PREFS_LOG" ]
  [ ! -s "$OPEN_LOG" ]
  kill -0 "$pid"
  [ ! -e "$STATE/run.pid" ]
}

@test "_run: Apple events refused means nothing is asked and nothing done, exit 3" {
  fake_iterm >/dev/null
  FAKE_PROBE=1 runner 0 0 - prefs
  [ "$status" -eq 3 ]
  grep -q "aborted: cannot send Apple events to iTerm2; nothing done" "$LOG"
  no grep -q quit "$OSA_LOG"
  [ ! -s "$PREFS_LOG" ]
  [ ! -s "$OPEN_LOG" ]
  [ ! -e "$STATE/run.pid" ]
}

@test "_run: the domain is saved, privately, before the quit is asked" {
  fake_iterm >/dev/null
  runner 0 0 - prefs
  [ "$status" -eq 0 ]
  [ -f "$STATE/domain-before-quit.plist" ]
  [ "$(ls -l "$STATE/domain-before-quit.plist" | cut -c1-10)" = "-rw-------" ]
  [ "$(grep -v '^prefs' "$SEQ" | tr '\n' ' ')" = "osa-probe defaults-export osa-quit " ]
}

@test "_run: an unclean shutdown is logged with the saved domain's path, and the items still run" {
  fake_iterm >/dev/null
  FAKE_CLEAN=0 runner 0 0 - prefs
  [ "$status" -eq 0 ]
  grep -qF "quit: not clean (crash or kill); settings changed since the last save are not in the store; iterm2-prefs capture --from $STATE/domain-before-quit.plist --all lists them" "$LOG"
  in_order "quit: not clean" "prefs: exit 0" "launch: started"
}

@test "_run: iTerm2 starts with the environment of a Dock launch" {
  fake_iterm >/dev/null
  export CLAUDE_CONFIG_DIR=x CLAUDE_PROFILE=x BROWSER=x OPEN_AS_ALIAS=x CLAUDE_CODE_SESSION_ID=x \
    CLAUDECODE=x CLAUDE_PID=x ITERM_SESSION_ID=x alfred_workflow_uid=x
  runner 0 0 - prefs
  [ "$status" -eq 0 ]
  [ -f "$OPEN_ENV" ]
  for v in CLAUDE_CONFIG_DIR CLAUDE_PROFILE BROWSER OPEN_AS_ALIAS CLAUDE_CODE_SESSION_ID \
           CLAUDECODE CLAUDE_PID ITERM_SESSION_ID alfred_workflow_uid; do
    no grep -q "^$v=" "$OPEN_ENV"
  done
  grep -q "^HOME=" "$OPEN_ENV"
  grep -Fxq "PATH=/usr/bin:/bin:/usr/sbin:/sbin" "$OPEN_ENV"
  grep -Fxq -- "-b com.googlecode.iterm2" "$OPEN_LOG"
}

@test "_run: an item that fails does not stop the next, iTerm2 still starts, exit 1" {
  fake_iterm >/dev/null
  FAKE_INSTALL_RC=1 runner 0 0 - prefs-install prefs
  [ "$status" -eq 1 ]
  in_order "prefs-install: exit 1" "prefs: exit 0" "launch: started" "done: 2 items, 1 failed, restore skipped"
}

@test "_run restore 1 prompt 1: restore gets the everyone prompt, and the caller's when a caller id was given" {
  fake_iterm >/dev/null
  runner 1 1 abc-123 prefs
  [ "$status" -eq 0 ]
  grep -Fxq restore "$CT_LOG"
  grep -Fxq -- --prompt "$CT_LOG"
  grep -F "iTerm2 was relaunched by iterm2-relaunch (prefs), which ended this session mid-run." "$CT_LOG"
  grep -Fxq -- --prompt-for "$CT_LOG"
  grep -Fxq abc-123 "$CT_LOG"
  grep -F "You started this relaunch of iTerm2 (iterm2-relaunch prefs) and it has run. Read $LOG and run iterm2-relaunch status" "$CT_LOG"
  grep -q "done: 1 items, 0 failed, restore ok" "$LOG"
}

@test "_run restore 1 prompt 1: without a caller id there is no --prompt-for" {
  fake_iterm >/dev/null
  runner 1 1 - prefs
  [ "$status" -eq 0 ]
  grep -Fxq -- --prompt "$CT_LOG"
  no grep -Fxq -- --prompt-for "$CT_LOG"
}

@test "_run restore 1 prompt 0: restore is called with no prompt flags" {
  fake_iterm >/dev/null
  runner 1 0 abc-123 prefs
  [ "$status" -eq 0 ]
  grep -Fxq restore "$CT_LOG"
  no grep -q -- "--prompt" "$CT_LOG"
}

@test "_run restore 1: a restore that cannot start is logged with the command to run" {
  fake_iterm >/dev/null
  FAKE_RESTORE_DRY=1 WAIT=3 runner 1 0 - prefs
  [ "$status" -eq 0 ]
  grep -Fq "restore: failed; run: claude-tab restore" "$LOG"
  grep -q "done: 1 items, 0 failed, restore failed" "$LOG"
  no grep -Fxq restore "$CT_LOG"
}

@test "_run restore 1: an iTerm2 that dies during the restore is started once more and not restored again" {
  fake_iterm >/dev/null
  FAKE_RESTORE_CRASH=1 runner 1 0 - prefs
  [ "$status" -eq 0 ]
  [ "$(grep -c -Fx -- "-b com.googlecode.iterm2" "$OPEN_LOG")" -eq 2 ]
  [ "$(grep -c -Fx restore "$CT_LOG")" -eq 1 ]
  grep -Fq "restore: iTerm2 exited during the restore (crash?); started it again, restored nothing further" "$LOG"
  grep -q "restore failed" "$LOG"
}

@test "_run restore 1: sessions that survived the quit are counted in the log and the restore is ok" {
  fake_iterm >/dev/null
  FAKE_DRY_ROWS=$(printf 'skip:live\t-\ta\t-\nskip:live\t-\tb\t-\nnew\t-\tc\tcmd') runner 1 0 - prefs
  [ "$status" -eq 0 ]
  in_order "restore: 2 sessions were still running and were left as they are" "done: 1 items, 0 failed, restore ok"
}

@test "_run: when open fails the log says launch: failed and the items' results stand" {
  fake_iterm >/dev/null
  : >"$BATS_TEST_TMPDIR/open-fails"
  runner 1 0 - prefs
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$OPEN_LOG")" -eq 2 ]
  in_order "prefs: exit 0" "launch: failed" "done: 1 items, 0 failed, restore skipped"
}

@test "_run: with iTerm2 not running nothing is asked, the items run and iTerm2 is started" {
  runner 0 0 - prefs
  [ "$status" -eq 0 ]
  [ ! -e "$OSA_LOG" ]
  in_order "quit: iTerm2 was not running" "prefs: exit 0" "launch: started"
  no grep -q "quit: in" "$LOG"
}

@test "_run exits 2 where uname is not Darwin" {
  FAKE_OS=Linux runner 0 0 - prefs
  [ "$status" -eq 2 ]
  [ ! -s "$PREFS_LOG" ]
}

@test "status: runner, last and log lines" {
  run sh "$BIN" status
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "runner: none" ]
  [ "${lines[1]}" = "log: $LOG" ]
  fake_iterm >/dev/null
  runner 0 0 - prefs
  run sh "$BIN" status
  [ "${lines[0]}" = "runner: none" ]
  [[ "${lines[1]}" == "last: "*"done: 1 items, 0 failed, restore skipped" ]]
  [ "${lines[2]}" = "log: $LOG" ]
  mkdir -p "$STATE"
  echo $$ >"$STATE/run.pid"
  run sh "$BIN" status
  [ "${lines[0]}" = "runner: $$ running" ]
  rm "$STATE/run.pid"
}

@test "_detach: the command runs in a session of its own, logging to a 0600 file" {
  run sh "$BIN" _detach "$STATE/d.log" /bin/sh -c 'echo detached'
  [ "$status" -eq 0 ]
  for _ in $(seq 1 50); do grep -q detached "$STATE/d.log" 2>/dev/null && break; sleep 0.1; done
  grep -Fxq detached "$STATE/d.log"
  [ "$(ls -l "$STATE/d.log" | cut -c1-10)" = "-rw-------" ]
}
