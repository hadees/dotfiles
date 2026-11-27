#!/usr/bin/env bats

# The work board's frozen contracts, made executable: the `demo` scenario's five
# documents, the shape checker (tests/helpers/workboard-shape.py), the stub
# modules (tests/workboard-stubs/) and the helper every workboard test file
# sources (tests/helpers/workboard.bash). Nothing here reads product code: the
# first work-board step ships no file under dot_local/ or bin/. All names are
# fixtures (see CLAUDE.md).

bats_require_minimum_version 1.5.0

load helpers/workboard

setup() {
  wb_setup
}

teardown() {
  wb_teardown
}

P1=octo-work-org/proj-one
P2=octo-personal/proj-two

# mutate <kind> <python statement acting on d>: the demo document of that kind,
# changed, as $BATS_TEST_TMPDIR/mut.json.
mutate() {
  $WB_PY - "$WB_FIXTURES/demo/$1.json" "$BATS_TEST_TMPDIR/mut.json" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
exec(sys.argv[3])
open(sys.argv[2], "w").write(json.dumps(d) + "\n")
PY
}

# rejects <kind> <statement> <word>: the checker exits 1 and its line names <word>.
rejects() {
  mutate "$1" "$2"
  run wb_shape "$1" "$BATS_TEST_TMPDIR/mut.json"
  [ "$status" -eq 1 ] || { echo "accepted: $2"; return 1; }
  [[ "$output" == *"$3"* ]] || { echo "line does not name $3: $output"; return 1; }
}

@test "wb_setup: the sandbox is under BATS_TEST_TMPDIR, python survives the faked HOME, the pins are the fixture ones" {
  [ "$HOME" = "$BATS_TEST_TMPDIR/home" ]
  [ -d "$HOME/.claude" ]
  [ -d "$HOME/.claude-personal" ]
  [ "$(git config --get credential.https://github.com/octo-work-org.username)" = work-acct ]
  [ "$(git config --get credential.https://github.com/octo-personal.username)" = personal-acct ]
  [ "$(git config --get claude.profile.work-acct)" = '~/.claude' ]
  [ "$(git config --get claude.profile.personal-acct)" = '~/.claude-personal' ]
  [ -z "${CLAUDECODE-}${CLAUDE_CONFIG_DIR-}${CLAUDE_PROFILE-}${XDG_STATE_HOME-}" ]
  [ "$WB_SRC" = "$WB_ROOT/dot_local/libexec/workboard" ]
  run python3 -c 'print(1)'
  [ "$output" = 1 ]
  run $WB_PY -c 'print(2)'
  [ "$output" = 2 ]
  [[ "$WB_PY" == *" -I -B" ]]
}

@test "demo: the five documents have the frozen shape" {
  local k
  for k in github local who inbox board; do
    run wb_shape "$k" "$WB_FIXTURES/demo/$k.json"
    [ "$status" -eq 0 ] || { echo "$k: $output"; return 1; }
  done
}

@test "checker: a board with one card key removed is rejected, naming it" {
  rejects board 'del d["cards"][3]["title"]' title
}

@test "checker: a board with one card key added is rejected, naming it" {
  rejects board 'd["cards"][3]["surplus"] = 1' surplus
}

@test "checker: a board with one card key of the wrong kind is rejected, naming it" {
  rejects board 'd["cards"][3]["number"] = "11"' number
}

