#!/usr/bin/env bats

# ~/bin/iterm2-relaunch: quit iTerm2, do work while it is down, start it again,
# bring the Claude sessions back. Everything runs in a sandboxed HOME against stubs
# (uname, ps, osascript, defaults, open, brew, iterm2-prefs, claude-peer, claude-tab, screen-heads-up): no test can
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
  export ITERM2_RELAUNCH_CLAUDE_PEER="$BATS_TEST_TMPDIR/bin/claude-peer"
  export PEER_LOG="$BATS_TEST_TMPDIR/peer.log"
  # named but not created: a test that wants the helper calls heads_up_stub
  export ITERM2_RELAUNCH_HEADS_UP="$BATS_TEST_TMPDIR/bin/screen-heads-up"
  export HU_LOG="$BATS_TEST_TMPDIR/hu.log"
  # a stub brew, always: no test can reach a real one
  export ITERM2_RELAUNCH_BREW="$BATS_TEST_TMPDIR/bin/brew"
  export BREW_LOG="$BATS_TEST_TMPDIR/brew.log" FAKE_BREW_DIR="$BATS_TEST_TMPDIR/casks"
  export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
  mkdir -p "$FAKE_BREW_DIR"
  export CT_ENV="$BATS_TEST_TMPDIR/ct.env"
  # The front starts the runner under env -i; these are what its stubs read, as a
  # production runner would be given its seams.
  export ITERM2_RELAUNCH_PASS="$(grep -ohE 'FAKE_[A-Z0-9_]+' "$BATS_TEST_FILENAME" | sort -u | tr '\n' ' ') \
SEQ OSA_LOG PREFS_LOG CT_LOG CT_ENV PEER_LOG OPEN_LOG OPEN_ENV HU_LOG BREW_LOG BATS_TEST_TMPDIR GIT_CONFIG_GLOBAL"
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
  *"get version"*)
    echo "osa-probe" >>"$SEQ"
    [ "${FAKE_PROBE:-0}" = 0 ] || echo "not allowed" >&2
    exit "${FAKE_PROBE:-0}";;
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
  read)
    case $* in
      *KillJobsInServersOnQuit*) [ -n "${FAKE_KILLJOBS-}" ] || exit 1; printf '%s\n' "$FAKE_KILLJOBS";;
      *) printf '%s\n' "${FAKE_CLEAN:-1}";;
    esac;;
esac
STUB
  # unquoted heredoc: clean_open hands the stub none of the test's variables, so the
  # paths are baked in
  cat >"$b/open" <<STUB
#!/bin/sh
echo "\$*" >>"$OPEN_LOG"
echo open >>"$SEQ"
env >"$OPEN_ENV"
[ ! -e "$BATS_TEST_TMPDIR/open-fails" ] || exit 1
f="$BATS_TEST_TMPDIR/openfake.\$\$"
( /bin/sh -c '/bin/sleep 300 & echo \$! >"\$1"; wait' sh "\$f" >/dev/null 2>&1 3>&- & )
while [ ! -s "\$f" ]; do /bin/sleep 0.05; done
printf '%s iTerm2\n' "\$(cat "\$f")" >>"$FAKE_PROCS_FILE"
STUB
  cat >"$b/iterm2-prefs" <<'STUB'
#!/bin/sh
case "$1 ${2-}" in
  "status --line") printf '%s\n' "${FAKE_PREFS_LINE-not composed (folder /x)}"; exit 0;;
  "install --dry-run") [ -z "${FAKE_DRY_MSG-}" ] || echo "$FAKE_DRY_MSG" >&2; exit "${FAKE_DRY:-0}";;
esac
echo "$*" >>"$PREFS_LOG"
echo "prefs $*" >>"$SEQ"
[ "${FAKE_PREFS_HANG:-0}" = 0 ] || exec /bin/sleep 30
# FAKE_WAITER_FILE: leave a live compose-at-quit waiter behind, alive for a second
if [ -n "${FAKE_WAITER_FILE-}" ]; then
  ( /bin/sh -c '( /bin/sleep 1; echo waiter-ended >>"$SEQ" ) & echo $! >"$1"; wait' sh "$FAKE_WAITER_FILE" >/dev/null 2>&1 3>&- & )
  while [ ! -s "$FAKE_WAITER_FILE" ]; do /bin/sleep 0.05; done
fi
case $1 in
  install) exit "${FAKE_INSTALL_RC:-${FAKE_PREFS_RC:-0}}";;
  compose) exit "${FAKE_PREFS_RC:-0}";;
esac
STUB
  # brew: logs its arguments, cwd and whether the three variables are set, and
  # answers from $FAKE_BREW_DIR (<token>.json for info, <token>.versions for list,
  # after.<token> becomes the versions once an upgrade succeeds)
  cat >"$b/brew" <<'STUB'
#!/bin/sh
echo "$*|cwd=$(pwd)|askpass=${SUDO_ASKPASS+set}|no_ask=${HOMEBREW_NO_ASK+set}|no_auto=${HOMEBREW_NO_AUTO_UPDATE+set}" >>"$BREW_LOG"
echo "brew $1" >>"$SEQ"
d=$FAKE_BREW_DIR
case $1 in
  info) [ -f "$d/$4.json" ] || exit 1; cat "$d/$4.json";;
  list) [ ! -f "$d/$4.versions" ] || cat "$d/$4.versions";;
  update) exit "${FAKE_UPDATE:-0}";;
  fetch) exit "${FAKE_FETCH:-0}";;
  upgrade)
    /bin/sleep "${FAKE_UPGRADE_SLEEP:-0}"
    if [ "${FAKE_UPGRADE:-0}" = 0 ] && [ -f "$d/after.$3" ]; then cp "$d/after.$3" "$d/$3.versions"; fi
    exit "${FAKE_UPGRADE:-0}";;
esac
STUB
  # claude-peer: status prints $FAKE_PEER_STATUS; install and default log, then exit
  # $FAKE_PEER_INSTALL / $FAKE_PEER_DEFAULT
  cat >"$b/claude-peer" <<'STUB'
#!/bin/sh
case $1 in
  status) [ -z "${FAKE_PEER_STATUS-}" ] || printf '%s\n' "$FAKE_PEER_STATUS"; exit 0;;
esac
echo "$*" >>"$PEER_LOG"
echo "peer $*" >>"$SEQ"
case $1 in
  install) exit "${FAKE_PEER_INSTALL:-0}";;
  default) exit "${FAKE_PEER_DEFAULT:-0}";;
esac
STUB
  cat >"$b/claude-tab" <<'STUB'
#!/bin/sh
[ "$1" != list ] || { [ -z "${FAKE_LIST-}" ] || printf '%s\n' "$FAKE_LIST"; exit 0; }
if [ "$1" = restore ] && [ "${2-}" = --dry-run ]; then
  echo dry >>"$CT_LOG"
  [ -z "${FAKE_DRY_ROWS-}" ] || printf '%s\n' "$FAKE_DRY_ROWS"
  exit "${FAKE_RESTORE_DRY:-0}"
fi
printf '%s\n' "$@" >>"$CT_LOG"
[ "$1" != restore ] || env >"$CT_ENV"
if [ "$1" = restore ] && [ "${FAKE_RESTORE_CRASH:-0}" = 1 ]; then
  for p in $(cut -d' ' -f1 "$FAKE_PROCS_FILE"); do kill "$p" 2>/dev/null; done
  : >"$FAKE_PROCS_FILE"
