#!/usr/bin/env bats

# bin/postbox is the local mailbox Claude Code sessions use to reach a
# session in another profile, or two at once. These tests drive the real
# script under a sandboxed HOME with stub am/curl/minisign/launchctl/claude
# binaries: no daemon is started, no release is downloaded, no launchd job is
# registered and no Claude Code config is touched. All names are fixtures —
# no real account, profile, or project name may appear (see CLAUDE.md); the
# agent names are the server's vocabulary, which names nothing.

setup() {
  # Pin python3 while HOME is still real: an asdf shim first on PATH finds no
  # version under the fake HOME and exits 126 instead of running.
  if py="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)"; then
    mkdir -p "$BATS_TEST_TMPDIR/pybin" && ln -s "$py" "$BATS_TEST_TMPDIR/pybin/python3"
    export PATH="$BATS_TEST_TMPDIR/pybin:$PATH"
  fi
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/code"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  # CI runners export XDG_CONFIG_HOME, which would move the systemd unit.
  unset CLAUDE_CONFIG_DIR XDG_STATE_HOME XDG_CONFIG_HOME CLAUDE_PROJECT_DIR CLAUDE_PID

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
  # claude: records the profile it was run as, its argv, and (for the
  # courier's relay, which hands the prompt over stdin) what it was told.
  cat > "$BIN/claude" <<'STUB'
#!/bin/sh
printf '%s\t%s\n' "${CLAUDE_CONFIG_DIR:-unset}" "$*" >> "$CLAUDE_LOG"
[ -t 0 ] || cat >> "$CLAUDE_LOG.stdin"
printf '\n' >> "$CLAUDE_LOG.stdin"
exit 0
STUB
  cat > "$BIN/uname" <<'STUB'
#!/bin/sh
case $1 in -s) printf '%s\n' "${FAKE_OS:-Darwin}" ;; -m) printf 'arm64\n' ;; *) printf 'Darwin\n' ;; esac
STUB
  chmod +x "$BIN"/*
  export FAKE_OS=Darwin
  export PATH="$BIN:$PATH"

  SOCKDIR=$(mktemp -d /tmp/pb.XXXXXX)
  WORK="$HOME/code/some-project"
  mkdir -p "$WORK"
  cd "$WORK" || return 1
}

teardown() {
  cd / || true
  [ -z "${SLEEPERS:-}" ] || kill $SLEEPERS 2>/dev/null || true
  rm -rf "${SOCKDIR:-}"
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

@test "names: a root that is itself a repository is listed and not descended into" {
  git init -q "$WORK"
  mkdir -p "$WORK/sub"
  git init -q "$WORK/sub"
  run "$PB" names "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == "~/code/some-project	"* ]]
  [[ "$output" != *"sub"* ]]
}

@test "names: node_modules is skipped at both levels" {
  mkdir -p "$HOME/code/node_modules/pkg" "$HOME/code/outer/node_modules"
  git init -q "$HOME/code/node_modules/pkg"
  git init -q "$HOME/code/outer/node_modules"
  git init -q "$HOME/code/outer/kept"
  run "$PB" names
  [ "$status" -eq 0 ]
  [[ "$output" == *"~/code/outer/kept	"* ]]
  [[ "$output" != *"node_modules"* ]]
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
  ! grep -q 'HTTP_BEARER_TOKEN' "$plist" || { echo "the plist carries HTTP_BEARER_TOKEN"; false; }
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

@test "install: waits for bootout to finish before bootstrapping again" {
  # launchd keeps the old job for a moment after bootout returns; a
  # bootstrap in that window fails with error 5 and leaves nothing loaded.
  echo 3 > "$BATS_TEST_TMPDIR/still-loaded"
  cat > "$BIN/launchctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"
f="$BATS_TEST_TMPDIR/still-loaded"
if [ "$1" = print ]; then
  n=$(cat "$f"); [ "$n" -gt 0 ] || exit 1
  echo $((n - 1)) > "$f"; exit 0
fi
exit 0
STUB
  run "$PB" install
  [ "$status" -eq 0 ]
  # bootout, three prints that still see the job, the one that does not, then bootstrap.
  [ "$(grep -o '^[a-z]*' "$LAUNCHCTL_LOG" | tr '\n' ' ')" = "bootout print print print print bootstrap kickstart " ]
}

@test "stop: boots the job out so KeepAlive cannot undo it, and never sends a kill" {
  mkdir -p "$HOME/Library/LaunchAgents"
  : > "$HOME/Library/LaunchAgents/local.postbox.plist"
  run "$PB" stop
  [ "$status" -eq 0 ]
  grep -q "^bootout gui/[0-9]*/local.postbox" "$LAUNCHCTL_LOG" || { echo "no bootout in: $(cat "$LAUNCHCTL_LOG")"; false; }
  ! grep -q '^kill' "$LAUNCHCTL_LOG" || { echo "stop sent a kill: $(cat "$LAUNCHCTL_LOG")"; false; }
  [[ "$output" == *"postbox start"* ]]
}

@test "start: bootstraps an installed plist that is not loaded, kickstarts one that is" {
  mkdir -p "$HOME/Library/LaunchAgents"
  : > "$HOME/Library/LaunchAgents/local.postbox.plist"
  run "$PB" start
  [ "$status" -eq 0 ]
  grep -q '^bootstrap ' "$LAUNCHCTL_LOG" || { echo "no bootstrap in: $(cat "$LAUNCHCTL_LOG")"; false; }
  ! grep -q '^kickstart' "$LAUNCHCTL_LOG" || { echo "kickstart on an unloaded job: $(cat "$LAUNCHCTL_LOG")"; false; }
  : > "$LAUNCHCTL_LOG"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$LAUNCHCTL_LOG"\nexit 0\n' > "$BIN/launchctl"
  run "$PB" start
  [ "$status" -eq 0 ]
  grep -q '^kickstart ' "$LAUNCHCTL_LOG" || { echo "no kickstart in: $(cat "$LAUNCHCTL_LOG")"; false; }
  ! grep -q '^bootstrap' "$LAUNCHCTL_LOG" || { echo "bootstrap on a loaded job: $(cat "$LAUNCHCTL_LOG")"; false; }
}

@test "stop: nothing installed is an error, as on systemd" {
  run "$PB" stop
  [ "$status" -eq 1 ]
  [[ "$output" == *"not installed"* ]]
  ! grep -q '^bootout' "$LAUNCHCTL_LOG" || { echo "bootout with no plist: $(cat "$LAUNCHCTL_LOG")"; false; }
}

@test "status: a stopped job (plist kept, not loaded) points at start, a missing plist at install" {
  printf '#!/bin/sh\n[ "$1" = print ] && exit 1\nexit 0\n' > "$BIN/launchctl"
  run "$PB" status
  [[ "$output" == *"not loaded (postbox install)"* ]]
  mkdir -p "$HOME/Library/LaunchAgents"
  : > "$HOME/Library/LaunchAgents/local.postbox.plist"
  run "$PB" status
  [[ "$output" == *"not loaded (postbox start)"* ]]
}

@test "start: neither loaded nor installed is an error" {
  run "$PB" start
  [ "$status" -eq 1 ]
  [[ "$output" == *"not installed"* ]]
}

