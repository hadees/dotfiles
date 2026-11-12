#!/usr/bin/env bats

# loginguard compares the organization `claude auth status --json` reports
# for a profile directory with the pin in git config (claude.<dir>.org), and
# refuses a launch or a prompt on a mismatch. These tests drive the real
# script under a sandboxed HOME and GIT_CONFIG_GLOBAL with a stub `claude`
# that prints a fixture instead of asking the real CLI (the real CLI and the
# real login are never touched). Fixture UUIDs only (see CLAUDE.md); the
# fixtures carry no organization name and no email on purpose.

PINNED=11111111-2222-4333-8444-555555555555
OTHER=99999999-8888-4777-8666-555555555555

setup() {
  command -v python3 >/dev/null || skip "python3 not installed"
  REAL_PYTHON3="$(python3 -c 'import sys; print(sys.executable)')"
  REAL_GIT="$(command -v git)"

  mkdir -p "$BATS_TEST_TMPDIR/home"
  export HOME
  HOME="$(cd "$BATS_TEST_TMPDIR/home" && pwd -P)"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  : > "$GIT_CONFIG_GLOBAL"

  # A pinned session (where these tests are usually run from) hands its
  # variables down; the real CLI must never be the one asked.
  unset CLAUDE_CODE_EXECPATH CLAUDE_CONFIG_DIR CLAUDE_LOGIN_CHECK \
    CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY XDG_STATE_HOME
  export LOGINGUARD_LOG="$BATS_TEST_TMPDIR/events.log"

  # An asdf-style shim resolves relative to $HOME, which is sandboxed here.
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  stub_exe "$BIN/python3" "exec \"$REAL_PYTHON3\" \"\$@\""
  stub_exe "$BIN/git" "exec \"$REAL_GIT\" \"\$@\""
  CALLS="$BATS_TEST_TMPDIR/calls.log"
  stub_claude "$BIN/claude" "$CALLS"
  export PATH="$BIN:$PATH"

  LG="$BATS_TEST_DIRNAME/../bin/executable_loginguard"
  export STATUS_FIXTURE="$BATS_TEST_TMPDIR/status.json"
  export STATUS_RC=0
  mkdir -p "$HOME/.claude" "$HOME/.claude-alpha" "$HOME/.claude-beta"
}

stub_exe() { # path, body
  printf '#!/bin/sh\n%s\n' "$2" > "$1"
  chmod +x "$1"
}

# Records "<arguments>|<CLAUDE_CONFIG_DIR or UNSET>", answers `auth status`
# with $STATUS_FIXTURE, and on `auth logout` rewrites the fixture to logged
# out unless $LOGOUT_BROKEN is set.
stub_claude() { # path, call log
  stub_exe "$1" "echo \"\$*|\${CLAUDE_CONFIG_DIR-UNSET}\" >> \"$2\"
case \"\$1 \$2\" in
  'auth logout')
    [ -n \"\${LOGOUT_BROKEN-}\" ] || echo '{\"loggedIn\":false}' > \"\$STATUS_FIXTURE\"
    exit 0 ;;
  'auth status')
    cat \"\$STATUS_FIXTURE\"
    exit \"\$STATUS_RC\" ;;
esac
exit 0"
}

# How many times the stub was asked to log out.
logouts() {
  [ -f "$CALLS" ] || { echo 0; return; }
  grep -c '^auth logout' "$CALLS" || true
}

pin() { # dir spelling, value [label]
  git config --file "$GIT_CONFIG_GLOBAL" "claude.$1.org" "$2"
  [ -z "${3-}" ] || git config --file "$GIT_CONFIG_GLOBAL" "claude.$1.org-label" "$3"
}

set_status() { # org [expiry] [method]
  printf '{"loggedIn":true,"authMethod":"%s","orgId":"%s","loginExpiresAt":"%s"}\n' \
    "${3:-claude.ai}" "$1" "${2:-2099-01-01T00:00:00.000Z}" > "$STATUS_FIXTURE"
}

# An ISO timestamp N days from now.
days_ahead() {
  python3 -c 'import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=float(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%S.000Z"))' "$1"
}

field() { # n of the TAB-separated $output
  printf '%s\n' "$output" | awk -F'\t' -v n="$1" '{print $n}'
}