fi
case $1 in save) exit "${FAKE_SAVE:-0}";; restore) exit "${FAKE_RESTORE:-0}";; esac
STUB
  chmod +x "$b"/uname "$b"/ps "$b"/osascript "$b"/defaults "$b"/open "$b"/brew "$b"/iterm2-prefs "$b"/claude-peer "$b"/claude-tab
  export PATH="$b:$PATH"
}

# heads_up_stub: the screen-heads-up helper. An ask logs "<what>|<seconds>|" and exits
# $FAKE_HEADS_UP (its second and later asks $FAKE_HEADS_UP_2 when set; the first
# $FAKE_HU_BUSY asks exit 4). With FAKE_HU_WAIT=1 an ask waits, like a countdown,
# until --not-now arrives, then exits 1.
heads_up_stub() {
  cat >"$ITERM2_RELAUNCH_HEADS_UP" <<'STUB'
#!/bin/sh
d=${BATS_TEST_TMPDIR:?}
printf '%s|' "$@" >>"$HU_LOG"; echo >>"$HU_LOG"
case ${1-} in
  --not-now) echo "hu-not-now" >>"$SEQ"; [ -e "$d/hu.waiting" ] || exit 1; : >"$d/hu.notnow"; exit 0;;
  --free) echo "hu-free" >>"$SEQ"; exit 0;;
esac
echo "hu-ask" >>"$SEQ"
echo x >>"$d/hu.asks"
n=$(wc -l <"$d/hu.asks")
[ "$n" -gt "${FAKE_HU_BUSY:-0}" ] || exit 4
if [ "${FAKE_HU_WAIT:-0}" = 1 ]; then
  : >"$d/hu.waiting"
  while [ ! -e "$d/hu.notnow" ]; do /bin/sleep 0.05; done
  exit 1
fi
[ "$n" -gt "$(( ${FAKE_HU_BUSY:-0} + 1 ))" ] && [ -n "${FAKE_HEADS_UP_2-}" ] && exit "$FAKE_HEADS_UP_2"
exit "${FAKE_HEADS_UP:-0}"
STUB
  chmod +x "$ITERM2_RELAUNCH_HEADS_UP"
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
  [ "$(grep -Ev '^(prefs|open)' "$SEQ" | tr '\n' ' ')" = "osa-probe defaults-export osa-quit " ]
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

# The front. ITERM2_RELAUNCH_DETACH=0 runs the runner in the foreground, so the log
# is complete when the call returns.

@test "items: prefs-install when not composed, prefs when composed, with their states" {
  run sh "$BIN" items
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'prefs-install\tready\tone-time switch to the composed preferences folder')" ]
  FAKE_DRY=1 FAKE_DRY_MSG="iterm2-prefs: no fragments" run sh "$BIN" items
  [ "${lines[0]}" = "$(printf 'prefs-install\trefused\titerm2-prefs: no fragments')" ]
  FAKE_PREFS_LINE="composed, 3 waiting, 0 kept" run sh "$BIN" items
  [ "${lines[0]}" = "$(printf 'prefs\tready\t3 waiting')" ]
  FAKE_PREFS_LINE="composed, in sync" run sh "$BIN" items
  [ "${lines[0]}" = "$(printf 'prefs\tnothing\tin sync')" ]
  FAKE_PREFS_LINE="composed, 0 waiting, 2 kept" run sh "$BIN" items
  [ "${lines[0]}" = "$(printf 'prefs\tnothing\tin sync')" ]
  [ ! -s "$PREFS_LOG" ]
}

@test "a refused item stops everything before iTerm2 is asked anything" {
  pid=$(fake_iterm)
  FAKE_DRY=1 FAKE_DRY_MSG="boom" run sh "$BIN" --yes prefs-install 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"iterm2-relaunch: prefs-install: boom"* ]]
  [ ! -s "$OSA_LOG" ]
  [ ! -s "$CT_LOG" ]
  [ ! -s "$PREFS_LOG" ]
  [ ! -s "$OPEN_LOG" ]
  kill -0 "$pid"
}

@test "items with nothing to do are dropped, and with none left iTerm2 is left running, exit 0" {
  pid=$(fake_iterm)
  FAKE_PREFS_LINE="composed, in sync" run sh "$BIN" --yes prefs
  [ "$status" -eq 0 ]
  [[ "$output" == *"prefs: nothing to do"* ]]
  [[ "$output" == *"nothing to do; iTerm2 left running"* ]]
  [ ! -s "$OSA_LOG" ]
  [ ! -s "$CT_LOG" ]
  [ ! -s "$PREFS_LOG" ]
  kill -0 "$pid"
}

@test "unknown items, unknown options and a bad number are usage errors, exit 2" {
  run sh "$BIN" bogus 2>&1
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown item: bogus"* ]]
  run sh "$BIN" --nope prefs 2>&1
  [ "$status" -eq 2 ]
  run sh "$BIN" --grace x prefs 2>&1
  [ "$status" -eq 2 ]
  run sh "$BIN" --yes 2>&1
  [ "$status" -eq 2 ]
  FAKE_OS=Linux run sh "$BIN" prefs 2>&1
  [ "$status" -eq 2 ]
}

@test "without --yes and without a terminal it refuses, and nothing was saved or asked" {
  pid=$(fake_iterm)
  run sh "$BIN" prefs-install 2>&1 </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"this quits iTerm2 and ends every session in it; pass --yes once the operator has agreed"* ]]
  [ ! -s "$OSA_LOG" ]
  [ ! -s "$CT_LOG" ]
  [ ! -s "$PREFS_LOG" ]
  kill -0 "$pid"
}

@test "--dry-run prints the would: lines in order and touches nothing" {
  pid=$(fake_iterm)
  run sh "$BIN" --dry-run prefs-install,prefs-install
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 5 ]
  [ "${lines[0]}" = "would: prefs-install: one-time switch to the composed preferences folder" ]
  [ "${lines[1]}" = "would: save Claude tabs (claude-tab save)" ]
  [ "${lines[2]}" = "would: quit iTerm2 after 5s and wait up to 120s for it" ]
  [ "${lines[3]}" = "would: start iTerm2" ]
  [ "${lines[4]}" = "would: restore Claude tabs and peers (claude-tab restore)" ]
  [ ! -s "$OSA_LOG" ]
  [ ! -s "$CT_LOG" ]
  [ ! -s "$PREFS_LOG" ]
  [ ! -s "$OPEN_LOG" ]
  [ ! -e "$STATE" ]
  kill -0 "$pid"
}

@test "--dry-run with --no-restore, and without iTerm2 running, leaves those lines out" {
  run sh "$BIN" --dry-run --no-restore --grace 2 prefs-install
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "would: start iTerm2" ]
}

@test "Apple events refused in the foreground: the reason is printed, exit 1, nothing saved" {
  pid=$(fake_iterm)
  FAKE_PROBE=1 run sh "$BIN" --yes prefs-install 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot send Apple events to iTerm2: not allowed"* ]]
  no grep -q quit "$OSA_LOG"
  [ ! -s "$CT_LOG" ]
  [ ! -s "$PREFS_LOG" ]
  kill -0 "$pid"
}