@test "checker: a missing, unknown or wrong key is named at every level the contracts spell out" {
  local kind stmt word
  while IFS='|' read -r kind stmt word; do
    rejects "$kind" "$stmt" "$word"
  done <<'EOF'
github|d["surplus"] = 1|surplus
github|del d["accounts"]|accounts
github|d["accounts"]["work-acct"]["cost"] = "2"|cost
github|d["repos"]["octo-work-org/proj-one"]["surplus"] = 1|surplus
github|d["issues"][3]["prs"][0]["surplus"] = 1|surplus
github|d["issues"][0]["labels"] = "bug"|labels
github|del d["prs"][0]["checks"]|checks
github|d["prs"][0]["review"] = "MAYBE"|review
github|d["prs"][0]["closes"][0]["surplus"] = 1|surplus
local|d["surplus"] = 1|surplus
local|d["repos"][0]["surplus"] = 1|surplus
local|d["repos"][0]["write"] = "no"|write
local|d["worktrees"][0]["main"] = 1|main
local|del d["worktrees"][3]["claim"]["by"]|by
local|d["worktrees"][3]["claim"]["surplus"] = 1|surplus
local|d["links"] = [{"slug": "x"}]|number
local|d["log"]["octo-work-org/proj-one"][0]["surplus"] = 1|surplus
who|d["surplus"] = 1|surplus
who|d["sources"]["panel"] = "up"|panel
who|d["rows"][0]["surplus"] = 1|surplus
who|del d["rows"][0]["dir"]|dir
inbox|d["surplus"] = 1|surplus
inbox|d["rows"][0]["surplus"] = 1|surplus
inbox|d["rows"][0]["cand"] = "yes"|cand
board|d["surplus"] = 1|surplus
board|d["v"] = 2|board.v:
board|d["rev"] = "1"|rev
board|d["health"]["surplus"] = 1|surplus
board|del d["health"]["stale_jobs"]|stale_jobs
board|d["health"]["accounts"][0]["surplus"] = 1|surplus
board|d["repos"][0]["surplus"] = 1|surplus
board|d["cards"][0]["stage"] = "done"|stage
board|d["cards"][1]["queue"]["surplus"] = 1|surplus
board|d["cards"][4]["prs"][0]["surplus"] = 1|surplus
board|d["cards"][4]["holders"][0]["surplus"] = 1|surplus
board|d["cards"][4]["sessions"][0]["surplus"] = 1|surplus
board|d["cards"][8]["log"][0]["surplus"] = 1|surplus
board|d["needs"][0]["surplus"] = 1|surplus
EOF
}

@test "checker: rev and build are optional, and a document over several lines is refused" {
  local k
  mutate board 'del d["rev"], d["build"]'
  run wb_shape board "$BATS_TEST_TMPDIR/mut.json"
  [ "$status" -eq 0 ]
  $WB_PY -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), indent=1))' "$WB_FIXTURES/demo/who.json" > "$BATS_TEST_TMPDIR/pretty.json"
  run wb_shape who "$BATS_TEST_TMPDIR/pretty.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"one line"* ]]
  run wb_shape bogus "$WB_FIXTURES/demo/who.json"
  [ "$status" -eq 2 ]
}

@test "checker: the origin and waiting keys are optional, and each is checked when present" {
  mutate github 'd["issues"][0].update(author_kind="User", association="MEMBER", editor=None, blockers={"open": 1, "total": 2})'
  run wb_shape github "$BATS_TEST_TMPDIR/mut.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  mutate board 'd["cards"][0].update(origin="session", blockers=None); d["health"].update(stamps_ignored=0, blocked=1, blocked_linked=1, blocked_clear=0, needs_human=2)'
  run wb_shape board "$BATS_TEST_TMPDIR/mut.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  rejects github 'd["issues"][0]["blockers"] = {"open": "1", "total": 2}' blockers
  rejects board 'd["cards"][0]["origin"] = "stranger"' origin
  rejects board 'd["health"]["blocked"] = "1"' blocked
}