@test "no pin: unpinned, exit 0, and claude is never asked" {
  run "$LG" verdict --profile "$HOME/.claude-alpha"
  [ "$status" -eq 0 ]
  [ "$(field 1)" = unpinned ]
  [ ! -e "$CALLS" ]
  run "$LG" launch --profile "$HOME/.claude-alpha"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$CALLS" ]
}

@test "an unpinned directory never starts python" {
  run sh -x "$LG" verdict --profile "$HOME/.claude-alpha"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -q 'python3 -I' || { echo "python3 started for an unpinned directory"; false; }
}

@test "tilde-key pin, status in the pinned org: ok" {
  pin '~/.claude-alpha' "$PINNED"
  set_status "$PINNED"
  run "$LG" verdict --profile "$HOME/.claude-alpha"
  [ "$status" -eq 0 ]
  [ "$(field 1)" = ok ]
  [ "$(field 2)" = "$PINNED" ]
  [ "$(field 3)" = "$PINNED" ]
  [ "$(field 5)" = - ]
}

@test "expanded-key pin and a trailing slash on --profile are found" {
  pin "$HOME/.claude-alpha" "$PINNED"
  set_status "$PINNED"
  run "$LG" verdict --profile "$HOME/.claude-alpha/"
  [ "$status" -eq 0 ]
  [ "$(field 1)" = ok ]
  pin '~/.claude-beta' "$PINNED"
  run "$LG" verdict --profile "$HOME/.claude-beta//"
  [ "$(field 1)" = ok ]
}

@test "other org: verdict exits 3 with both UUIDs; launch refuses and logs one clean line" {
  pin '~/.claude-alpha' "$PINNED"
  set_status "$OTHER"
  run "$LG" verdict --profile "$HOME/.claude-alpha"
  [ "$status" -eq 3 ]
  [ "$(field 1)" = mismatch ]
  [ "$(field 2)" = "$PINNED" ]
  [ "$(field 3)" = "$OTHER" ]
  [ "$(field 5)" = - ]
  run "$LG" launch --profile "$HOME/.claude-alpha"
  [ "$status" -eq 3 ]
  [[ $output == *"claude: REFUSED:"* ]]
  [[ $output == *"$PINNED"* ]]
  [[ $output == *"$OTHER"* ]]
  [[ $output == *"claude auth login"* ]]
  [[ $output == *"CLAUDE_LOGIN_CHECK=0"* ]]
  [ "$(wc -l < "$LOGINGUARD_LOG")" -eq 1 ]
  [ "$(awk -F'\t' '{print NF}' "$LOGINGUARD_LOG")" -eq 6 ]
  [ "$(awk -F'\t' '{print $2}' "$LOGINGUARD_LOG")" = refused-launch ]
  ! grep -q '@' "$LOGINGUARD_LOG" || { echo "the events log holds an @"; false; }
}

@test "another directory pinned to the stored org is named, with its label" {
  pin '~/.claude-alpha' "$PINNED"
  pin '~/.claude-beta' "$OTHER" "Fixture Beta"
  set_status "$OTHER"
  run "$LG" verdict --profile "$HOME/.claude-alpha"
  [ "$status" -eq 3 ]
  [ "$(field 5)" = "other=~/.claude-beta" ]
  run "$LG" launch --profile "$HOME/.claude-alpha"
  [[ $output == *"~/.claude-beta"* ]]
  [[ $output == *"Fixture Beta"* ]]
}

@test "logged out: exit 0; launch is silent, launch --attended says so" {
  pin '~/.claude-alpha' "$PINNED"
  echo '{"loggedIn":false}' > "$STATUS_FIXTURE"
  STATUS_RC=1 run "$LG" verdict --profile "$HOME/.claude-alpha"
  [ "$status" -eq 0 ]
  [ "$(field 1)" = logged-out ]
  STATUS_RC=1 run "$LG" launch --profile "$HOME/.claude-alpha"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  STATUS_RC=1 run "$LG" launch --profile "$HOME/.claude-alpha" --attended
  [ "$status" -eq 0 ]
  [[ $output == *"not logged in"* ]]
  [[ $output == *"claude auth login"* ]]
}

@test "unverifiable: a pin that is not a UUID" {
  pin '~/.claude-alpha' not-a-uuid
  set_status "$PINNED"
  run "$LG" verdict --profile "$HOME/.claude-alpha"
  [ "$status" -eq 4 ]
  [ "$(field 1)" = unverifiable ]
  [ "$(field 5)" = pin-not-a-uuid ]
  run "$LG" launch --profile "$HOME/.claude-alpha"
  [ "$status" -eq 4 ]
  [[ $output == *"REFUSED"* ]]
}