@test "status: open files against the installed plist's limit, and a stale plist is named" {
  cat > "$BIN/launchctl" <<'STUB'
#!/bin/sh
[ "$1" = print ] && printf '\tpid = 4242\n'
exit 0
STUB
  cat > "$BIN/lsof" <<'STUB'
#!/bin/sh
echo HEADER; i=0; while [ $i -lt "$FAKE_FDS" ]; do echo fd; i=$((i + 1)); done
STUB
  chmod +x "$BIN/launchctl" "$BIN/lsof"
  "$PB" install >/dev/null
  FAKE_FDS=40 run "$PB" status
  [[ "$output" == *"files:   40 open of 4096"$'\n'* ]]
  FAKE_FDS=3300 run "$PB" status
  [[ "$output" == *"files:   3300 open of 4096 — WARNING: over 80%; postbox restart"* ]]
  # A plist written before the limit existed runs on launchd's default.
  sed -i.bak '/ResourceLimits/,/<\/dict>/d' "$HOME/Library/LaunchAgents/local.postbox.plist"
  FAKE_FDS=261 run "$PB" status
  [[ "$output" == *"files:   261 open of 256 (launchd default: the installed plist predates the limit — postbox install) — WARNING"* ]]
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

# --- leader check: native inbox, connection, Claude Peers roll-call -------------

# A real unix socket (a path that is a socket is all the check reads). Short
# path: a socket path is capped near 104 bytes on macOS.
mksock() { # name -> path
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$SOCKDIR/$1"
  printf '%s\n' "$SOCKDIR/$1"
}

# A live registry record (bats' own pid) in profile dir $1 for cwd $2, named $3,
# with inbox socket path $4 (may be empty).
reg() {
  mkdir -p "$1/sessions"
  printf '{"pid":%s,"cwd":"%s","name":"%s","status":"idle","messagingSocketPath":"%s"}\n' "$$" "$2" "$3" "$4" > "$1/sessions/$3.json"
}

# claude-peer stub: logs its arguments. `peers --leader <d>` prints $FAKE_CLAIMS
# (only for <d> = $FAKE_LEADER when that is set: the real match is exact);
# `peers <dir>` prints $FAKE_LIVE, else $FAKE_CLAIMS; `log show --all` prints
# the file $FAKE_LOG.
peer_stub() {
  cat > "$BIN/claude-peer" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$PEER_LOG"
printf '%s\n' "$PWD" >> "$PEER_LOG.pwd"
case $1 in
  peers)
    if [ "${2-}" = --leader ]; then
      [ -z "${FAKE_LEADER:-}" ] || [ "$3" = "$FAKE_LEADER" ] || exit 0
      c=${FAKE_CLAIMS:-}
    else c=${FAKE_LIVE-${FAKE_CLAIMS:-}}; fi
    [ -z "$c" ] || printf '%s\n' "$c" ;;
  log) [ ! -f "${FAKE_LOG:-/nonexistent}" ] || cat "$FAKE_LOG" ;;
  name) [ "$2" = lead ] && echo proj-lead ;;
  claim) [ -z "${FAKE_CLAIM:-}" ] || printf '%b\n' "$FAKE_CLAIM" ;;
esac
STUB
  chmod +x "$BIN/claude-peer"
  export PEER_LOG="$BATS_TEST_TMPDIR/peer.log" POSTBOX_CLAUDE_PEER="$BIN/claude-peer"
}

leader_profile() {
  export CLAUDE_CONFIG_DIR="$HOME/.claude-a"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf '{"mcpServers":{"postbox":{"type":"http"}}}' > "$CLAUDE_CONFIG_DIR/.claude.json"
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.a '~/.claude-a'
}

# One `claude-peer peers` row: worktree, pid ($2, default 4242), leader, label.
claim_line() { printf '%s\t%s\t%s\t%s\n' "$1" "${2:-4242}" "$WORK" "${1##*/}"; }

@test "hook prompt: the up line says who started the peer, from its claim's by field" {
  leader_profile; peer_stub
  wt="$HOME/code/alpha"; mkdir -p "$wt"
  reg "$CLAUDE_CONFIG_DIR" "$wt" PeerA "$(mksock a.sock)"
  export FAKE_CLAIMS="$(claim_line "$wt")"
  FAKE_CLAIM="by\tpane" run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ "$output" = "postbox: Claude Peers: PeerA (alpha; started by the operator) is up; SendMessage reaches it." ]
  FAKE_CLAIM="by\tLead" run payload '{"cwd":"'"$WORK"'","session_id":"s2"}' hook prompt
  [ "$output" = "postbox: Claude Peers: PeerA (alpha; started by Lead) is up; SendMessage reaches it." ]
  FAKE_CLAIM="by\t-" run payload '{"cwd":"'"$WORK"'","session_id":"s3"}' hook prompt
  [ "$output" = "postbox: Claude Peers: PeerA (alpha; started by the operator) is up; SendMessage reaches it." ]
}

@test "hook start: a non-peer without a native inbox socket is told, and told to tell the operator" {
  leader_profile
  unset CLAUDE_CODE_MESSAGING_SOCKET
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook start
  [[ "$output" == *"This session has no native inbox"* ]]
  [[ "$output" == *"Tell the operator before starting work."* ]]
  [[ "$output" != *"not connected in this profile"* ]]
}

@test "hook start: a healthy non-peer start adds nothing" {
  leader_profile
  export CLAUDE_CODE_MESSAGING_SOCKET
  CLAUDE_CODE_MESSAGING_SOCKET=$(mksock own.sock)
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook start
  [[ "$output" != *"no native inbox"* ]]
  [[ "$output" != *"not connected"* ]]
  [[ "$output" != *"Tell the operator"* ]]
}

@test "hook start: a profile that lacks the server is told so" {
  leader_profile
  rm "$CLAUDE_CONFIG_DIR/.claude.json"
  export CLAUDE_CODE_MESSAGING_SOCKET
  CLAUDE_CODE_MESSAGING_SOCKET=$(mksock own.sock)
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook start
  [[ "$output" == *"The postbox MCP server is not connected in this profile"* ]]
  [[ "$output" == *"Tell the operator before starting work."* ]]
  [[ "$output" != *"no native inbox"* ]]
}

@test "hook start: a peer gets none of the added sentences; a stray variable elsewhere does not make a peer" {
  unset CLAUDE_CODE_MESSAGING_SOCKET
  export CLAUDE_CONFIG_DIR="$HOME/.claude-a"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  export CLAUDE_PEER_WORKTREE="$WORK"
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook start
  [[ "$output" == *"this session is agent "* ]]
  [[ "$output" != *"no native inbox"* ]]
  [[ "$output" != *"not connected"* ]]
  [[ "$output" != *"Tell the operator"* ]]
  mkdir -p "$WORK/sub"
  run payload '{"cwd":"'"$WORK"'/sub","session_id":"s1"}' hook start
  [[ "$output" != *"no native inbox"* ]]
  export CLAUDE_PEER_WORKTREE="$HOME/code/elsewhere"
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook start
  [[ "$output" == *"no native inbox"* ]]
}

@test "hook prompt: a leader whose three peers all have an inbox is told once, by name" {
  leader_profile; peer_stub
  claims=''
  for i in alpha beta gamma; do
    wt="$HOME/code/$i"; mkdir -p "$wt"
    reg "$CLAUDE_CONFIG_DIR" "$wt" "Peer-$i" "$(mksock "$i.sock")"
    claims="$claims$(claim_line "$wt")"$'\n'
  done
  export FAKE_CLAIMS="${claims%$'\n'}" POSTBOX_NOW=1000
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ "$status" -eq 0 ]
  [[ "$output" == "postbox: Claude Peers: Peer-alpha (alpha), Peer-beta (beta), Peer-gamma (gamma) are up; SendMessage reaches them." ]]
  grep -q -- "peers --leader $WORK" "$PEER_LOG"
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ -z "$output" ]
  [ "$(awk -F'\t' 'NF == 4 && $4 == "told"' "$POSTBOX_STATE/rollcall/s1" | wc -l | tr -d ' ')" -eq 3 ]
}

