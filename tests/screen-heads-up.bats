#!/usr/bin/env bats

# screen-heads-up: a countdown that proceeds unless "Not now" is chosen. The
# real script runs against a stub terminal-notifier that records its
# arguments and says whatever the test tells it to, plus stub lsappinfo, open
# and uname. Nothing here posts a real notification or touches the screen.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  unset XDG_STATE_HOME
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  cp "$BATS_TEST_DIRNAME/../bin/executable_screen-heads-up" "$BIN/screen-heads-up"
  export PATH="$BIN:$PATH"
  STATE="$HOME/.local/state/screen-heads-up"
  export TN_LOG="$BATS_TEST_TMPDIR/tn.log" OPEN_LOG="$BATS_TEST_TMPDIR/open.log"
  : > "$TN_LOG"; : > "$OPEN_LOG"
  export SCREEN_HEADS_UP_NOTIFIER="$BIN/terminal-notifier"
  export SCREEN_HEADS_UP_LSAPPINFO="$BIN/lsappinfo"
  export SCREEN_HEADS_UP_OPEN="$BIN/open"
  export SCREEN_HEADS_UP_TICK=0.1
  export FAKE_FRONT=com.example.editor
  unset FAKE_TN_AFTER FAKE_TN_SAY FAKE_TN_EXIT FAKE_UNAME

  cat > "$BIN/terminal-notifier" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$TN_LOG"
case "$*" in *-remove*) exit 0 ;; esac
sleep "${FAKE_TN_AFTER:-0}"
printf '%s\n' "${FAKE_TN_SAY-}"
exit "${FAKE_TN_EXIT:-0}"
STUB
  cat > "$BIN/lsappinfo" <<'STUB'
#!/bin/sh
case "$1" in
  front) echo 'ASN:0x0-0x1001:' ;;
  info) printf '"CFBundleIdentifier"="%s"\n' "$FAKE_FRONT" ;;
esac
STUB
  cat > "$BIN/open" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$OPEN_LOG"
STUB
  cat > "$BIN/uname" <<'STUB'
#!/bin/sh
echo "${FAKE_UNAME:-Darwin}"
STUB
  chmod +x "$BIN/terminal-notifier" "$BIN/lsappinfo" "$BIN/open" "$BIN/uname"
}

# The log's events, comma-joined.
events() { cut -f2 "$STATE/log" | paste -sd, -; }

# A heads-up left waiting in the background; its pid lands in $bg.
start_bg() { # <what> <seconds>
  screen-heads-up "$@" > "$BATS_TEST_TMPDIR/bg.out" 2>&1 3>&- &
  bg=$!
  # `answer` appears once the notice is out, after `asked` is logged.
  for _ in $(seq 50); do [ -e "$STATE/waiting" ] && [ -e "$STATE/answer" ] && break; sleep 0.1; done
  [ -e "$STATE/answer" ]
}

@test "go: nobody answers, the count runs out, exit 0, the log says asked then go" {
  FAKE_TN_AFTER=5 run screen-heads-up "doing x" 3
  [ "$status" -eq 0 ]
  [[ "$output" == *"doing x; going ahead in 3s unless Not now (or: screen-heads-up --not-now)"* ]]
  [[ "$output" == *"screen-heads-up: go" ]]
  [ "$(events)" = "asked,go" ]
  [ ! -e "$STATE/waiting" ]
}

@test "not now: the button's answer ends it with exit 1 before the count is over" {
  start=$SECONDS
  FAKE_TN_AFTER=0.3 FAKE_TN_SAY="Not now" run screen-heads-up "doing x" 100
  [ "$status" -eq 1 ]
  [ $((SECONDS - start)) -lt 5 ]
  [[ "$output" == *"screen-heads-up: not now" ]]
  [ "$(events)" = "asked,not-now:click" ]
  [ ! -e "$STATE/waiting" ]
}

@test "a closed or clicked notice is not a go and not a stop: the count runs to its end" {
  start=$(date +%s)
  FAKE_TN_AFTER=0.1 FAKE_TN_SAY="@CLOSED" run screen-heads-up "doing x" 20
  [ "$status" -eq 0 ]
  [ $(( $(date +%s) - start )) -ge 1 ]
  [ "$(events)" = "asked,go" ]
  for say in @TIMEOUT @ACTIONCLICKED "not now" "Not now please" ""; do
    FAKE_TN_SAY="$say" run screen-heads-up "doing x" 3
    [ "$status" -eq 0 ]
  done
  FAKE_TN_EXIT=7 run screen-heads-up "doing x" 3
  [ "$status" -eq 0 ]
  ! grep -q 'not-now' "$STATE/log"
}

@test "--not-now ends a waiting heads-up with exit 1, and says so when none waits" {
  run screen-heads-up --not-now
  [ "$status" -eq 1 ]
  [[ "$output" == *"no heads-up is waiting" ]]
  FAKE_TN_AFTER=5 start_bg "doing x" 100
  run screen-heads-up --status
  [[ "$output" == *"waiting: pid $bg, "*"s left, doing x"* ]]
  run screen-heads-up --not-now
  [ "$status" -eq 0 ]
  [ "$output" = "screen-heads-up: told pid $bg not now" ]
  st=0; wait "$bg" || st=$?
  [ "$st" -eq 1 ]
  [ "$(events)" = "asked,not-now:command" ]
  [ ! -e "$STATE/waiting" ]
}

