#!/usr/bin/env bats

# The work board's process: bin/executable_workboard and board.py, run against
# step 1's stub modules (wb_modules board: only board.py is real), a stub panel
# and stub launchctl/open/open-as/uname. Every server is started on a free port
# and ended in teardown; every wait polls. Fixture data only (see CLAUDE.md).
# Two listeners: TCP (the page, with a key from /enter; a plug-in's routes, with a
# tool key) and a Unix socket under $WORKBOARD_RUNTIME (status, the verbs, the links).

bats_require_minimum_version 1.5.0

load helpers/workboard

setup() {
  wb_setup
  wb_demo >/dev/null
  wb_modules board >/dev/null
  WB="$WB_ROOT/bin/executable_workboard"
  PORT="$(wb_free_port)"
  PANEL_PORT="$(wb_free_port)"
  git config --file "$GIT_CONFIG_GLOBAL" workboard.port "$PORT"
  git config --file "$GIT_CONFIG_GLOBAL" workboard.panel-url "http://127.0.0.1:$PANEL_PORT"
  export WORKBOARD_TICK=0.1
  export WORKBOARD_LAUNCHCTL=false   # never the real agent
  export WORKBOARD_HTML="$BATS_TEST_TMPDIR/board.html"
  printf '<!doctype html>\n<head>\n<!--workboard:token-->\n<title>fixture</title>\n</head>\n<p>board</p>\n' > "$WORKBOARD_HTML"
  STATE="$HOME/.local/state/workboard"
  CALLS="$WORKBOARD_DEMO/calls.log"
  SERVE_PID="" PANEL_PID=""
}

teardown() {
  export WORKBOARD_LAUNCHCTL=false
  "$WB" stop >/dev/null 2>&1 || true
  [ -z "$SERVE_PID" ] || kill "$SERVE_PID" 2>/dev/null || true
  [ -z "$PANEL_PID" ] || kill "$PANEL_PID" 2>/dev/null || true
  wb_teardown
  return 0
}