@test "hook prompt: a peer that appears at the fifth prompt is announced then, and no python3 starts before" {
  leader_profile; peer_stub
  real=$(command -v python3)
  printf '#!/bin/sh\n[ -z "${ROLLCALL_OTHERS+x}" ] || echo rollcall >> "%s"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR/py.log" "$real" > "$BIN/python3"
  chmod +x "$BIN/python3"
  wt="$HOME/code/alpha"; mkdir -p "$wt"
  reg "$CLAUDE_CONFIG_DIR" "$wt" PeerA "$(mksock a.sock)"
  export POSTBOX_NOW=1000
  for _ in 1 2 3 4; do
    run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
    [ -z "$output" ]
  done
  [ ! -e "$POSTBOX_STATE/rollcall/s1" ]
  [ ! -e "$BATS_TEST_TMPDIR/py.log" ]
  export FAKE_CLAIMS="$(claim_line "$wt")"
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ "$output" = "postbox: Claude Peers: PeerA (alpha) is up; SendMessage reaches it." ]
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ -z "$output" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/py.log" | tr -d ' ')" -eq 1 ]
}

@test "hook prompt: a claim that vanishes is reported once, and not again" {
  leader_profile; peer_stub
  wt="$HOME/code/alpha"; mkdir -p "$wt"
  reg "$CLAUDE_CONFIG_DIR" "$wt" PeerA "$(mksock a.sock)"
  export FAKE_CLAIMS="$(claim_line "$wt")" POSTBOX_NOW=1000
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [[ "$output" == *"PeerA (alpha) is up"* ]]
  export FAKE_CLAIMS=''
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ "$output" = "postbox: Claude Peers: alpha has stopped." ]
  [ ! -s "$POSTBOX_STATE/rollcall/s1" ]
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ -z "$output" ]
}

@test "hook prompt: a restarted peer (same worktree, new pid) is announced again" {
  leader_profile; peer_stub
  wt="$HOME/code/alpha"; mkdir -p "$wt"
  reg "$CLAUDE_CONFIG_DIR" "$wt" PeerA "$(mksock a.sock)"
  export FAKE_CLAIMS="$(claim_line "$wt" 4242)" POSTBOX_NOW=1000
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [[ "$output" == *"PeerA (alpha) is up"* ]]
  export FAKE_CLAIMS="$(claim_line "$wt" 4343)"
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ "$output" = "postbox: Claude Peers: PeerA (alpha) is up; SendMessage reaches it." ]
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ -z "$output" ]
}

@test "hook prompt: a peer with no registry record yet is waited for 60 seconds from its own first sighting" {
  leader_profile; peer_stub
  wt="$HOME/code/alpha"; mkdir -p "$wt"
  POSTBOX_NOW=1000 run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ -z "$output" ]
  # The session is old; the claim is new.
  export FAKE_CLAIMS="$(claim_line "$wt")"
  POSTBOX_NOW=5000 run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ -z "$output" ]
  POSTBOX_NOW=5010 run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ -z "$output" ]
  [ "$(cat "$POSTBOX_STATE/rollcall/s1")" = "$(printf '%s\t4242\t5000\tpending' "$wt")" ]
  POSTBOX_NOW=5061 run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [[ "$output" == *"Claude Peers check: 0 of 1 reachable natively"* ]]
  [[ "$output" == *"alpha — its shell is up but no Claude session is registered"* ]]
  [[ "$output" == *"Tell the operator once and carry on; do not work around it."* ]]
  [ "$(cat "$POSTBOX_STATE/rollcall/s1")" = "$(printf '%s\t4242\t5000\ttold' "$wt")" ]
  POSTBOX_NOW=5100 run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ -z "$output" ]
}

@test "hook prompt: a session with no inbox socket, and one under another profile, are told apart" {
  leader_profile; peer_stub
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.b '~/.claude-b'
  mkdir -p "$HOME/.claude-b"
  w1="$HOME/code/alpha"; w2="$HOME/code/beta"; w3="$HOME/code/gamma"; mkdir -p "$w1" "$w2" "$w3"
  reg "$CLAUDE_CONFIG_DIR" "$w1" Peer1 ""
  reg "$HOME/.claude-b" "$w2" Peer2 "$(mksock b.sock)"
  reg "$CLAUDE_CONFIG_DIR" "$w3" Peer3 "$(mksock c.sock)"
  export FAKE_CLAIMS="$(claim_line "$w1")"$'\n'"$(claim_line "$w2")"$'\n'"$(claim_line "$w3")" POSTBOX_NOW=1000
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [[ "$output" == *"1 of 3 reachable natively (Peer3 (gamma))"* ]]
  [[ "$output" == *"alpha — its Claude session has no inbox socket (/status there)"* ]]
  [[ "$output" == *"beta — it runs under another profile (.claude-b): reach it by postbox mail as $("$PB" name "$w2")"* ]]
  [[ "$output" != *"no Claude session is registered"* ]]
}

@test "hook prompt: a legacy state file does not suppress a new peer" {
  leader_profile; peer_stub
  wt="$HOME/code/alpha"; mkdir -p "$wt"
  reg "$CLAUDE_CONFIG_DIR" "$wt" PeerA "$(mksock a.sock)"
  mkdir -p "$POSTBOX_STATE/rollcall"
  printf 'done\n' > "$POSTBOX_STATE/rollcall/s1"
  export FAKE_CLAIMS="$(claim_line "$wt")" POSTBOX_NOW=1000
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ "$output" = "postbox: Claude Peers: PeerA (alpha) is up; SendMessage reaches it." ]
}

@test "hook prompt: a peer never runs the roll-call" {
  leader_profile; peer_stub
  export CLAUDE_PEER_WORKTREE="$WORK" FAKE_CLAIMS="$(claim_line "$HOME/code/alpha")"
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ -z "$output" ]
  [ ! -e "$PEER_LOG" ]
  [ ! -e "$POSTBOX_STATE/rollcall/s1" ]
}

@test "hook prompt: without a claude-peer executable the roll-call is skipped and mail is still listed" {
  leader_profile
  export POSTBOX_CLAUDE_PEER="$BATS_TEST_TMPDIR/nope"
  export FAKE_INBOX='{"unread_count":1,"messages":[{"id":3,"subject":"review please","from":"BlueLake"}]}'
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [[ "$output" == "postbox: 1 unread message(s) for "* ]]
  [[ "$output" != *"Claude Peers"* ]]
}

@test "hook prompt: the roll-call line and unread mail arrive together" {
  leader_profile; peer_stub
  wt="$HOME/code/alpha"; mkdir -p "$wt"
  reg "$CLAUDE_CONFIG_DIR" "$wt" Peer1 "$(mksock p1.sock)"
  export FAKE_CLAIMS="$(claim_line "$wt")" POSTBOX_NOW=1000
  export FAKE_INBOX='{"unread_count":1,"messages":[{"id":3,"subject":"review please","from":"BlueLake"}]}'
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [[ "$output" == *"Claude Peers: Peer1 (alpha) is up"* ]]
  [[ "$output" == *"1 unread message(s) for "* ]]
  [[ "$output" == *"BlueLake: review please"* ]]
}