@test "--yes: the tabs are saved, then the runner does the work" {
  fake_iterm >/dev/null
  FAKE_PREFS_LINE="composed, 1 waiting, 0 kept" ITERM2_RELAUNCH_DETACH=0 run sh "$BIN" --yes --grace 1 prefs
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$CT_LOG")" = save ]
  [ "$(cat "$PREFS_LOG")" = compose ]
  in_order "start: items=prefs restore=1 prompt=1 caller=" "quit: asked" "prefs: exit 0" "done: 1 items, 0 failed, restore ok"
}

@test "a save that fails, or no claude-tab, means restore 0; --no-restore never calls claude-tab; --no-prompt passes prompt 0" {
  export ITERM2_RELAUNCH_DETACH=0 FAKE_PREFS_LINE="composed, 1 waiting, 0 kept"
  fake_iterm >/dev/null
  FAKE_SAVE=1 run sh "$BIN" --yes --grace 1 prefs 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"no tabs were saved"* ]]
  grep -q "restore=0 " "$LOG"
  no grep -Fxq restore "$CT_LOG"
  fake_iterm >/dev/null
  ITERM2_RELAUNCH_CLAUDE_TAB="$BATS_TEST_TMPDIR/none" run sh "$BIN" --yes --grace 1 prefs 2>&1
  [ "$status" -eq 0 ]
  grep -q "restore=0 " "$LOG"
  : >"$CT_LOG"
  fake_iterm >/dev/null
  run sh "$BIN" --yes --grace 1 --no-restore prefs
  [ "$status" -eq 0 ]
  [ ! -s "$CT_LOG" ]
  grep -q "restore=0 " "$LOG"
  fake_iterm >/dev/null
  run sh "$BIN" --yes --grace 1 --no-prompt prefs
  [ "$status" -eq 0 ]
  grep -q "restore=1 prompt=0 " "$LOG"
  no grep -q -- "--prompt" "$CT_LOG"
}

@test "the caller's session id reaches the runner" {
  export ITERM2_RELAUNCH_DETACH=0 FAKE_PREFS_LINE="composed, 1 waiting, 0 kept"
  fake_iterm >/dev/null
  CLAUDE_CODE_SESSION_ID=abc run sh "$BIN" --yes --grace 1 prefs
  [ "$status" -eq 0 ]
  grep -q "caller=abc " "$LOG"
  unset CLAUDE_CODE_SESSION_ID
  fake_iterm >/dev/null
  run sh "$BIN" --yes --grace 1 prefs
  [ "$status" -eq 0 ]
  grep -q "caller=- " "$LOG"
}

@test "the runner, and what it starts, get none of the caller's Claude environment, only the allowlist and the seams" {
  export FAKE_PREFS_LINE="composed, 1 waiting, 0 kept" LC_ALL=C LANG=C
  export CLAUDE_PID=123 CLAUDE_CODE_SESSION_ID=abc CLAUDECODE=1 BROWSER=x OPEN_AS_ALIAS=x CLAUDE_PROFILE=x ITERM_SESSION_ID=x
  fake_iterm >/dev/null
  run sh "$BIN" --yes --grace 1 prefs
  [ "$status" -eq 0 ]
  for _ in $(seq 1 150); do grep -q " done: " "$LOG" && break; sleep 0.1; done
  grep -q "done: 1 items, 0 failed, restore ok" "$LOG"
  grep -q "caller=abc " "$LOG"
  [ -s "$CT_ENV" ]
  for v in CLAUDE_PID CLAUDE_CODE_SESSION_ID CLAUDECODE BROWSER OPEN_AS_ALIAS CLAUDE_PROFILE ITERM_SESSION_ID; do
    no grep -q "^$v=" "$CT_ENV"
  done
  grep -q "^HOME=" "$CT_ENV"
  grep -q "^LC_ALL=C" "$CT_ENV"
  grep -q "^ITERM2_RELAUNCH_TICK=" "$CT_ENV"
  grep -q "^ITERM2_RELAUNCH_CLAUDE_TAB=" "$CT_ENV"
}

@test "detached: it returns only after the runner is alive and has logged start, and prints the runner's pid and the log path" {
  export FAKE_PREFS_LINE="composed, 1 waiting, 0 kept"
  fake_iterm >/dev/null
  run sh "$BIN" --yes --grace 2 prefs
  [ "$status" -eq 0 ]
  pid=$(cat "$STATE/run.pid")
  kill -0 "$pid"
  [ "${lines[0]}" = "iterm2-relaunch: runner $pid has the work (prefs) and asks iTerm2 to quit in 2s" ]
  [ "${lines[1]}" = "iterm2-relaunch: log: $LOG" ]
  [ "${lines[2]}" = "iterm2-relaunch: to call it off before iTerm2 is asked: iterm2-relaunch cancel" ]
  grep -q " start: items=prefs " "$LOG"
  no grep -q "quit: asked" "$LOG"
  for _ in $(seq 1 150); do grep -q " done: " "$LOG" && break; sleep 0.1; done
  grep -q "done: 1 items, 0 failed" "$LOG"
}

@test "a runner that never comes up is reported and iTerm2 is asked nothing" {
  export FAKE_PREFS_LINE="composed, 1 waiting, 0 kept"
  pid=$(fake_iterm)
  copy="$BATS_TEST_TMPDIR/relaunch-copy"
  sed 's/^  _run) /  _gone) /' "$BIN" >"$copy"
  grep -q '^  _gone) ' "$copy"
  run sh "$copy" --yes --grace 1 prefs 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"the runner did not start; iTerm2 is not asked to quit"* ]]
  no grep -q quit "$OSA_LOG"
  [ ! -s "$PREFS_LOG" ]
  kill -0 "$pid"
}

@test "a second relaunch while a runner lives is refused" {
  export FAKE_PREFS_LINE="composed, 1 waiting, 0 kept"
  fake_iterm >/dev/null
  /bin/sleep 300 3>&- >/dev/null 2>&1 &
  other=$!
  mkdir -p "$STATE"
  echo "$other" >"$STATE/run.pid"
  run sh "$BIN" --yes prefs 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"a relaunch is already under way (pid $other)"* ]]
  [ ! -s "$OSA_LOG" ]
  [ ! -s "$CT_LOG" ]
  [ ! -s "$PREFS_LOG" ]
}

@test "iTerm2 not running: the items run at once, iTerm2 is started, nothing is asked" {
  FAKE_PREFS_LINE="composed, 1 waiting, 0 kept" run sh "$BIN" prefs </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "iterm2-relaunch: iTerm2 was not running; 1 items done, 0 failed; started it" ]
  [ "$(cat "$PREFS_LOG")" = compose ]
  grep -Fxq -- "-b com.googlecode.iterm2" "$OPEN_LOG"
  [ ! -s "$OSA_LOG" ]
  [ ! -s "$CT_LOG" ]
  kill "$(cut -d' ' -f1 "$FAKE_PROCS_FILE")"
  : >"$FAKE_PROCS_FILE"
  FAKE_PREFS_RC=1 FAKE_PREFS_LINE="composed, 1 waiting, 0 kept" run sh "$BIN" prefs </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 items done, 1 failed; started it" ]]
}

