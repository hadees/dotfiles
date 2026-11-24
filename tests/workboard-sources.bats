#!/usr/bin/env bats

# The work board's who and inbox sources (who.py, inbox.py), each tested alone:
# the panel is a python http.server thread the test starts over a fixture
# snapshot, the registries are fixture files under the sandbox HOME. Nothing
# reads the real panel, registry or claims. All names are fixtures (CLAUDE.md).

bats_require_minimum_version 1.5.0

load helpers/workboard

setup() {
  wb_setup
  wb_modules who inbox >/dev/null
  PANEL="$BATS_TEST_TMPDIR/panel"
  mkdir -p "$PANEL" "$HOME/.claude/sessions" "$HOME/.claude-personal/sessions"
  export PANEL
  # The fixture snapshot: panel order is blocked (4102), then asked (4202); the
  # others repeat 4102, and add 4101 and 4201 and 4301 (profile with no directory).
  $WB_PY - "$PANEL/snapshot.json" <<'PY'
import json, sys
def row(pid, profile, label, group, role, kind, reason, since, seen):
    return {"pid": pid, "profile": profile, "label": label, "group": group, "role": role,
            "kind": kind, "reason": reason, "since": since, "seen": seen,
            "tty": "/dev/ttys%03d" % (pid % 1000), "guid": "guid-%d" % pid}
r4102 = row(4102, "default", "Alpha", "proj-one", "peer", "blocked", "approve a Bash call", 1799999000, False)
r4202 = row(4202, "personal", "Lead", "proj-two", "lead", "asked", "asked a question", 1799999500, False)
snap = {"v": 1, "generated_at": 1799999998.0, "build": "x", "health": {}, "tally": {},
        "needs": [r4102, r4202],
        "others": [
            {"group": "proj-one", "needs": 1, "working": 1, "idle": 0, "rows": [
                row(4101, "default", "Lead", "proj-one", "lead", "working", "", 1799990000, True), r4102]},
            {"group": "proj-two", "needs": 1, "working": 1, "idle": 0, "rows": [
                row(4201, "personal", "Beta", "proj-two", "peer", "working", "", 1799999000, True), r4202,
                row(4301, "ghost", "Gamma", "proj-two", "peer", "idle", "", 1799999100, True)]}]}
open(sys.argv[1], "w").write(json.dumps(snap))
PY
  record 4102 default /sb/code/proj-one/.claude/worktrees/alpha
  record 4101 default /sb/code/proj-one
  record 4201 personal /sb/code/proj-two/.claude/worktrees/beta
  # 4202 and 4301 have no record at all.
}

# record <pid> <default|personal> <cwd>
record() {
  local d="$HOME/.claude"
  [ "$2" = personal ] && d="$HOME/.claude-personal"
  printf '{"pid": %s, "cwd": "%s", "kind": "interactive"}\n' "$1" "$3" > "$d/sessions/$1.json"
}

# panel_py: the python that serves $PANEL over a thread on a free port and
# defines PORT, URL and stop(); a status other than 200 is read from $PANEL/status.
panel_py() {
  cat <<'PY'
import functools, http.server, json, os, threading
PANEL = os.environ["PANEL"]
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if os.path.exists(PANEL + "/status"):
            self.send_response(int(open(PANEL + "/status").read())); self.end_headers(); return
        super().do_GET()
    def log_message(self, *a):
        pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(H, directory=PANEL))
threading.Thread(target=srv.serve_forever, daemon=True).start()
URL = "http://127.0.0.1:%d" % srv.server_address[1]
def stop():
    srv.shutdown(); srv.server_close()
import who, inbox
PROFILES = {"default": os.path.expanduser("~/.claude"), "personal": os.path.expanduser("~/.claude-personal")}
PY
}

@test "who.read: needs rows first in the panel's order, then the others, once each, as session rows" {
  run wb_driver "$WORKBOARD_LIBEXEC" <<PY
$(panel_py)
doc = who.read(URL, PROFILES, {}, 1800000000.0, {})
open(os.environ["BATS_TEST_TMPDIR"] + "/who.json", "w").write(json.dumps(doc) + "\n")
print(doc["sources"], doc["fetched_at"])
print([(r["id"], r["needs"]) for r in doc["rows"]])
print(all(r["source"] == "session" and r["stale"] is False and r["seat"] is None and r["text"] is None for r in doc["rows"]))
stop()
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "${lines[0]}" == "{'panel': 'ok', 'jobs': 'off'} 1800000000.0" ]]
  [[ "${lines[1]}" == "[('s:default:4102', True), ('s:personal:4202', True), ('s:default:4101', False), ('s:personal:4201', False), ('s:ghost:4301', False)]" ]]
  [ "${lines[2]}" = True ]
  run wb_shape who "$BATS_TEST_TMPDIR/who.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "who.read: the panel's own fields are carried, tty and guid are not" {
  run wb_driver "$WORKBOARD_LIBEXEC" <<PY