@test "unverifiable: the status is not JSON" {
  pin '~/.claude-alpha' "$PINNED"
  echo 'not json' > "$STATUS_FIXTURE"
  run "$LG" verdict --profile "$HOME/.claude-alpha"
  [ "$status" -eq 4 ]
  [ "$(field 5)" = status-not-json ]
  run "$LG" launch --profile "$HOME/.claude-alpha"
  [ "$status" -eq 4 ]
  [[ $output == *"REFUSED"* ]]
}

@test "unverifiable: logged in with no orgId" {
  pin '~/.claude-alpha' "$PINNED"
  echo '{"loggedIn":true,"authMethod":"claude.ai"}' > "$STATUS_FIXTURE"
  run "$LG" verdict --profile "$HOME/.claude-alpha"
  [ "$status" -eq 4 ]
  [ "$(field 5)" = no-org-in-status ]
  run "$LG" launch --profile "$HOME/.claude-alpha"
  [ "$status" -eq 4 ]
}

@test "unverifiable: an api_key login with no orgId" {
  pin '~/.claude-alpha' "$PINNED"
  echo '{"loggedIn":true,"authMethod":"api_key"}' > "$STATUS_FIXTURE"
  run "$LG" verdict --profile "$HOME/.claude-alpha"
  [ "$status" -eq 4 ]
  [ "$(field 5)" = auth-method:api_key ]
  run "$LG" launch --profile "$HOME/.claude-alpha"
  [ "$status" -eq 4 ]
}

@test "a matching orgId under a non-claude.ai authMethod is a mismatch naming the method" {
  pin '~/.claude-alpha' "$PINNED"
  set_status "$PINNED" "" oauth_token
  run "$LG" verdict --profile "$HOME/.claude-alpha"
  [ "$status" -eq 3 ]
  [ "$(field 1)" = mismatch ]
  [ "$(field 5)" = auth-method:oauth_token ]
  run "$LG" launch --profile "$HOME/.claude-alpha"
  [ "$status" -eq 3 ]
  [[ $output == *"oauth_token"* ]]
}

@test "unverifiable: no claude on PATH" {
  pin '~/.claude-alpha' "$PINNED"
  bare="$BATS_TEST_TMPDIR/bare"
  mkdir -p "$bare"
  cp "$BIN/python3" "$BIN/git" "$bare/"
  run env PATH="$bare" "$LG" verdict --profile "$HOME/.claude-alpha"
  [ "$status" -eq 4 ]
  [ "$(field 5)" = no-claude ]
  run env PATH="$bare" "$LG" launch --profile "$HOME/.claude-alpha"
  [ "$status" -eq 4 ]
  [[ $output == *"REFUSED"* ]]
}

@test "unverifiable: no python3 on PATH" {
  pin '~/.claude-alpha' "$PINNED"
  nopy="$BATS_TEST_TMPDIR/nopy"
  mkdir -p "$nopy"
  cp "$BIN/git" "$nopy/"
  run env PATH="$nopy" "$LG" verdict --profile "$HOME/.claude-alpha"
  [ "$status" -eq 4 ]
  [ "$(field 5)" = no-python3 ]
  run env PATH="$nopy" "$LG" launch --profile "$HOME/.claude-alpha"
  [ "$status" -eq 4 ]
  [[ $output == *"REFUSED"* ]]
  run env PATH="$nopy" CLAUDE_CONFIG_DIR="$HOME/.claude-alpha" "$LG" hook prompt
  [ "$status" -eq 2 ]
}

@test "--profile for the default directory unsets the variable; another directory sets it" {
  pin '~/.claude' "$PINNED"
  pin '~/.claude-alpha' "$PINNED"
  set_status "$PINNED"
  CLAUDE_CONFIG_DIR="$HOME/.claude-beta" run "$LG" verdict --profile "$HOME/.claude"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "auth status --json|UNSET" ]
  : > "$CALLS"
  CLAUDE_CONFIG_DIR="$HOME/.claude-beta" run "$LG" verdict --profile "$HOME/.claude-alpha"
  [ "$(cat "$CALLS")" = "auth status --json|$HOME/.claude-alpha" ]
}

