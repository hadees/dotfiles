#!/usr/bin/env bats

# The work board's process: bin/executable_workboard and board.py, run against
# step 1's stub modules (wb_modules board: only board.py is real), a stub panel
# and stub launchctl/open/open-as/uname. Every server is started on a free port
# and ended in teardown; every wait polls. Fixture data only (see CLAUDE.md).

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
  printf '<!doctype html>\n<title>fixture</title>\n<p>board</p>\n' > "$WORKBOARD_HTML"
  STATE="$HOME/.local/state/workboard"
  CALLS="$WORKBOARD_DEMO/calls.log"
  SERVE_PID="" PANEL_PID=""
}

teardown() {
  export WORKBOARD_LAUNCHCTL=false
  "$WB" stop >/dev/null 2>&1 || true
  [ -z "$SERVE_PID" ] || kill "$SERVE_PID" 2>/dev/null || true
  [ -z "$PANEL_PID" ] || kill "$PANEL_PID" 2>/dev/null || true
  return 0
}

# hreq METHOD PATH [-H 'Name: value']... [-d body]: sets STATUS, HEADERS (lower-cased
# names), BODY. Call it plainly, not in $( ).
hreq() {
  rm -f "$BATS_TEST_TMPDIR"/resp.*
  $WB_PY - "$PORT" "$@" <<'PY' || return 1
import http.client, os, sys
port, method, path, rest = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4:]
headers, body = {}, None
while rest:
    if rest[0] == "-H":
        k, v = rest[1].split(": ", 1)
        headers[k] = v
    else:
        body = rest[1].encode()
    rest = rest[2:]
d = os.environ["BATS_TEST_TMPDIR"]
c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
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

