#!/usr/bin/env bats

# bin/remote-mcp registers a remote, bearer-token MCP server in Claude Code
# profiles and, for a server on a tailnet, relays it through a loopback
# forwarder. These tests drive the real script under a sandboxed HOME and git
# config with stub op/claude/tailnet/curl binaries: no vault is read, no
# Claude Code config is touched, and nothing leaves loopback. Every name is a
# fixture — a reserved-domain URL, invented server, tailnet and profile
# names, an obviously fake token and a reference that is not in any real
# scheme (see CLAUDE.md, and tests/no-secrets.bats for why the literal scheme
# may not appear here).

setup() {
  # python3 is resolved to its real interpreter before HOME is sandboxed, and
  # re-exposed under a stub on PATH below: an asdf shim resolves relative to
  # $HOME and exits 126 the moment that is overridden.
  REAL_PYTHON3="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)" || REAL_PYTHON3=''

  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude" "$HOME/.claude-other"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  : > "$GIT_CONFIG_GLOBAL"
  unset CLAUDE_CONFIG_DIR CLAUDE_CODE_MCP_SERVER_NAME XDG_STATE_HOME

  RM="$BATS_TEST_DIRNAME/../bin/executable_remote-mcp"
  export REMOTE_MCP_STATE="$BATS_TEST_TMPDIR/state"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  export CALLS="$BATS_TEST_TMPDIR/calls.log"
  : > "$CALLS"
  export FAKE_TOKEN=fake-token-0123
  export FAKE_TAILNET_PORT=1

  # op: records its argv and answers with a fake token.
  cat > "$BIN/op" <<'STUB'
#!/bin/sh
printf 'op\t%s\n' "$*" >> "$CALLS"
[ -z "${FAKE_OP_FAIL:-}" ] || exit 1
printf '%s' "$FAKE_TOKEN"
STUB
  # claude: records the profile it ran as and plays the two `mcp` commands
  # against the same file the real one writes, so the script's read-back of
  # the entry is exercised. FAKE_CLAUDE_DROPS_HELPER writes the entry the way
  # a CLI that lost the field would.
  cat > "$BIN/claude" <<'STUB'
#!/bin/sh
printf 'claude\t%s\t%s\n' "${CLAUDE_CONFIG_DIR:-unset}" "$*" >> "$CALLS"
cfg=${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}
cfg=${cfg:-$HOME/.claude.json}
case "$1 $2" in
  "mcp add-json")
    entry=$6
    [ -z "${FAKE_CLAUDE_DROPS_HELPER:-}" ] || entry='{"type": "http", "url": "dropped"}'
    printf '{"mcpServers": {"%s": %s}}\n' "$5" "$entry" > "$cfg" ;;
  "mcp remove") printf '{"mcpServers": {}}\n' > "$cfg" ;;
esac
STUB
  # tailnet: only `port <name>` is asked for.
  cat > "$BIN/tailnet" <<'STUB'
#!/bin/sh
printf 'tailnet\t%s\n' "$*" >> "$CALLS"
[ -z "${FAKE_TAILNET_MISSING:-}" ] || { printf "tailnet: tailnet '%s' is not installed\n" "$2" >&2; exit 1; }
printf '%s\n' "$FAKE_TAILNET_PORT"
STUB
  chmod +x "$BIN/op" "$BIN/claude" "$BIN/tailnet"
  if [ -n "$REAL_PYTHON3" ]; then
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_PYTHON3" > "$BIN/python3"
    chmod +x "$BIN/python3"
  fi
  export PATH="$BIN:$PATH"
}