$(panel_py)
doc = who.read(URL, PROFILES, {}, 1800000000.0, {})
r = doc["rows"][0]
print(r["pid"], r["profile"], r["label"], r["group"], r["role"], r["kind"], r["reason"], r["since"], r["seen"])
print(any("tty" in r or "guid" in r for r in doc["rows"]))
stop()
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = "4102 default Alpha proj-one peer blocked approve a Bash call 1799999000 False" ]
  [ "${lines[1]}" = False ]
}

@test "who.read: dir is the record's cwd, null with no record or no profile directory" {
  run wb_driver "$WORKBOARD_LIBEXEC" <<PY
$(panel_py)
doc = who.read(URL, PROFILES, {}, 1800000000.0, {})
print({r["pid"]: r["dir"] for r in doc["rows"]})
stop()
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "{4102: '/sb/code/proj-one/.claude/worktrees/alpha', 4202: None, 4101: '/sb/code/proj-one', 4201: '/sb/code/proj-two/.claude/worktrees/beta', 4301: None}" ]
}

@test "who.read: a record is read once per pid, and again after the pid left the snapshot" {
  cp "$PANEL/snapshot.json" "$BATS_TEST_TMPDIR/full.json"
  run wb_driver "$WORKBOARD_LIBEXEC" <<PY
$(panel_py)
cache = {}
def dir_of(pid):
    return {r["pid"]: r["dir"] for r in who.read(URL, PROFILES, {}, 1.0, cache)["rows"]}[pid]
first = dir_of(4101)
open(os.path.expanduser("~/.claude/sessions/4101.json"), "w").write('{"cwd": "/sb/elsewhere"}')
print(first, dir_of(4101))
snap = json.load(open(PANEL + "/snapshot.json"))
full = json.dumps(snap)
snap["others"][0]["rows"] = [r for r in snap["others"][0]["rows"] if r["pid"] != 4101]
open(PANEL + "/snapshot.json", "w").write(json.dumps(snap))
print(4101 in [r["pid"] for r in who.read(URL, PROFILES, {}, 1.0, cache)["rows"]])
open(PANEL + "/snapshot.json", "w").write(full)
print(dir_of(4101))
stop()
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = "/sb/code/proj-one /sb/code/proj-one" ]
  [ "${lines[1]}" = False ]
  [ "${lines[2]}" = /sb/elsewhere ]
}

@test "who.read: a stopped panel is down with no rows, inside two seconds" {
  run wb_driver "$WORKBOARD_LIBEXEC" <<PY
$(panel_py)
import time
stop()
t = time.time()
doc = who.read(URL, PROFILES, {}, 5.0, {})
print(doc["sources"], doc["rows"], time.time() - t < 2)
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "{'panel': 'down', 'jobs': 'off'} [] True" ]
}

@test "who.read: a system proxy does not catch the loopback request" {
  HTTP_PROXY=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 run wb_driver "$WORKBOARD_LIBEXEC" <<PY
$(panel_py)
print(who.read(URL, PROFILES, {}, 1.0, {})["sources"]["panel"])
stop()
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = ok ]
}

@test "who.read: a 503 is down with no rows" {
  printf 503 > "$PANEL/status"
  run wb_driver "$WORKBOARD_LIBEXEC" <<PY
$(panel_py)
doc = who.read(URL, PROFILES, {}, 5.0, {})
print(doc["sources"], doc["rows"])
stop()
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "{'panel': 'down', 'jobs': 'off'} []" ]
}

@test "who.read: a body that is not JSON is down with no rows" {
  printf 'not json' > "$PANEL/snapshot.json"
  run wb_driver "$WORKBOARD_LIBEXEC" <<PY
$(panel_py)
doc = who.read(URL, PROFILES, {}, 5.0, {})
print(doc["sources"], doc["rows"])
stop()
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "{'panel': 'down', 'jobs': 'off'} []" ]
}

@test "who.profile_dirs: default and personal for the sandbox, none for a directory that does not exist" {
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.gone-acct '~/.claude-gone'
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.dup-acct "$HOME/.claude"
  run wb_driver "$WORKBOARD_LIBEXEC" <<PY
import who
print(sorted(who.profile_dirs().items()))
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "[('default', '$HOME/.claude'), ('personal', '$HOME/.claude-personal')]" ]
}

@test "who.profile_dirs: CLAUDE_CONFIG_DIR is a profile too, labelled by its base name" {
  mkdir -p "$HOME/custom"
  CLAUDE_CONFIG_DIR="$HOME/custom" run wb_driver "$WORKBOARD_LIBEXEC" <<PY
import who
print(sorted(who.profile_dirs()))
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "['custom', 'default', 'personal']" ]
}

