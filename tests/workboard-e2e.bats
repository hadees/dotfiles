#!/usr/bin/env bats

# The work board's real parts together, read only: board.py, model.py,
# github.py, local.py, who.py and inbox.py (wb_modules names every one), run by
# bin/executable_workboard. Only the outside is stubbed: `gh` on WORKBOARD_GH
# (it answers from the recorded GraphQL responses), `worktabs` and
# `claude-peer`, and the claude-tab panel, a python server on a free port that
# serves a snapshot file the test rewrites. Repositories are real git, with a
# linked worktree on the head branch of a fixture pull request, and the
# registries are files under the sandbox HOME. A red test here is two parts
# reading a contract differently; the step that is wrong is revised, not
# patched here. Fixture data only (see CLAUDE.md): invented owners, accounts and
# titles.

bats_require_minimum_version 1.5.0

load helpers/workboard

setup() {
  wb_setup
  unset GH_TOKEN GITHUB_TOKEN GH_NO_TOKEN
  wb_modules board model github local who inbox verbs >/dev/null
  WB="$WB_ROOT/bin/executable_workboard"
  PORT="$(wb_free_port)"
  PANEL_PORT="$(wb_free_port)"
  git config --file "$GIT_CONFIG_GLOBAL" workboard.port "$PORT"
  git config --file "$GIT_CONFIG_GLOBAL" workboard.panel-url "http://127.0.0.1:$PANEL_PORT"
  git config --file "$GIT_CONFIG_GLOBAL" user.name "Fixture Author"
  git config --file "$GIT_CONFIG_GLOBAL" user.email "fixture@example.com"
  export WORKBOARD_TICK=0.1
  export WORKBOARD_LAUNCHCTL=false   # never the real agent
  export WORKBOARD_HTML="$BATS_TEST_TMPDIR/board.html"
  printf '<!doctype html>\n<head>\n<!--workboard:token-->\n<title>fixture</title>\n</head>\n<p>board</p>\n' > "$WORKBOARD_HTML"
  STATE="$HOME/.local/state/workboard"
  SNAPSHOT="$BATS_TEST_TMPDIR/snapshot.json"
  SERVE_PID="" PANEL_PID=""

  # real git: two repositories, each with a linked worktree on a pull request's head branch
  CODE="$(mkdir -p "$BATS_TEST_TMPDIR/code" && cd "$BATS_TEST_TMPDIR/code" && pwd -P)"
  P1="$CODE/proj-one" ALPHA="$CODE/alpha" P2="$CODE/proj-two" BETA="$CODE/beta"
  make_repo "$P1" octo-work-org/proj-one "$ALPHA" wb-alpha
  make_repo "$P2" octo-personal/proj-two "$BETA" wb-beta
  git config --file "$GIT_CONFIG_GLOBAL" "workboard.octo-work-org/proj-one.intake" all
  git config --file "$GIT_CONFIG_GLOBAL" "workboard.octo-personal/proj-two.intake" mine
  export P1 ALPHA P2 BETA

  # the registries the who source reads a session's cwd from
  mkdir -p "$HOME/.claude/sessions" "$HOME/.claude-personal/sessions"
  printf '{"cwd": "%s"}\n' "$ALPHA" > "$HOME/.claude/sessions/4102.json"
  printf '{"cwd": "%s"}\n' "$P1" > "$HOME/.claude/sessions/4101.json"
  printf '{"cwd": "%s"}\n' "$BETA" > "$HOME/.claude-personal/sessions/4201.json"

  make_stubs
  write_snapshot working
}

teardown() {
  export WORKBOARD_LAUNCHCTL=false
  "$WB" stop >/dev/null 2>&1 || true
  [ -z "$SERVE_PID" ] || kill "$SERVE_PID" 2>/dev/null || true
  [ -z "$PANEL_PID" ] || kill "$PANEL_PID" 2>/dev/null || true
  wb_teardown
  return 0
}

# make_repo <dir> <owner/repo> <worktree dir> <branch>
make_repo() {
  git init -q "$1" && git -C "$1" remote add origin "https://github.com/$2.git" &&
    git -C "$1" commit -q --allow-empty -m "fixture" &&
    git -C "$1" worktree add -q -b "$4" "$3"
}