teardown() {
  for f in "$REMOTE_MCP_STATE"/*/pid; do
    [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null
  done
  return 0
}

gc() { git config --file "$GIT_CONFIG_GLOBAL" "$@"; }

# Reading a profile's entry and running the forwarder need python3; the
# unconfigured paths and the headers helper for a direct server do not, and
# stay tested on a box without it.
need_python3() { [ -n "$REAL_PYTHON3" ] || skip "python3 not installed"; }

# A direct server `web` pinned for the default profile and one other.
direct_server() {
  gc remote-mcp.web.url https://mcp.example.test/mcp
  gc --add remote-mcp.web.token '~/.claude ref for the default profile'
  gc --add remote-mcp.web.token '~/.claude-other ref-other'
}

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

calls() { grep -c "^$1" "$CALLS" || true; }

# The headers helper with stdout in $output and stderr in $stderr. Environment
# for it goes in front of the call. (`run --separate-stderr` needs bats 1.5.)
headers() {
  run sh -c '"$0" headers 2>"$1"' "$RM" "$BATS_TEST_TMPDIR/stderr"
  stderr=$(cat "$BATS_TEST_TMPDIR/stderr")
}

# --- nothing configured --------------------------------------------------------

@test "unconfigured: status is one line, exit 0, and runs nothing" {
  # python3 and curl are shadowed by recorders so a call would show.
  for t in python3 curl; do
    printf '#!/bin/sh\nprintf "%s\\n" >> "$CALLS"\n' "$t" > "$BIN/$t"; chmod +x "$BIN/$t"
  done
  run "$RM" status
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"no servers configured"* ]]
  [ ! -s "$CALLS" ]
  [ ! -e "$REMOTE_MCP_STATE" ]
}

@test "unconfigured: connect and disconnect say so without needing claude" {
  rm "$BIN/claude"
  run env PATH="$BIN:/usr/bin:/bin" "$RM" connect
  [ "$status" -eq 0 ]
  [[ "$output" == *"no servers configured"* ]]
  run env PATH="$BIN:/usr/bin:/bin" "$RM" disconnect
  [ "$status" -eq 0 ]
}

@test "unconfigured: headers fails with one stderr line, no stdout, with op absent from PATH" {
  rm "$BIN/op"
  PATH="$BIN:/usr/bin:/bin" CLAUDE_CODE_MCP_SERVER_NAME=web headers
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"web: not configured"* ]]
}

@test "headers outside Claude Code names what is missing" {
  run "$RM" headers
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLAUDE_CODE_MCP_SERVER_NAME is not set"* ]]
}

@test "a repo's own git config cannot add or redirect a server" {
  repo="$BATS_TEST_TMPDIR/repo"
  git init -q "$repo"
  git -C "$repo" config remote-mcp.web.url https://elsewhere.example.test/mcp
  git -C "$repo" config --add remote-mcp.web.token '~/.claude ref-from-the-repo'
  cd "$repo"
  run "$RM" status
  [[ "$output" == *"no servers configured"* ]]
  CLAUDE_CODE_MCP_SERVER_NAME=web headers
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ ! -s "$CALLS" ]
}

# --- the headers helper ----------------------------------------------------------

@test "headers: the profile picks the pin, and the reference reaches op verbatim" {
  direct_server
  CLAUDE_CODE_MCP_SERVER_NAME=web CLAUDE_CONFIG_DIR="$HOME/.claude-other" headers
  [ "$status" -eq 0 ]
  [ "$output" = '{"Authorization": "Bearer fake-token-0123"}' ]
  grep -q "^op	read --no-newline ref-other$" "$CALLS"

  # CLAUDE_CONFIG_DIR unset is the default directory, and a reference keeps
  # its spaces.
  : > "$CALLS"
  CLAUDE_CODE_MCP_SERVER_NAME=web headers
  [ "$status" -eq 0 ]
  grep -q "^op	read --no-newline ref for the default profile$" "$CALLS"
}

@test "headers: a profile with no pin never reaches op or the forwarder" {
  direct_server
  gc remote-mcp.web.tailnet net-a
  mkdir -p "$HOME/.claude-third"
  CLAUDE_CODE_MCP_SERVER_NAME=web CLAUDE_CONFIG_DIR="$HOME/.claude-third" headers
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"no token pinned for $HOME/.claude-third"* ]]
  [ ! -s "$CALLS" ]
}

@test "headers: a failed read and a token that is not a bearer token print no header" {
  direct_server
  FAKE_OP_FAIL=1 CLAUDE_CODE_MCP_SERVER_NAME=web headers
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"op read failed"* ]]

  FAKE_TOKEN='two words"' CLAUDE_CODE_MCP_SERVER_NAME=web headers
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # The value never reaches a message.
  [[ "$stderr" != *"two words"* ]]
}

@test "a malformed token pin is warned about, not silently dropped" {
  need_python3
  direct_server
  gc --add remote-mcp.web.token 'no-reference-here'
  run "$RM" status
  [[ "$output" == *"ignoring a token pin"* ]]
}

@test "a server name this cannot use is warned about, not silently dropped" {
  gc 'remote-mcp.bad name.url' https://mcp.example.test/mcp
  run "$RM" status
  [[ "$output" == *"ignoring server 'bad name'"* ]]
}

# --- connect ---------------------------------------------------------------------

@test "connect: add-json per pinned profile, the default one with CLAUDE_CONFIG_DIR unset" {
  need_python3
  direct_server
  run "$RM" connect
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/.claude: connected (https://mcp.example.test/mcp)"* ]]
  [[ "$output" == *"$HOME/.claude-other: connected"* ]]
  grep -q "^claude	unset	mcp add-json --scope user web " "$CALLS"
  grep -q "^claude	$HOME/.claude-other	mcp add-json --scope user web " "$CALLS"
  # The default profile's config is the file in HOME, and the entry names
  # this script as its headers helper.
  grep -q '"headersHelper": ".*executable_remote-mcp headers"' "$HOME/.claude.json"
  grep -q '"url": "https://mcp.example.test/mcp"' "$HOME/.claude-other/.claude.json"
  # Registering reads no token.
  [ "$(calls op)" -eq 0 ]

  run "$RM" connect
  [[ "$output" == *"$HOME/.claude: already connected"* ]]
  [ "$(calls 'claude	unset	mcp add-json')" -eq 1 ]
}

@test "connect: a pinned directory that does not exist is skipped out loud" {
  need_python3
  direct_server
  gc --add remote-mcp.web.token '~/.claude-absent ref-absent'
  run "$RM" connect
  [[ "$output" == *".claude-absent is not a directory"* ]]
  [ ! -e "$HOME/.claude-absent" ]
}

@test "connect: an entry for another URL is replaced" {
  need_python3
  direct_server
  "$RM" connect >/dev/null
  gc remote-mcp.web.url https://mcp.example.test/v2/mcp
  run "$RM" status
  [[ "$output" == *"$HOME/.claude: stale entry"* ]]
  run "$RM" connect
  [[ "$output" == *"$HOME/.claude: connected (https://mcp.example.test/v2/mcp)"* ]]
  grep -q "^claude	unset	mcp remove --scope user web$" "$CALLS"
}

@test "connect: a CLI that does not keep the headers helper is reported, not trusted" {
  need_python3
  direct_server
  run env FAKE_CLAUDE_DROPS_HELPER=1 "$RM" connect
  [[ "$output" == *"did not keep the headers helper"* ]]
  [[ "$output" != *"connected ("* ]]
}

@test "connect: a tailnet server gets a recorded loopback port and keeps its path" {
  need_python3
  direct_server
  gc remote-mcp.web.tailnet net-a
  run "$RM" connect
  [ "$status" -eq 0 ]
  port=$(cat "$REMOTE_MCP_STATE/web/port")
  [[ "$port" =~ ^[0-9]+$ ]]
  [[ "$output" == *"connected (http://127.0.0.1:$port/mcp)"* ]]
  grep -q "^tailnet	port net-a$" "$CALLS"

  # A second server never shares the port, and a pinned port wins.
  gc remote-mcp.docs.url https://docs.example.test/mcp
  gc remote-mcp.docs.tailnet net-a
  gc --add remote-mcp.docs.token '~/.claude ref-docs'
  "$RM" connect docs >/dev/null
  [ "$(cat "$REMOTE_MCP_STATE/docs/port")" != "$port" ]
  gc remote-mcp.web.port 18999
  run "$RM" status
  [[ "$output" == *"127.0.0.1:18999"* ]]
}

@test "connect: a tailnet that is not installed stops it with tailnet's own words" {
  need_python3
  direct_server
  gc remote-mcp.web.tailnet net-a
  run env FAKE_TAILNET_MISSING=1 "$RM" connect
  [ "$status" -eq 1 ]
  [[ "$output" == *"tailnet 'net-a' is not installed"* ]]
  [ "$(calls claude)" -eq 0 ]
}

@test "connect: a forwarded server must be https" {
  need_python3
  gc remote-mcp.web.url http://mcp.example.test/mcp
  gc remote-mcp.web.tailnet net-a
  gc --add remote-mcp.web.token '~/.claude ref'
  run "$RM" connect
  [ "$status" -eq 1 ]
  [[ "$output" == *"needs an https URL"* ]]
}

@test "disconnect removes the entry from each connected profile" {
  need_python3
  direct_server
  "$RM" connect >/dev/null
  run "$RM" disconnect
  [[ "$output" == *"$HOME/.claude: disconnected"* ]]
  [[ "$output" == *"$HOME/.claude-other: disconnected"* ]]
  run "$RM" status
  [[ "$output" == *"$HOME/.claude: not connected"* ]]
}

@test "disconnect does not signal a stranger that inherited the forwarder's pid" {
  need_python3
  direct_server
  gc remote-mcp.web.tailnet net-a
  "$RM" connect >/dev/null
  sleep 30 3>&- &
  stranger=$!
  printf '%s\n' "$stranger" > "$REMOTE_MCP_STATE/web/pid"
  "$RM" disconnect >/dev/null
  kill -0 "$stranger"
  kill "$stranger"
  [ ! -e "$REMOTE_MCP_STATE/web/pid" ]
}

# --- status ------------------------------------------------------------------------

@test "status reads only: no token, no claude, no forwarder started" {
  need_python3
  direct_server
  gc remote-mcp.web.tailnet net-a
  gc remote-mcp.web.health /health
  "$RM" connect >/dev/null
  : > "$CALLS"
  run "$RM" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"web  https://mcp.example.test/mcp"* ]]
  [[ "$output" == *"route:   tailnet net-a"*"forwarder not running"* ]]
  [[ "$output" == *"health:  /health"* ]]
  [[ "$output" == *"$HOME/.claude: connected"* ]]
  [ "$(calls op)" -eq 0 ]
  [ "$(calls claude)" -eq 0 ]
  [ ! -e "$REMOTE_MCP_STATE/web/pid" ]
}

# --- the forwarder -------------------------------------------------------------------

# The far side is a port nothing listens on, so what is tested is everything
# the forwarder decides for itself: who it answers, what it says it is, and
# what it reports when the tailnet side is down.
start_forwarder() {
  direct_server
  gc remote-mcp.web.tailnet net-a
  PORT=$(free_port)
  gc remote-mcp.web.port "$PORT"
  export FAKE_TAILNET_PORT=$(free_port)
}

@test "headers starts the forwarder once, and it answers for the current config only" {
  need_python3
  start_forwarder
  CLAUDE_CODE_MCP_SERVER_NAME=web headers
  [ "$status" -eq 0 ]
  [ "$output" = '{"Authorization": "Bearer fake-token-0123"}' ]
  pid=$(cat "$REMOTE_MCP_STATE/web/pid")
  kill -0 "$pid"
  run curl -s --noproxy '*' "http://127.0.0.1:$PORT/.remote-mcp"
  [ "${lines[0]}" = "web https://mcp.example.test 127.0.0.1:$FAKE_TAILNET_PORT" ]
  [ "${lines[1]}" = "$pid" ]

  # Same config: reused.
  env CLAUDE_CODE_MCP_SERVER_NAME=web "$RM" headers >/dev/null
  [ "$(cat "$REMOTE_MCP_STATE/web/pid")" = "$pid" ]

  # The URL changed under it: replaced, not trusted.
  gc remote-mcp.web.url https://mcp2.example.test/mcp
  env CLAUDE_CODE_MCP_SERVER_NAME=web "$RM" headers >/dev/null
  [ "$(cat "$REMOTE_MCP_STATE/web/pid")" != "$pid" ]
  run curl -s --noproxy '*' "http://127.0.0.1:$PORT/.remote-mcp"
  [[ "$output" == "web https://mcp2.example.test "* ]]

  run "$RM" status
  [[ "$output" == *"forwarder running on 127.0.0.1:$PORT"* ]]
  "$RM" disconnect >/dev/null
  run curl -s -m 2 --noproxy '*' "http://127.0.0.1:$PORT/.remote-mcp"
  [ "$status" -ne 0 ]
}

@test "the forwarder refuses a browser's request and a foreign Host, and reports a dead far side as 502" {
  need_python3
  start_forwarder
  env CLAUDE_CODE_MCP_SERVER_NAME=web "$RM" headers >/dev/null
  code() { curl -s -o /dev/null -m 5 --noproxy '*' -w '%{http_code}' "$@" "http://127.0.0.1:$PORT/mcp"; }
  [ "$(code -H 'Origin: https://page.example.test')" = 403 ]
  [ "$(code -H 'Host: mcp.example.test')" = 403 ]
  [ "$(code)" = 502 ]
}

# --- check ---------------------------------------------------------------------------

@test "check: asks as a profile, keeps the token off curl's argv, and relays health verbatim" {
  direct_server
  gc remote-mcp.web.health /health
  cat > "$BIN/curl" <<'STUB'
#!/bin/sh
printf 'curl\t%s\n' "$*" >> "$CALLS"
cat > "$CALLS.stdin"
out=; url=
while [ $# -gt 0 ]; do
  case $1 in -o) out=$2; shift;; esac
  url=$1; shift
done
case $url in
  */health) printf '{"status": "degraded", "reasons": ["fixture"]}\n' > "$out"; printf 200;;
  *) printf 401;;