@test "a refusal is appended to run.log, and --dry-run writes none" {
  FAKE_DRY=1 FAKE_DRY_MSG="boom" run sh "$BIN" --dry-run prefs-install
  [ "$status" -eq 1 ]
  [ ! -e "$STATE" ]
  FAKE_DRY=1 FAKE_DRY_MSG="boom" run sh "$BIN" --yes prefs-install
  FAKE_DRY=1 FAKE_DRY_MSG="boom" run sh "$BIN" --yes prefs-install
  [ "$(grep -c " refused: prefs-install: boom" "$LOG")" -eq 2 ]
  [ "$(stat -f %Lp "$STATE/run.log" 2>/dev/null || stat -c %a "$STATE/run.log")" = 600 ]
}

# The heads-up before the screen is taken, and cancel.

@test "_run: the heads-up is asked before anything else, with the items and the grace, and go lets the quit proceed" {
  heads_up_stub
  fake_iterm >/dev/null
  runner 0 0 - prefs prefs-install
  [ "$status" -eq 0 ]
  [ "$(grep -v '^prefs' "$SEQ" | head -n 2 | tr '\n' ' ')" = "hu-ask osa-probe " ]
  [ "$(head -n 1 "$HU_LOG")" = "iTerm2 quits for prefs,prefs-install and is back in about 15s; every session in it ends and is resumed|1|" ]
  in_order "quit: in 1s" "heads-up: go" "quit: asked" "done: 2 items, 0 failed"
}

@test "_run: not now aborts with exit 3, iTerm2 is asked nothing and no item runs" {
  heads_up_stub
  pid=$(fake_iterm)
  FAKE_HEADS_UP=1 runner 0 0 - prefs
  [ "$status" -eq 3 ]
  in_order "quit: in 1s" "aborted: not now; nothing done"
  [ ! -e "$OSA_LOG" ]
  [ ! -s "$PREFS_LOG" ]
  [ ! -s "$OPEN_LOG" ]
  no grep -q -- "--free" "$HU_LOG"
  [ ! -e "$STATE/run.pid" ]
  kill -0 "$pid"
}

@test "_run: without the helper, or when it fails, the grace is waited and logged" {
  fake_iterm >/dev/null
  GRACE=2 runner 0 0 - prefs
  [ "$status" -eq 0 ]
  in_order "quit: in 2s" "heads-up: no helper; waited 2s" "quit: asked"
  heads_up_stub
  fake_iterm >/dev/null
  FAKE_HEADS_UP=3 runner 0 0 - prefs
  [ "$status" -eq 0 ]
  in_order "quit: in 1s" "heads-up: helper failed (exit 3); waited 1s" "quit: asked"
  no grep -q -- "--free" "$HU_LOG"
}

@test "_run restore 1: the heads-up is asked again before the restore, and not now leaves the tabs for claude-tab restore by hand" {
  heads_up_stub
  fake_iterm >/dev/null
  FAKE_HEADS_UP_2=1 runner 1 0 - prefs
  [ "$status" -eq 0 ]
  [ "$(grep -c '^hu-ask' "$SEQ")" -eq 2 ]
  grep -q "^iTerm2 is back; its Claude tabs are being restored into the front window, leave it alone for about a minute|1|$" "$HU_LOG"
  in_order "launch: started" "restore: not now; run: claude-tab restore" "done: 1 items, 0 failed, restore skipped"
  no grep -Fxq restore "$CT_LOG"
}

@test "_run: exit 4 is asked again and, when it stays 4, counts as not now" {
  heads_up_stub
  pid=$(fake_iterm)
  FAKE_HU_BUSY=2 runner 0 0 - prefs
  [ "$status" -eq 0 ]
  [ "$(grep -c '^hu-ask' "$SEQ")" -eq 3 ]
  in_order "heads-up: go" "quit: asked"
  rm -f "$BATS_TEST_TMPDIR/hu.asks"
  : >"$SEQ"
  pid=$(fake_iterm)
  FAKE_HEADS_UP=4 FAKE_HU_BUSY=99 runner 0 0 - prefs
  [ "$status" -eq 3 ]
  [ "$(grep -c '^hu-ask' "$SEQ")" -eq 30 ]
  in_order "heads-up: another one was waiting" "aborted: not now; nothing done"
  [ "$(wc -l <"$OPEN_LOG")" -eq 1 ]
  kill -0 "$pid"
}

@test "_run: after a go the helper is told --free with --no-restore, on done and on an abort" {
  heads_up_stub
  fake_iterm >/dev/null
  runner 0 0 - prefs
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$HU_LOG")" = "--free|iTerm2 is back (1 items, 0 failed)|--no-restore|" ]
  in_order "heads-up: go" "launch: started" "done: 1 items"
  : >"$HU_LOG"
  fake_iterm >/dev/null
  FAKE_PROBE=1 runner 0 0 - prefs
  [ "$status" -eq 3 ]
  [ "$(tail -n 1 "$HU_LOG")" = "--free|iTerm2 was not quit|--no-restore|" ]
}

@test "cancel: a waiting heads-up is told --not-now and the runner ends itself" {
  heads_up_stub
  export FAKE_PREFS_LINE="composed, 1 waiting, 0 kept" FAKE_HU_WAIT=1
  pid=$(fake_iterm)
  run sh "$BIN" --yes --grace 5 prefs
  [ "$status" -eq 0 ]
  for _ in $(seq 1 50); do [ -e "$BATS_TEST_TMPDIR/hu.waiting" ] && break; sleep 0.1; done
  [ -e "$BATS_TEST_TMPDIR/hu.waiting" ]
  run sh "$BIN" cancel
  [ "$status" -eq 0 ]
  [ "$output" = "iterm2-relaunch: cancelled; iTerm2 was not asked to quit" ]
  [ ! -e "$STATE/run.pid" ]
  grep -q "aborted: not now; nothing done" "$LOG"
  no grep -q "cancelled:" "$LOG"
  no grep -q "quit: asked" "$LOG"
  kill -0 "$pid"
}

@test "cancel: before the quit was asked it stops the runner and says so" {
  export FAKE_PREFS_LINE="composed, 1 waiting, 0 kept"
  pid=$(fake_iterm)
  run sh "$BIN" --yes --grace 5 prefs
  [ "$status" -eq 0 ]
  run sh "$BIN" cancel
  [ "$status" -eq 0 ]
  [ "$output" = "iterm2-relaunch: cancelled; iTerm2 was not asked to quit" ]
  [ ! -e "$STATE/run.pid" ]
  grep -q " cancelled: before iTerm2 was asked to quit" "$LOG"
  sleep 2
  kill -0 "$pid"
  no grep -q "quit: asked" "$LOG"
  [ ! -e "$OSA_LOG" ] || no grep -q quit "$OSA_LOG"
}

@test "cancel: after quit: asked it refuses; with no runner it says so" {
  run sh "$BIN" cancel 2>&1
  [ "$status" -eq 1 ]
  [ "$output" = "iterm2-relaunch: no relaunch is under way" ]
  /bin/sleep 300 3>&- >/dev/null 2>&1 &
  other=$!
  mkdir -p "$STATE"
  echo "$other" >"$STATE/run.pid"
  for line in asking asked; do
    echo "2026-11-13T00:00:00Z quit: $line" >"$LOG"
    run sh "$BIN" cancel 2>&1
    [ "$status" -eq 1 ]
    [ "$output" = "iterm2-relaunch: too late: iTerm2 has been asked to quit (Cancel in its own alert still stops it)" ]
    kill -0 "$other"
  done
  kill "$other"
  rm -f "$STATE/run.pid"
}