@test "hook prompt: a prompt from a subdirectory of the leader announces nothing, stops nothing" {
  leader_profile; peer_stub
  wt="$HOME/code/alpha"; mkdir -p "$wt" "$WORK/sub"
  reg "$CLAUDE_CONFIG_DIR" "$wt" PeerA "$(mksock a.sock)"
  export FAKE_CLAIMS="$(claim_line "$wt")" FAKE_LEADER="$WORK" POSTBOX_NOW=1000 CLAUDE_PROJECT_DIR="$WORK"
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ "$output" = "postbox: Claude Peers: PeerA (alpha) is up; SendMessage reaches it." ]
  run payload '{"cwd":"'"$WORK"'/sub","session_id":"s1"}' hook prompt
  [ -z "$output" ]
  grep -q -- "peers --leader $WORK\$" "$PEER_LOG"
  ! grep -q -- "--leader $WORK/sub" "$PEER_LOG" || { echo "the roll-call asked for the subdirectory's peers"; false; }
}

@test "hook prompt: without CLAUDE_PROJECT_DIR the worktree's own claim keeps a live peer from being reported stopped" {
  leader_profile; peer_stub
  wt="$HOME/code/alpha"; mkdir -p "$wt" "$WORK/sub"
  reg "$CLAUDE_CONFIG_DIR" "$wt" PeerA "$(mksock a.sock)"
  export FAKE_CLAIMS="$(claim_line "$wt")" FAKE_LEADER="$WORK" POSTBOX_NOW=1000
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [[ "$output" == *"PeerA (alpha) is up"* ]]
  run payload '{"cwd":"'"$WORK"'/sub","session_id":"s1"}' hook prompt
  [ -z "$output" ]
  grep -q -- "^peers $wt\$" "$PEER_LOG"
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ -z "$output" ]
  # Really gone (its pid dead: no claim anywhere): reported once.
  export FAKE_CLAIMS=''
  run payload '{"cwd":"'"$WORK"'/sub","session_id":"s1"}' hook prompt
  [ "$output" = "postbox: Claude Peers: alpha has stopped." ]
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ -z "$output" ]
}

@test "hook prompt: from a subdirectory, the inbox checked is the start directory's agent" {
  mkdir -p "$WORK/sub"
  export CLAUDE_PROJECT_DIR="$WORK"
  run payload '{"cwd":"'"$WORK"'/sub","session_id":"s1"}' hook prompt
  top=$("$PB" name "$WORK"); sub=$("$PB" name "$WORK/sub")
  [ "$top" != "$sub" ]
  grep -q -- "check-inbox --agent $top " "$AM_LOG"
  ! grep -q -- "--agent $sub " "$AM_LOG" || { echo "the inbox checked was the subdirectory's agent"; false; }
}

# The claude-peer log, as `log show --all` prints it.
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
logl() { printf '%s\t%s\t%s\t%s\n' "$(iso "$1")" "$2" "$3" "${4-}" >> "$FAKE_LOG"; }

# A leader with one live peer, alpha, already announced.
news_leader() {
  leader_profile; peer_stub
  wt="$HOME/code/alpha"; mkdir -p "$wt"
  reg "$CLAUDE_CONFIG_DIR" "$wt" PeerA "$(mksock a.sock)"
  export FAKE_CLAIMS="$(claim_line "$wt")" FAKE_LOG="$BATS_TEST_TMPDIR/peer-log" POSTBOX_NOW=1800000000
  : > "$FAKE_LOG"
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [[ "$output" == *"PeerA (alpha) is up"* ]]
}

@test "hook prompt: a tab's claim, note and done are relayed once each, in their own words" {
  news_leader
  logl 1799999000 Alpha claim "build T3"
  logl 1799999100 Alpha note "halfway"
  logl 1799999200 Alpha done "DONE: abc123"
  logl 1799999300 Beta done ""
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ "$output" = "postbox: Claude Peers: Alpha claimed: build T3
postbox: Claude Peers: Alpha noted: halfway
postbox: Claude Peers: Alpha done: DONE: abc123
postbox: Claude Peers: Beta done." ]
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ -z "$output" ]
  [ "$(cat "$POSTBOX_STATE/rollcall/log/$(printf '%s' "$(cd "$WORK" && pwd -P)" | tr -c 'A-Za-z0-9._-' '_')")" = 4 ]
}

@test "hook prompt: an end or gone line replaces the bare stopped line; idle is relayed as written" {
  news_leader
  logl 1799999000 Beta idle "Beta has been idle for 12m"
  logl 1799999100 Alpha end "Alpha ended after 3h (build T3)"
  export FAKE_CLAIMS=''
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ "$output" = "postbox: Claude Peers: Beta has been idle for 12m
postbox: Claude Peers: Alpha ended after 3h (build T3)" ]
  news_leader
  logl 1799999200 Alpha gone "Alpha's pane is gone"
  export FAKE_CLAIMS=''
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ "$output" = "postbox: Claude Peers: Alpha's pane is gone" ]
}

@test "hook prompt: Lead's own lines and the leader directory's are not echoed back; other kinds are not relayed" {
  news_leader
  logl 1799999000 Lead claim "build peer contexts"
  logl 1799999000 "${WORK##*/}" note "from the leader"
  logl 1799999000 Lead start "Alpha by Lead"
  logl 1799999000 Lead stop "Alpha by Lead"
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ -z "$output" ]
}

@test "hook prompt: six new lines print five and a count of the rest" {
  news_leader
  for i in 1 2 3 4 5 6; do logl 1799999000 Alpha note "n$i"; done
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ "${#lines[@]}" -eq 6 ]
  [ "${lines[4]}" = "postbox: Claude Peers: Alpha noted: n5" ]
  [ "${lines[5]}" = "postbox: Claude Peers: 1 more in claude-peer log show --all" ]
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ -z "$output" ]
}

@test "hook prompt: with no counter an hour-old line is relayed; a line two days old never is" {
  news_leader
  rm -rf "$POSTBOX_STATE/rollcall/log"
  logl $((1800000000 - 2 * 86400)) Alpha note "ancient"
  logl $((1800000000 - 3600)) Alpha note "an hour ago"
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ "$output" = "postbox: Claude Peers: Alpha noted: an hour ago" ]
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
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

# --- courier ------------------------------------------------------------------

# A live session $3 (registry name) of profile $1 in directory $2 with
# status $4. Pid is bats' own so it counts as alive.
live_session_at() {
  mkdir -p "$1/sessions" "$2"
  printf '{"pid":%s,"cwd":"%s","name":"%s","status":"%s"}\n' "$$" "$2" "$3" "$4" > "$1/sessions/$$-$3.json"
}

# The relay is detached, so give it a moment to land in the stub's log.
wait_relays() { # expected-count
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ "$(grep -c . "$CLAUDE_LOG" 2>/dev/null || echo 0)" -ge "$1" ] && return 0
    sleep 0.25
  done
  return 1
}

SEND='{"tool_name":"mcp__postbox__send_message","tool_input":{"to":["GreenCastle"],"subject":"asked subject"},"tool_response":{"deliveries":[{"payload":{"id":9,"to":["GreenCastle"],"cc":[],"bcc":[],"subject":"please review the plan","from":"RedStone"}}],"count":1}}'