make_stubs() {
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"         # every gh call's arguments, never its environment
  export GH_ENV_LOG="$BATS_TEST_TMPDIR/gh-env.log" # the GH_TOKEN each graphql call carried
  : > "$GH_LOG"
  : > "$GH_ENV_LOG"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1 $2 $3" = "auth token --user" ]; then echo "tok-$4"; exit 0; fi
[ "$1 $2" = "api graphql" ] || exit 2
case "${GH_TOKEN-}" in
  *work-acct) name=work-acct f=graphql-work.json ;;
  *personal-acct) name=personal-acct f=graphql-personal.json ;;
  *) exit 1 ;;
esac
printf '%s\n' "${GH_TOKEN-}" >> "$GH_ENV_LOG"
case "$*" in
  *"query=query { viewer { login } }"*) printf '{"data":{"viewer":{"login":"%s"}}}\n' "$name"; exit 0 ;;
esac
cat "$WB_FIXTURES/$f"
if grep -q '"errors"' "$WB_FIXTURES/$f"; then exit 1; fi
SH
  cat > "$BATS_TEST_TMPDIR/bin/worktabs" <<'SH'
#!/bin/sh
[ "$1" = plan ] || exit 2
printf 'work\tproj-one\tok\t-\t%s\n' "$P1"
printf 'home\tproj-two\tok\t-\t%s\n' "$P2"
SH
  cat > "$BATS_TEST_TMPDIR/bin/claude-peer" <<'SH'
#!/bin/sh
case "$1" in
  peers) [ "$2" != "$P1" ] || printf '%s\n' "$ALPHA" ;;
  claim) [ "$2" != "$ALPHA" ] || printf 'label\tAlpha\nby\tLead\ntask\tFixture task: build alpha\nhandoff\t-\nstarted\t1799999000\n' ;;
  log) printf '2026-11-20T10:00:00\tAlpha\tclaim\tFixture task: build alpha\n' ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh" "$BATS_TEST_TMPDIR/bin/worktabs" "$BATS_TEST_TMPDIR/bin/claude-peer"
  export WB_FIXTURES
  export WORKBOARD_GH="$BATS_TEST_TMPDIR/bin/gh"
  export WORKBOARD_WORKTABS="$BATS_TEST_TMPDIR/bin/worktabs"
  export WORKBOARD_CLAUDE_PEER="$BATS_TEST_TMPDIR/bin/claude-peer"
}

# write_snapshot <working|asked>: the panel's snapshot (two needs rows, two
# others) written through a rename; "asked" changes the kind of one row.
write_snapshot() {
  $WB_PY - "$SNAPSHOT" "$1" <<'PY'
import json, os, sys
def row(pid, profile, label, group, role, kind, reason, seen):
    return {"pid": pid, "profile": profile, "label": label, "group": group, "role": role,
            "kind": kind, "reason": reason, "since": 1799999000, "seen": seen}
blocked = "blocked" if sys.argv[2] == "working" else "asked"
snap = {"needs": [row(4102, "default", "Alpha", "work", "peer", blocked, "approve a Bash call", False),
                  row(4202, "personal", "Lead", "home", "lead", "asked", "asked a question", False)],
        "others": [{"group": "work", "rows": [row(4101, "default", "Lead", "work", "lead", "working", "", True)]},
                   {"group": "home", "rows": [row(4201, "personal", "Beta", "home", "peer", "working", "", True)]}]}
open(sys.argv[1] + ".new", "w").write(json.dumps(snap))
os.replace(sys.argv[1] + ".new", sys.argv[1])
PY
}

start_panel() {
  cat > "$BATS_TEST_TMPDIR/panel.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path != "/snapshot.json":
            self.send_response(404); self.end_headers(); return
        data = open(sys.argv[2], "rb").read()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(data)
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  $WB_PY "$BATS_TEST_TMPDIR/panel.py" "$PANEL_PORT" "$SNAPSHOT" 3>&- &
  PANEL_PID=$!
  wait_for $WB_PY -c "import socket; socket.create_connection(('127.0.0.1', $PANEL_PORT), 1)" 2>/dev/null
}