@test "inbox: read is the empty document and changed is False" {
  run wb_driver "$WORKBOARD_LIBEXEC" <<PY
import inbox, json, os
doc = inbox.read({}, 1800000000.0, {})
open(os.environ["BATS_TEST_TMPDIR"] + "/inbox.json", "w").write(json.dumps(doc) + "\n")
print(json.dumps(doc), inbox.changed({}, {}))
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = '{"v": 1, "fetched_at": 1800000000.0, "source": "none", "errors": {}, "rows": []} False' ]
  run wb_shape inbox "$BATS_TEST_TMPDIR/inbox.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "inbox: its header says it is the Inbox order's contract with no queue to read" {
  run grep -c "Inbox order's contract" "$WB_SRC/inbox.py"
  [ "$output" = 1 ]
  run grep -c "no queue to read" "$WB_SRC/inbox.py"
  [ "$output" = 1 ]
}

@test "who.py by hand: one counts line, no label and no directory, nothing written" {
  local pid port
  port="$(wb_free_port)"
  (cd "$PANEL" && exec $WB_PY -m http.server --bind 127.0.0.1 "$port" >/dev/null 2>&1) &
  pid=$!
  local n=0
  until curl -s --noproxy '*' -o /dev/null "http://127.0.0.1:$port/snapshot.json" || [ $((n++)) -gt 50 ]; do sleep 0.1; done
  run $WB_PY "$WB_SRC/who.py" --panel-url "http://127.0.0.1:$port"
  kill "$pid" 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "panel ok · rows 5 · needs 2 · dir 3" ]
  [ ! -e "$HOME/.local/state/workboard" ]
}

@test "who.py by hand: a panel that does not answer prints down and zero counts" {
  run $WB_PY "$WB_SRC/who.py" --panel-url "http://127.0.0.1:$(wb_free_port)"
  [ "$status" -eq 0 ]
  [ "$output" = "panel down · rows 0 · needs 0 · dir 0" ]
}

@test "who.py by hand: the panel url comes from workboard.panel-url, else claude-tab.panel-port" {
  local port
  port="$(wb_free_port)"
  git config --file "$GIT_CONFIG_GLOBAL" workboard.panel-url "http://127.0.0.1:$port"
  run $WB_PY "$WB_SRC/who.py"
  [ "$output" = "panel down · rows 0 · needs 0 · dir 0" ]
  run $WB_PY -c '
import sys; sys.path.insert(0, sys.argv[1]); import who
print(who._panel_url())' "$WB_SRC"
  [ "$output" = "http://127.0.0.1:$port" ]
  git config --file "$GIT_CONFIG_GLOBAL" --unset workboard.panel-url
  git config --file "$GIT_CONFIG_GLOBAL" claude-tab.panel-port 47777
  run $WB_PY -c '
import sys; sys.path.insert(0, sys.argv[1]); import who
print(who._panel_url())' "$WB_SRC"
  [ "$output" = "http://127.0.0.1:47777" ]
  git config --file "$GIT_CONFIG_GLOBAL" --unset claude-tab.panel-port
  run $WB_PY -c '
import sys; sys.path.insert(0, sys.argv[1]); import who
print(who._panel_url())' "$WB_SRC"
  [ "$output" = "http://127.0.0.1:47600" ]
}

@test "who.py and inbox.py --fixture print the demo document and nothing live is asked" {
  wb_demo >/dev/null
  run $WB_PY "$WB_SRC/who.py" --fixture "$WORKBOARD_DEMO" --panel-url "http://127.0.0.1:1"
  [ "$status" -eq 0 ]
  [ "$output" = "$(sed 's/ *$//' "$WORKBOARD_DEMO/who.json" | $WB_PY -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read())))')" ]
  run $WB_PY "$WB_SRC/inbox.py" --fixture "$WORKBOARD_DEMO"
  [ "$status" -eq 0 ]
  [ "$output" = "$($WB_PY -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))' "$WORKBOARD_DEMO/inbox.json")" ]
}

@test "inbox.py by hand prints its counts line" {
  run $WB_PY "$WB_SRC/inbox.py"
  [ "$status" -eq 0 ]
  [ "$output" = "source none · rows 0" ]
}

@test "--fixture refuses a document with the wrong top-level keys" {
  wb_demo >/dev/null
  echo '{"v":1}' > "$WORKBOARD_DEMO/who.json"
  run $WB_PY "$WB_SRC/who.py" --fixture "$WORKBOARD_DEMO"
  [ "$status" -eq 1 ]
}

@test "the modules parse under the oldest python the board supports and leave no bytecode" {
  [ -x /usr/bin/python3 ] || skip "no /usr/bin/python3"
  run /usr/bin/python3 -I -B -c 'import ast,sys; [ast.parse(open(f).read()) for f in sys.argv[1:]]' "$WB_SRC/who.py" "$WB_SRC/inbox.py"
  [ "$status" -eq 0 ]
  wb_no_pycache
}
