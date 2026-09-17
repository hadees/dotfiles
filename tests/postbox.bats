#!/usr/bin/env bats

# bin/postbox is the local mailbox Claude Code sessions use to reach a
# session in another profile, or two at once. These tests drive the real
# script under a sandboxed HOME with stub am/curl/minisign/launchctl/claude
# binaries: no daemon is started, no release is downloaded, no launchd job is
# registered and no Claude Code config is touched. All names are fixtures —
# no real account, profile, or project name may appear (see CLAUDE.md); the
# agent names are the server's vocabulary, which names nothing.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/code"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  # CI runners export XDG_CONFIG_HOME, which would move the systemd unit.
  unset CLAUDE_CONFIG_DIR XDG_STATE_HOME XDG_CONFIG_HOME

  PB="$BATS_TEST_DIRNAME/../bin/executable_postbox"
  export POSTBOX_STATE="$BATS_TEST_TMPDIR/state"
  export POSTBOX_BIN="$BATS_TEST_TMPDIR/localbin"
  export POSTBOX_AM="$BATS_TEST_TMPDIR/bin/am"

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  export AM_LOG="$BATS_TEST_TMPDIR/am.log"
  export LAUNCHCTL_LOG="$BATS_TEST_TMPDIR/launchctl.log"
  export SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
  export CLAUDE_LOG="$BATS_TEST_TMPDIR/claude.log"
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  export FAKE_INBOX=""
  export FAKE_HTTP=405

  # `am --version` and `am check-inbox ... --json`. The inbox answer comes
  # from FAKE_INBOX (a JSON document) so no server is ever consulted.
  cat > "$BIN/am" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$AM_LOG"
case $1 in
  --version) printf 'am 0.3.36\n' ;;
  check-inbox) [ -n "${FAKE_INBOX:-}" ] || exit 1; printf '%s\n' "$FAKE_INBOX" ;;
  *) exit 1 ;;
esac
STUB
  # curl: the daemon probe reads only the status code it prints.
  cat > "$BIN/curl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$CURL_LOG"
case " $* " in
  *" -w "*) printf '%s' "${FAKE_HTTP:-405}" ;;
esac
exit 0
STUB
  cat > "$BIN/launchctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"
case $1 in print) exit 1 ;; esac
exit 0
STUB
  # systemctl: a Linux runner has a real one whose user session answers, so
  # the install would really enable a unit there. Record and succeed.
  cat > "$BIN/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
exit 0
STUB
  cat > "$BIN/claude" <<'STUB'
#!/bin/sh
printf '%s\t%s\n' "${CLAUDE_CONFIG_DIR:-unset}" "$*" >> "$CLAUDE_LOG"
exit 0
STUB
  cat > "$BIN/uname" <<'STUB'