wait_for() {
  local i
  for i in $(seq 1 100); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

# The server started and its first pass is in calls.log.
board_up() { hreq GET /health 2>/dev/null && [ "$STATUS" = 200 ] && grep -q '^github.poll' "$CALLS" 2>/dev/null; }
who_loaded() { hreq GET /status.json && [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["who"]["sessions"]')" -gt 0 ]; }

start_board() {
  run "$WB" start
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  wait_for board_up
}

# full_token / profile_token <dir>: the path token of that URL.
token_of() { sed -n 's|.*/b/\([0-9a-f]*\)/.*|\1|p'; }
full_token() { "$WB" url | token_of; }
profile_token() { CLAUDECODE=1 CLAUDE_CONFIG_DIR="$1" "$WB" url | token_of; }

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

@test "the socket is bound to loopback only" {
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
  [[ "$BODY" == *'"ok": true'* && "$BODY" == *'"fixture": false'* ]]
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
    app.route("GET", "/pane/broken", broken)
PY
  start_board
  hreq GET /health -H "Host: evil.example"
  [ "$STATUS" = 403 ] && [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["error"]')" = "bad host" ]
  hreq GET /health -H "Origin: http://evil.example"
  [ "$STATUS" = 403 ] && [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["error"]')" = "bad origin" ]
  hreq POST /api/url -H "Content-Length: 70000" -d '{}'
  [ "$STATUS" = 413 ] && [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["error"]')" = "bad body" ]
  hreq GET /pane/broken
  [ "$STATUS" = 500 ] && [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["error"]')" = "route failed" ]
  hreq GET "/b/$(full_token)/nope"
  [ "$STATUS" = 404 ] && [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["error"]')" = "not found" ]
  # the class is logged, the message is not
  grep -q 'route /pane/broken failed: RuntimeError' "$STATE/log"
  run ! grep -q 'do not leak' "$STATE/log"
}

@test "a wrong token is 403 and counted; anything else is 404" {
  start_board
  hreq GET /b/0000/board.json
  [ "$STATUS" = 403 ]
  hreq GET /b/1111/
  [ "$STATUS" = 403 ]
  hreq GET /nope
  [ "$STATUS" = 404 ]
  hreq GET /status.json
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["tally"]["token_rejects"]')" = 2 ]
}

@test "the full token serves both repositories; a profile's token only its own, with scope set" {
  start_board
  local full per
  full="$(full_token)"
  hreq GET "/b/$full/board.json"
  [ "$STATUS" = 200 ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'sorted(set(c["slug"] for c in d["cards"]))')" = "['octo-personal/proj-two', 'octo-work-org/proj-one']" ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["scope"]')" = None ]
  per="$(profile_token "$HOME/.claude-personal")"
  [ -n "$per" ] && [ "$per" != "$full" ]
  hreq GET "/b/$per/board.json"
  [ "$STATUS" = 200 ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'sorted(set(c["slug"] for c in d["cards"]))')" = "['octo-personal/proj-two']" ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["scope"]')" = "$HOME/.claude-personal" ]
}

@test "the page is the file with the panel's CSP; a missing file is 500 naming the path" {
  start_board
  local tok
  tok="$(full_token)"
  hreq GET "/b/$tok/"
  [ "$STATUS" = 200 ]
  [[ "$BODY" == *"<p>board</p>"* ]]
  [[ "$HEADERS" == *"content-security-policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'"* ]]
  rm "$WORKBOARD_HTML"
  hreq GET "/b/$tok/"
  [ "$STATUS" = 500 ]
  [[ "$BODY" == *"$WORKBOARD_HTML"* ]]
}

@test "board.json carries rev and build; If-None-Match is 304 until the board changes" {
  start_board
  local tok
  tok="$(full_token)"
  hreq GET "/b/$tok/board.json"
  [ "$STATUS" = 200 ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'type(d["rev"]).__name__')" = int ]
  [ -n "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["build"]')" ]
  local etag
  etag="$(sed -n 's/^etag: //p' "$BATS_TEST_TMPDIR/resp.headers")"
  [ -n "$etag" ]
  hreq GET "/b/$tok/board.json" -H "If-None-Match: $etag"
  [ "$STATUS" = 304 ]
  sed -i.bak 's/first queued idea/another queued idea/' "$WORKBOARD_DEMO/board.json"
  changed() { hreq GET "/b/$tok/board.json" -H "If-None-Match: $etag" && [ "$STATUS" = 200 ]; }
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
    app.route("GET", "/pane/links", links)
    app.route("GET", "/pane/poll", poll)
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
  hreq GET "/b/$tok/board.json"
  seen() { grep -q '^who.read' "$CALLS"; }
  wait_for seen
}

@test "at rest the GitHub passes stop, and the next request starts one at once" {
  export WORKBOARD_REST=1
  start_board
  [ "$(grep -c '^github.poll' "$CALLS")" = 1 ]
  paused() { hreq GET /status.json && [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["tally"].get("paused", 0)')" -ge 1 ]; }
  sleep 1.2
  wait_for paused
  [ "$(grep -c '^github.poll' "$CALLS")" = 1 ]
  hreq GET "/b/$(full_token)/board.json"
  two() { [ "$(grep -c '^github.poll' "$CALLS")" -ge 2 ]; }
  wait_for two
}

@test "/go: header, pid in scope, the panel's own call, and plain-text refusals" {
  start_panel
  start_board
  local tok per
  tok="$(full_token)"
  per="$(profile_token "$HOME/.claude-personal")"
  hreq GET "/b/$tok/board.json"
  wait_for who_loaded
  hreq POST "/b/$tok/go" -d pid=4102
  [ "$STATUS" = 403 ]
  hreq POST "/b/$tok/go" -H "X-Workboard: 1" -d pid=9999
  [ "$STATUS" = 404 ]
  hreq POST "/b/$tok/go" -H "X-Workboard: 1" -d pid=4102
  [ "$STATUS" = 200 ]
  [ "$(cat "$BATS_TEST_TMPDIR/panel.log")" = "/go 1 pid=4102" ]
  hreq POST "/b/$per/go" -H "X-Workboard: 1" -d pid=4102
  [ "$STATUS" = 404 ]
  [[ "$HEADERS" == *"content-type: text/plain"* ]]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/resp.body" | tr -d ' ')" = 1 ]
  hreq POST "/b/$per/go" -H "X-Workboard: 1" -d pid=4202
  [ "$STATUS" = 200 ]
  # a panel that does not answer is 502, said in one plain sentence
  kill "$PANEL_PID"
  wait "$PANEL_PID" 2>/dev/null || true
  PANEL_PID=""
  hreq POST "/b/$tok/go" -H "X-Workboard: 1" -d pid=4102
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
  hreq POST "/b/$tok/open" -d 'key=octo-work-org%2Fproj-one%2312'
  [ "$STATUS" = 403 ]
  hreq POST "/b/$tok/open" -H "X-Workboard: 1" -d 'key=octo-work-org%2Fproj-one%2312&url=https%3A%2F%2Fevil.example%2F'
  [ "$STATUS" = 200 ]
  [ "$(cat "$BATS_TEST_TMPDIR/open.log")" = "https://github.com/octo-work-org/proj-one/issues/12" ]
  # a card with no url, and a key that is no card
  hreq POST "/b/$tok/open" -H "X-Workboard: 1" -d 'key=octo-work-org%2Fproj-one~Q1'
  [ "$STATUS" = 404 ]
  [[ "$HEADERS" == *"content-type: text/plain"* ]]
  hreq POST "/b/$tok/open" -H "X-Workboard: 1" -d 'key=nothing'
  [ "$STATUS" = 404 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/open.log" | tr -d ' ')" = 1 ]
}

@test "--fixture serves the board, polls nothing, relays no click (409, plain text)" {
  $WB serve --port "$PORT" --fixture "$WORKBOARD_DEMO" > "$BATS_TEST_TMPDIR/serve.out" 2> "$BATS_TEST_TMPDIR/serve.err" 3>&- &
  SERVE_PID=$!
  up() { grep -q "^workboard: on http://127.0.0.1:$PORT/" "$BATS_TEST_TMPDIR/serve.out"; }
  wait_for up
  hreq GET /health
  [[ "$BODY" == *'"fixture": true'* ]]
  local tok
  tok="$(full_token)"
  hreq GET "/b/$tok/board.json"
  [ "$STATUS" = 200 ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'len(d["cards"])')" = 12 ]
  hreq POST "/b/$tok/go" -H "X-Workboard: 1" -d pid=4102
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

@test "touching a .py file in the module directory makes it replace itself, same pid, new build" {
  start_board
  hreq GET /health
  local pid build
  pid="$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["pid"]')"
  build="$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["build"]')"
  sleep 0.05
  : > "$WORKBOARD_LIBEXEC/zz_touched.py"
  rebuilt() { hreq GET /health 2>/dev/null && [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["build"]')" != "$build" ]; }
  local i ok=""
  for i in $(seq 1 30); do
    if rebuilt; then ok=1; break; fi
    sleep 0.1
  done
  [ -n "$ok" ] || { echo "the build did not change within three seconds"; false; }
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["pid"]')" = "$pid" ]
}

@test "start twice is one process, stop ends it, a second stop is exit 3" {
  start_board
  local first
  first="$(cat "$STATE/pid")"
  run "$WB" start
  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/pid")" = "$first" ]
  hreq GET /health
  [ "${first%% *}" = "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["pid"]')" ]
  run "$WB" stop
  [ "$status" -eq 0 ]
  run ! hreq GET /health
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
  hreq GET "/b/$(full_token)/board.json"
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

@test "url: the full token without CLAUDECODE; with it, the profile's, even when the secret cannot be read" {
  start_board
  local full per
  full="$(full_token)"
  [ "${#full}" = 32 ]
  run "$WB" url --repo proj-one
  [[ "$output" == "http://127.0.0.1:$PORT/b/$full/#r=proj-one" ]]
  run "$WB" url --group work
  [[ "$output" == "http://127.0.0.1:$PORT/b/$full/#g=work" ]]
  chmod 000 "$STATE/secret"
  run env CLAUDECODE=1 CLAUDE_CONFIG_DIR="$HOME/.claude-personal" "$WB" url
  chmod 600 "$STATE/secret"
  [ "$status" -eq 0 ]
  per="$(token_of <<< "$output")"
  [ "${#per}" = 32 ] && [ "$per" != "$full" ]
  hreq GET "/b/$per/board.json"
  [ "$STATUS" = 200 ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["scope"]')" = "$HOME/.claude-personal" ]
  # nothing running: exit 3
  "$WB" stop >/dev/null
  run -3 env CLAUDECODE=1 "$WB" url
  [ "$status" -eq 3 ]
}

@test "/api/url without the profile header is code 2" {
  start_board
  hreq POST /api/url -H "X-Workboard: 1" -d '{}'
  [ "$STATUS" = 200 ]
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["code"]')" = 2 ]
  hreq POST /api/url -H "X-Workboard: 1" -H "X-Workboard-Profile: /not/a/profile" -d '{}'
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["code"]')" = 2 ]
  hreq POST /api/url -H "X-Workboard-Profile: $HOME/.claude" -d '{}'
  [ "$STATUS" = 403 ]
}

@test "open passes iterm2 and the url, with the fragment for --repo; elsewhere than macOS it is exit 2" {
  printf '#!/bin/sh\necho Linux\n' > "$BATS_TEST_TMPDIR/bin/uname"
  chmod +x "$BATS_TEST_TMPDIR/bin/uname"
  run -2 "$WB" open
  [ "$status" -eq 2 ]
  printf '#!/bin/sh\necho Darwin\n' > "$BATS_TEST_TMPDIR/bin/uname"
  printf '#!/bin/sh\necho "$*" > "%s/open-as.log"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/open-as"
  chmod +x "$BATS_TEST_TMPDIR/open-as"
  export WORKBOARD_OPEN_AS="$BATS_TEST_TMPDIR/open-as"
  run "$WB" open --repo proj-one
  [ "$status" -eq 0 ]
  grep -Eq "^iterm2 http://127\.0\.0\.1:$PORT/b/[0-9a-f]{32}/#r=proj-one$" "$BATS_TEST_TMPDIR/open-as.log"
  hreq GET /health
  [ "$STATUS" = 200 ]
}

@test "verbs: a plug-in's api and cli verbs are served, and absent when the module is" {
  start_board
  hreq POST /api/list -d '{"dir": "/x"}'
  [ "$STATUS" = 403 ]
  hreq POST /api/list -H "X-Workboard: 1" -d '{"dir": "/x"}'
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" '(d["code"], d["text"])')" = "(0, 'list ok')" ]
  hreq POST /api/list -H "X-Workboard: 1" -d '{"dir": "/x", "nope": 1}'
  [ "$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["code"]')" = 2 ]
  run "$WB" list
  [ "$status" -eq 0 ]
  [ "$output" = "list ok" ]
  "$WB" stop >/dev/null
  rm "$WORKBOARD_LIBEXEC/verbs.py"
  start_board
  hreq POST /api/list -H "X-Workboard: 1" -d '{"dir": "/x"}'
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
    app.route("GET", "/pane", route)
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
  hreq GET /status.json
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
  hreq GET "/b/$(full_token)/board.json"
  [ "$STATUS" = 200 ]
}

@test "a pass that raises is counted and logged by class; no title reaches the state directory" {
  export WORKBOARD_STUB_RAISE=github.poll
  start_board
  hreq GET "/b/$(full_token)/board.json"
  wait_for who_loaded
  sleep 2.2
  grep -q 'pass github failed: RuntimeError' "$STATE/log"
  hreq GET /status.json
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