# hreq [--local] METHOD PATH [-H 'Name: value']... [-d body]: sets STATUS and BODY (and
# leaves the body in resp.body). --local speaks to the Unix socket, else TCP.
# Call it plainly, not in $( ).
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
class Unix(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(10)
        self.sock.connect(sock)
c = Unix("localhost", timeout=10) if sock else http.client.HTTPConnection("127.0.0.1", port, timeout=10)
c.request(method, path, body=body, headers=headers)
r = c.getresponse()
data = r.read()
d = os.environ["BATS_TEST_TMPDIR"]
open(d + "/resp.status", "w").write(str(r.status))
open(d + "/resp.body", "wb").write(data)
PY
  STATUS="$(cat "$BATS_TEST_TMPDIR/resp.status")"
  BODY="$(cat "$BATS_TEST_TMPDIR/resp.body")"
}

# link_token <link>: fetches the single-use link and prints the page token its
# answer holds in the meta tag.
link_token() {
  local p="${1#http://127.0.0.1:$PORT}"
  hreq GET "${p%%#*}" || return 1
  [ "$STATUS" = 200 ] || return 1
  sed -n 's|.*<meta name="workboard-token" content="\([0-9a-f]*\)">.*|\1|p' <<< "$BODY"
}

# jget <file> <python expression of d>: prints it.
jget() {
  $WB_PY -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

# bget <python expression of d>: the expression over the board just fetched.
bget() { jget "$BATS_TEST_TMPDIR/resp.body" "$1"; }

# wait_for <command>...: polled, up to ten seconds (times TESTS_WAIT_SCALE).
wait_for() {
  local i
  for i in $(seq 1 $((100 * ${TESTS_WAIT_SCALE:-1}))); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

# The page is asked for each time, which is what keeps the who clock running.
fetch_board() { hreq GET /b/board.json -H "Authorization: Bearer $TOK" && [ "$STATUS" = 200 ]; }

# Every source has answered once: GitHub, the local pass, and the panel's three
# sessions that have a registry record.
loaded() {
  fetch_board && hreq --local GET /status.json &&
    [ "$(bget 'd["tally"].get("github_passes", 0) >= 1 and d["tally"].get("local_passes", 0) >= 1 and d["who"]["sessions"] >= 4')" = True ]
}

# boot [nopanel]: the panel, then the real server, then every source loaded.
boot() {
  [ "${1-}" = nopanel ] || start_panel
  run "$WB" start
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  TOK="$(link_token "$("$WB" url)")"
  wait_for loaded || { fetch_board; echo "$BODY"; tail -5 "$STATE/log"; return 1; }
}

@test "the served board passes the checker and holds the cards the fixtures make" {
  boot
  fetch_board
  wb_shape board "$BATS_TEST_TMPDIR/resp.body"
  [ "$(bget 'next(c["stage"] for c in d["cards"] if c["key"] == "octo-work-org/proj-one#14")')" = review ]
  [ "$(bget 'next(c["stage"] for c in d["cards"] if c["key"] == "octo-personal/proj-two#25")')" = building ]
  [ "$(bget 'next(c["stage"] for c in d["cards"] if c["key"] == "octo-work-org/proj-one#11")')" = inbox ]
  [ "$(bget 'd["health"]["panel"]')" = ok ]
}

@test "the real reader and model give each issue card its origin, count the marks, and a scoped board counts only its own" {
  boot
  fetch_board
  wb_shape board "$BATS_TEST_TMPDIR/resp.body"
  [ "$(bget 'sorted((c["number"], c["origin"]) for c in d["cards"] if c["form"] == "issue")')" = "[(11, 'teammate'), (14, 'hand'), (25, 'hand'), (30, 'outside'), (31, 'hand')]" ]
  [ "$(bget '{k: d["health"][k] for k in ("stamps_ignored", "blocked", "blocked_linked", "blocked_clear", "needs_human")}')" = "{'stamps_ignored': 0, 'blocked': 1, 'blocked_linked': 1, 'blocked_clear': 1, 'needs_human': 1}" ]
  [ "$(bget 'next(c["blockers"] for c in d["cards"] if c["number"] == 14)')" = "{'open': 0, 'total': 2}" ]
  # the profile's own board: the personal repository has no mark, the work one has all of them
  scoped() {
    hreq --local POST /api/url -H "X-Workboard: 1" -H "X-Workboard-Profile: $1" -d '{}' || return 1
    TOK="$(link_token "$(bget 'd["text"]')")"
    fetch_board
  }
  scoped "$HOME/.claude-personal"
  [ "$(bget 'sorted({c["origin"] for c in d["cards"] if c["form"] == "issue"})')" = "['hand', 'outside']" ]
  [ "$(bget '[d["health"][k] for k in ("blocked", "needs_human")]')" = "[0, 0]" ]
  scoped "$HOME/.claude"
  [ "$(bget '[d["health"][k] for k in ("blocked", "needs_human")]')" = "[1, 1]" ]
}

@test "status prints the origins and marks counts and no title, label or repository name" {
  boot
  run -0 "$WB" status
  [[ "$output" == *$'\norigins: bot 0 · hand 3 · outside 1 · session 0 · stamps ignored 0 · teammate 1\n'* ]]
  [[ "$output" == *$'\nmarks: blocked 1 · blocked clear 1 · blocked linked 1 · needs human 1\n'* ]]
  counts="$(grep -E '^(origins|marks):' <<< "$output")"
  [[ "$counts" != *Fixture* && "$counts" != *proj-* && "$counts" != *bug* ]]
}

@test "a needs row whose registry cwd is in the pull request's worktree carries that card's key, and the card is in_needs" {
  boot
  fetch_board
  [ "$(bget 'next(n["card"] for n in d["needs"] if n["pid"] == 4102)')" = "octo-work-org/proj-one#14" ]
  [ "$(bget 'next(c["in_needs"] for c in d["cards"] if c["key"] == "octo-work-org/proj-one#14")')" = True ]
  [ "$(bget 'next(n["card"] for n in d["needs"] if n["pid"] == 4202)')" = None ]
  # the session with a cwd in the worktree of the draft pull request is on its card, not in needs
  [ "$(bget '[s["pid"] for c in d["cards"] if c["key"] == "octo-personal/proj-two#25" for s in c["sessions"]]')" = "[4201]" ]
}

@test "needs is as long as the panel's, and status prints equal numbers" {
  boot
  fetch_board
  [ "$(bget 'len(d["needs"])')" = 2 ]
  run "$WB" status
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nneeds: 2 (panel: 2)\n'* ]]
}

@test "with the panel stopped health.panel is down within a second and the cards are still served" {
  boot
  fetch_board
  n="$(bget 'len(d["cards"])')"
  [ "$n" -gt 0 ]
  kill "$PANEL_PID"; wait "$PANEL_PID" 2>/dev/null || true; PANEL_PID=""
  down() { fetch_board && [ "$(bget 'd["health"]["panel"]')" = down ]; }
  i=0
  until down; do
    i=$((i + 1))
    [ "$i" -le 20 ] || { echo "health.panel still $(bget 'd["health"]["panel"]') after a second"; false; }
    sleep 0.05
  done
  [ "$(bget 'len(d["cards"])')" = "$n" ]
  [ "$(bget 'd["health"]["panel_age"] is None or d["health"]["panel_age"] >= 0')" = True ]
}

@test "a changed panel snapshot raises rev" {
  boot
  fetch_board
  before="$(bget 'd["rev"]')"
  write_snapshot asked
  raised() { fetch_board && [ "$(bget 'd["rev"]')" -gt "$before" ]; }
  wait_for raised
  [ "$(bget 'next(n["kind"] for n in d["needs"] if n["pid"] == 4102)')" = asked ]
}

@test "gh is asked once per account per pass for the board, and no token is ever an argument" {
  boot
  hreq --local GET /status.json
  passes="$(jget "$BATS_TEST_TMPDIR/resp.body" 'd["tally"]["github_passes"]')"
  [ "$passes" -eq 1 ]
  # the board query carries $login; the login lookup is the other graphql call
  [ "$(grep -c 'api graphql.*query=query(\$login' "$GH_LOG")" -eq $((2 * passes)) ]
  [ "$(grep -c 'api graphql' "$GH_LOG")" -eq $((4 * passes)) ]
  [ "$(grep -c '^tok-work-acct$' "$GH_ENV_LOG")" -eq $((2 * passes)) ]
  [ "$(grep -c '^tok-personal-acct$' "$GH_ENV_LOG")" -eq $((2 * passes)) ]
  run grep -c 'tok-' "$GH_LOG"
  [ "$output" = 0 ]
}

@test "github.account_of and the account local.read writes agree for pinned, unpinned and mixed-case owners" {
  local i=0 owner
  for owner in octo-work-org Octo-Work-Org octo-personal OCTO-Personal octo-nopin; do
    i=$((i + 1))
    git init -q "$CODE/own$i"
    git -C "$CODE/own$i" remote add origin "https://github.com/$owner/repo$i.git"
    git -C "$CODE/own$i" commit -q --allow-empty -m fixture
  done
  git init -q "$CODE/own6"
  git -C "$CODE/own6" remote add origin "git@github.com:Octo-Personal/repo6.git"
  git -C "$CODE/own6" commit -q --allow-empty -m fixture
  OWNERS="octo-work-org Octo-Work-Org octo-personal OCTO-Personal octo-nopin Octo-Personal" run wb_driver "$WORKBOARD_LIBEXEC" <<PY
import github, local, os
code = "$CODE"
doc = local.read([], [code + "/own%d" % i for i in range(1, 7)], 1800000000.0)
owners = os.environ["OWNERS"].split()
by_dir = {r["dir"]: r for r in doc["repos"]}
assert len(owners) == 6
seen = set()
for i, owner in enumerate(owners, 1):
    r = by_dir[code + "/own%d" % i]
    assert r["slug"] == "%s/repo%d" % (owner.lower(), i), r["slug"]
    assert r["account"] == github.account_of(owner), (owner, r["account"], github.account_of(owner))
    seen.add(r["account"])
assert seen == {"work-acct", "personal-acct", "-"}, seen
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "serve --fixture on the demo directory, through the real model, serves the scenario's twelve keys and stages" {
  wb_demo >/dev/null
  $WB serve --port "$PORT" --fixture "$WORKBOARD_DEMO" > "$BATS_TEST_TMPDIR/serve.out" 2> "$BATS_TEST_TMPDIR/serve.err" 3>&- &
  SERVE_PID=$!
  up() { grep -q "^workboard: on http://127.0.0.1:$PORT/" "$BATS_TEST_TMPDIR/serve.out"; }
  wait_for up
  TOK="$(link_token "$("$WB" url)")"
  fetch_board
  wb_shape board "$BATS_TEST_TMPDIR/resp.body"
  [ "$(bget 'len(d["cards"])')" = 12 ]
  got="$(bget 'sorted((c["key"], c["stage"]) for c in d["cards"])')"
  want="$(jget "$WORKBOARD_DEMO/board.json" 'sorted((c["key"], c["stage"]) for c in d["cards"])')"
  [ "$got" = "$want" ]
  # every origin and mark the real model gives the demo's issues
  [ "$(bget 'sorted((c["number"], c["origin"]) for c in d["cards"] if c["form"] == "issue")')" = "[(11, 'teammate'), (12, 'outside'), (13, 'teammate'), (14, 'hand'), (22, 'session'), (25, 'hand')]" ]
  [ "$(bget '{k: d["health"][k] for k in ("stamps_ignored", "blocked", "blocked_linked", "blocked_clear", "needs_human")}')" = "{'stamps_ignored': 1, 'blocked': 2, 'blocked_linked': 2, 'blocked_clear': 1, 'needs_human': 1}" ]
  [ "$(bget '{c["number"]: c["blockers"] for c in d["cards"] if c["number"] in (13, 14)}')" = "{13: {'open': 1, 'total': 1}, 14: {'open': 0, 'total': 2}}" ]
  # the real model's board is the fixture board, whatever the clock
  [ "$(bget '[c["key"] for c in d["cards"]]')" = "$(jget "$WORKBOARD_DEMO/board.json" '[c["key"] for c in d["cards"]]')" ]
  run ! grep -q '^api graphql' "$GH_LOG"
}

@test "workboard poll, local, who and inbox by hand print counts and no fixture title" {
  wb_demo >/dev/null
  start_panel
  run "$WB" poll --local "$WORKBOARD_DEMO/local.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *work-acct* && "$output" == *personal-acct* ]]
  [[ "$output" != *"Fixture"* && "$output" != *"tok-"* ]]
  run "$WB" local
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [[ "$output" != *"Fixture"* && "$output" != *"$CODE"* ]]
  run "$WB" who --panel-url "http://127.0.0.1:$PANEL_PORT"
  [ "$status" -eq 0 ]
  [ "$output" = "panel ok · rows 4 · needs 2 · dir 3" ]
  run "$WB" inbox
  [ "$status" -eq 0 ]
  [ "$output" = "source none · rows 0" ]
}

@test "after twenty ticks no file under the state directory or the home holds a fixture title, body, label or claim task" {
  boot
  # twenty who passes: one tick each while the page is being asked for
  twenty() { fetch_board && hreq --local GET /status.json && [ "$(bget 'd["tally"].get("who_passes", 0)')" -ge 20 ]; }
  wait_for twenty
  # the board does hold them in memory, so the check below can fail
  fetch_board
  [[ "$BODY" == *"Fixture title: issue closed by 15"* && "$BODY" == *"Fixture task: build alpha"* ]]
  "$WB" stop >/dev/null
  [ -f "$STATE/tally.json" ]
  run grep -rlE 'Fixture (title|body|task)' "$HOME" "$STATE"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  run grep -rlw -e bug "$HOME" "$STATE"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "no page token, link nonce or tool key is in a process's arguments or in a file under the home, the state directory or the runtime directory" {
  boot
  nonce="$("$WB" url | sed -n 's|.*/enter/\([^#]*\).*|\1|p')"
  [ -n "$nonce" ]
  hreq --local POST /api/bearer -H "X-Workboard: 1" -H "X-Workboard-Profile: $HOME/.claude" -d '{}'
  tool="$(bget 'd["text"]')"
  [[ "$tool" =~ ^[0-9a-f]{32}$ ]]
  [ "$tool" != "$TOK" ]
  run ps -A -o args=
  [ "$status" -eq 0 ]
  [[ "$output" == *"board.py serve"* ]]   # the snapshot holds the server, so the next line tests something
  [[ "$output" != *"$TOK"* && "$output" != *"$tool"* && "$output" != *"$nonce"* ]]
  "$WB" stop >/dev/null
  run grep -rlF -e "$TOK" -e "$tool" -e "$nonce" "$HOME" "$STATE" "$WORKBOARD_RUNTIME"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "with the real page, /enter holds the meta tag where the marker was, and /b/ holds neither" {
  export WORKBOARD_HTML="$WB_ROOT/dot_local/share/workboard/board.html"
  boot
  link="$("$WB" url)"
  hreq GET "${link#http://127.0.0.1:$PORT}"
  [ "$STATUS" = 200 ]
  [[ "$BODY" != *"<!--workboard:token-->"* ]]
  [ "$(grep -c '<meta name="workboard-token" content="[0-9a-f]\{32\}">' <<< "$BODY")" -eq 1 ]
  # the answer is the page file with the one marker line swapped for the tag
  $WB_PY - "$WORKBOARD_HTML" "$BATS_TEST_TMPDIR/resp.body" <<'PY'
import re, sys
page, got = open(sys.argv[1]).read(), open(sys.argv[2]).read()
assert page.count("<!--workboard:token-->") == 1
want = re.sub(r'<meta name="workboard-token" content="[0-9a-f]{32}">', "<!--workboard:token-->", got)
assert want == page, "the /enter answer differs from the page file beyond the marker"
PY
  hreq GET /b/
  [ "$STATUS" = 200 ]
  [[ "$BODY" != *"<!--workboard:token-->"* && "$BODY" != *'<meta name="workboard-token"'* ]]
}

@test "a caller on plain TCP with no key gets only {\"ok\": true} from /health, 404 from /status.json and /api/url, 403 from /b/board.json" {
  boot
  hreq GET /health
  [ "$STATUS" = 200 ]
  [ "$(bget 'd')" = "{'ok': True}" ]
  hreq GET /status.json
  [ "$STATUS" = 404 ]
  hreq POST /api/url -H "X-Workboard: 1" -H "X-Workboard-Profile: $HOME/.claude" -d '{}'
  [ "$STATUS" = 404 ]
  hreq GET /b/board.json
  [ "$STATUS" = 403 ]
  hreq GET /b/board.json -H "Authorization: Bearer $(printf '0%.0s' $(seq 32))"
  [ "$STATUS" = 403 ]
}

@test "no __pycache__ is left in the source tree" {
  wb_no_pycache
}