@test "board.json: the scenario's twelve cards, with their forms, stages, order and marks" {
  run $WB_PY - "$WB_FIXTURES/demo/board.json" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
P1, P2 = "octo-work-org/proj-one", "octo-personal/proj-two"
want = {
    P1 + "~Q1": ("queue", "inbox"), P1 + "#12": ("issue", "inbox"), P1 + "~Q3": ("queue", "inbox"),
    P1 + "#11": ("issue", "inbox"), P1 + "#13": ("issue", "building"), P1 + "@agent-1": ("local", "building"),
    P1 + "@agent-2": ("local", "building"), P1 + "#14": ("issue", "review"), P2 + "#25": ("issue", "building"),
    P2 + "#21": ("pr", "review"), P2 + "#22": ("issue", "landed"), P2 + "#24": ("pr", "landed")}
cards = b["cards"]
assert {c["key"]: (c["form"], c["stage"]) for c in cards} == want and len(cards) == 12
assert [c["key"] for c in cards if c["in_needs"]] == [P1 + "#14"]
assert [c["key"] for c in cards if c["unattended"]] == [P1 + "#13"]
assert [n["id"] for n in b["needs"]] == ["s:default:4102", "s:personal:4202"]
assert [n["card"] for n in b["needs"]] == [P1 + "#14", None]
assert [c["key"] for c in cards if c["stage"] == "inbox"] == [P1 + "~Q1", P1 + "#12", P1 + "~Q3", P1 + "#11"]
assert {c["key"]: c["trial_day"] for c in cards if c["trial_day"] is not None} == {P2 + "#22": 3, P2 + "#24": 2}
queued = {c["key"]: c["queue"]["id"] for c in cards if c["queue"]}
assert queued == {P1 + "~Q1": "Q1", P1 + "#12": "Q2", P1 + "~Q3": "Q3"}
assert [c["queue"]["score"] for c in cards[:3]] == ["9.5", "12.0", "3.0"]
h = b["health"]
assert (h["cards"], h["unattended"], h["unjoined"], h["unjoined_jobs"], h["stale_jobs"]) == (12, 1, 1, 0, 1)
assert h["accounts"][0]["error"] == "more than 50 open pull requests; some are not shown" and h["accounts"][1]["error"] is None
assert (b["v"], b["rev"], b["build"], b["scope"], b["generated_at"]) == (1, 1, "fixture", None, 1800000000.0)
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "demo inputs: the scenario's repositories, accounts, and who and queue rows" {
  run $WB_PY - "$WB_FIXTURES/demo" <<'PY'
import json, os, sys
d = lambda n: json.load(open(os.path.join(sys.argv[1], n + ".json")))
local, who, inbox, gh = d("local"), d("who"), d("inbox"), d("github")
r1, r2 = local["repos"]
assert (r1["group"], r1["account"], r1["intake"], r1["write"], r1["take"]) == ("work", "work-acct", "all", False, "ask")
assert (r2["group"], r2["account"], r2["intake"], r2["write"], r2["take"]) == ("home", "personal-acct", "mine", True, "auto")
assert r1["profile"].endswith("/.claude") and r2["profile"].endswith("/.claude-personal")
assert [r["id"] for r in who["rows"] if r["needs"]] == ["s:default:4102", "s:personal:4202"]
assert [r["id"] for r in who["rows"][:2]] == ["s:default:4102", "s:personal:4202"]
jobs = [r for r in who["rows"] if r["source"] == "job"]
assert [(j["seat"], j["label"], j["pid"], j["stale"]) for j in jobs] == [("work-sonnet", "Lead", None, True), ("work-sonnet", "Lead", 4101, False)]
assert [(r["id"], r["tier"], r["score"], r["order"]) for r in inbox["rows"]] == [("Q1", 1, "9.5", 1), ("Q2", 2, "12.0", 2), ("Q3", 3, "3.0", 3)]
assert inbox["rows"][2]["kind"] == "unfinished" and inbox["rows"][1]["issue"] == 12
assert gh["accounts"]["work-acct"]["error"] == "more than 50 open pull requests; some are not shown"
assert 1800000000 - [p for p in gh["prs"] if p["number"] == 23][0]["merged_at"] == 2 * 86400
assert 1800000000 - [p for p in gh["prs"] if p["number"] == 24][0]["merged_at"] == 1 * 86400
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "wb_demo: the copies leave no /wb-fixture, name directories that exist, and still have the shape" {
  local k
  wb_demo >/dev/null
  [ -n "$WORKBOARD_DEMO" ]
  run grep -rl '/wb-fixture' "$WORKBOARD_DEMO"
  [ "$status" -eq 1 ]
  [ -d "$WORKBOARD_DEMO/code/proj-one/.claude/worktrees/alpha" ]
  [ -d "$WORKBOARD_DEMO/code/proj-two/.git" ]
  [ -d "$WORKBOARD_DEMO/.claude-personal" ]
  grep -q "$WORKBOARD_DEMO/code/proj-one/.claude/worktrees/alpha" "$WORKBOARD_DEMO/who.json"
  for k in github local who inbox board; do
    run wb_shape "$k" "$WORKBOARD_DEMO/$k.json"
    [ "$status" -eq 0 ] || { echo "$k: $output"; return 1; }
  done
}

@test "wb_modules: a named module with no real file fails; the stubs fill the rest" {
  WB_SRC="$BATS_TEST_TMPDIR/src"
  mkdir -p "$WB_SRC"
  run wb_modules model
  [ "$status" -ne 0 ]
  run wb_modules nonsense
  [ "$status" -ne 0 ]
  : > "$WB_SRC/model.py"
  run wb_modules model
  [ "$status" -eq 0 ]
  [ "$(readlink "$output/model.py")" = "$WB_SRC/model.py" ]
  [ "$(readlink "$output/github.py")" = "$WB_STUBS/github.py" ]
  [ "$(readlink "$output/verbs.py")" = "$WB_STUBS/verbs.py" ]
  [ ! -e "$output/board.py" ]
  [ ! -e "$output/mcp_endpoint.py" ]
  [ ! -e "$output/pane.py" ]
  [ ! -e "$output/app.py" ]
  [ "$(readlink "$output/origin.py")" = "$WB_SRC/origin.py" ]
}

@test "wb_modules: with no name it is a directory of stubs that imports under -I" {
  local dir
  dir="$(wb_modules)"
  [ "$(readlink "$dir/origin.py")" = "$WB_SRC/origin.py" ]
  [ "$(ls "$dir" | tr '\n' ' ')" = "github.py inbox.py local.py model.py origin.py verbs.py who.py " ]
  run wb_driver "$dir" <<'PY'
import model, github, local, who, inbox, verbs
assert model.__file__.endswith("model.py")
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "stubs: every function exists with the frozen parameter names" {
  local dir
  wb_demo >/dev/null
  dir="$(wb_modules)"
  run wb_driver "$dir" <<'PY'
import inspect, model, github, local, who, inbox, verbs
frozen = {
    model: {"build_board": "github local who inbox trial_days now scope"},
    github: {"poll": "local prior budget now only", "account_of": "owner", "token_for": "account",
             "next_interval": "cost remaining budget", "tally": ""},
    local: {"read": "links also now", "profile_of": "slug account", "slug_of": "dir"},
    who: {"read": "panel_url profiles local now cache", "profile_dirs": ""},
    inbox: {"read": "local now cache", "changed": "local cache"},
    verbs: {"list_cards": "ctx dir stage profile", "take": "ctx dir ref force profile",
            "add": "ctx dir title body take profile", "move": "ctx dir ref to force profile",
            "show": "ctx dir ref profile"}}
for mod, fns in frozen.items():
    for name, params in fns.items():
        got = " ".join(inspect.signature(getattr(mod, name)).parameters)
        assert got == params, (mod.__name__, name, got)
    assert mod.__doc__ is None
header = open(model.__file__).read().splitlines()[0]
assert header.startswith("# TEST STAND-IN"), header
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local f
  for f in model github local who inbox verbs app; do
    [[ "$(head -n 1 "$WB_STUBS/$f.py")" == "# TEST STAND-IN"* ]]
  done
}

@test "stubs: each returns the scenario from WORKBOARD_DEMO and logs its call" {
  local dir
  wb_demo >/dev/null
  dir="$(wb_modules)"
  run wb_driver "$dir" <<'PY'
import json, os, model, github, local, who, inbox
demo = os.environ["WORKBOARD_DEMO"]
doc = lambda n: json.load(open(os.path.join(demo, n + ".json")))
P2 = "octo-personal/proj-two"
assert github.poll({}, None, 1200, 1.0, None) == doc("github")
assert github.account_of("octo-work-org") == "work-acct" and github.account_of("octo-personal") == "personal-acct"
assert github.account_of("nobody") == "-"
assert github.token_for("work-acct") == "fixture-token-work-acct" and github.token_for("-") is None
assert github.next_interval(2, 4000, 1200) == 60 and github.tally() == {}
mine = local.read([{"slug": P2, "number": 25, "worktree": "/w", "at": 1}], [], 1.0)
assert mine["links"] == [{"slug": P2, "number": 25, "worktree": "/w", "at": 1}] and mine["repos"] == doc("local")["repos"]
assert local.profile_of(P2, "personal-acct") == doc("local")["repos"][1]["profile"]
assert local.slug_of(demo + "/code/proj-one/.claude/worktrees/alpha/src") == "octo-work-org/proj-one"
assert local.slug_of(demo + "/code/proj-two") == P2 and local.slug_of(demo) is None
assert who.read("http://127.0.0.1:1", {}, {}, 1.0, {}) == doc("who")
assert who.profile_dirs() == {"default": os.path.expanduser("~/.claude"), "personal": os.path.expanduser("~/.claude-personal")}
assert inbox.read({}, 1.0, {}) == doc("inbox") and inbox.changed({}, {}) is False

full = doc("board")
full.pop("rev"), full.pop("build")
assert model.build_board({}, {}, {}, {}, 7, 1800000000.0, None) == full
personal = os.path.expanduser("~/.claude-personal")
scoped = model.build_board({}, {}, {}, {}, 7, 1800000000.0, personal)
assert scoped["scope"] == personal and [r["slug"] for r in scoped["repos"]] == [P2]
assert scoped["cards"] and all(c["slug"] == P2 for c in scoped["cards"])
assert [n["id"] for n in scoped["needs"]] == ["s:personal:4202"]
work = model.build_board({}, {}, {}, {}, 7, 1800000000.0, os.path.expanduser("~/.claude"))
assert [n["id"] for n in work["needs"]] == ["s:default:4102"] and len(work["cards"]) + len(scoped["cards"]) == 12

lines = open(os.path.join(demo, "calls.log")).read().splitlines()
assert "github.poll local budget now" in lines, lines
assert "local.read links also now" in lines and "who.read panel_url profiles local now cache" in lines
assert "inbox.changed local cache" in lines and "github.tally" in lines
assert "model.build_board github local who inbox trial_days now" in lines and any(l.endswith(" scope") for l in lines)
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "stubs: WORKBOARD_STUB_RAISE makes the named function raise the first scenario title" {
  local dir
  wb_demo >/dev/null
  dir="$(wb_modules)"
  export WORKBOARD_STUB_RAISE=github.poll
  run wb_driver "$dir" <<'PY'
import json, os, github, who
title = json.load(open(os.path.join(os.environ["WORKBOARD_DEMO"], "board.json")))["cards"][0]["title"]
assert title.startswith("Fixture title")
try:
    github.poll({}, None, 1200, 1.0, None)
except RuntimeError as e:
    assert str(e) == title
else:
    raise AssertionError("did not raise")
assert who.read("u", {}, {}, 1.0, {})["v"] == 1 and github.next_interval(1, 1, 1) == 60
os.environ["WORKBOARD_STUB_RAISE"] = "read"
try:
    who.read("u", {}, {}, 1.0, {})
except RuntimeError:
    pass
else:
    raise AssertionError("bare name did not raise")
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "stub app: one registration of each kind is recorded, and its ctx serves the scenario" {
  local dir
  wb_demo >/dev/null
  dir="$(wb_modules)"
  run wb_driver "$dir" <<'PY'
import json, os, app, verbs
demo = os.environ["WORKBOARD_DEMO"]
doc = lambda n: json.load(open(os.path.join(demo, n + ".json")))
a = app.App()
f = lambda *x, **k: (0, "")
a.api("x", f), a.cli("x", f), a.command("x", f), a.route("GET", "/x", f), a.after_github(f), a.status("x", f)
assert [len(l) for l in (a.apis, a.clis, a.commands, a.routes, a.after_githubs, a.statuses)] == [1] * 6
assert a.routes[0] == ("GET", "/x", f, False) and a.apis[0] == ("x", f) and a.statuses[0] == ("x", f)
c = a.ctx
c.count("n"), c.poll_now("work-acct")
assert c.counts == ["n"] and c.polls == ["work-acct"]
board = c.board()
assert "rev" not in board and "build" not in board and board["cards"] == doc("board")["cards"]
assert c.local() == doc("local") and c.inbox() == doc("inbox")
assert c.state_dir.startswith(os.environ["BATS_TEST_TMPDIR"]) and os.path.isdir(c.state_dir)
assert c.account_of("octo-personal") == "personal-acct" and c.token_for("personal-acct") == "fixture-token-personal-acct"
assert c.profile_dirs() == {"default": os.path.expanduser("~/.claude"), "personal": os.path.expanduser("~/.claude-personal")}
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  mkdir "$BATS_TEST_TMPDIR/bare"
  run wb_driver "$BATS_TEST_TMPDIR/bare" <<'PY'
import app
try:
    import verbs
except ImportError:
    pass
else:
    raise AssertionError("importing the stub App must not expose the stub verbs")
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "stub app: a route records open, False by default; ask records its call; Req finds a header in any case" {
  local dir
  wb_demo >/dev/null
  dir="$(wb_modules)"
  run wb_driver "$dir" <<'PY'
import os, app
a = app.App()
f = lambda *x, **k: (0, "")
a.route("GET", "/gated", f), a.route("POST", "/free", f, open=True)
assert a.routes == [("GET", "/gated", f, False), ("POST", "/free", f, True)]
c = a.ctx
personal = os.path.expanduser("~/.claude-personal")
assert c.ask("bearer", {}, profile=personal) == (0, "fixture-key-personal")
assert c.ask("list", {"x": 1}) == (0, "fixture-key-none")
assert c.asks == [("bearer", {}, personal), ("list", {"x": 1}, None)]
r = app.Req("POST", "/mcp", b"{}", {"X-Workboard-Profile": "/p"}, profile="/q")
assert (r.method, r.path, r.body, r.profile) == ("POST", "/mcp", b"{}", "/q")
assert r.header("x-workboard-profile") == "/p" and r.header("Missing") is None
assert app.Req("GET", "/x").body == b"" and app.Req("GET", "/x").profile is None
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "wb_setup, wb_teardown: WORKBOARD_RUNTIME is a short directory under /tmp, and wb_teardown removes it" {
  local d="$WORKBOARD_RUNTIME"
  [[ "$d" == /tmp/wb.* ]]
  [ -d "$d" ]
  [ "${#d}" -lt 40 ]
  wb_teardown
  [ ! -e "$d" ]
}

@test "stub verbs: register records five api, five cli and one status, and each verb answers <name> ok" {
  local dir
  wb_demo >/dev/null
  dir="$(wb_modules)"
  run wb_driver "$dir" <<'PY'
import os, app, verbs
a = app.App()
verbs.register(a)
assert [n for n, _ in a.apis] == ["list", "take", "add", "move", "show"] and [n for n, _ in a.clis] == ["list", "take", "add", "move", "show"]
assert [n for n, _ in a.statuses] == ["writes"] and not a.routes and not a.commands
assert dict(a.apis)["list"](a.ctx, "/d") == (0, "list ok")
assert verbs.take(a.ctx, "/d", "11") == (0, "take ok") and verbs.add(a.ctx, "/d", "t") == (0, "add ok")
assert verbs.move(a.ctx, "/d", "11", "inbox", profile="p") == (0, "move ok")
assert verbs.show(a.ctx, "/d", "11") == (0, "show ok") and dict(a.apis)["show"](a.ctx, "/d", "11") == (0, "show ok")
cli = dict(a.clis)
assert cli["take"](["25", "--force"]) == {"dir": os.getcwd(), "ref": "25", "force": True}
assert cli["add"](["a title", "--body", "b", "--take", "--dir", "/x"]) == {"dir": "/x", "title": "a title", "body": "b", "take": True}
assert cli["show"](["25"]) == {"dir": os.getcwd(), "ref": "25"}
assert cli["list"]([]) == {"dir": os.getcwd()} and cli["list"](["--stage", "inbox"])["stage"] == "inbox"
assert cli["move"](["11", "done"]) == {"dir": os.getcwd(), "ref": "11", "to": "done"}
for name, argv in (("take", []), ("move", ["11"]), ("show", []), ("add", []), ("list", ["--stage"])):
    try:
        cli[name](argv)
    except ValueError:
        pass
    else:
        raise AssertionError(name)
assert "verbs.take ctx dir ref" in open(os.path.join(os.environ["WORKBOARD_DEMO"], "calls.log")).read().splitlines()
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "wb_driver, wb_free_port: the module directory leads sys.path, and the port can be bound" {
  local port
  mkdir "$BATS_TEST_TMPDIR/m"
  echo 'NAME = "mine"' > "$BATS_TEST_TMPDIR/m/probe.py"
  run wb_driver "$BATS_TEST_TMPDIR/m" <<'PY'
import probe, sys
assert probe.NAME == "mine" and sys.path[0].endswith("/m")
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  port="$(wb_free_port)"
  [[ "$port" =~ ^[0-9]+$ ]]
  [ "$port" -gt 1023 ]
  run $WB_PY -c 'import socket,sys; s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1])))' "$port"
  [ "$status" -eq 0 ]
}

@test "fixtures and stubs hold no name outside the fixture vocabulary" {
  run $WB_PY - "$WB_FIXTURES" "$WB_STUBS" <<'PY'
import glob, json, os, re, sys
owners, repos = {"octo-work-org", "octo-personal"}, {"proj-one", "proj-two"}
slugs = {"octo-work-org/proj-one", "octo-personal/proj-two"}
accounts = {"work-acct", "personal-acct", "-"}
people = accounts | {"colleague-a", "colleague-b", "Lead", "Secretary"}
bad = []

def walk(v, key, where):
    if isinstance(v, dict):
        for k, x in v.items():
            walk(x, k, where + "." + k)
    elif isinstance(v, list):
        for x in v:
            walk(x, key, where)
    elif isinstance(v, str):
        if key == "slug" and v not in slugs: bad.append((where, v))
        if key in ("account", "login") and v not in accounts: bad.append((where, v))
        if key in ("author", "assignees") and v not in people: bad.append((where, v))
        if key == "profile" and v.startswith("/") and not v.endswith(("/.claude", "/.claude-personal")): bad.append((where, v))
        if v.startswith("/") and not v.startswith("/wb-fixture"): bad.append((where, v))
        if re.search(r"/(Users|home|private|var)/", v): bad.append((where, v))

for path in sorted(glob.glob(os.path.join(sys.argv[1], "demo", "*.json"))):
    doc = json.load(open(path))
    walk(doc, "", os.path.basename(path))
    names = list(doc.get("accounts", {})) + list(doc.get("repos", {}) if isinstance(doc.get("repos"), dict) else []) + list(doc.get("log", {}))
    bad += [(path, n) for n in names if n not in accounts | slugs]
for path in sorted(glob.glob(os.path.join(sys.argv[1], "demo", "*.json")) + glob.glob(os.path.join(sys.argv[2], "*.py"))):
    text = open(path).read()
    for o, r in re.findall(r"github\.com/([^/\"\s]+)/([^/\"\s#]+)", text):
        if o not in owners or r not in repos: bad.append((path, o + "/" + r))
    if re.search(r"/(Users|home)/", text): bad.append((path, "a home directory"))
assert not bad, bad
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "wb_no_pycache: fails while a __pycache__ sits in the source directory" {
  WB_SRC="$BATS_TEST_TMPDIR/src"
  mkdir -p "$WB_SRC"
  wb_no_pycache
  mkdir "$WB_SRC/__pycache__"
  run wb_no_pycache
  [ "$status" -ne 0 ]
}

@test "nothing in this file wrote a __pycache__ into the module directory" {
  wb_no_pycache
}
