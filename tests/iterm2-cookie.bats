#!/usr/bin/env bats

# iterm2-cookie and iterm2_cookie_state in dot_functions mint, check and
# forget the API cookie the Claude Code hooks hand to it2. Every test runs in
# a sandbox HOME with a stub it2 and a plain file standing in for iTerm2's API
# socket: nothing here may ask a real iTerm2 for a cookie or touch the real
# ~/.local/state/iterm2.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.config/iterm2" "$HOME/Library/Application Support/iTerm2/private"
  unset CLAUDECODE ITERM_SESSION_ID ITERM2_COOKIE ITERM2_KEY
  export TERM_PROGRAM=bats

  DOTFUNCTIONS="$BATS_TEST_DIRNAME/../dot_functions"
  STATE="$HOME/.local/state/iterm2"
  COOKIE="$STATE/api-cookie"
  SOCK="$HOME/Library/Application Support/iTerm2/private/socket"
  : > "$SOCK"
  touch -t 202001010000 "$SOCK"

  # The stub answers `auth cookie` as the real one does and records every
  # call. $IT2_GETS is how many `session get-status` calls succeed before it
  # starts failing; $IT2_AUTH=fail makes `auth cookie` exit 1.
  IT2_LOG="$BATS_TEST_TMPDIR/it2.log"
  export IT2_LOG
  cat > "$HOME/.config/iterm2/it2" <<'EOF'
#!/bin/sh
echo "$* cookie=${ITERM2_COOKIE-unset}" >> "$IT2_LOG"
case "$1 $2" in
  "auth cookie")
    [ "${IT2_AUTH-}" = fail ] && exit 1
    echo "ITERM2_COOKIE=abc ITERM2_KEY=def"
    ;;
  "session get-status")
    [ "${ITERM2_COOKIE-}" = abc ] || exit 1
    n=$(grep -c '^session get-status' "$IT2_LOG")
    [ "$n" -le "${IT2_GETS-99}" ] || exit 1
    ;;
esac
EOF
  chmod +x "$HOME/.config/iterm2/it2"
}

cookie() {
  run zsh -c "source '$DOTFUNCTIONS'; iterm2-cookie $*"
}

# A cookie file dated $1 (touch -t form).
write_cookie() {
  mkdir -p "$STATE"
  echo "abc def" > "$COOKIE"
  touch -t "$1" "$COOKIE"
}

state() {
  zsh -c "source '$DOTFUNCTIONS'; iterm2_cookie_state; print -r -- \$REPLY"
}

@test "mint: writes 'abc def', mode 0600 in a 0700 directory, no temporary file left" {
  export ITERM_SESSION_ID=w0t0p0:SESS
  cookie
  [ "$status" -eq 0 ]
  [[ "$output" == *"Forever"* ]]
  [[ "$output" == *"fresh until iTerm2 quits"* ]]
  [ "$(cat "$COOKIE")" = "abc def" ]
  [ "$(stat -c %a "$COOKIE" 2>/dev/null || stat -f %Lp "$COOKIE")" = 600 ]
  [ "$(stat -c %a "$STATE" 2>/dev/null || stat -f %Lp "$STATE")" = 700 ]
  [ "$(ls -A "$STATE")" = api-cookie ]
  # used twice, with the session id from the part after the colon
  [ "$(grep -c '^session get-status --session SESS cookie=abc' "$IT2_LOG")" -eq 2 ]
}

@test "mint: a denied request leaves no file and returns 1" {
  export ITERM_SESSION_ID=w0t0p0:SESS IT2_AUTH=fail
  write_cookie 202001010000
  cookie
  [ "$status" -eq 1 ]
  [[ "$output" == *"denied or dismissed"* ]]
  [ ! -e "$COOKIE" ]
}