@test "courier: wakes the recipient's idle session in another profile with one native SendMessage from a relay run as that profile" {
  export CLAUDE_CONFIG_DIR="$HOME/.claude-mine"
  mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.other '~/.claude-other'
  other="$HOME/code/other-project"
  live_session_at "$HOME/.claude-other" "$other" "other-project-x9" idle
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/other-project.name GreenCastle
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/some-project.name RedStone
  run payload "{\"cwd\":\"$WORK\",${SEND#\{}" courier
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  wait_relays 1
  # Run as the recipient's profile, headless, MCP excluded, only SendMessage allowed.
  grep -q "^$HOME/.claude-other	-p --output-format text --max-turns 3 --model haiku --permission-mode auto --strict-mcp-config --tools SendMessage --allowedTools SendMessage$" "$CLAUDE_LOG"
  # Told to message that session about who sent mail to whom, never what the
  # sender wrote: neither the response's subject nor the request's.
  grep -q 'SendMessage tool (not any MCP tool) exactly once: to="other-project-x9"' "$CLAUDE_LOG.stdin"
  grep -q "new mail for GreenCastle from RedStone\\." "$CLAUDE_LOG.stdin"
  grep -q "fetch_inbox as GreenCastle in project $HOME/code" "$CLAUDE_LOG.stdin"
  ! grep -q 'please review the plan' "$CLAUDE_LOG.stdin" || { echo "the relay prompt carries the delivered subject"; false; }
  ! grep -q 'asked subject' "$CLAUDE_LOG.stdin" || { echo "the relay prompt carries the requested subject"; false; }
  grep -q 'courier: RedStone -> GreenCastle (other-project-x9) via' "$POSTBOX_STATE/logs/courier.log"
}

@test "courier: a recipient in the default profile is relayed with the config-dir variable unset" {
  export CLAUDE_CONFIG_DIR="$HOME/.claude-mine"
  mkdir -p "$CLAUDE_CONFIG_DIR/sessions" "$HOME/.claude"
  other="$HOME/code/other-project"
  live_session_at "$HOME/.claude" "$other" "other-project-x9" idle
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/other-project.name GreenCastle
  run payload "{\"cwd\":\"$WORK\",${SEND#\{}" courier
  wait_relays 1
  grep -q '^unset	-p ' "$CLAUDE_LOG"
}

@test "courier: busy and waiting sessions are left to their own Stop hook" {
  export CLAUDE_CONFIG_DIR="$HOME/.claude-mine"
  mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.other '~/.claude-other'
  other="$HOME/code/other-project"
  live_session_at "$HOME/.claude-other" "$other" "busy-one" busy
  live_session_at "$HOME/.claude-other" "$other" "waiting-one" waiting
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/other-project.name GreenCastle
  run payload "{\"cwd\":\"$WORK\",${SEND#\{}" courier
  [ "$status" -eq 0 ]
  sleep 1
  [ ! -s "$CLAUDE_LOG" ]
}

@test "courier: every recipient session is woken, the sender's own directory never, and each only once" {
  export CLAUDE_CONFIG_DIR="$HOME/.claude-mine"
  mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.other '~/.claude-other'
  live_session_at "$HOME/.claude-other" "$HOME/code/other-project" "other-a" idle
  live_session_at "$HOME/.claude-mine" "$HOME/code/third-project" "third-b" idle
  live_session_at "$HOME/.claude-mine" "$WORK" "me" idle
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/other-project.name GreenCastle
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/third-project.name BlueLake
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/some-project.name RedStone
  run payload '{"cwd":"'"$WORK"'","tool_name":"mcp__postbox__send_message","tool_input":{"to":["GreenCastle","BlueLake"],"cc":["RedStone"],"subject":"all hands"}}' courier
  wait_relays 2
  sleep 0.5
  [ "$(grep -c . "$CLAUDE_LOG")" -eq 2 ]
  grep -q 'to="other-a"' "$CLAUDE_LOG.stdin"
  grep -q 'to="third-b"' "$CLAUDE_LOG.stdin"
  ! grep -q 'to="me"' "$CLAUDE_LOG.stdin" || { echo "the relay prompt addresses to=\"me\""; false; }
  grep -q "new mail for BlueLake from RedStone\\." "$CLAUDE_LOG.stdin"
  ! grep -q 'all hands' "$CLAUDE_LOG.stdin" || { echo "the relay prompt carries the subject"; false; }
}

@test "courier: a reply wakes whoever the server actually delivered to" {
  export CLAUDE_CONFIG_DIR="$HOME/.claude-mine"
  mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.other '~/.claude-other'
  live_session_at "$HOME/.claude-other" "$HOME/code/other-project" "other-a" idle
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/other-project.name GreenCastle
  run payload '{"cwd":"'"$WORK"'","tool_name":"mcp__postbox__reply_message","tool_input":{"message_id":9,"body_md":"ok"},"tool_response":{"deliveries":[{"payload":{"id":10,"to":["GreenCastle"],"subject":"Re: the plan"}}]}}' courier
  wait_relays 1
  grep -q 'to="other-a"' "$CLAUDE_LOG.stdin"
  ! grep -q 'Re: the plan' "$CLAUDE_LOG.stdin" || { echo "the relay prompt carries the reply's subject"; false; }
}

@test "courier: no live session for the recipient, another tool, or the courier switched off — nothing runs" {
  export CLAUDE_CONFIG_DIR="$HOME/.claude-mine"
  mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
  run payload "{\"cwd\":\"$WORK\",${SEND#\{}" courier
  [ "$status" -eq 0 ]
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.other '~/.claude-other'
  live_session_at "$HOME/.claude-other" "$HOME/code/other-project" "other-a" idle
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/other-project.name GreenCastle
  run payload '{"cwd":"'"$WORK"'","tool_name":"mcp__postbox__fetch_inbox","tool_input":{"to":["GreenCastle"]}}' courier
  git config --file "$GIT_CONFIG_GLOBAL" postbox.courier false
  run payload "{\"cwd\":\"$WORK\",${SEND#\{}" courier
  [ "$status" -eq 0 ]
  sleep 1
  [ ! -s "$CLAUDE_LOG" ]
}