@test "no --profile and the variable unset: the pin of ~/.claude is consulted" {
  pin '~/.claude' "$PINNED"
  set_status "$OTHER"
  run "$LG" verdict
  [ "$status" -eq 3 ]
  [ "$(field 2)" = "$PINNED" ]
  # and the environment is passed untouched
  [ "$(cat "$CALLS")" = "auth status --json|UNSET" ]
}

@test "hook prompt: silent exit 0 unless mismatch or unverifiable" {
  pin '~/.claude' "$PINNED"
  set_status "$PINNED"
  run "$LG" hook prompt < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  echo '{"loggedIn":false}' > "$STATUS_FIXTURE"
  run "$LG" hook prompt < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  set_status "$OTHER"
  run "$LG" hook prompt < /dev/null
  [ "$status" -eq 2 ]
  [[ $output == "loginguard:"* ]]
  [[ $output == *"$PINNED"* ]]
  [[ $output == *"$OTHER"* ]]
  [ "$(awk -F'\t' '{print $2}' "$LOGINGUARD_LOG")" = blocked-prompt ]
  echo 'not json' > "$STATUS_FIXTURE"
  run "$LG" hook prompt < /dev/null
  [ "$status" -eq 2 ]
}

@test "hook prompt with no pin at all: exit 0, nothing asked" {
  run "$LG" hook prompt < /dev/null
  [ "$status" -eq 0 ]
  [ ! -e "$CALLS" ]
}

@test "CLAUDE_LOGIN_CHECK=0 over a mismatch bypasses launch and hook, and logs both" {
  pin '~/.claude' "$PINNED"
  set_status "$OTHER"
  CLAUDE_LOGIN_CHECK=0 run "$LG" launch --profile "$HOME/.claude"
  [ "$status" -eq 0 ]
  [[ $output == *"bypassed"* ]]
  CLAUDE_LOGIN_CHECK=0 run "$LG" hook prompt < /dev/null
  [ "$status" -eq 0 ]
  [ "$(grep -c "$(printf '\tbypassed\t')" "$LOGINGUARD_LOG")" -eq 2 ]
}

@test "expiry: attended launch warns inside three days, never otherwise" {
  pin '~/.claude' "$PINNED"
  set_status "$PINNED" "$(days_ahead 2)"
  run "$LG" launch --profile "$HOME/.claude" --attended
  [ "$status" -eq 0 ]
  [[ $output == *"expires"* ]]
  [[ $output == *"claude auth login"* ]]
  run "$LG" launch --profile "$HOME/.claude"
  [ -z "$output" ]
  set_status "$PINNED" "$(days_ahead 10)"
  run "$LG" launch --profile "$HOME/.claude" --attended
  [ -z "$output" ]
  run "$LG" launch --profile "$HOME/.claude"
  [ -z "$output" ]
  set_status "$PINNED" "$(days_ahead -1)"
  run "$LG" launch --profile "$HOME/.claude" --attended
  [[ $output == *"expired"* ]]
  run "$LG" launch --profile "$HOME/.claude"
  [ -z "$output" ]
}

@test "explain: one sentence per verdict" {
  run "$LG" explain --profile "$HOME/.claude-alpha"
  [ "$status" -eq 0 ]
  [[ $output == "no claude.~/.claude-alpha.org pin" ]]
  pin '~/.claude-alpha' "$PINNED" Alpha
  set_status "$PINNED"
  run "$LG" explain --profile "$HOME/.claude-alpha"
  [[ $output == "ok:"*"$PINNED"*"Alpha"* ]]
  echo '{"loggedIn":false}' > "$STATUS_FIXTURE"
  run "$LG" explain --profile "$HOME/.claude-alpha"
  [[ $output == "pinned to $PINNED (Alpha)"* ]]
  set_status "$OTHER"
  run "$LG" explain --profile "$HOME/.claude-alpha"
  [ "$status" -eq 0 ]
  [[ $output == "MISMATCH:"*"$OTHER"*"$PINNED"* ]]
  echo 'not json' > "$STATUS_FIXTURE"
  run "$LG" explain --profile "$HOME/.claude-alpha"
  [[ $output == "UNVERIFIABLE (status-not-json):"* ]]
}