@test "mint: a cookie that works once and then fails is removed as single-use" {
  export ITERM_SESSION_ID=w0t0p0:SESS IT2_GETS=1
  cookie
  [ "$status" -eq 1 ]
  [[ "$output" == *"single-use"* ]]
  [ ! -e "$COOKIE" ]
  [ "$(ls -A "$STATE")" = "" ]
}

@test "mint: a cookie that fails the first use is removed" {
  export ITERM_SESSION_ID=w0t0p0:SESS IT2_GETS=0
  cookie
  [ "$status" -eq 1 ]
  [[ "$output" == *"would not accept"* ]]
  [ ! -e "$COOKIE" ]
}

@test "mint: outside an iTerm2 session it refuses without calling it2" {
  cookie
  [ "$status" -eq 1 ]
  [[ "$output" == *"not inside an iTerm2 session"* ]]
  [ ! -e "$IT2_LOG" ]
  [ ! -e "$COOKIE" ]
}

@test "mint: with no it2 anywhere it refuses" {
  export ITERM_SESSION_ID=w0t0p0:SESS
  rm "$HOME/.config/iterm2/it2"
  run zsh -c "PATH=/usr/bin:/bin; source '$DOTFUNCTIONS'; iterm2-cookie"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no it2 found"* ]]
}

@test "mint: removes a rejected cookie and truncates the uncookied count" {
  export ITERM_SESSION_ID=w0t0p0:SESS
  mkdir -p "$STATE"
  echo "old new" > "$COOKIE.rejected"
  printf xxx > "$STATE/uncookied"
  cookie
  [ "$status" -eq 0 ]
  [ ! -e "$COOKIE.rejected" ]
  [ -e "$STATE/uncookied" ]
  [ ! -s "$STATE/uncookied" ]
}

@test "state: fresh when the cookie is newer than the socket" {
  write_cookie 202101010000
  [ "$(state)" = fresh ]
}

@test "state: fresh when the socket is missing" {
  write_cookie 201901010000
  rm "$SOCK"
  [ "$(state)" = fresh ]
}

@test "state: stale when the cookie is older than the socket" {
  write_cookie 201901010000
  [ "$(state)" = stale ]
}

@test "state: rejected when only the set-aside file exists" {
  mkdir -p "$STATE"
  echo "abc def" > "$COOKIE.rejected"
  [ "$(state)" = rejected ]
}

@test "state: absent when nothing exists" {
  [ "$(state)" = absent ]
}

@test "status: prints the state; a fresh accepted cookie says accepted" {
  export ITERM_SESSION_ID=w0t0p0:SESS
  write_cookie 202101010000
  cookie status
  [ "$status" -eq 0 ]
  [ "$output" = "fresh accepted" ]
  [ -e "$COOKIE" ]
}

@test "status: a refused cookie is renamed to .rejected" {
  export ITERM_SESSION_ID=w0t0p0:SESS IT2_GETS=0
  write_cookie 202101010000
  cookie status
  [ "$output" = "fresh REFUSED" ]
  [ ! -e "$COOKIE" ]
  [ -e "$COOKIE.rejected" ]
}

@test "status: outside a session it makes no call and only names the state" {
  write_cookie 202101010000
  cookie status
  [ "$output" = fresh ]
  [ ! -e "$IT2_LOG" ]
}

@test "status: a stale cookie is not tried" {
  export ITERM_SESSION_ID=w0t0p0:SESS
  write_cookie 201901010000
  cookie status
  [ "$output" = stale ]
  [ ! -e "$IT2_LOG" ]
}

@test "forget: removes the cookie and the rejected one" {
  write_cookie 202101010000
  echo "abc def" > "$COOKIE.rejected"
  cookie forget
  [ "$status" -eq 0 ]
  [ ! -e "$COOKIE" ]
  [ ! -e "$COOKIE.rejected" ]
}

@test "an unknown argument is a usage error" {
  cookie nonsense
  [ "$status" -eq 2 ]
  [[ "$output" == *usage* ]]
}