@test "courier: the relay's model and permission mode come from git config" {
  export CLAUDE_CONFIG_DIR="$HOME/.claude-mine"
  mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.other '~/.claude-other'
  live_session_at "$HOME/.claude-other" "$HOME/code/other-project" "other-a" idle
  git config --file "$GIT_CONFIG_GLOBAL" postbox.code/other-project.name GreenCastle
  git config --file "$GIT_CONFIG_GLOBAL" postbox.courier.model sonnet
  git config --file "$GIT_CONFIG_GLOBAL" postbox.courier.mode default
  run payload "{\"cwd\":\"$WORK\",${SEND#\{}" courier
  wait_relays 1
  grep -q -- '--model sonnet --permission-mode default' "$CLAUDE_LOG"
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
  [[ "$output" == *'"PostToolUse"'*'postbox courier'* ]]
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

# --- Lead: postbox lead, lead-news, the Stop hook's news ------------------------

# A live Lead record (its own sleeping pid) in profile $1 at cwd $2, named $3,
# status $4, sessionId $5. Sets LPID.
lead_rec() {
  sleep 300 </dev/null >/dev/null 2>&1 &
  LPID=$!; SLEEPERS="${SLEEPERS:-} $LPID"
  mkdir -p "$1/sessions"
  printf '{"pid":%s,"cwd":"%s","name":"%s","status":"%s","sessionId":"%s"}\n' "$LPID" "$2" "$3" "$4" "${5:-}" > "$1/sessions/$LPID.json"
}
rkey() { printf '%s' "$(cd "$WORK" && pwd -P)" | tr -c 'A-Za-z0-9._-' '_'; }
counter() { cat "$POSTBOX_STATE/rollcall/log/$(rkey)" 2>/dev/null || echo none; }
STOP='{"cwd":"'"$HOME/code/some-project"'","session_id":"s1","stop_hook_active":false}'

@test "lead: prints the Lead for the leader directory and for a tab's worktree; none is exit 1" {
  news_leader
  lead_rec "$CLAUDE_CONFIG_DIR" "$WORK" proj-7 idle
  run "$PB" lead "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "proj-7"$'\t'".claude-a"$'\t'"idle" ]
  run "$PB" lead "$wt"
  [ "$output" = "proj-7"$'\t'".claude-a"$'\t'"idle" ]
  rm "$CLAUDE_CONFIG_DIR/sessions/$LPID.json"
  run "$PB" lead "$wt"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "hook start: a tab's line names its Lead, and is unchanged without one" {
  news_leader
  export CLAUDE_PEER_WORKTREE="$wt"
  run payload '{"cwd":"'"$wt"'","session_id":"p1"}' hook start
  base=$output
  [[ "$base" != *"Claude Peers tab"* ]]
  run env POSTBOX_CLAUDE_PEER=/nonexistent "$PB" hook start <<< '{"cwd":"'"$wt"'","session_id":"p1"}'
  [ "$output" = "$base" ]
  lead_rec "$CLAUDE_CONFIG_DIR" "$WORK" proj-7 idle
  run payload '{"cwd":"'"$wt"'","session_id":"p1"}' hook start
  [[ "$output" == *" You are a Claude Peers tab; Lead is the session proj-7 (SendMessage). If that name stops answering, postbox lead prints the current one."* ]]
}

@test "lead-news: wakes an idle Lead once per state of the log, never counts, and the next prompt delivers" {
  news_leader
  lead_rec "$CLAUDE_CONFIG_DIR" "$WORK" proj-7 idle
  logl 1799999500 Alpha claim "fix thing"
  run "$PB" lead-news "$WORK"
  [ "$status" -eq 0 ]
  wait_relays 1
  [ "$(grep -c . "$CLAUDE_LOG")" -eq 1 ]
  grep -q "^$CLAUDE_CONFIG_DIR	-p " "$CLAUDE_LOG"
  grep -qF 'to="proj-7"' "$CLAUDE_LOG.stdin"
  grep -qF 'postbox: Claude Peers: Alpha claimed: fix thing (from the tabs' "$CLAUDE_LOG.stdin"
  grep -q 'lead-news: .*: woke proj-7 with 1 line(s)' "$POSTBOX_STATE/logs/courier.log"
  [ "$(counter)" = none ]
  [ "$(cat "$POSTBOX_STATE/rollcall/relayed/$(rkey)")" = 1 ]
  "$PB" lead-news "$WORK"
  grep -q 'already relayed' "$POSTBOX_STATE/logs/courier.log"
  [ "$(grep -c . "$CLAUDE_LOG")" -eq 1 ]
  "$PB" lead-news --again "$WORK"
  wait_relays 2
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ "$output" = "postbox: Claude Peers: Alpha claimed: fix thing" ]
  [ "$(counter)" = 1 ]
}

@test "lead-news: a busy Lead is left to its Stop hook, which blocks once with the line" {
  news_leader
  lead_rec "$CLAUDE_CONFIG_DIR" "$WORK" proj-7 busy
  logl 1799999500 Alpha claim "fix thing"
  run "$PB" lead-news "$WORK"
  [ "$status" -eq 0 ]
  [ ! -e "$CLAUDE_LOG" ]
  [ "$(counter)" = none ]
  grep -q 'lead-news: .*: Lead busy (its Stop hook delivers)' "$POSTBOX_STATE/logs/courier.log"
  run payload "$STOP" hook stop
  [ "$output" = '{"decision": "block", "reason": "postbox: Claude Peers: Alpha claimed: fix thing Take this as news from your tabs: tell the operator what matters, then stop."}' ]
  run payload "$STOP" hook stop
  [ -z "$output" ]
}

@test "lead-news: no Lead session runs nothing and says so" {
  news_leader
  logl 1799999500 Alpha claim "fix thing"
  run "$PB" lead-news "$WORK"
  [ "$status" -eq 0 ]
  [ ! -e "$CLAUDE_LOG" ]
  grep -q 'lead-news: .*: no Lead session' "$POSTBOX_STATE/logs/courier.log"
}

@test "lead-news: wake-lead done holds a claim for the next prompt; off and postbox.courier false run nothing" {
  news_leader
  lead_rec "$CLAUDE_CONFIG_DIR" "$WORK" proj-7 idle
  logl 1799999500 Alpha claim "fix thing"
  git config --file "$GIT_CONFIG_GLOBAL" claude-peer.wake-lead done
  "$PB" lead-news "$WORK"
  grep -q 'nothing pending' "$POSTBOX_STATE/logs/courier.log"
  run payload "$STOP" hook stop
  [ -z "$output" ]
  [ ! -e "$CLAUDE_LOG" ]
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ "$output" = "postbox: Claude Peers: Alpha claimed: fix thing" ]
  logl 1799999600 Alpha done "ok"
  git config --file "$GIT_CONFIG_GLOBAL" claude-peer.wake-lead off
  "$PB" lead-news "$WORK"
  grep -q ': off$' "$POSTBOX_STATE/logs/courier.log"
  run payload "$STOP" hook stop
  [ -z "$output" ]
  git config --file "$GIT_CONFIG_GLOBAL" --unset claude-peer.wake-lead
  git config --file "$GIT_CONFIG_GLOBAL" postbox.courier false
  "$PB" lead-news "$WORK"
  grep -q 'courier disabled' "$POSTBOX_STATE/logs/courier.log"
  [ ! -e "$CLAUDE_LOG" ]
}

@test "lead-news: a double quote and a backslash in a tab's text do not reach the relay" {
  news_leader
  lead_rec "$CLAUDE_CONFIG_DIR" "$WORK" proj-7 idle
  logl 1799999500 Alpha note 'say "hi" back\slash'
  "$PB" lead-news "$WORK"
  wait_relays 1
  grep -qF 'Alpha noted: say hi backslash (from' "$CLAUDE_LOG.stdin"
}

@test "lead-news: Lead by pid, then by session id, then every session in the directory" {
  news_leader
  lead_rec "$CLAUDE_CONFIG_DIR" "$WORK" L-one idle
  lead_rec "$CLAUDE_CONFIG_DIR" "$WORK" L-two idle; two=$LPID
  mkdir -p "$HOME/code/moved"
  lead_rec "$CLAUDE_CONFIG_DIR" "$HOME/code/moved" L-three idle sid-3
  logl 1799999500 Alpha claim "fix thing"
  "$PB" lead-news "$WORK" "$two" -
  wait_relays 1; sleep 0.3
  [ "$(grep -c . "$CLAUDE_LOG")" -eq 1 ]
  grep -qF 'to="L-two"' "$CLAUDE_LOG.stdin"
  "$PB" lead-news --again "$WORK" 2147483000 sid-3
  wait_relays 2; sleep 0.3
  [ "$(grep -c . "$CLAUDE_LOG")" -eq 2 ]
  grep -qF 'to="L-three"' "$CLAUDE_LOG.stdin"
  "$PB" lead-news --again "$WORK" 2147483000 sid-none
  wait_relays 4
  grep -qF 'to="L-one"' "$CLAUDE_LOG.stdin"
  grep -q 'handed over by pid 2147483000, now gone; told 2 session(s) in the directory' "$POSTBOX_STATE/logs/courier.log"
}

@test "hook stop: a session that never led never runs claude-peer" {
  peer_stub
  run payload '{"cwd":"'"$WORK"'","session_id":"s9","stop_hook_active":false}' hook stop
  [ -z "$output" ]
  [ ! -e "$PEER_LOG" ]
}