@test "settings is valid JSON naming both hooks and the blocking exit" {
  run "$LG" settings
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | python3 -m json.tool > /dev/null
  [[ $output == *"loginguard hook prompt"* ]]
  [[ $output == *"exit 2"* ]]
  [[ $output == *'"onFailure": "block"'* ]]
  [[ $output == *"loginguard hook auth"* ]]
  [ "$(printf '%s\n' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Notification"]["matcher"])')" = auth_success ]
}

@test "an unknown subcommand or flag prints usage and exits 2" {
  run "$LG" bogus
  [ "$status" -eq 2 ]
  [[ $output == usage:* ]]
  run "$LG"
  [ "$status" -eq 2 ]
  run "$LG" hook other
  [ "$status" -eq 2 ]
  run "$LG" verdict --attended
  [ "$status" -eq 2 ]
}

@test "CLAUDE_CODE_EXECPATH names the binary that is asked" {
  pin '~/.claude' "$PINNED"
  set_status "$PINNED"
  stub_claude "$BATS_TEST_TMPDIR/claude2" "$BATS_TEST_TMPDIR/calls2.log"
  CLAUDE_CODE_EXECPATH="$BATS_TEST_TMPDIR/claude2" run "$LG" verdict
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/calls2.log" ]
  [ ! -e "$CALLS" ]
}

@test "after-login over a mismatch logs out once, says REMOVED with both UUIDs, logs it" {
  pin '~/.claude-alpha' "$PINNED"
  set_status "$OTHER"
  run "$LG" after-login --profile "$HOME/.claude-alpha"
  [ "$status" -eq 3 ]
  [[ $output == *"claude: REMOVED the login just made:"* ]]
  [[ $output == *"$PINNED"* ]]
  [[ $output == *"$OTHER"* ]]
  [[ $output == *"claude auth login"* ]]
  [ "$(logouts)" -eq 1 ]
  [ "$(wc -l < "$LOGINGUARD_LOG")" -eq 1 ]
  [ "$(awk -F'\t' '{print $2}' "$LOGINGUARD_LOG")" = removed-login ]
  [ "$(awk -F'\t' '{print NF}' "$LOGINGUARD_LOG")" -eq 6 ]
}

@test "after-login over ok, logged-out or unpinned removes nothing and is silent" {
  run "$LG" after-login --profile "$HOME/.claude-alpha"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  pin '~/.claude-alpha' "$PINNED"
  set_status "$PINNED"
  run "$LG" after-login --profile "$HOME/.claude-alpha"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  echo '{"loggedIn":false}' > "$STATUS_FIXTURE"
  run "$LG" after-login --profile "$HOME/.claude-alpha"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(logouts)" -eq 0 ]
}

@test "after-login over an unverifiable status removes nothing and exits 4" {
  pin '~/.claude-alpha' "$PINNED"
  echo 'not json' > "$STATUS_FIXTURE"
  run "$LG" after-login --profile "$HOME/.claude-alpha"
  [ "$status" -eq 4 ]
  [[ $output == *"status-not-json"* ]]
  echo '{"loggedIn":true,"authMethod":"api_key"}' > "$STATUS_FIXTURE"
  run "$LG" after-login --profile "$HOME/.claude-alpha"
  [ "$status" -eq 4 ]
  [ "$(logouts)" -eq 0 ]
}

@test "after-login --profile for the default directory logs out with the variable unset" {
  pin '~/.claude' "$PINNED"
  set_status "$OTHER"
  CLAUDE_CONFIG_DIR="$HOME/.claude-beta" run "$LG" after-login --profile "$HOME/.claude"
  [ "$status" -eq 3 ]
  [ "$(grep '^auth logout' "$CALLS")" = "auth logout|UNSET" ]
}

@test "hook auth over a mismatch logs out, exits 0 and prints nothing" {
  pin '~/.claude-alpha' "$PINNED"
  set_status "$OTHER"
  CLAUDE_CONFIG_DIR="$HOME/.claude-alpha" run "$LG" hook auth < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(logouts)" -eq 1 ]
  [ "$(awk -F'\t' '{print $2}' "$LOGINGUARD_LOG")" = removed-login ]
}