@test "_run: a TERM or INT after the quit was asked is ignored, the items run and iTerm2 is started" {
  export FAKE_PREFS_LINE="composed, 1 waiting, 0 kept" FAKE_QUIT_DELAY=1
  fake_iterm >/dev/null
  run sh "$BIN" --yes --grace 1 prefs
  [ "$status" -eq 0 ]
  pid=$(cat "$STATE/run.pid")
  for _ in $(seq 1 100); do grep -q " quit: asked" "$LOG" && break; sleep 0.05; done
  kill -TERM "$pid"
  kill -INT "$pid"
  for _ in $(seq 1 150); do grep -q " done: " "$LOG" && break; sleep 0.1; done
  in_order "quit: asking" "quit: asked" "prefs: exit 0" "launch: started" "done: 1 items, 0 failed"
  no grep -q "cancelled:" "$LOG"
  grep -Fxq -- "-b com.googlecode.iterm2" "$OPEN_LOG"
}

@test "_run: a runner that ends after the quit was asked and before the launch still starts iTerm2, once" {
  fake_iterm >/dev/null
  copy="$BATS_TEST_TMPDIR/relaunch-copy"
  sed 's/^  run_items >>"\$log" 2>&1$/  exit 9/' "$BIN" >"$copy"
  grep -q '^  exit 9$' "$copy"
  run sh "$copy" _run 5 1 0 0 - prefs
  [ "$status" -eq 9 ]
  [ ! -s "$PREFS_LOG" ]
  in_order "quit: asked" "launch: the runner ended early; starting iTerm2"
  [ "$(grep -c -Fx -- "-b com.googlecode.iterm2" "$OPEN_LOG")" -eq 1 ]
}

# brew: items.

# cask <token> <installed|null> <version> <outdated true|false> <auto_updates true|false> <artifact>
# <current versions line, or none>: the stub brew's cask record.
cask() {
  local inst='null'
  [ "$2" = null ] || inst="\"$2\""
  printf '{"formulae":[],"casks":[{"token":"%s","installed":%s,"version":"%s","outdated":%s,"auto_updates":%s,"artifacts":[{"%s":["x"]},{"zap":[{"trash":"y"}]}]}]}\n' \
    "$1" "$inst" "$3" "$4" "$5" "$6" >"$FAKE_BREW_DIR/$1.json"
  [ "$7" = none ] || echo "$1 $7" >"$FAKE_BREW_DIR/$1.versions"
}

@test "items: an outdated cask is ready with installed -> version; a current one is nothing; a token that is not installed is not listed" {
  cask claude-code@latest 2.1.322 2.1.323 true false binary none
  cask claude-code 2.1.0 2.1.0 false false binary none
  cask notinstalled null 1.0 false false binary none
  printf '[iterm2-relaunch]\n\tbrew = notinstalled\n\tbrew = nosuchcask\n' >"$HOME/.gitconfig"
  run sh "$BIN" items
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  [ "${lines[2]}" = "$(printf 'brew:claude-code@latest\tready\t2.1.322 -> 2.1.323')" ]
  [ "${lines[3]}" = "$(printf 'brew:claude-code\tnothing\t2.1.0 is current')" ]
}

@test "items: a cask that updates itself, and one with a pkg artifact, are refused with the reason" {
  cask selfupdating 3.7.3 3.7.7 true true app none
  cask withpkg 1.0 2.0 true false pkg none
  cask withinstaller 1.0 2.0 true false installer none
  printf '[iterm2-relaunch]\n\tbrew = selfupdating\n\tbrew = withpkg\n\tbrew = withinstaller\n' >"$HOME/.gitconfig"
  run sh "$BIN" items
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 5 ]
  [ "${lines[2]}" = "$(printf 'brew:selfupdating\trefused\tupdates itself; its Homebrew record only looks stale')" ]
  [ "${lines[3]}" = "$(printf 'brew:withpkg\trefused\tits installer may ask for a password; upgrade it from a terminal')" ]
  [ "${lines[4]}" = "$(printf 'brew:withinstaller\trefused\tits installer may ask for a password; upgrade it from a terminal')" ]
  pid=$(fake_iterm)
  run sh "$BIN" --yes brew:selfupdating 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"iterm2-relaunch: brew:selfupdating: updates itself; its Homebrew record only looks stale"* ]]
  [ ! -s "$OSA_LOG" ]
  no grep -q "^fetch" "$BREW_LOG"
  kill -0 "$pid"
}

@test "items: values of iterm2-relaunch.brew are offered after the two defaults, once each, and only if they are plain tokens" {
  for t in claude-code@latest claude-code zeta alpha 'bad touch'; do cask "$t" 1.0 2.0 true false binary none; done
  printf '[iterm2-relaunch]\n\tbrew = zeta\n\tbrew = claude-code\n\tbrew = alpha\n\tbrew = "bad touch"\n' >"$HOME/.gitconfig"
  run sh "$BIN" items
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "${lines[@]:2}" | cut -f1 | tr '\n' ' ')" = "brew:claude-code@latest brew:claude-code brew:zeta brew:alpha " ]
  no grep -q "bad" "$BREW_LOG"
}

@test "brew: a token that is not a plain cask name is a usage error, exit 2" {
  run sh "$BIN" brew: 2>&1
  [ "$status" -eq 2 ]
  run sh "$BIN" 'brew:-x' 2>&1
  [ "$status" -eq 2 ]
  run sh "$BIN" 'brew:a b' 2>&1
  [ "$status" -eq 2 ]
  [ ! -s "$BREW_LOG" ]
}

@test "front: brew update runs before the states, brew fetch before the consent, and a failed fetch quits nothing" {
  export ITERM2_RELAUNCH_DETACH=0
  cask claude-code@latest 2.1.322 2.1.323 true false binary "2.1.322"
  fake_iterm >/dev/null
  run sh "$BIN" --yes --grace 1 brew:claude-code@latest
  [ "$status" -eq 0 ]
  [ "$(head -n 4 "$SEQ" | tr '\n' ' ')" = "brew update brew info brew fetch osa-probe " ]
  grep -Fq "fetch --cask claude-code@latest|" "$BREW_LOG"
  : >"$SEQ"; : >"$BREW_LOG"; : >"$OSA_LOG"; : >"$CT_LOG"
  pid=$(fake_iterm)
  FAKE_FETCH=1 run sh "$BIN" --yes --grace 1 brew:claude-code@latest 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"iterm2-relaunch: brew:claude-code@latest: download failed"* ]]
  [ ! -s "$OSA_LOG" ]
  [ ! -s "$CT_LOG" ]
  grep -q " refused: brew:claude-code@latest: download failed" "$LOG"
  kill -0 "$pid"
}

@test "front: a failed brew update warns and the cached state is used; --dry-run says it would update and runs no brew update or fetch" {
  cask claude-code@latest 2.1.322 2.1.323 true false binary none
  pid=$(fake_iterm)
  FAKE_UPDATE=1 run sh "$BIN" --dry-run --no-restore brew:claude-code@latest 2>&1
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "would: brew update first" ]
  [ "${lines[1]}" = "would: brew:claude-code@latest: 2.1.322 -> 2.1.323" ]
  no grep -q "^update\|^fetch" "$BREW_LOG"
  FAKE_UPDATE=1 run sh "$BIN" brew:claude-code@latest </dev/null 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"iterm2-relaunch: brew update failed; using the cached state"* ]]
  [[ "$output" == *"this quits iTerm2 and ends every session in it"* ]]
  kill -0 "$pid"
}