@test "hook stop: with mail and news both pending the mail blocks and the news waits for the next prompt" {
  news_leader
  logl 1799999500 Alpha claim "fix thing"
  export FAKE_INBOX='{"unread_count":1,"messages":[{"id":3,"subject":"review please","from":"BlueLake"}]}'
  run payload "$STOP" hook stop
  [[ "$output" == *'new message(s)'* ]]
  [[ "$output" != *'claimed'* ]]
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [[ "$output" == *"postbox: Claude Peers: Alpha claimed: fix thing"* ]]
}

# --- a peer's turn end; a Lead that starts with news waiting --------------------

# A peer at $HOME/code/alpha whose Stop hook runs with payload $1.
peer_stop() {
  peer_stub
  wt="$HOME/code/alpha"; mkdir -p "$wt"
  export CLAUDE_PEER_WORKTREE="$wt"
  run payload "$1" hook stop
}

@test "hook stop: a peer's turn end runs log idle with the first line, from its worktree" {
  peer_stop '{"cwd":"'"$HOME/code/alpha"'","session_id":"p1","last_assistant_message":"\n  first line\nsecond\nthird"}'
  [ -z "$output" ]
  [ "$(cat "$PEER_LOG")" = "log idle   first line" ]
  [ "$(cat "$PEER_LOG.pwd")" = "$(cd "$HOME/code/alpha" && pwd)" ]
}

@test "hook stop: a peer with a background task in flight is paused, not idle" {
  peer_stop '{"cwd":"'"$HOME/code/alpha"'","session_id":"p1","background_tasks":[{"id":1}],"last_assistant_message":"x"}'
  [ ! -e "$PEER_LOG" ]
  grep -q "turn-end: $HOME/code/alpha: paused on 1 background task(s)" "$POSTBOX_STATE/logs/courier.log"
}

@test "hook stop: a peer inside a held turn still reports; without the arrays nothing is in flight" {
  peer_stop '{"cwd":"'"$HOME/code/alpha"'","session_id":"p1","stop_hook_active":true,"last_assistant_message":"done here"}'
  [ "$(cat "$PEER_LOG")" = "log idle done here" ]
}

@test "hook stop: a peer with unread mail gets the mail block and no log idle" {
  export FAKE_INBOX='{"unread_count":1,"messages":[{"id":3,"subject":"review please","from":"BlueLake"}]}'
  peer_stop '{"cwd":"'"$HOME/code/alpha"'","session_id":"p1","last_assistant_message":"x"}'
  [[ "$output" == *'"decision": "block"'* ]]
  [ ! -e "$PEER_LOG" ]
}

@test "hook stop: a non-peer never runs log idle" {
  peer_stub
  run payload '{"cwd":"'"$WORK"'","session_id":"s9","last_assistant_message":"x"}' hook stop
  ! grep -q 'log idle' "$PEER_LOG" 2>/dev/null || { echo "a non-peer ran log idle"; false; }
}

@test "hook stop: a tab and an escape in the first line do not reach log idle" {
  peer_stop '{"cwd":"'"$HOME/code/alpha"'","session_id":"p1","last_assistant_message":"a\tb\u001b[31mc"}'
  [ "$(cat "$PEER_LOG")" = "log idle ab[31mc" ]
}

@test "hook start: a Lead coming back reads what its tabs logged meanwhile, once" {
  news_leader
  logl 1799999400 Alpha claim "fix"
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  [ "$(counter)" = 1 ]
  logl 1799999500 Alpha done "DONE: abc"
  run payload '{"cwd":"'"$WORK"'","session_id":"s2"}' hook start
  [[ "$output" == *$'\n'"postbox: Claude Peers: Alpha done: DONE: abc" ]]
  run payload '{"cwd":"'"$WORK"'","session_id":"s2"}' hook prompt
  [[ "$output" != *"Alpha done"* ]]
}

@test "hook start: no delivered count, no claude-peer; a peer's start adds no news" {
  leader_profile; peer_stub
  export FAKE_LOG="$BATS_TEST_TMPDIR/peer-log"; : > "$FAKE_LOG"
  logl 1799999500 Alpha done "DONE: abc"
  run payload '{"cwd":"'"$WORK"'","session_id":"s2"}' hook start
  [ ! -e "$PEER_LOG" ]
  [[ "$output" != *"Alpha done"* ]]
  mkdir -p "$POSTBOX_STATE/rollcall/log"; echo 0 > "$POSTBOX_STATE/rollcall/log/$(rkey)"
  export CLAUDE_PEER_WORKTREE="$WORK"
  run payload '{"cwd":"'"$WORK"'","session_id":"s2"}' hook start
  [[ "$output" != *"Alpha done"* ]]
}

# --- the stall clock: postbox handoff-check --once ----------------------------------

# news_leader plus a stub terminal-notifier; the clock's own arguments in HC.
clock() {
  news_leader
  NOTIFY_LOG="$BATS_TEST_TMPDIR/notify.log"; export NOTIFY_LOG
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$NOTIFY_LOG"\n' > "$BIN/terminal-notifier"
  chmod +x "$BIN/terminal-notifier"
  HC=(handoff-check --once "$WORK" "$wt" 4242 - -)
}
sfile() { echo "$POSTBOX_STATE/handoff/$(rkey).alpha"; }
leadnews() { cat "$POSTBOX_STATE/logs/courier.log" 2>/dev/null | grep -c 'lead-news:'; }

@test "handoff-check: a live claim with nothing pending does nothing" {
  clock
  run "$PB" "${HC[@]}"
  [ "$status" -eq 0 ]
  ! grep -q 'idle' "$PEER_LOG" || { echo "a live claim was reported gone"; false; }
  [ ! -e "$NOTIFY_LOG" ]
}

@test "handoff-check: a dead claim with no line is reported gone once; with an end line it is not" {
  clock
  export FAKE_LIVE=''
  "$PB" "${HC[@]}"
  grep -qx 'log --as Alpha idle Alpha is gone: its session and its pane ended without a line' "$PEER_LOG"
  : > "$PEER_LOG"
  logl 1800000010 Alpha end "Alpha ended after 3m"
  "$PB" "${HC[@]}"
  ! grep -q 'idle' "$PEER_LOG" || { echo "an ended session was reported gone"; false; }
}

@test "handoff-check: a done that waits a whole interval wakes Lead again and tells the operator, once" {
  clock
  logl 1799999500 Alpha done "DONE: abc"
  "$PB" "${HC[@]}"
  [ "$(sed -n 's/^seen=//p' "$(sfile)")" = 1 ]
  [ "$(leadnews)" -eq 0 ]
  [ ! -e "$NOTIFY_LOG" ]
  "$PB" "${HC[@]}"
  [ "$(leadnews)" -eq 1 ]
  [ "$(grep -c . "$NOTIFY_LOG")" -eq 1 ]
  grep -qF -- '-title some-project · Alpha -message Alpha done: DONE: abc (not picked up by Lead)' "$NOTIFY_LOG"
  "$PB" "${HC[@]}"
  [ "$(leadnews)" -eq 1 ]
  [ "$(grep -c . "$NOTIFY_LOG")" -eq 1 ]
}

@test "handoff-check: a line Lead's prompt delivered between passes clears seen and tells nobody" {
  clock
  logl 1799999500 Alpha done "DONE: abc"
  "$PB" "${HC[@]}"
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook prompt
  "$PB" "${HC[@]}"
  [ "$(leadnews)" -eq 0 ]
  [ ! -e "$NOTIFY_LOG" ]
  ! grep -q '^seen=' "$(sfile)" 2>/dev/null || { echo "seen survived delivery"; false; }
}