@test "no notifier: exit 3 at once, could-not-ask in the log" {
  SCREEN_HEADS_UP_NOTIFIER="$BATS_TEST_TMPDIR/absent" run screen-heads-up "doing x" 3
  [ "$status" -eq 3 ]
  [ "$(events)" = "could-not-ask:no-notifier" ]
  [ ! -s "$TN_LOG" ]
}

@test "not macOS: exit 3" {
  FAKE_UNAME=Linux run screen-heads-up "doing x" 3
  [ "$status" -eq 3 ]
  [ "$(events)" = "could-not-ask:not-macos" ]
  [ ! -s "$TN_LOG" ]
}

@test "usage: seconds that are not digits, one argument, a what that starts with a dash: exit 2 and nothing asked" {
  for args in "" "doing-x" "doing-x abc" "doing-x -1" "doing-x 1.5" "doing-x 3 extra" "-doing 3" "--bogus"; do
    # shellcheck disable=SC2086
    run screen-heads-up $args
    [ "$status" -eq 2 ]
  done
  run screen-heads-up "doing x" ""
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
  [ ! -s "$TN_LOG" ]
  [ ! -e "$STATE/log" ]
}

@test "a second heads-up while one waits is exit 4 and the first still ends as go" {
  FAKE_TN_AFTER=5 start_bg "first" 15
  run screen-heads-up "second" 3
  [ "$status" -eq 4 ]
  st=0; wait "$bg" || st=$?
  [ "$st" -eq 0 ]
  [ "$(events)" = "asked,busy,go" ]
}

@test "the notice carries the what, the seconds and the Not now action, and is removed on go" {
  FAKE_TN_AFTER=5 run screen-heads-up "doing x" 3
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$TN_LOG")" = "-title Screen needed in 3s -message doing x -action Not now -timeout 3 -group screen-heads-up -sound default" ]
  [ "$(sed -n 2p "$TN_LOG")" = "-remove screen-heads-up" ]
}

@test "the what is cut to 200 characters and loses quotes and control characters" {
  w=$(printf 'q"u\\o\tte\n%0300d' 0)
  # The notifier has to start before the count ends, or it is killed unlogged.
  run screen-heads-up "$w" 3
  [ "$status" -eq 0 ]
  msg=$(sed -n '1s/.*-message \(.*\) -action .*/\1/p' "$TN_LOG")
  [ "${#msg}" -eq 200 ]
  [[ "$msg" == quote000* ]]
  [ "$(cut -f4 "$STATE/log" | head -n 1)" = "$msg" ]
}

@test "go records what was in front; --free says the screen is free and opens that app again when another is in front, not when it still is, never with --no-restore" {
  run screen-heads-up "doing x" 1
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$STATE/held")" = "doing x" ]
  [ "$(sed -n 2p "$STATE/held")" = "com.example.editor" ]

  : > "$TN_LOG"
  FAKE_FRONT=com.example.other run screen-heads-up --free
  [ "$status" -eq 0 ]
  [ "$(cat "$OPEN_LOG")" = "-b com.example.editor" ]
  [ "$TN_LOG" ] && grep -qx -- '-title Screen is free -message doing x -group screen-heads-up' "$TN_LOG"
  [ ! -e "$STATE/held" ]
  [ "$(events)" = "asked,go,free" ]

  : > "$OPEN_LOG"
  screen-heads-up "doing y" 1
  FAKE_FRONT=com.example.editor run screen-heads-up --free "all done"
  [ "$status" -eq 0 ]
  [ ! -s "$OPEN_LOG" ]
  grep -q -- '-message all done' "$TN_LOG"

  screen-heads-up "doing z" 1
  FAKE_FRONT=com.example.other run screen-heads-up --free --no-restore
  [ "$status" -eq 0 ]
  [ ! -s "$OPEN_LOG" ]

  # Nothing held: a notice, no app to bring back.
  FAKE_FRONT=com.example.other run screen-heads-up --free
  [ "$status" -eq 0 ]
  [ ! -s "$OPEN_LOG" ]
}

@test "TERM while waiting removes the notice and the waiting file and exits 1" {
  FAKE_TN_AFTER=5 start_bg "doing x" 100
  kill -TERM "$bg"
  st=0; wait "$bg" || st=$?
  [ "$st" -eq 1 ]
  [ ! -e "$STATE/waiting" ]
  grep -qx -- '-remove screen-heads-up' "$TN_LOG"
  [ "$(events)" = "asked,ended:TERM" ]
}

@test "--status counts the log" {
  run screen-heads-up --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"waiting: none"* ]]
  [[ "$output" == *"held: none"* ]]
  [[ "$output" == *"notifier: $BIN/terminal-notifier"* ]]
  [[ "$output" == *"log: 0 asked, 0 go, 0 not now, 0 could not ask"* ]]

  screen-heads-up "doing x" 1
  FAKE_TN_SAY="Not now" FAKE_TN_AFTER=0.1 screen-heads-up "doing y" 50 || true
  SCREEN_HEADS_UP_NOTIFIER="$BATS_TEST_TMPDIR/absent" screen-heads-up "doing z" 1 || true
  run screen-heads-up --status
  [[ "$output" == *"log: 2 asked, 1 go, 1 not now, 1 could not ask"* ]]
  [[ "$output" == *"held: doing x since 20"* ]]
  SCREEN_HEADS_UP_NOTIFIER="$BATS_TEST_TMPDIR/absent" run screen-heads-up --status
  [[ "$output" == *"notifier: MISSING"* ]]
}