@test "front: a current cask is nothing to do and iTerm2 is left running" {
  cask claude-code@latest 2.1.323 2.1.323 false false binary none
  pid=$(fake_iterm)
  run sh "$BIN" --yes brew:claude-code@latest
  [ "$status" -eq 0 ]
  [[ "$output" == *"brew:claude-code@latest: nothing to do"* ]]
  [[ "$output" == *"nothing to do; iTerm2 left running"* ]]
  [ ! -s "$OSA_LOG" ]
  no grep -q "^fetch" "$BREW_LOG"
  kill -0 "$pid"
}

@test "front: with jobs surviving a quit it notes, before the consent, that running sessions keep the old version" {
  cask claude-code@latest 2.1.322 2.1.323 true false binary "2.1.322"
  fake_iterm >/dev/null
  FAKE_KILLJOBS=0 run sh "$BIN" brew:claude-code@latest </dev/null 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"iterm2-relaunch: note: jobs survive a quit on this machine, so running Claude sessions keep the old claude-code@latest until restarted"* ]]
  FAKE_KILLJOBS=1 run sh "$BIN" brew:claude-code@latest </dev/null 2>&1
  no grep -q "note:" <<<"$output"
  run sh "$BIN" brew:claude-code@latest </dev/null 2>&1
  no grep -q "note:" <<<"$output"
}

@test "_run brew: upgrade --cask runs from HOME with HOMEBREW_NO_ASK and no SUDO_ASKPASS, and the versions before and after are logged" {
  cask claude-code@latest 2.1.322 2.1.323 true false binary "2.1.322"
  echo "claude-code@latest 2.1.323" >"$FAKE_BREW_DIR/after.claude-code@latest"
  fake_iterm >/dev/null
  SUDO_ASKPASS=/nonexistent runner 0 0 - brew:claude-code@latest
  [ "$status" -eq 0 ]
  grep -Fx "upgrade --cask claude-code@latest|cwd=$HOME|askpass=|no_ask=set|no_auto=set" "$BREW_LOG"
  in_order "quit: exited after" "brew:claude-code@latest: 2.1.322 -> 2.1.323" "brew:claude-code@latest: exit 0" "launch: started" "done: 1 items, 0 failed"
  no grep -q "kept running" "$LOG"
}

@test "_run brew: sessions that kept running through an upgrade that changed the version are counted in the log" {
  cask claude-code@latest 2.1.322 2.1.323 true false binary "2.1.322"
  echo "claude-code@latest 2.1.323" >"$FAKE_BREW_DIR/after.claude-code@latest"
  fake_iterm >/dev/null
  FAKE_LIST=$(printf '1\tp\ta\n2\tp\tb') runner 0 0 - brew:claude-code@latest
  [ "$status" -eq 0 ]
  in_order "brew:claude-code@latest: 2.1.322 -> 2.1.323" \
    "brew:claude-code@latest: 2 Claude sessions kept running through the upgrade and stay on 2.1.322 until each is restarted" \
    "brew:claude-code@latest: exit 0"
}

@test "_run brew: an upgrade that fails still starts iTerm2 and restores the tabs, exit 1" {
  cask claude-code@latest 2.1.322 2.1.323 true false binary "2.1.322"
  fake_iterm >/dev/null
  FAKE_UPGRADE=1 FAKE_LIST=$(printf '1\tp\ta') runner 1 0 - brew:claude-code@latest
  [ "$status" -eq 1 ]
  in_order "brew:claude-code@latest: 2.1.322 -> 2.1.322" "brew:claude-code@latest: exit 1" "launch: started" "done: 1 items, 1 failed, restore ok"
  no grep -q "kept running" "$LOG"
  grep -Fxq restore "$CT_LOG"
}

@test "_run brew: an upgrade that outlasts the timeout is killed and logged, and iTerm2 still starts" {
  cask claude-code@latest 2.1.322 2.1.323 true false binary "2.1.322"
  fake_iterm >/dev/null
  ITERM2_RELAUNCH_ITEM_TIMEOUT=3 FAKE_UPGRADE_SLEEP=5 runner 0 0 - brew:claude-code@latest
  [ "$status" -eq 1 ]
  in_order "brew:claude-code@latest: timed out after 3s" "brew:claude-code@latest: 2.1.322 -> 2.1.322" \
    "brew:claude-code@latest: exit 124" "launch: started" "done: 1 items, 1 failed"
}

@test "_run prefs,brew:x: prefs runs first, both are logged, one relaunch" {
  cask claude-code@latest 2.1.322 2.1.323 true false binary "2.1.322"
  fake_iterm >/dev/null
  runner 0 0 - brew:claude-code@latest prefs
  [ "$status" -eq 0 ]
  in_order "quit: asked" "prefs: exit 0" "brew:claude-code@latest: exit 0" "launch: started" "done: 2 items, 0 failed"
  [ "$(grep -c "quit: asked" "$LOG")" -eq 1 ]
  [ "$(grep -c -Fx -- "-b com.googlecode.iterm2" "$OPEN_LOG")" -eq 1 ]
}

@test "no Homebrew: brew items are refused, prefs items still work" {
  export ITERM2_RELAUNCH_BREW="$BATS_TEST_TMPDIR/no-such-brew"
  pid=$(fake_iterm)
  run sh "$BIN" --yes brew:claude-code@latest 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"iterm2-relaunch: brew:claude-code@latest: Homebrew not found"* ]]
  [ ! -s "$OSA_LOG" ]
  run sh "$BIN" items
  [ "${#lines[@]}" -eq 2 ]
  [ ! -s "$BREW_LOG" ]
  FAKE_PREFS_LINE="composed, 1 waiting, 0 kept" ITERM2_RELAUNCH_DETACH=0 run sh "$BIN" --yes --grace 1 prefs
  [ "$status" -eq 0 ]
  [ "$(cat "$PREFS_LOG")" = compose ]
}

# The claude-peer item.

@test "items: claude-peer is ready when status asks for install, ready when its default line asks for default peers, nothing otherwise, refused when it is not deployed" {
  FAKE_PREFS_LINE="composed, in sync" run sh "$BIN" items
  [ "${lines[1]}" = "$(printf 'claude-peer\tnothing\tinstalled and current')" ]
  long=$(printf 'x%.0s' $(seq 1 150))
  FAKE_PEER_STATUS="main: not installed - $long claude-peer install (with iTerm2 quit)" FAKE_PREFS_LINE="composed, in sync" run sh "$BIN" items
  [ "${lines[1]}" = "$(printf 'claude-peer\tready\t%s' "$(printf 'main: not installed - %s claude-peer install' "$long" | cut -c1-120)")" ]
  FAKE_PEER_STATUS="$(printf 'main: installed\ndefault: the enter file says peers but the triggers do not - claude-peer default peers')" \
    FAKE_PREFS_LINE="composed, in sync" run sh "$BIN" items
  [ "${lines[1]}" = "$(printf 'claude-peer\tready\tdefault: the enter file says peers but the triggers do not - claude-peer default peers')" ]
  FAKE_PEER_STATUS="default: mixed (1 of 3 profiles enter by variable) - claude-peer default peers|builtin" \
    FAKE_PREFS_LINE="composed, in sync" run sh "$BIN" items
  [ "${lines[1]}" = "$(printf 'claude-peer\tnothing\tinstalled and current')" ]
  ITERM2_RELAUNCH_CLAUDE_PEER="$BATS_TEST_TMPDIR/no-such-peer" FAKE_PREFS_LINE="composed, in sync" run sh "$BIN" items
  [ "${lines[1]}" = "$(printf 'claude-peer\trefused\tclaude-peer is not deployed')" ]
  [ ! -s "$PEER_LOG" ]
}