@test "handoff-check: a dead claim with nothing pending stops and removes its state" {
  clock
  export FAKE_LIVE=''
  mkdir -p "${POSTBOX_STATE}/handoff"; echo 'seen=3' > "$(sfile)"
  "$PB" "${HC[@]}"
  [ ! -e "$(sfile)" ]
}

@test "handoff-check: postbox.notify false logs and notifies nobody; no notifier is logged as such" {
  clock
  git config --file "$GIT_CONFIG_GLOBAL" postbox.notify false
  logl 1799999500 Alpha done "DONE: abc"
  "$PB" "${HC[@]}"; "$PB" "${HC[@]}"
  [ ! -e "$NOTIFY_LOG" ]
  grep -q 'operator: some-project · Alpha: Alpha done: DONE: abc (not picked up by Lead) (postbox.notify false)' "$POSTBOX_STATE/logs/courier.log"
  git config --file "$GIT_CONFIG_GLOBAL" --unset postbox.notify
  rm -f "$(sfile)" "$BIN/terminal-notifier"
  # a PATH that holds only what postbox needs, so no real notifier is found
  local b="$BATS_TEST_TMPDIR/minbin" c
  mkdir -p "$b"
  for c in sh git python3 sed awk tr cut grep date cat mkdir mv rm wc sort; do ln -s "$(command -v "$c")" "$b/$c"; done
  PATH="$b" "$PB" "${HC[@]}"; PATH="$b" "$PB" "${HC[@]}"
  grep -q 'operator: no notifier (some-project · Alpha)' "$POSTBOX_STATE/logs/courier.log"
}

@test "handoff-check: stall-minutes 0 or not a number runs no pass" {
  clock
  export FAKE_LIVE=''
  git config --file "$GIT_CONFIG_GLOBAL" claude-peer.stall-minutes 0
  "$PB" "${HC[@]}"
  git config --file "$GIT_CONFIG_GLOBAL" claude-peer.stall-minutes soon
  "$PB" "${HC[@]}"
  ! grep -q 'idle' "$PEER_LOG" || { echo "a clock that is off ran"; false; }
}

@test "handoff-check: without --once it loops and leaves once the claim is dead and nothing is pending" {
  clock
  export FAKE_LIVE='' POSTBOX_CHECK_SLEEP=0
  run "$PB" handoff-check "$WORK" "$wt" 4242 - -
  [ "$status" -eq 0 ]
  [ "$(grep -c 'is gone' "$PEER_LOG")" -eq 1 ]
}

# --- the clock sees a live peer gone quiet -------------------------------------------

# PeerA's record in alpha, with status $1 updated $2 seconds before POSTBOX_NOW.
quiet_rec() {
  printf '{"pid":%s,"cwd":"%s","name":"PeerA","status":"%s","statusUpdatedAt":%s}\n' \
    "$$" "$wt" "$1" "$(( (1800000000 - $2) * 1000 ))" > "$CLAUDE_CONFIG_DIR/sessions/PeerA.json"
}

@test "handoff-check: a peer waiting for 20 minutes with nothing logged is reported once" {
  clock
  quiet_rec waiting 1200
  "$PB" "${HC[@]}"
  grep -qx 'log --as Alpha idle Alpha has been waiting for 20m with nothing logged' "$PEER_LOG"
  [ "$(grep -c . "$NOTIFY_LOG")" -eq 1 ]
  grep -qF -- '-message waiting for 20m, nothing logged' "$NOTIFY_LOG"
  "$PB" "${HC[@]}"
  [ "$(grep -c 'has been' "$PEER_LOG")" -eq 1 ]
  [ "$(grep -c . "$NOTIFY_LOG")" -eq 1 ]
}

@test "handoff-check: a busy peer, or one whose idle line its Stop hook already wrote, is left alone" {
  clock
  quiet_rec busy 1200
  "$PB" "${HC[@]}"
  quiet_rec idle 1200
  logl $((1800000000 - 1200 - 5)) Alpha idle "Alpha stopped after 1h without logging done"
  "$PB" "${HC[@]}"
  ! grep -q 'has been' "$PEER_LOG" || { echo "a quiet peer was reported anyway"; false; }
  [ ! -e "$NOTIFY_LOG" ]
}

@test "handoff-check: a live claim with no registry record is logged and nothing else" {
  clock
  rm "$CLAUDE_CONFIG_DIR/sessions/PeerA.json"
  "$PB" "${HC[@]}"
  grep -q "handoff-check: $wt: no registry record" "$POSTBOX_STATE/logs/courier.log"
  ! grep -q 'has been' "$PEER_LOG" || { echo "reported without a record"; false; }
}

# --- the start hook says who is Lead ---------------------------------------------

lead_start() { # title (may be empty)
  peer_stub
  local t=''
  [ -z "$1" ] || t=',"session_title":"'"$1"'"'
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"'"$t"'}' hook start
}
leadline() { printf 'postbox: you are Lead of %s (session proj-lead). The Lead section of your memory applies to this session and to no other.' "$WORK"; }
leadlog() { grep "lead: $WORK: " "$POSTBOX_STATE/logs/courier.log" | tail -n 1 | sed 's/.*: //'; }

@test "hook start: the session titled with the leader's name is told it is Lead, and the log says yes" {
  lead_start proj-lead
  [ "$(printf '%s\n' "$output" | grep -cxF "$(leadline)")" -eq 1 ]
  [ "$(leadlog)" = "yes (proj-lead)" ]
  run payload '{"cwd":"'"$WORK"'","session_id":"s1","session_title":"proj-lead"}' hook prompt
  [[ "$output" != *"you are Lead"* ]]
}

@test "hook start: another title, none, or a foreign -lead is not Lead; only a -lead title asks claude-peer" {
  lead_start proj-alpha
  [[ "$output" != *"you are Lead"* ]]
  ! grep -q '^name' "$PEER_LOG" 2>/dev/null || { echo "a non-lead title asked claude-peer"; false; }
  [ "$(leadlog)" = "no (proj-alpha)" ]
  lead_start ''
  [[ "$output" != *"you are Lead"* ]]
  [ "$(leadlog)" = "no (-)" ]
  lead_start octo-lead
  [[ "$output" != *"you are Lead"* ]]
  [ "$(leadlog)" = "no (octo-lead)" ]
}

@test "hook start: a peer titled proj-lead is not Lead and logs nothing" {
  export CLAUDE_PEER_WORKTREE="$WORK"
  lead_start proj-lead
  [[ "$output" != *"you are Lead"* ]]
  ! grep -q 'lead:' "$POSTBOX_STATE/logs/courier.log" 2>/dev/null || { echo "a peer logged a lead line"; false; }
}

@test "hook start: with no title, the registry name counts only when the operator set it" {
  export CLAUDE_PID=4242
  mkdir -p "$HOME/.claude/sessions"
  printf '{"pid":4242,"name":"proj-lead","nameSource":"user"}\n' > "$HOME/.claude/sessions/4242.json"
  lead_start ''
  [ "$(printf '%s\n' "$output" | grep -cxF "$(leadline)")" -eq 1 ]
  printf '{"pid":4242,"name":"proj-lead","nameSource":"derived"}\n' > "$HOME/.claude/sessions/4242.json"
  lead_start ''
  [[ "$output" != *"you are Lead"* ]]
}

@test "hook start: without claude-peer the output is what it was before" {
  export POSTBOX_CLAUDE_PEER=/nonexistent
  run payload '{"cwd":"'"$WORK"'","session_id":"s1","session_title":"proj-lead"}' hook start
  a=$output
  run payload '{"cwd":"'"$WORK"'","session_id":"s1"}' hook start
  [ "$a" = "$output" ]
  [[ "$a" != *"you are Lead"* ]]
}