#!/bin/sh
case $1 in -s) printf '%s\n' "${FAKE_OS:-Darwin}" ;; -m) printf 'arm64\n' ;; *) printf 'Darwin\n' ;; esac
STUB
  chmod +x "$BIN"/*
  export FAKE_OS=Darwin
  export PATH="$BIN:$PATH"

  WORK="$HOME/code/some-project"
  mkdir -p "$WORK"
  cd "$WORK" || return 1
}

teardown() {
  cd / || true
}

# A registry entry for a live session of this profile at $2, named $3, under
# the config dir $1. The pid is bats' own, so `kill -0` finds it alive.
live_session() {
  mkdir -p "$1/sessions"
  printf '{"pid":%s,"cwd":"%s","name":"%s","status":"idle"}\n' "$$" "$2" "$3" > "$1/sessions/$$.json"
}

payload() { printf '%s' "$1" | "$PB" "${@:2}"; }

# --- names --------------------------------------------------------------------

@test "name: is adjective+noun from the vocabulary, and stable for a directory" {
  run "$PB" name
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[A-Z][a-z]+[A-Z][a-z]+$ ]]
  first=$output
  run "$PB" name "$WORK"
  [ "$output" = "$first" ]
  run "$PB" name .
  [ "$output" = "$first" ]
}

@test "name: keys on the path under HOME, so the same layout names alike anywhere" {
  run "$PB" name
  a=$output
  export HOME="$BATS_TEST_TMPDIR/otherhome"
  mkdir -p "$HOME/code/some-project"
  run "$PB" name "$HOME/code/some-project"
  [ "$status" -eq 0 ]
  [ "$output" = "$a" ]
}

@test "name: a different directory is a different agent, a worktree included" {
  run "$PB" name
  a=$output
  mkdir -p "$HOME/code/some-project-branch"
  run "$PB" name "$HOME/code/some-project-branch"
  [ "$status" -eq 0 ]
  [ "$output" != "$a" ]
}

@test "name: a symlinked path and its target are one agent" {
  run "$PB" name
  a=$output
  ln -s "$WORK" "$HOME/code/alias"
  run "$PB" name "$HOME/code/alias"
  [ "$output" = "$a" ]
}

@test "name: a pin from git config wins, normalised to the server's casing" {
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/some-project.name whiteRABBIT
  run "$PB" name --source
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'WhiteRabbit\tpin')" ]
}

@test "name: a pin outside the vocabulary warns and falls back to the derived name" {
  run "$PB" name --source
  derived=${output%%	*}
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/some-project.name BackendHarmonizer
  run "$PB" name --source
  [ "$status" -eq 0 ]
  [[ "$output" == *"$derived	pin-invalid"* ]]
  [[ "$output" == *"pin postbox.code/some-project.name = 'BackendHarmonizer' is not adjective+noun"* ]]
  run "$PB" name
  [ "${lines[0]}" = "$derived" ] || [ "${lines[-1]}" = "$derived" ]
}

@test "name: a valid pin must split as adjective then noun — an adjective alone is rejected" {
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/some-project.name Golden
  run "$PB" name --source
  [[ "$output" == *"pin-invalid"* ]]
}

@test "names: lists every repo under the roots and stops at the first repo" {
  git init -q "$WORK"
  mkdir -p "$HOME/code/nested/inner" "$WORK/vendored"
  git init -q "$HOME/code/nested/inner"
  git init -q "$WORK/vendored"
  run "$PB" names
  [ "$status" -eq 0 ]
  [[ "$output" == *"~/code/some-project	"* ]]
  [[ "$output" == *"~/code/nested/inner	"* ]]
  [[ "$output" != *"vendored"* ]]
  [[ "$output" == *"	hash" ]] || [[ "$output" == *"	hash"$'\n'* ]]
}

@test "names: two directories sharing a name fail loudly with both named" {
  git init -q "$WORK"
  mkdir -p "$HOME/code/twin"
  git init -q "$HOME/code/twin"
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/some-project.name AmberLake
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/twin.name AmberLake
  run "$PB" names
  [ "$status" -eq 1 ]
  [[ "$output" == *"COLLISION: AmberLake is ~/code/some-project and ~/code/twin"* ]]
  [[ "$output" == *"pin one of them"* ]]
}

@test "names: roots come from routes.root when no argument is given" {
  mkdir -p "$HOME/elsewhere/thing"
  git init -q "$HOME/elsewhere/thing"
  git config --file "$GIT_CONFIG_GLOBAL" routes.root '~/elsewhere'
  run "$PB" names
  [ "$status" -eq 0 ]
  [[ "$output" == *"~/elsewhere/thing	"* ]]
  [[ "$output" != *"some-project"* ]]
}

# --- daemon -------------------------------------------------------------------

@test "install: with the pinned version already present, writes the plist and bootstraps it" {
  run "$PB" install
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* ]]
  plist="$HOME/Library/LaunchAgents/local.postbox.plist"
  [ -f "$plist" ]
  grep -q '<string>local.postbox</string>' "$plist"
  grep -q '<string>serve-http</string>' "$plist"
  grep -q '<string>--no-tui</string>' "$plist"
  grep -q '<string>--no-auth</string>' "$plist"
  grep -q '<string>127.0.0.1</string>' "$plist"
  grep -q '<key>STORAGE_ROOT</key>' "$plist"
  grep -q "<string>$POSTBOX_STATE/archive</string>" "$plist"
  grep -q '<key>APP_ENVIRONMENT</key>' "$plist"
  grep -q '<string>production</string>' "$plist"
  grep -q '<key>HTTP_CORS_ENABLED</key>' "$plist"
  grep -q '<key>HTTP_ALLOW_LOCALHOST_UNAUTHENTICATED</key>' "$plist"
  grep -q '<key>KeepAlive</key>' "$plist"
  # launchd's default of 256 open files was exhausted within an hour.
  grep -A2 '<key>SoftResourceLimits</key>' "$plist" | grep -q '<key>NumberOfFiles</key>'
  grep -A3 '<key>SoftResourceLimits</key>' "$plist" | grep -q '<integer>4096</integer>'
  grep -q "bootstrap gui/$(id -u) $plist" "$LAUNCHCTL_LOG"
  [ -d "$POSTBOX_STATE/archive" ]
  [ -d "$POSTBOX_STATE/logs" ]
}

@test "install: never a bearer token in the plist, and CORS off" {
  run "$PB" install
  plist="$HOME/Library/LaunchAgents/local.postbox.plist"
  ! grep -q 'HTTP_BEARER_TOKEN' "$plist"
  grep -A1 '<key>HTTP_CORS_ENABLED</key>' "$plist" | grep -q '<string>false</string>'
}

@test "install: the port comes from postbox.port" {
  git config --file "$GIT_CONFIG_GLOBAL" postbox.port 9911
  run "$PB" install
  grep -q '<string>9911</string>' "$HOME/Library/LaunchAgents/local.postbox.plist"
  run "$PB" settings
  run "$PB" status
  [[ "$output" == *"http://127.0.0.1:9911/mcp/"* ]]
}

@test "install: on Linux writes a systemd user unit instead" {
  export FAKE_OS=Linux
  run "$PB" install
  [ "$status" -eq 0 ]
  unit="$HOME/.config/systemd/user/postbox.service"
  [ -f "$unit" ]
  grep -q '^ExecStart=.*serve-http --host 127.0.0.1 --port 8765 --no-tui --no-auth$' "$unit"
  grep -q '^Environment=APP_ENVIRONMENT=production$' "$unit"
  grep -q '^LimitNOFILE=4096$' "$unit"
  grep -q '^--user enable --now postbox$' "$SYSTEMCTL_LOG"
  [ ! -f "$HOME/Library/LaunchAgents/local.postbox.plist" ]
}

@test "install: a release that fails to download installs nothing" {
  rm "$BIN/am"
  cat > "$BIN/minisign" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "$BIN/minisign"
  # curl "succeeds" but writes no file, so the signature step has nothing to
  # verify and must refuse — nothing may land in the bin dir.
  cat > "$BIN/curl" <<'STUB'
#!/bin/sh
exit 22
STUB
  chmod +x "$BIN/curl"
  run "$PB" install
  [ "$status" -eq 1 ]
  [[ "$output" == *"download failed"* ]]
  [ ! -e "$POSTBOX_BIN/am" ]
  [ ! -f "$HOME/Library/LaunchAgents/local.postbox.plist" ]
}

@test "install: a signature that does not verify installs nothing" {
  rm "$BIN/am"
  cat > "$BIN/minisign" <<'STUB'
#!/bin/sh
exit 1
STUB
  cat > "$BIN/curl" <<'STUB'
#!/bin/sh
# -o <file> <url>: write something so the files exist
while [ $# -gt 0 ]; do [ "$1" = -o ] && { : > "$2"; }; shift; done
exit 0
STUB
  chmod +x "$BIN/minisign" "$BIN/curl"
  run "$PB" install
  [ "$status" -eq 1 ]
  [[ "$output" == *"signature did not verify"* ]]
  [ ! -e "$POSTBOX_BIN/am" ]
}

@test "install: refuses without minisign rather than skipping verification" {
  rm "$BIN/am"
  run env PATH="$BIN:/usr/bin:/bin" "$PB" install
  [ "$status" -eq 1 ]
  [[ "$output" == *"minisign not found"* ]]
}

@test "uninstall: removes the job and keeps the mail unless --purge" {
  run "$PB" install
  run "$PB" uninstall
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/Library/LaunchAgents/local.postbox.plist" ]
  grep -q "bootout gui/$(id -u)/local.postbox" "$LAUNCHCTL_LOG"
  [ -d "$POSTBOX_STATE/archive" ]
  run "$PB" uninstall --purge
  [ ! -d "$POSTBOX_STATE" ]
}

@test "status: reports binary, daemon, http, project, profiles and names" {
  export FAKE_HTTP=405
  run "$PB" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"binary:  $POSTBOX_AM (am 0.3.36)"* ]]
  [[ "$output" == *"daemon:  local.postbox not loaded"* ]]
  [[ "$output" == *"http:    http://127.0.0.1:8765/mcp/ answering"* ]]
  [[ "$output" == *"project: $HOME/code"* ]]
  [[ "$output" == *"names:   "* ]]
  [[ "$output" == *"name:    "*" (hash) for $WORK"* ]]
}

@test "status: works before install — no state directory yet — and counts the repos" {
  git init -q "$WORK"
  [ ! -d "$POSTBOX_STATE" ]
  run "$PB" status
  [ "$status" -eq 0 ]
  [[ "$output" != *"No such file"* ]]
  [[ "$output" == *"names:   1 repos, no two share a name"* ]]
}

@test "status: a daemon that does not answer is called out" {
  export FAKE_HTTP=000
  run "$PB" status
  [[ "$output" == *"NOT answering"* ]]
}

@test "status: an installed version other than the pinned one is a nudge to re-check the vocabulary" {
  cat > "$BIN/am" <<'STUB'
#!/bin/sh
[ "$1" = --version ] && printf 'am 0.9.0\n'
STUB
  run "$PB" status
  [[ "$output" == *"am 0.9.0; this script pins 0.3.36"* ]]
}

# --- profiles -----------------------------------------------------------------

@test "connect: adds the http server to every mapped profile that lacks it, via claude mcp" {
  mkdir -p "$HOME/.claude" "$HOME/.claude-other"
  printf '{"mcpServers":{"postbox":{"type":"http"}}}' > "$HOME/.claude-other/.claude.json"
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.other '~/.claude-other'
  run "$PB" connect
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/.claude-other: already connected"* ]]
  [[ "$output" == *"$HOME/.claude: connected"* ]]
  [ "$(wc -l < "$CLAUDE_LOG" | tr -d ' ')" -eq 1 ]
  # The default directory is addressed with CLAUDE_CONFIG_DIR *unset* — the
  # stub prints "unset" for that — because that is how Claude Code reads
  # ~/.claude.json; setting it to ~/.claude would write a file nothing reads.
  grep -q "^unset	mcp add --scope user --transport http postbox http://127.0.0.1:8765/mcp/$" "$CLAUDE_LOG"
}

@test "connect: the default profile's config is ~/.claude.json, not ~/.claude/.claude.json" {
  mkdir -p "$HOME/.claude"
  printf '{"mcpServers":{"postbox":{"type":"http"}}}' > "$HOME/.claude/.claude.json"
  run "$PB" connect
  [[ "$output" == *"$HOME/.claude: connected"* ]]
  printf '{"mcpServers":{"postbox":{"type":"http"}}}' > "$HOME/.claude.json"
  run "$PB" connect
  [[ "$output" == *"$HOME/.claude: already connected"* ]]
}

@test "status: names the profiles that are not connected" {
  mkdir -p "$HOME/.claude"
  run "$PB" status
  [[ "$output" == *"profile: $HOME/.claude NOT connected (postbox connect)"* ]]
}

# --- hooks --------------------------------------------------------------------

@test "hook start: names the agent, the project, the native-first rule, and unread mail" {
  export CLAUDE_CONFIG_DIR="$HOME/.claude-other"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/some-project.name RedStone
  export FAKE_INBOX='{"agent":"RedStone","unread_count":2,"messages":[{"id":7,"subject":"hello","from":"BlueLake"},{"id":6,"subject":"Contact approved: BlueLake -> RedStone","from":"BlueLake"}]}'
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook start
  [ "$status" -eq 0 ]
  [[ "$output" == *"this session is agent RedStone in project $HOME/code (program .claude-other, task code/some-project)"* ]]
  [[ "$output" == *"ListAgents"*"SendMessage"* ]]
  [[ "$output" == *"register_agent with exactly this name"* ]]
  [[ "$output" == *"1 unread message(s) — fetch_inbox as RedStone."* ]]
  [[ "$output" == *"BlueLake: hello"* ]]
  [[ "$output" != *"Contact approved"* ]]
  grep -q -- '--agent RedStone --project '"$HOME"'/code --host 127.0.0.1 --port 8765 --json --rate-limit 0' "$AM_LOG"
}

@test "hook start: with the daemon down, says so and still names the agent" {
  export FAKE_HTTP=000
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook start
  [ "$status" -eq 0 ]
  [[ "$output" == *"this session is agent "* ]]
  [[ "$output" == *"daemon is not answering"* ]]
}

@test "hook prompt: silent with no unread mail, lists it when there is" {
  export FAKE_INBOX='{"unread_count":0,"messages":[]}'
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  export FAKE_INBOX='{"unread_count":1,"messages":[{"id":3,"subject":"review please","from":"BlueLake"}]}'
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [[ "$output" == *"1 unread message(s) for "* ]]
  [[ "$output" == *"BlueLake: review please"* ]]
}

@test "hook stop: blocks once per new message, keyed by session, never twice" {
  export FAKE_INBOX='{"unread_count":1,"messages":[{"id":3,"subject":"review please","from":"BlueLake"}]}'
  run payload '{"cwd":"'"$WORK"'","session_id":"s1","stop_hook_active":false}' hook stop
  [ "$status" -eq 0 ]
  [[ "$output" == '{"decision": "block", "reason": "postbox: 1 new message(s) for '*'BlueLake: review please'*'fetch_inbox'*'}' ]]
  run payload '{"cwd":"'"$WORK"'","session_id":"s1","stop_hook_active":false}' hook stop
  [ -z "$output" ]
  # A newer message blocks again; another session is on its own clock.
  export FAKE_INBOX='{"unread_count":2,"messages":[{"id":4,"subject":"and this","from":"BlueLake"},{"id":3,"subject":"review please","from":"BlueLake"}]}'
  run payload '{"cwd":"'"$WORK"'","session_id":"s1","stop_hook_active":false}' hook stop
  [[ "$output" == *'"decision": "block"'* ]]
  run payload '{"cwd":"'"$WORK"'","session_id":"s2","stop_hook_active":false}' hook stop
  [[ "$output" == *'"decision": "block"'* ]]
}

@test "hook stop: never blocks inside a turn it already held (stop_hook_active)" {
  export FAKE_INBOX='{"unread_count":1,"messages":[{"id":3,"subject":"x","from":"BlueLake"}]}'
  run payload '{"cwd":"'"$WORK"'","session_id":"s1","stop_hook_active":true}' hook stop
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook stop: contact notices alone never hold a session" {
  export FAKE_INBOX='{"unread_count":1,"messages":[{"id":3,"subject":"Contact approved: A -> B","from":"BlueLake"}]}'
  run payload '{"cwd":"'"$WORK"'","session_id":"s1","stop_hook_active":false}' hook stop
  [ -z "$output" ]
}

@test "hook: a prompt after a start does not re-block the stop for mail already reported" {
  export FAKE_INBOX='{"unread_count":1,"messages":[{"id":3,"subject":"x","from":"BlueLake"}]}'
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook start
  run payload '{"cwd":"'"$WORK"'","session_id":"s1","stop_hook_active":false}' hook stop
  [ -z "$output" ]
}

@test "hook: an unknown event or an unparseable payload is silent" {
  run payload 'not json' hook start
  [ "$status" -eq 0 ]
  [[ "$output" == *"this session is agent"* ]]
  run payload '{}' hook nonsense
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- guard ----------------------------------------------------------------------

@test "guard: one recipient who is a live session in this profile is refused, with its native name" {
  export CLAUDE_CONFIG_DIR="$HOME/.claude-other"
  other="$HOME/code/other-project"
  mkdir -p "$other"
  live_session "$CLAUDE_CONFIG_DIR" "$other" "other-project-a1"
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/other-project.name GreenCastle
  run payload '{"tool_name":"mcp__postbox__send_message","tool_input":{"to":["GreenCastle"]},"cwd":"'"$WORK"'"}' guard
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
  [[ "$output" == *'"hookEventName": "PreToolUse"'* ]]
  [[ "$output" == *'GreenCastle is the session \"other-project-a1\" in this same profile'* ]]
  [[ "$output" == *"SendMessage"* ]]
}

@test "guard: the same recipient given as a cc or via reply_message is refused too" {
  export CLAUDE_CONFIG_DIR="$HOME/.claude-other"
  other="$HOME/code/other-project"
  mkdir -p "$other"
  live_session "$CLAUDE_CONFIG_DIR" "$other" "other-project-a1"
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/other-project.name GreenCastle
  run payload '{"tool_name":"mcp__postbox__reply_message","tool_input":{"cc":["GreenCastle"]},"cwd":"'"$WORK"'"}' guard
  [[ "$output" == *'"deny"'* ]]
}

@test "guard: two or more recipients go through" {
  export CLAUDE_CONFIG_DIR="$HOME/.claude-other"
  other="$HOME/code/other-project"
  mkdir -p "$other"
  live_session "$CLAUDE_CONFIG_DIR" "$other" "other-project-a1"
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/other-project.name GreenCastle
  run payload '{"tool_name":"mcp__postbox__send_message","tool_input":{"to":["GreenCastle","BlueLake"]},"cwd":"'"$WORK"'"}' guard
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run payload '{"tool_name":"mcp__postbox__send_message","tool_input":{"to":["GreenCastle"],"cc":["BlueLake"]},"cwd":"'"$WORK"'"}' guard
  [ -z "$output" ]
}

@test "guard: a recipient no live session of this profile owns goes through — that is the gap postbox fills" {
  export CLAUDE_CONFIG_DIR="$HOME/.claude-other"
  mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
  run payload '{"tool_name":"mcp__postbox__send_message","tool_input":{"to":["GreenCastle"]},"cwd":"'"$WORK"'"}' guard
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "guard: a session of another profile at that directory does not count as native" {
  export CLAUDE_CONFIG_DIR="$HOME/.claude-other"
  mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
  other="$HOME/code/other-project"
  mkdir -p "$other"
  live_session "$HOME/.claude-third" "$other" "other-project-a1"
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/other-project.name GreenCastle
  run payload '{"tool_name":"mcp__postbox__send_message","tool_input":{"to":["GreenCastle"]},"cwd":"'"$WORK"'"}' guard
  [ -z "$output" ]
}

@test "guard: a dead registry entry is not a live session" {
  export CLAUDE_CONFIG_DIR="$HOME/.claude-other"
  other="$HOME/code/other-project"
  mkdir -p "$other" "$CLAUDE_CONFIG_DIR/sessions"
  printf '{"pid":2147483000,"cwd":"%s","name":"gone"}\n' "$other" > "$CLAUDE_CONFIG_DIR/sessions/2147483000.json"
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/other-project.name GreenCastle
  run payload '{"tool_name":"mcp__postbox__send_message","tool_input":{"to":["GreenCastle"]},"cwd":"'"$WORK"'"}' guard
  [ -z "$output" ]
}

@test "guard: only the two sending tools are read; everything else is silent and free" {
  export CLAUDE_CONFIG_DIR="$HOME/.claude-other"
  live_session "$CLAUDE_CONFIG_DIR" "$HOME/code/other-project" "x"
  run payload '{"tool_name":"mcp__postbox__fetch_inbox","tool_input":{"to":["GreenCastle"]},"cwd":"'"$WORK"'"}' guard
  [ -z "$output" ]
  run payload '{"tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"'"$WORK"'"}' guard
  [ -z "$output" ]
  run payload 'garbage' guard
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- misc ---------------------------------------------------------------------

@test "settings: prints the four hook blocks with the PreToolUse matcher on the two sending tools" {
  run "$PB" settings
  [ "$status" -eq 0 ]
  [[ "$output" == *'"SessionStart"'*'postbox hook start'* ]]
  [[ "$output" == *'"UserPromptSubmit"'*'postbox hook prompt'* ]]
  [[ "$output" == *'"Stop"'*'postbox hook stop'* ]]
  [[ "$output" == *'"matcher": "mcp__postbox__send_message|mcp__postbox__reply_message"'* ]]
  [[ "$output" == *'postbox guard'* ]]
}

@test "usage: --help prints the usage block and an unknown command fails" {
  run "$PB" --help
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"postbox names"* ]]
  run "$PB" bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown command 'bogus'"* ]]
}

@test "dir: is the state directory" {
  run "$PB" dir
  [ "$output" = "$POSTBOX_STATE" ]
}

@test "vocabulary: counts match the declared sizes" {
  run sh -c 'eval "$(sed -n "/^ADJ=/,/^count_words/p" "$1" | sed "\$d")"; set -- $ADJ; a=$#; set -- $NOUN; printf "%s %s %s %s\n" "$a" "$ADJ_N" "$#" "$NOUN_N"' sh "$PB"
  [ "$status" -eq 0 ]
  read -r a an n nn <<< "$output"
  [ "$a" = "$an" ]
  [ "$n" = "$nn" ]
  [ "$a" = 75 ]
  [ "$n" = 132 ]
}