esac
STUB
  chmod +x "$BIN/curl"
  run "$RM" check web '~/.claude-other'
  [ "$status" -eq 0 ]
  [[ "$output" == *"web as $HOME/.claude-other"* ]]
  [[ "$output" == *"mcp:    http 401 unauthorized"* ]]
  [[ "$output" == *"health: http 200"* ]]
  [[ "$output" == *'{"status": "degraded", "reasons": ["fixture"]}'* ]]
  grep -q "^op	read --no-newline ref-other$" "$CALLS"
  run grep -c "^curl.*$FAKE_TOKEN" "$CALLS"
  [ "$output" = 0 ]
  grep -q "^Authorization: Bearer $FAKE_TOKEN$" "$CALLS.stdin"
}

@test "check: curl's own failures are named, not guessed at" {
  direct_server
  printf '#!/bin/sh\ncat >/dev/null\nexit "${FAKE_CURL_RC:-0}"\n' > "$BIN/curl"; chmod +x "$BIN/curl"
  run env FAKE_CURL_RC=6 "$RM" check web
  [[ "$output" == *"mcp:    unresolvable"* ]]
  run env FAKE_CURL_RC=7 "$RM" check web
  [[ "$output" == *"mcp:    unreachable"* ]]
  run env FAKE_CURL_RC=52 "$RM" check web
  [[ "$output" == *"mcp:    no response (curl exit 52)"* ]]
}

# --- the doctor ----------------------------------------------------------------------

# remote-mcp-doctor in a plain zsh. PATH is cut to the sandbox and the base
# system: the caller's own ~/bin holds a deployed remote-mcp on any machine
# that has applied this repo, and the "not deployed" test would find it.
doctor() {
  run zsh -c 'PATH="$HOME/bin:$2:/usr/bin:/bin"; source "$1"; remote-mcp-doctor' zsh "$BATS_TEST_DIRNAME/../dot_functions" "$BIN"
}

@test "remote-mcp-doctor: one status line with nothing configured, and it reads no token" {
  need_python3
  mkdir -p "$HOME/bin"
  ln -s "$RM" "$HOME/bin/remote-mcp"
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"script:  $HOME/bin/remote-mcp"* ]]
  [[ "$output" == *"no servers configured"* ]]
  [ "${#lines[@]}" -eq 4 ]

  direct_server
  doctor
  [[ "$output" == *"  web  https://mcp.example.test/mcp"* ]]
  [[ "$output" == *"$HOME/.claude: not connected"* ]]
  [ "$(calls op)" -eq 0 ]
}

@test "remote-mcp-doctor: says so when the script is not deployed" {
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"script:  NOT FOUND"* ]]
}