# hreq [--local] METHOD PATH [-H 'Name: value']... [-d body]: sets STATUS, HEADERS
# (lower-cased names), BODY. --local speaks to the Unix socket, else TCP. Call it
# plainly, not in $( ): a $( ) keeps what it prints and loses the variables.
hreq() {
  local sock=""
  if [ "$1" = --local ]; then sock="$WORKBOARD_RUNTIME/workboard/$PORT.sock"; shift; fi
  rm -f "$BATS_TEST_TMPDIR"/resp.*
  $WB_PY - "$PORT" "$sock" "$@" <<'PY' || return 1
import http.client, os, socket, sys
port, sock, method, path, rest = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
headers, body = {}, None
while rest:
    if rest[0] == "-H":
        k, v = rest[1].split(": ", 1)
        headers[k] = v
    else:
        body = rest[1].encode()
    rest = rest[2:]
d = os.environ["BATS_TEST_TMPDIR"]
class Unix(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(10)
        self.sock.connect(sock)
c = Unix("localhost", timeout=10) if sock else http.client.HTTPConnection("127.0.0.1", port, timeout=10)
c.request(method, path, body=body, headers=headers)
r = c.getresponse()
data = r.read()
open(d + "/resp.status", "w").write(str(r.status))
open(d + "/resp.headers", "w").write("".join("%s: %s\n" % (k.lower(), v) for k, v in r.getheaders()))
open(d + "/resp.body", "wb").write(data)
PY
  STATUS="$(cat "$BATS_TEST_TMPDIR/resp.status")"
  HEADERS="$(cat "$BATS_TEST_TMPDIR/resp.headers")"
  BODY="$(cat "$BATS_TEST_TMPDIR/resp.body")"
}

# jget <file> <python expression of d>: prints it.
jget() {
  $WB_PY -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

# wait_for <command>...: polled, up to ten seconds (times TESTS_WAIT_SCALE).
wait_for() {
  local i
  for i in $(seq 1 $((100 * ${TESTS_WAIT_SCALE:-1}))); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

# The server started and its first pass is in calls.log.
board_up() { hreq GET /health 2>/dev/null && [ "$STATUS" = 200 ] && grep -q '^github.poll' "$CALLS" 2>/dev/null; }
who_loaded() { hreq --local GET /status.json && [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["who"]["sessions"]')" -gt 0 ]; }

start_board() {
  run "$WB" start
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  wait_for board_up
}

# link_token <link>: fetches the single-use link and prints the page token its
# answer holds in the meta tag. full_token / profile_token <dir> ask for a link first.
link_token() {
  local p="${1#http://127.0.0.1:$PORT}"
  hreq GET "${p%%#*}" || return 1
  [ "$STATUS" = 200 ] || return 1
  sed -n 's|.*<meta name="workboard-token" content="\([0-9a-f]*\)">.*|\1|p' <<< "$BODY"
}
full_token() { link_token "$("$WB" url)"; }
profile_token() { link_token "$(CLAUDECODE=1 CLAUDE_CONFIG_DIR="$1" "$WB" url)"; }
# tool_key <dir>: that profile's tool key, from the socket.
tool_key() {
  hreq --local POST /api/bearer -H "X-Workboard: 1" -H "X-Workboard-Profile: $1" -d '{}' || return 1
  jget "$BATS_TEST_TMPDIR/resp.body" 'd["text"]'
}
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

start_panel() {
  cat > "$BATS_TEST_TMPDIR/panel.py" <<'PY'
import http.server, os, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        open(sys.argv[2], "a").write("%s %s %s\n" % (self.path, self.headers.get("X-Claude-Tab"), body))
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(b'{"ok": true}')
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  $WB_PY "$BATS_TEST_TMPDIR/panel.py" "$PANEL_PORT" "$BATS_TEST_TMPDIR/panel.log" 3>&- &
  PANEL_PID=$!
  wait_for $WB_PY -c "import socket,sys; socket.create_connection(('127.0.0.1', $PANEL_PORT), 1)" 2>/dev/null
}

@test "the TCP listener is bound to loopback only" {
  start_board
  run $WB_PY - "$PORT" <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect(("192.0.2.1", 9))
    ip = s.getsockname()[0]
except OSError:
    ip = "127.0.0.1"
if ip.startswith("127."):
    print("none"); sys.exit(0)
c = socket.socket(); c.settimeout(2)
try:
    c.connect((ip, int(sys.argv[1]))); print("open")
except OSError:
    print("closed")
PY
  [ "$output" != none ] || skip "no non-loopback address to try"
  [ "$output" = closed ] || { echo "$output"; false; }
  hreq GET /health
  [ "$STATUS" = 200 ]
  [ "$BODY" = '{"ok": true}' ]
}

@test "a wrong Host is 403, a foreign Origin is 403, the server's own origin is served" {
  start_board
  hreq GET /health -H "Host: evil.example"
  [ "$STATUS" = 403 ]
  hreq GET /health -H "Host: localhost:$PORT"
  [ "$STATUS" = 200 ]
  hreq GET /health -H "Origin: http://evil.example"
  [ "$STATUS" = 403 ]
  hreq GET /health -H "Origin: http://127.0.0.1:$PORT"
  [ "$STATUS" = 200 ]
  [[ "$HEADERS" == *"cache-control: no-store"* && "$HEADERS" == *"x-content-type-options: nosniff"* ]]
}

@test "every refusal answers with a well-formed body: bad Host, foreign Origin, bad body, route failure" {
  cat > "$WORKBOARD_LIBEXEC/pane.py" <<'PY'
def register(app):
    def broken(req):
        raise RuntimeError("do not leak this message")
    app.route("GET", "/pane/broken", broken, open=True)
PY
  start_board
  hreq GET /health -H "Host: evil.example"
  [ "$STATUS" = 403 ] && [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["error"]')" = "bad host" ]
  hreq GET /health -H "Origin: http://evil.example"
  [ "$STATUS" = 403 ] && [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["error"]')" = "bad origin" ]
  hreq POST /api/url -H "Content-Length: 70000" -d '{}'
  [ "$STATUS" = 413 ] && [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["error"]')" = "bad body" ]
  # the socket answers 413 and closes before the body is sent; where the client can
  # still read the answer it is the same well-formed 413, where the platform resets
  # the connection first it is nothing, and either way the board answers the next request
  $WB_PY - "$WORKBOARD_RUNTIME/workboard/$PORT.sock" > "$BATS_TEST_TMPDIR/oversize" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(10)
s.connect(sys.argv[1])
got = b""
try:
    s.sendall(b"POST /api/url HTTP/1.1\r\nHost: localhost\r\nContent-Length: 70000\r\n\r\n" + b"{}" * 35000)
except OSError:
    pass
try:
    while chunk := s.recv(65536):
        got += chunk
except OSError:
    pass
sys.stdout.buffer.write(got)
PY
  if [ -s "$BATS_TEST_TMPDIR/oversize" ]; then
    head -n1 "$BATS_TEST_TMPDIR/oversize" | grep -q ' 413 '
    grep -q '"bad body"' "$BATS_TEST_TMPDIR/oversize"
  fi
  hreq GET /health
  [ "$STATUS" = 200 ]
  hreq GET /pane/broken
  [ "$STATUS" = 500 ] && [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["error"]')" = "route failed" ]
  hreq GET /b/nope
  [ "$STATUS" = 404 ] && [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["error"]')" = "not found" ]
  # the class is logged, the message is not
  grep -q 'route /pane/broken failed: RuntimeError' "$STATE/log"
  run ! grep -q 'do not leak' "$STATE/log"
}

@test "over TCP nothing token-less answers: status, the verbs and the links are 404, health is just ok" {
  start_board
  hreq GET /status.json
  [ "$STATUS" = 404 ]
  hreq POST /api/url -H "X-Workboard: 1" -H "X-Workboard-Profile: $HOME/.claude" -d '{}'
  [ "$STATUS" = 404 ]
  hreq POST /api/bearer -H "X-Workboard: 1" -H "X-Workboard-Profile: $HOME/.claude" -d '{}'
  [ "$STATUS" = 404 ]
  hreq POST /api/list -H "X-Workboard: 1" -d '{"dir": "/x"}'
  [ "$STATUS" = 404 ]
  hreq GET /health
  [ "$STATUS" = 200 ]
  [ "$BODY" = '{"ok": true}' ]
}

@test "over the socket: health has pid and build, status is as before, a verb answers" {
  start_board
  hreq --local GET /health
  [ "$STATUS" = 200 ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'sorted(d)')" = "['build', 'fixture', 'ok', 'pid']" ]
  hreq --local GET /status.json
  [ "$STATUS" = 200 ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'sorted(d)[:3]')" = "['cards', 'github', 'inbox']" ]
  hreq --local POST /api/list -H "X-Workboard: 1" -d '{"dir": "/x"}'
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" '(d["code"], d["text"])')" = "(0, 'list ok')" ]
  hreq --local GET /nope
  [ "$STATUS" = 404 ]
}

@test "the socket's directory is 0700 and the socket 0600; a directory open to others stops the server" {
  start_board
  [ "$(mode_of "$WORKBOARD_RUNTIME/workboard")" = 700 ]
  [ "$(mode_of "$WORKBOARD_RUNTIME/workboard/$PORT.sock")" = 600 ]
  "$WB" stop >/dev/null
  [ ! -e "$WORKBOARD_RUNTIME/workboard/$PORT.sock" ]
  chmod 755 "$WORKBOARD_RUNTIME/workboard"
  run -1 "$WB" serve --port "$PORT"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" = 1 ]
  [[ "$output" == *"$WORKBOARD_RUNTIME/workboard"* ]]
  run -1 "$WB" start
  [ "$status" -eq 1 ]
}

@test "a socket path over 100 bytes is one line naming it and exit 1" {
  local long="$WORKBOARD_RUNTIME/$(printf 'x%.0s' $(seq 1 120))"
  run -1 env WORKBOARD_RUNTIME="$long" "$WB" serve --port "$PORT"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" = 1 ]
  [[ "$output" == *"$long/workboard/$PORT.sock"* ]]
}

@test "a stale socket file is replaced; one that still answers is already running" {
  mkdir -m 700 "$WORKBOARD_RUNTIME/workboard"
  local sock="$WORKBOARD_RUNTIME/workboard/$PORT.sock"
  $WB_PY -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$sock"
  [ -S "$sock" ]
  start_board
  hreq --local GET /health
  [ "$STATUS" = 200 ]
  "$WB" stop >/dev/null
  $WB_PY -c 'import socket, sys, time; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(16); time.sleep(60)' "$sock" 3>&- &
  SERVE_PID=$!
  live() { $WB_PY -c "import socket; socket.socket(socket.AF_UNIX).connect('$sock')" 2>/dev/null; }
  wait_for live
  run -1 "$WB" serve --port "$PORT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already running"* ]]
}

@test "a wrong token is 403 and counted; the old path form and anything else is 404" {
  start_board
  hreq GET /b/board.json
  [ "$STATUS" = 403 ]
  hreq GET /b/board.json -H "Authorization: Bearer 0000"
  [ "$STATUS" = 403 ]
  hreq GET /b/board.json -H "Authorization: Bearer $(full_token)x"
  [ "$STATUS" = 403 ]
  hreq GET "/b/$(full_token)/board.json" -H "Authorization: Bearer $(full_token)"
  [ "$STATUS" = 404 ]
  hreq GET "/b/$(full_token)/"
  [ "$STATUS" = 404 ]
  hreq GET /nope
  [ "$STATUS" = 404 ]
  hreq --local GET /status.json
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["tally"]["token_rejects"]')" = 3 ]
}

@test "the full token serves both repositories; a profile's token only its own, with scope set" {
  start_board
  local full per
  full="$(full_token)"
  hreq GET /b/board.json -H "Authorization: Bearer $full"
  [ "$STATUS" = 200 ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'sorted(set(c["slug"] for c in d["cards"]))')" = "['octo-personal/proj-two', 'octo-work-org/proj-one']" ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["scope"]')" = None ]
  per="$(profile_token "$HOME/.claude-personal")"
  [ -n "$per" ] && [ "$per" != "$full" ]
  hreq GET /b/board.json -H "Authorization: Bearer $per"
  [ "$STATUS" = 200 ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'sorted(set(c["slug"] for c in d["cards"]))')" = "['octo-personal/proj-two']" ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["scope"]')" = "$HOME/.claude-personal" ]
}

@test "/b/ is the page with the marker gone and no key; the link's answer holds the key in the meta tag" {
  start_board
  hreq GET /b/
  [ "$STATUS" = 200 ]
  [[ "$BODY" == *"<p>board</p>"* ]]
  [[ "$BODY" != *workboard-token* && "$BODY" != *"workboard:token"* ]]
  [[ "$HEADERS" == *"content-security-policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'"* ]]
  local tok
  tok="$(full_token)"
  [ "${#tok}" = 32 ]
  hreq GET "/enter/$(basename "$("$WB" url)")"
  [ "$STATUS" = 200 ]
  [[ "$BODY" == *'<head>'$'\n''<meta name="workboard-token" content="'* && "$BODY" != *"workboard:token"* ]]
  rm "$WORKBOARD_HTML"
  hreq GET /b/
  [ "$STATUS" = 500 ]
  [[ "$BODY" == *"$WORKBOARD_HTML"* ]]
  printf '<!doctype html>\n<p>no marker</p>\n' > "$WORKBOARD_HTML"
  hreq GET "/enter/$(basename "$("$WB" url)")"
  [ "$STATUS" = 500 ]
  [[ "$BODY" == *"<!--workboard:token-->"* ]]
}

@test "board.json carries rev and build; If-None-Match is 304 until the board changes" {
  start_board
  local tok
  tok="$(full_token)"
  hreq GET /b/board.json -H "Authorization: Bearer $tok"
  [ "$STATUS" = 200 ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'type(d["rev"]).__name__')" = int ]
  [ -n "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["build"]')" ]
  local etag
  etag="$(sed -n 's/^etag: //p' "$BATS_TEST_TMPDIR/resp.headers")"
  [ -n "$etag" ]
  hreq GET /b/board.json -H "Authorization: Bearer $tok" -H "If-None-Match: $etag"
  [ "$STATUS" = 304 ]
  sed -i.bak 's/first queued idea/another queued idea/' "$WORKBOARD_DEMO/board.json"
  changed() { hreq GET /b/board.json -H "Authorization: Bearer $tok" -H "If-None-Match: $etag" && [ "$STATUS" = 200 ]; }
  wait_for changed
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["rev"]')" -gt 1 ]
}

@test "the clocks: poll has prior after the first pass and only when asked, local gets links.tsv, who waits for a viewer" {
  mkdir -p "$STATE"
  printf 'octo-work-org/proj-one\t11\t/x/wt\t1799999999\n' > "$STATE/links.tsv"
  cat > "$WORKBOARD_LIBEXEC/pane.py" <<'PY'
import json
def register(app):
    def links(req):
        return 200, {"Content-Type": "application/json"}, json.dumps(app.ctx.local()["links"]).encode()
    def poll(req):
        app.ctx.poll_now("work-acct")
        return 200, {"Content-Type": "text/plain"}, b"ok\n"
    app.route("GET", "/pane/links", links, open=True)
    app.route("GET", "/pane/poll", poll, open=True)
PY
  start_board
  grep -qx 'github.poll local budget now' "$CALLS"
  grep -q '^local.read links also now$' "$CALLS"
  hreq GET /pane/links
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd[0]["slug"] + " " + str(d[0]["number"]) + " " + str(d[0]["at"])')" = "octo-work-org/proj-one 11 1799999999" ]
  # ten ticks and more with no page request: nobody reads the panel
  sleep 1.5
  run ! grep -q '^who.read' "$CALLS"
  hreq GET /pane/poll
  [ "$STATUS" = 200 ]
  polled() { grep -qx 'github.poll local prior budget now only' "$CALLS"; }
  wait_for polled
  local tok
  tok="$(full_token)"
  hreq GET /b/board.json -H "Authorization: Bearer $tok"
  seen() { grep -q '^who.read' "$CALLS"; }
  wait_for seen
}

@test "at rest the GitHub passes stop, and the next request starts one at once" {
  export WORKBOARD_REST=1
  start_board
  [ "$(grep -c '^github.poll' "$CALLS")" = 1 ]
  paused() { hreq --local GET /status.json && [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["tally"].get("paused", 0)')" -ge 1 ]; }
  sleep 1.2
  wait_for paused
  [ "$(grep -c '^github.poll' "$CALLS")" = 1 ]
  hreq GET /b/board.json -H "Authorization: Bearer $(full_token)"
  two() { [ "$(grep -c '^github.poll' "$CALLS")" -ge 2 ]; }
  wait_for two
}

@test "/go: header, pid in scope, the panel's own call, and plain-text refusals" {
  start_panel
  start_board
  local tok per
  tok="$(full_token)"
  per="$(profile_token "$HOME/.claude-personal")"
  hreq GET /b/board.json -H "Authorization: Bearer $tok"
  wait_for who_loaded
  hreq POST /b/go -H "Authorization: Bearer $tok" -d pid=4102
  [ "$STATUS" = 403 ]
  hreq POST /b/go -H "X-Workboard: 1" -d pid=4102
  [ "$STATUS" = 403 ]
  hreq POST /b/go -H "Authorization: Bearer $tok" -H "X-Workboard: 1" -d pid=9999
  [ "$STATUS" = 404 ]
  hreq POST /b/go -H "Authorization: Bearer $tok" -H "X-Workboard: 1" -d pid=4102
  [ "$STATUS" = 200 ]
  [ "$(cat "$BATS_TEST_TMPDIR/panel.log")" = "/go 1 pid=4102" ]
  hreq POST /b/go -H "Authorization: Bearer $per" -H "X-Workboard: 1" -d pid=4102
  [ "$STATUS" = 404 ]
  [[ "$HEADERS" == *"content-type: text/plain"* ]]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/resp.body" | tr -d ' ')" = 1 ]
  hreq POST /b/go -H "Authorization: Bearer $per" -H "X-Workboard: 1" -d pid=4202
  [ "$STATUS" = 200 ]
  # a panel that does not answer is 502, said in one plain sentence
  kill "$PANEL_PID"
  wait "$PANEL_PID" 2>/dev/null || true
  PANEL_PID=""
  hreq POST /b/go -H "Authorization: Bearer $tok" -H "X-Workboard: 1" -d pid=4102
  [ "$STATUS" = 502 ]
  [[ "$HEADERS" == *"content-type: text/plain"* ]]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/resp.body" | tr -d ' ')" = 1 ]
}

@test "/open runs the opener with the card's own url and nothing from the body" {
  printf '#!/bin/sh\necho "$*" >> "%s/open.log"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/opener"
  chmod +x "$BATS_TEST_TMPDIR/opener"
  export WORKBOARD_OPEN="$BATS_TEST_TMPDIR/opener"
  start_board
  local tok
  tok="$(full_token)"
  hreq POST /b/open -H "Authorization: Bearer $tok" -d 'key=octo-work-org%2Fproj-one%2312'
  [ "$STATUS" = 403 ]
  hreq POST /b/open -H "Authorization: Bearer $tok" -H "X-Workboard: 1" -d 'key=octo-work-org%2Fproj-one%2312&url=https%3A%2F%2Fevil.example%2F'
  [ "$STATUS" = 200 ]
  [ "$(cat "$BATS_TEST_TMPDIR/open.log")" = "https://github.com/octo-work-org/proj-one/issues/12" ]
  # a card with no url, and a key that is no card
  hreq POST /b/open -H "Authorization: Bearer $tok" -H "X-Workboard: 1" -d 'key=octo-work-org%2Fproj-one~Q1'
  [ "$STATUS" = 404 ]
  [[ "$HEADERS" == *"content-type: text/plain"* ]]
  hreq POST /b/open -H "Authorization: Bearer $tok" -H "X-Workboard: 1" -d 'key=nothing'
  [ "$STATUS" = 404 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/open.log" | tr -d ' ')" = 1 ]
  hreq POST /b/open -H "X-Workboard: 1" -d 'key=octo-work-org%2Fproj-one%2312'
  [ "$STATUS" = 403 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/open.log" | tr -d ' ')" = 1 ]
}

@test "--fixture serves the board, polls nothing, relays no click (409, plain text)" {
  $WB serve --port "$PORT" --fixture "$WORKBOARD_DEMO" > "$BATS_TEST_TMPDIR/serve.out" 2> "$BATS_TEST_TMPDIR/serve.err" 3>&- &
  SERVE_PID=$!
  up() { grep -q "^workboard: on http://127.0.0.1:$PORT/" "$BATS_TEST_TMPDIR/serve.out"; }
  wait_for up
  hreq --local GET /health
  [[ "$BODY" == *'"fixture": true'* ]]
  local tok
  tok="$(full_token)"
  hreq GET /b/board.json -H "Authorization: Bearer $tok"
  [ "$STATUS" = 200 ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'len(d["cards"])')" = 12 ]
  hreq POST /b/go -H "Authorization: Bearer $tok" -H "X-Workboard: 1" -d pid=4102
  [ "$STATUS" = 409 ]
  [[ "$HEADERS" == *"content-type: text/plain"* ]]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/resp.body" | tr -d ' ')" = 1 ]
  run ! grep -q '^github.poll' "$CALLS"
}

@test "a port in use is one line and exit 1" {
  start_board
  run -1 "$WB" serve --port "$PORT"
  [ "$status" -eq 1 ]
  [ "$output" = "workboard: port $PORT is in use" ]
}

@test "touching a .py file in the module directory makes it replace itself: same pid, new build, the socket and a token still serve" {
  start_board
  local tok pid build
  tok="$(full_token)"
  hreq --local GET /health
  pid="$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["pid"]')"
  build="$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["build"]')"
  sleep 0.05
  : > "$WORKBOARD_LIBEXEC/zz_touched.py"
  rebuilt() { hreq --local GET /health 2>/dev/null && [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["build"]')" != "$build" ]; }
  local i ok=""
  for i in $(seq 1 30); do
    if rebuilt; then ok=1; break; fi
    sleep 0.1
  done
  [ -n "$ok" ] || { echo "the build did not change within three seconds"; false; }
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["pid"]')" = "$pid" ]
  hreq GET /b/board.json -H "Authorization: Bearer $tok"
  [ "$STATUS" = 200 ]
}

@test "start twice is one process, stop ends it and takes its socket away, a second stop is exit 3" {
  start_board
  local first
  first="$(cat "$STATE/pid")"
  run "$WB" start
  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/pid")" = "$first" ]
  hreq --local GET /health
  [ "${first%% *}" = "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["pid"]')" ]
  run "$WB" stop
  [ "$status" -eq 0 ]
  run ! hreq GET /health
  run ! hreq --local GET /health
  [ ! -e "$WORKBOARD_RUNTIME/workboard/$PORT.sock" ]
  run -3 "$WB" stop
  [ "$status" -eq 3 ]
}

@test "with a loaded launchd agent start, stop and restart go through launchctl and start nothing" {
  cat > "$BATS_TEST_TMPDIR/bin/launchctl" <<EOF
#!/bin/sh
echo "\$*" >> "$BATS_TEST_TMPDIR/launchctl.log"
case "\$1" in
  print) [ -e "$BATS_TEST_TMPDIR/loaded" ] ;;
  bootout) rm -f "$BATS_TEST_TMPDIR/loaded" ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/launchctl"
  : > "$BATS_TEST_TMPDIR/loaded"
  export WORKBOARD_LAUNCHCTL="$BATS_TEST_TMPDIR/bin/launchctl"
  local target="gui/$(id -u)/local.workboard"
  run "$WB" start
  [ "$status" -eq 0 ]
  run "$WB" restart
  [ "$status" -eq 0 ]
  run "$WB" stop
  [ "$status" -eq 0 ]
  grep -qx "kickstart $target" "$BATS_TEST_TMPDIR/launchctl.log"
  grep -qx "kickstart -k $target" "$BATS_TEST_TMPDIR/launchctl.log"
  grep -qx "bootout $target" "$BATS_TEST_TMPDIR/launchctl.log"
  run ! hreq GET /health
  [ ! -e "$STATE/pid" ]
}

@test "status prints its lines and none of the scenario's titles, labels or repository names" {
  start_board
  hreq GET /b/board.json -H "Authorization: Bearer $(full_token)"
  wait_for who_loaded
  run "$WB" status
  [ "$status" -eq 0 ]
  local word
  for word in server github local who inbox cards needs tally; do
    grep -q "^$word:" <<< "$output" || { echo "no $word: line in: $output"; false; }
  done
  grep -q '^needs: 2 (panel: 2)$' <<< "$output"
  while IFS= read -r word; do
    [[ "$output" != *"$word"* ]] || { echo "status holds: $word"; false; }
  done < <($WB_PY -c '
import json, sys
d = json.load(open(sys.argv[1]))
for c in d["cards"]:
    print(c["title"])
    for l in c["labels"]:
        print(l)
for r in d["repos"]:
    print(r["name"])
' "$WORKBOARD_DEMO/board.json")
}

@test "status with nothing running says so, exit 3" {
  run -3 "$WB" status
  [ "$status" -eq 3 ]
  [ "$output" = "server: not running" ]
}

@test "url prints a single-use link: nothing running is exit 3, no hex key in it, a fragment for --repo and --group" {
  run -3 "$WB" url
  [ "$status" -eq 3 ]
  start_board
  run "$WB" url
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^http://127\.0\.0\.1:$PORT/enter/[A-Za-z0-9_-]{24,}$ ]]
  run ! grep -Eq '[0-9a-f]{32}' <<< "$output"
  run "$WB" url --repo proj-one
  [[ "$output" =~ ^http://127\.0\.0\.1:$PORT/enter/[A-Za-z0-9_-]{24,}#r=proj-one$ ]]
  run "$WB" url --group work
  [[ "$output" =~ ^http://127\.0\.0\.1:$PORT/enter/[A-Za-z0-9_-]{24,}#g=work$ ]]
  "$WB" stop >/dev/null
  run -3 env CLAUDECODE=1 "$WB" url
  [ "$status" -eq 3 ]
}

@test "a link is good once: the first fetch serves the page with the key and its headers, the second is 403 and counted" {
  start_board
  local link p
  link="$("$WB" url)"
  p="${link#http://127.0.0.1:$PORT}"
  hreq GET "$p"
  [ "$STATUS" = 200 ]
  [[ "$BODY" =~ \<meta\ name=\"workboard-token\"\ content=\"[0-9a-f]{32}\"\> ]]
  [[ "$BODY" != *"workboard:token"* ]]
  [[ "$HEADERS" == *"content-security-policy: default-src 'none'"* ]]
  [[ "$HEADERS" == *"cache-control: no-store"* && "$HEADERS" == *"referrer-policy: no-referrer"* ]]
  local tok
  tok="$(sed -n 's|.*content="\([0-9a-f]*\)".*|\1|p' <<< "$BODY")"
  hreq GET /b/board.json -H "Authorization: Bearer $tok"
  [ "$STATUS" = 200 ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'sorted(set(c["slug"] for c in d["cards"]))')" = "['octo-personal/proj-two', 'octo-work-org/proj-one']" ]
  hreq GET "$p"
  [ "$STATUS" = 403 ]
  [ "$BODY" = "This link has been used or has expired. Run workboard open again." ]
  [[ "$HEADERS" == *"content-type: text/plain"* ]]
  hreq GET /enter/nothing
  [ "$STATUS" = 403 ]
  hreq --local GET /status.json
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["tally"]["enter_rejects"]')" = 2 ]
}

@test "a link expires after WORKBOARD_NONCE_TTL, and the 65th link asked for drops the first" {
  export WORKBOARD_NONCE_TTL=1
  start_board
  local link
  link="$("$WB" url)"
  sleep 2
  hreq GET "${link#http://127.0.0.1:$PORT}"
  [ "$STATUS" = 403 ]
  "$WB" stop >/dev/null
  export WORKBOARD_NONCE_TTL=60
  start_board
  local first last i
  first="$("$WB" url)"
  for i in $(seq 1 63); do "$WB" url >/dev/null; done
  # 64 are waiting: the first is still good
  last="$("$WB" url)"
  hreq GET "${first#http://127.0.0.1:$PORT}"
  [ "$STATUS" = 403 ]
  hreq GET "${last#http://127.0.0.1:$PORT}"
  [ "$STATUS" = 200 ]
}

@test "in a session the link is the profile's, even when the secret cannot be read; outside one an unreadable secret is one line" {
  start_board
  chmod 000 "$STATE/secret"
  local unreadable=1
  # root (the CI containers) and WSL's drvfs read through a mode 000
  if head -c1 "$STATE/secret" >/dev/null 2>&1; then unreadable=0; fi
  run env CLAUDECODE=1 CLAUDE_CONFIG_DIR="$HOME/.claude-personal" "$WB" url
  [ "$status" -eq 0 ]
  local per
  per="$(link_token "$output")"
  [ "${#per}" = 32 ]
  hreq GET /b/board.json -H "Authorization: Bearer $per"
  [ "$STATUS" = 200 ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["scope"]')" = "$HOME/.claude-personal" ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'sorted(set(c["slug"] for c in d["cards"]))')" = "['octo-personal/proj-two']" ]
  if [ "$unreadable" = 0 ]; then
    chmod 600 "$STATE/secret"
    skip "chmod 000 does not make the secret unreadable here (root or a filesystem that ignores modes)"
  fi
  run -1 "$WB" url
  chmod 600 "$STATE/secret"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" = 1 ]
}

@test "/api/url on the socket: no profile header and no proof is code 2, a wrong proof is code 2, a bad profile is code 2" {
  start_board
  hreq --local POST /api/url -H "X-Workboard: 1" -d '{}'
  [ "$STATUS" = 200 ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["code"]')" = 2 ]
  hreq --local POST /api/url -H "X-Workboard: 1" -H "X-Workboard-Ask: 00000000000000000000000000000000" -d '{}'
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["code"]')" = 2 ]
  hreq --local POST /api/url -H "X-Workboard: 1" -H "X-Workboard-Profile: /not/a/profile" -d '{}'
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["code"]')" = 2 ]
  hreq --local POST /api/url -H "X-Workboard-Profile: $HOME/.claude" -d '{}'
  [ "$STATUS" = 403 ]
  hreq --local POST /api/bearer -H "X-Workboard: 1" -d '{}'
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["code"]')" = 2 ]
}

@test "a plug-in's gated route needs a tool key, an open one nothing; ctx.ask answers from a route and from status" {
  cat > "$WORKBOARD_LIBEXEC/pane.py" <<'PY'
def register(app):
    def who(req):
        return 200, {"Content-Type": "text/plain"}, (req.profile or "none").encode()
    def asks(req):
        code, text = app.ctx.ask("list", {"dir": "/x"})
        return 200, {"Content-Type": "text/plain"}, ("%d %s" % (code, text)).encode()
    app.route("GET", "/pane/gated", who)
    app.route("GET", "/pane/open", who, open=True)
    app.route("GET", "/pane/ask", asks, open=True)
    app.status("asked", lambda: {"code": app.ctx.ask("list", {"dir": "/x"})[0]})
    app.command("ask-list", lambda argv: print(app.ctx.ask("list", {"dir": "/x"})) or 0)
PY
  start_board
  local per key
  per="$HOME/.claude-personal"
  hreq GET /pane/gated
  [ "$STATUS" = 403 ]
  hreq GET /pane/gated -H "Authorization: Bearer $(full_token)"
  [ "$STATUS" = 403 ]
  hreq GET /pane/gated -H "Authorization: Bearer $(profile_token "$per")"
  [ "$STATUS" = 403 ]
  key="$(tool_key "$per")"
  [ "${#key}" = 32 ]
  hreq GET /pane/gated -H "Authorization: Bearer $key"
  [ "$STATUS" = 200 ] && [ "$BODY" = "$per" ]
  hreq GET /pane/gated -H "Authorization: Bearer ${key}0"
  [ "$STATUS" = 403 ]
  hreq GET /pane/open
  [ "$STATUS" = 200 ] && [ "$BODY" = none ]
  hreq GET /b/board.json -H "Authorization: Bearer $key"
  [ "$STATUS" = 403 ]
  hreq --local GET /status.json
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["tally"]["token_rejects"]')" = 5 ]
  # a route and a status entry asking the server's own socket from inside a handler: no deadlock
  hreq GET /pane/ask
  [ "$STATUS" = 200 ] && [ "$BODY" = "0 list ok" ]
  hreq --local GET /status.json
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["asked"]["code"]')" = 0 ]
  run "$WB" ask-list
  [ "$status" -eq 0 ]
  [ "$output" = "(0, 'list ok')" ]
  "$WB" stop >/dev/null
  run "$WB" ask-list
  [ "$output" = "(3, 'workboard: not running')" ]
}

@test "open passes iterm2 and a single-use link, with the fragment for --repo, and no key in its arguments; elsewhere than macOS it is exit 2" {
  printf '#!/bin/sh\necho Linux\n' > "$BATS_TEST_TMPDIR/bin/uname"
  chmod +x "$BATS_TEST_TMPDIR/bin/uname"
  run -2 "$WB" open
  [ "$status" -eq 2 ]
  printf '#!/bin/sh\necho Darwin\n' > "$BATS_TEST_TMPDIR/bin/uname"
  printf '#!/bin/sh\necho "$*" > "%s/open-as.log"\nps -axo args= > "%s/ps.log"\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/open-as"
  chmod +x "$BATS_TEST_TMPDIR/open-as"
  export WORKBOARD_OPEN_AS="$BATS_TEST_TMPDIR/open-as"
  run "$WB" open --repo proj-one
  [ "$status" -eq 0 ]
  grep -Eq "^iterm2 http://127\.0\.0\.1:$PORT/enter/[A-Za-z0-9_-]{24,}#r=proj-one$" "$BATS_TEST_TMPDIR/open-as.log"
  run ! grep -Eq '[0-9a-f]{32}' "$BATS_TEST_TMPDIR/open-as.log"
  hreq GET /health
  [ "$STATUS" = 200 ]
}

@test "no token is in the log, in status, in the process list while open runs, or in the state directory" {
  printf '#!/bin/sh\necho Darwin\n' > "$BATS_TEST_TMPDIR/bin/uname"
  printf '#!/bin/sh\necho "$*" > "%s/open-as.log"\nps -axo args= > "%s/ps.log"\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/open-as"
  chmod +x "$BATS_TEST_TMPDIR/bin/uname" "$BATS_TEST_TMPDIR/open-as"
  export WORKBOARD_OPEN_AS="$BATS_TEST_TMPDIR/open-as"
  start_board
  local full per key
  full="$(full_token)"
  per="$(profile_token "$HOME/.claude-personal")"
  key="$(tool_key "$HOME/.claude-personal")"
  [ -n "$full" ] && [ -n "$per" ] && [ -n "$key" ]
  hreq GET /b/board.json -H "Authorization: Bearer $full"
  [ "$STATUS" = 200 ]
  run "$WB" open
  [ "$status" -eq 0 ]
  run "$WB" status
  [ "$status" -eq 0 ]
  hreq --local GET /status.json
  local tok
  for tok in "$full" "$per" "$key"; do
    run ! grep -rqF -- "$tok" "$STATE"
    run ! grep -qF -- "$tok" "$BATS_TEST_TMPDIR/ps.log"
    [[ "$BODY" != *"$tok"* ]]
  done
  [ -s "$BATS_TEST_TMPDIR/ps.log" ]
}

@test "verbs: a plug-in's api and cli verbs are served on the socket, and absent when the module is" {
  start_board
  hreq --local POST /api/list -d '{"dir": "/x"}'
  [ "$STATUS" = 403 ]
  hreq --local POST /api/list -H "X-Workboard: 1" -d '{"dir": "/x"}'
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" '(d["code"], d["text"])')" = "(0, 'list ok')" ]
  hreq --local POST /api/list -H "X-Workboard: 1" -d '{"dir": "/x", "nope": 1}'
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["code"]')" = 2 ]
  run "$WB" list
  [ "$status" -eq 0 ]
  [ "$output" = "list ok" ]
  "$WB" stop >/dev/null
  rm "$WORKBOARD_LIBEXEC/verbs.py"
  start_board
  hreq --local POST /api/list -H "X-Workboard: 1" -d '{"dir": "/x"}'
  [ "$STATUS" = 404 ]
  run "$WB" list
  [ "$status" -eq 2 ]
}

@test "a plug-in's route, command, status entry and after_github callback are each used; one that raises is counted" {
  export PANE_LOG="$BATS_TEST_TMPDIR/pane.log"
  cat > "$WORKBOARD_LIBEXEC/pane.py" <<'PY'
import os
def register(app):
    def route(req):
        app.ctx.count("pane_hit")
        return 200, {"Content-Type": "text/plain"}, b"pane " + req.method.encode() + b"\n"
    app.route("GET", "/pane", route, open=True)
    app.command("pane-cmd", lambda argv: print("ran " + " ".join(argv)) or 7)
    app.status("pane", lambda: {"hits": 1, "mode": "fixed"})
    def after(ctx, board, previous):
        open(os.environ["PANE_LOG"], "a").write("after %d\n" % len(board["cards"]))
    app.after_github(after)
PY
  printf 'raise RuntimeError("boom")\n' > "$WORKBOARD_LIBEXEC/notice.py"
  start_board
  hreq GET /pane
  [ "$STATUS" = 200 ] && [ "$BODY" = "pane GET" ]
  after_ran() { grep -qx 'after 12' "$PANE_LOG"; }
  wait_for after_ran
  hreq --local GET /status.json
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["pane"]["hits"]')" = 1 ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["tally"]["pane_hit"]')" = 1 ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["plugins"]')" = "['verbs', 'pane']" ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["plugin_errors"]')" = 1 ]
  run --separate-stderr "$WB" pane-cmd a b
  [ "$status" -eq 7 ]
  [ "$output" = "ran a b" ]
  run "$WB" status
  grep -q '^pane: hits 1 · mode fixed$' <<< "$output"
  # the board is still served
  hreq GET /b/board.json -H "Authorization: Bearer $(full_token)"
  [ "$STATUS" = 200 ]
}

@test "a pass that raises is counted and logged by class; no title reaches the state directory" {
  export WORKBOARD_STUB_RAISE=github.poll
  start_board
  hreq GET /b/board.json -H "Authorization: Bearer $(full_token)"
  wait_for who_loaded
  sleep 2.2
  grep -q 'pass github failed: RuntimeError' "$STATE/log"
  hreq --local GET /status.json
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["tally"]["pass_errors"]')" -ge 1 ]
  "$WB" stop >/dev/null
  local title
  while IFS= read -r title; do
    run ! grep -rqF -- "$title" "$STATE"
  done < <($WB_PY -c '
import json, sys
for c in json.load(open(sys.argv[1]))["cards"]:
    print(c["title"])
' "$WORKBOARD_DEMO/board.json")
  [ -f "$STATE/tally.json" ]
  [ "$(stat -c %a "$STATE" 2>/dev/null || stat -f %Lp "$STATE")" = 700 ]
  [ "$(stat -c %a "$STATE/secret" 2>/dev/null || stat -f %Lp "$STATE/secret")" = 600 ]
}

@test "an unknown verb and no verb are exit 2" {
  run -2 "$WB" bogus
  [ "$status" -eq 2 ]
  run -2 "$WB"
  [ "$status" -eq 2 ]
}

@test "the entry script parses as sh and the Python parses on 3.9" {
  sh -n "$WB"
  /usr/bin/python3 -I -B -c 'import ast,sys; [ast.parse(open(f).read()) for f in sys.argv[1:]]' "$WB_SRC/board.py"
}

@test "nothing in this file wrote a __pycache__ into the module directory" {
  wb_no_pycache
}