@test "front: with prefs-install in the same run claude-peer is ready whatever status says; a refused claude-peer stops everything" {
  pid=$(fake_iterm)
  run sh "$BIN" --dry-run --no-restore prefs-install,claude-peer
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "would: prefs-install: one-time switch to the composed preferences folder" ]
  [ "${lines[1]}" = "would: claude-peer: rewritten into the composed store after the switch" ]
  # prefs-install that has nothing to do (already composed) leaves claude-peer to status
  FAKE_PREFS_LINE="composed, in sync" run sh "$BIN" --dry-run --no-restore prefs-install,claude-peer
  [ "$output" = "$(printf 'prefs-install: nothing to do\nclaude-peer: nothing to do\nnothing to do; iTerm2 left running' | sed 's/^/iterm2-relaunch: /')" ]
  ITERM2_RELAUNCH_CLAUDE_PEER="$BATS_TEST_TMPDIR/no-such-peer" run sh "$BIN" --yes claude-peer 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"iterm2-relaunch: claude-peer: claude-peer is not deployed"* ]]
  [ ! -s "$OSA_LOG" ]
  [ ! -s "$PEER_LOG" ]
  kill -0 "$pid"
}

@test "_run prefs-install,claude-peer,brew:x given in any order: install of the preferences, then claude-peer install, then the upgrade" {
  cask claude-code@latest 2.1.322 2.1.323 true false binary "2.1.322"
  fake_iterm >/dev/null
  runner 0 0 - brew:claude-code@latest claude-peer prefs-install
  [ "$status" -eq 0 ]
  [ "$(grep -E '^(prefs|peer|brew upgrade)' "$SEQ" | tr '\n' ',')" = "prefs install,peer install,brew upgrade," ]
  in_order "prefs-install: exit 0" "claude-peer: exit 0" "brew:claude-code@latest: exit 0" "launch: started" "done: 3 items, 0 failed"
}