@test "hook prompt explains a removed login for ten minutes, not an hour" {
  pin '~/.claude-alpha' "$PINNED"
  set_status "$OTHER"
  export CLAUDE_CONFIG_DIR="$HOME/.claude-alpha"
  run "$LG" hook auth < /dev/null
  [ "$status" -eq 0 ]
  run "$LG" hook prompt < /dev/null
  [ "$status" -eq 2 ]
  [[ $output == "loginguard:"*"removed"* ]]
  [[ $output == *"/login"* ]]
  awk -F'\t' -v OFS='\t' '$1 = "2000-01-01T00:00:00Z"' "$LOGINGUARD_LOG" > "$BATS_TEST_TMPDIR/old.log"
  mv "$BATS_TEST_TMPDIR/old.log" "$LOGINGUARD_LOG"
  run "$LG" hook prompt < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "CLAUDE_LOGIN_CHECK=0 removes nothing from after-login or hook auth" {
  pin '~/.claude-alpha' "$PINNED"
  set_status "$OTHER"
  CLAUDE_LOGIN_CHECK=0 run "$LG" after-login --profile "$HOME/.claude-alpha"
  [ "$status" -eq 0 ]
  CLAUDE_LOGIN_CHECK=0 CLAUDE_CONFIG_DIR="$HOME/.claude-alpha" run "$LG" hook auth < /dev/null
  [ "$status" -eq 0 ]
  [ "$(logouts)" -eq 0 ]
  [ "$(grep -c "$(printf '\tbypassed\t')" "$LOGINGUARD_LOG")" -eq 2 ]
}

@test "a logout that does not take is logged remove-failed and says the login is still stored" {
  pin '~/.claude-alpha' "$PINNED"
  set_status "$OTHER"
  LOGOUT_BROKEN=1 run "$LG" after-login --profile "$HOME/.claude-alpha"
  [ "$status" -eq 3 ]
  [[ $output == *"still stored"* ]]
  [[ $output == *"claude auth logout"* ]]
  [ "$(logouts)" -eq 1 ]
  [ "$(awk -F'\t' '{print $2}' "$LOGINGUARD_LOG")" = remove-failed ]
}

@test "without python3: hook auth is silent, after-login removes nothing and exits 4" {
  pin '~/.claude-alpha' "$PINNED"
  nopy="$BATS_TEST_TMPDIR/nopy"
  mkdir -p "$nopy"
  cp "$BIN/git" "$nopy/"
  CLAUDE_CONFIG_DIR="$HOME/.claude-alpha" run env PATH="$nopy" "$LG" hook auth < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run env PATH="$nopy" "$LG" after-login --profile "$HOME/.claude-alpha"
  [ "$status" -eq 4 ]
  [[ $output == *"no-python3"* ]]
}

@test "after-login never logs out for an authMethod mismatch, matching orgId or not" {
  pin '~/.claude-alpha' "$PINNED"
  set_status "$PINNED" "" oauth_token
  run "$LG" after-login --profile "$HOME/.claude-alpha"
  [ "$status" -eq 3 ]
  [[ $output == *"nothing removed"* ]]
  set_status "$OTHER" "" oauth_token
  run "$LG" after-login --profile "$HOME/.claude-alpha"
  [ "$status" -eq 3 ]
  [[ $output == *"nothing removed"* ]]
  CLAUDE_CONFIG_DIR="$HOME/.claude-alpha" run "$LG" hook auth < /dev/null
  [ "$status" -eq 0 ]
  [ "$(logouts)" -eq 0 ]
}

@test "an uncaught exception fails closed: 2 for the prompt hook, 4 otherwise, no logout" {
  pin '~/.claude-alpha' "$PINNED"
  # Output that is not valid UTF-8 makes subprocess raise outside the script's handlers.
  stub_exe "$BIN/claude" "echo \"\$*\" >> \"$CALLS\"; printf '\\377\\376'"
  CLAUDE_CONFIG_DIR="$HOME/.claude-alpha" run "$LG" hook prompt < /dev/null
  [ "$status" -eq 2 ]
  [[ $output == *"internal error"* ]]
  run "$LG" launch --profile "$HOME/.claude-alpha"
  [ "$status" -eq 4 ]
  [[ $output == *"REFUSED"* ]]
  run "$LG" after-login --profile "$HOME/.claude-alpha"
  [ "$status" -eq 4 ]
  CLAUDE_CONFIG_DIR="$HOME/.claude-alpha" run "$LG" hook auth < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(logouts)" -eq 0 ]
  [ "$(grep -c "$(printf '\tinternal-error\t')" "$LOGINGUARD_LOG")" -eq 4 ]
}