@test "_run claude-peer: default peers runs only when status ends its default line with exactly that, and not for the mixed line" {
  fake_iterm >/dev/null
  FAKE_PEER_STATUS="default: the triggers say peers but the enter file is missing - claude-peer default peers" runner 0 0 - claude-peer
  [ "$status" -eq 0 ]
  [ "$(cat "$PEER_LOG")" = "install
default peers" ]
  in_order "claude-peer: exit 0" "done: 1 items, 0 failed"
  : >"$PEER_LOG"
  fake_iterm >/dev/null
  FAKE_PEER_STATUS="default: mixed (1 of 3 profiles enter by variable) - claude-peer default peers|builtin" runner 0 0 - claude-peer
  [ "$(cat "$PEER_LOG")" = install ]
  : >"$PEER_LOG"
  fake_iterm >/dev/null
  runner 0 0 - claude-peer
  [ "$(cat "$PEER_LOG")" = install ]
  : >"$PEER_LOG"
  fake_iterm >/dev/null
  FAKE_PEER_DEFAULT=1 FAKE_PEER_STATUS="default: x - claude-peer default peers" runner 0 0 - claude-peer
  [ "$status" -eq 1 ]
  in_order "claude-peer: exit 1" "launch: started" "done: 1 items, 1 failed"
}

@test "_run claude-peer: an install that fails is logged, default is not run, iTerm2 still starts, exit 1" {
  fake_iterm >/dev/null
  FAKE_PEER_INSTALL=1 FAKE_PEER_STATUS="default: x - claude-peer default peers" runner 0 0 - claude-peer
  [ "$status" -eq 1 ]
  [ "$(cat "$PEER_LOG")" = install ]
  in_order "claude-peer: exit 1" "launch: started" "done: 1 items, 1 failed"
}

@test "_run claude-peer: it waits for a live compose-at-quit waiter before it writes" {
  fake_iterm >/dev/null
  mkdir -p "$XDG_STATE_HOME/iterm2"
  # a live process that is the child of a shell that waits for it, as fake_iterm does
  f="$BATS_TEST_TMPDIR/waiter.pid"
  ( /bin/sh -c '/bin/sleep 300 & echo $! >"$1"; wait' sh "$f" >/dev/null 2>&1 3>&- & )
  while [ ! -s "$f" ]; do /bin/sleep 0.05; done
  waiter=$(cat "$f")
  echo "$waiter 4242" >"$XDG_STATE_HOME/iterm2/compose-at-quit.pid"
  ( /bin/sleep 2; echo "waiter-ended" >>"$SEQ"; kill "$waiter" ) 3>&- >/dev/null 2>&1 &
  runner 0 0 - claude-peer
  [ "$status" -eq 0 ]
  [ "$(grep -E '^(waiter-ended|peer)' "$SEQ" | tr '\n' ',')" = "waiter-ended,peer install," ]
  in_order "compose-at-quit: waited for its waiter" "claude-peer: exit 0"
  # no waiter file: no wait, no line
  : >"$LOG"; rm "$XDG_STATE_HOME/iterm2/compose-at-quit.pid"
  fake_iterm >/dev/null
  runner 0 0 - claude-peer
  no grep -q "compose-at-quit: waited" "$LOG"
}

@test "_run: a live compose-at-quit waiter is waited for before the first item, and another before iTerm2 starts" {
  fake_iterm >/dev/null
  mkdir -p "$XDG_STATE_HOME/iterm2"
  f="$BATS_TEST_TMPDIR/waiter.pid"
  ( /bin/sh -c '/bin/sleep 300 & echo $! >"$1"; wait' sh "$f" >/dev/null 2>&1 3>&- & )
  while [ ! -s "$f" ]; do /bin/sleep 0.05; done
  waiter=$(cat "$f")
  echo "$waiter 4242" >"$XDG_STATE_HOME/iterm2/compose-at-quit.pid"
  # ends a second after the quit was asked, so the runner is already waiting for it
  ( while ! grep -q osa-quit "$SEQ" 2>/dev/null; do /bin/sleep 0.05; done
    /bin/sleep 1; echo "waiter-ended" >>"$SEQ"; kill "$waiter" ) 3>&- >/dev/null 2>&1 &
  # the prefs stub leaves a second waiter behind, so the start has one to wait for
  FAKE_WAITER_FILE="$XDG_STATE_HOME/iterm2/compose-at-quit.pid" runner 0 0 - prefs
  [ "$status" -eq 0 ]
  [ "$(grep -E '^(waiter-ended|prefs|open)' "$SEQ" | tr '\n' ',')" = "waiter-ended,prefs compose,waiter-ended,open," ]
  [ "$(grep -c "compose-at-quit: waited for its waiter" "$LOG")" -eq 2 ]
}

@test "_run: an item that hangs is killed at the timeout, logged and counted failed, the next one runs and iTerm2 starts" {
  fake_iterm >/dev/null
  FAKE_PREFS_HANG=1 ITERM2_RELAUNCH_ITEM_TIMEOUT=3 runner 0 0 - prefs claude-peer
  [ "$status" -eq 1 ]
  in_order "prefs: timed out after 3s" "prefs: exit 124" "claude-peer: exit 0" "launch: started" "done: 2 items, 1 failed"
  [ "$(cat "$PEER_LOG")" = install ]
}

# The Alfred front.

# alfred_json: asserts `alfred` printed exactly one line of JSON and leaves it in $output.
alfred_json() {
  run sh "$BIN" alfred
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  python3 -I -c 'import json, sys; json.loads(sys.argv[1])' "$output"
}

@test "alfred: one item per row, ready rows carry the item as arg, a nothing prefs row and a refused row are not valid" {
  FAKE_PREFS_LINE="composed, 2 waiting, x" ITERM2_RELAUNCH_CLAUDE_PEER="$BATS_TEST_TMPDIR/no-such-peer" alfred_json
  python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["skipknowledge"] is True
a, b = d["items"]
assert a["title"] == "Apply iTerm2 preference changes (2 waiting)" and a["arg"] == "prefs" and a["valid"], a
assert a["subtitle"].startswith("Quits iTerm2 (every session ends), composes"), a
assert b["title"] == "claude-peer cannot run" and b["subtitle"] == "claude-peer is not deployed", b
assert b["valid"] is False and "arg" not in b, b
' "$output"
  FAKE_PREFS_LINE="composed, in sync" alfred_json
  python3 -I -c '
import json, sys
a, b = json.loads(sys.argv[1])["items"]
assert a == {"title": "iTerm2 preferences are in sync", "subtitle": "Nothing waits", "valid": False}, a
assert b["title"] == "Claude Peers workgroups are installed and current" and b["valid"] is False, b
' "$output"
  FAKE_PREFS_LINE="not composed (folder /x)" alfred_json
  python3 -I -c '
import json, sys
a = json.loads(sys.argv[1])["items"][0]
assert a["title"] == "Switch iTerm2 to composed preferences" and a["arg"] == "prefs-install" and a["valid"], a
' "$output"
}

@test "alfred: two ready rows add Everything that is ready first, its arg the comma list" {
  cask claude-code@latest 2.1.322 2.1.323 true false binary none
  FAKE_PREFS_LINE="composed, 1 waiting, x" alfred_json
  python3 -I -c '
import json, sys
items = json.loads(sys.argv[1])["items"]
e = items[0]
assert e["title"] == "Everything that is ready (2 items)", e
assert e["arg"] == "prefs,brew:claude-code@latest" and e["subtitle"] == "prefs, brew:claude-code@latest" and e["valid"], e
assert [i.get("arg") for i in items[1:]] == ["prefs", None, "brew:claude-code@latest"], items
assert items[3]["title"] == "Upgrade claude-code@latest (2.1.322 -> 2.1.323)", items[3]
' "$output"
}

@test "alfred: a current cask stays actionable, since only the front looks upstream" {
  cask claude-code 2.1.0 2.1.0 false false binary none
  FAKE_PREFS_LINE="composed, in sync" alfred_json
  python3 -I -c '
import json, sys
c = json.loads(sys.argv[1])["items"][2]
assert c["title"] == "Upgrade claude-code" and c["arg"] == "brew:claude-code" and c["valid"], c
assert c["subtitle"] == "2.1.0 is current; looks for a newer one first and quits nothing if there is none", c
' "$output"
}

@test "alfred: every form is one line of ASCII JSON, and brew update is never run" {
  cask claude-code@latest 1.0 2.0 true false binary none
  cask selfupdating 3.7.3 3.7.7 true true app none
  printf '[iterm2-relaunch]\n\tbrew = selfupdating\n' >"$HOME/.gitconfig"
  for line in "composed, in sync" "composed, 3 waiting, x" "not composed (folder /x)" "garbled"; do
    FAKE_PREFS_LINE=$line alfred_json
    [ -z "$(printf '%s' "$output" | LC_ALL=C tr -d '\0-\177')" ]
  done
  grep -q '^info' "$BREW_LOG"
  no grep -q '^update' "$BREW_LOG"
  FAKE_OS=Linux run sh "$BIN" alfred
  [ "$status" -eq 2 ]
}

@test "the Alfred workflow calls ~/bin/iterm2-relaunch by absolute path and passes the selection as argv" {
  run python3 -I - "$BATS_TEST_DIRNAME/../alfred/iterm2-relaunch/info.plist" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
assert p["bundleid"] == "local.iterm2-relaunch.alfred", p["bundleid"]
by_type = {o["type"]: o for o in p["objects"]}
sf = by_type["alfred.workflow.input.scriptfilter"]["config"]
act = by_type["alfred.workflow.action.script"]["config"]
assert sf["script"] == '"$HOME/bin/iterm2-relaunch" alfred\n', sf["script"]
assert act["script"] == '"$HOME/bin/iterm2-relaunch" --yes "$1"\n', act["script"]
assert sf["keyword"] == "irelaunch" and sf["scriptargtype"] == 1 and act["scriptargtype"] == 1
uids = {o["uid"] for o in p["objects"]}
assert len(uids) == 2
assert set(p["connections"]) <= uids and set(p["uidata"]) == uids
assert all(c["destinationuid"] in uids for v in p["connections"].values() for c in v)
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "alfred-install: hands the zipped workflow to Alfred with a clean environment, and warns when no Alfred app is installed" {
  export TMPDIR="$BATS_TEST_TMPDIR"
  export CLAUDE_CONFIG_DIR=x CLAUDE_PROFILE=x CLAUDE_CODE_SESSION_ID=x CLAUDECODE=x alfred_workflow_uid=x
  export ITERM2_RELAUNCH_APPLICATIONS="$BATS_TEST_TMPDIR/Applications"
  mkdir -p "$ITERM2_RELAUNCH_APPLICATIONS"
  run sh "$BIN" alfred-install "$BATS_TEST_DIRNAME/../alfred/iterm2-relaunch" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Alfred does not appear to be installed"* ]]
  [[ "$output" == *'iterm2-relaunch: handed iTerm2-Relaunch.alfredworkflow to Alfred; confirm the import in its window'* ]]
  [[ "$output" == *'iterm2-relaunch: then the keyword is "irelaunch"'* ]]
  [ "$(wc -l <"$OPEN_LOG" | tr -d ' ')" -eq 1 ]
  zipfile=$(cat "$OPEN_LOG")
  [ "${zipfile##*/}" = iTerm2-Relaunch.alfredworkflow ]
  python3 -I -c 'import sys, zipfile; assert zipfile.ZipFile(sys.argv[1]).namelist() == ["info.plist"]' "$zipfile"
  for v in CLAUDE_CONFIG_DIR CLAUDE_PROFILE CLAUDE_CODE_SESSION_ID CLAUDECODE alfred_workflow_uid; do
    no grep -q "^$v=" "$OPEN_ENV"
  done
  grep -Fxq "PATH=/usr/bin:/bin:/usr/sbin:/sbin" "$OPEN_ENV"
  mkdir "$ITERM2_RELAUNCH_APPLICATIONS/Alfred 5.app"
  run sh "$BIN" alfred-install "$BATS_TEST_DIRNAME/../alfred/iterm2-relaunch" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" != *"Alfred does not appear to be installed"* ]]
  run sh "$BIN" alfred-install "$BATS_TEST_TMPDIR/nowhere" 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"no info.plist in $BATS_TEST_TMPDIR/nowhere"* ]]
}
