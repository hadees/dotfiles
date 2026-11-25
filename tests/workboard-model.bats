#!/usr/bin/env bats

# The work board's model (dot_local/libexec/workboard/model.py), tested alone:
# four input documents in, one board document out. Each test builds small
# documents in python (the `pre.py` helpers below), runs the real model on them
# and asserts on the board. The `demo` fixtures are step 1's. All names are
# fixtures (see CLAUDE.md).

bats_require_minimum_version 1.5.0

load helpers/workboard

setup() {
  wb_setup
  wb_modules model >/dev/null
  T="$BATS_TEST_TMPDIR"

  # The vocabulary every test writes its documents in: one repository, `S`, and
  # builders for the rest. A snippet may set w = None or i = None to leave the
  # who or inbox document out of the command line.
  cat > "$T/pre.py" <<'PY'
import json, subprocess, sys
NOW = 1800000000
DAY = 86400
S = "octo-work-org/proj-one"
S2 = "octo-personal/proj-two"
g = {"v": 1, "accounts": {}, "repos": {}, "issues": [], "prs": []}
l = {"v": 1, "generated_at": 1.0, "skipped": 0, "repos": [], "worktrees": [], "links": [], "log": {}}
w = {"v": 1, "fetched_at": NOW - 2.0, "sources": {"panel": "ok", "jobs": "ok"}, "rows": []}
i = {"v": 1, "fetched_at": NOW - 10.0, "source": "queue", "errors": {}, "rows": []}
_n = [4000]

def repo(slug, name, account, profile, group, take="ask"):
    g["accounts"][account] = {"login": account, "fetched_at": NOW - 10.0, "cost": 1, "remaining": 5000,
                              "interval": 60, "error": None}
    g["repos"][slug] = {"account": account, "default_branch": "main", "error": None}
    d = "/wb/code/" + name
    l["repos"].append({"slug": slug, "name": name, "dir": d, "common": d + "/.git", "group": group,
                       "account": account, "profile": profile, "intake": "all", "write": False, "take": take,
                       "notify_lead": False})
    l["log"][slug] = []

def two():
    repo(S2, "proj-two", "personal-acct", "/wb/.claude-personal", "home", "auto")

repo(S, "proj-one", "work-acct", "/wb/.claude", "work")

def name_of(slug): return slug.split("/")[1]

def issue(n, slug=S, **kw):
    d = {"slug": slug, "number": n, "title": "Fixture title %d" % n, "url": "https://example.invalid/i/%d" % n,
         "body": "Fixture body", "updated_at": NOW - 1000, "author": "colleague-a", "assignees": [], "labels": [],
         "prs": []}
    d.update(kw); g["issues"].append(d); return d

def pr(n, slug=S, **kw):
    d = {"slug": slug, "number": n, "title": "Fixture pr %d" % n, "url": "https://example.invalid/p/%d" % n,
         "state": "OPEN", "draft": False, "branch": "br-%d" % n, "updated_at": NOW - 500, "merged_at": None,
         "review": "NONE", "merge": "UNKNOWN", "checks": "NONE", "closes": []}
    d.update(kw); g["prs"].append(d); return d

def closes(n, slug=S, state="OPEN"):
    return [{"slug": slug, "number": n, "title": "Fixture title %d" % n,
             "url": "https://example.invalid/i/%d" % n, "state": state}]

def wt(name, slug=S, path=None, **kw):
    d = {"slug": slug, "path": path or "/wb/code/%s/.claude/worktrees/%s" % (name_of(slug), name), "name": name,
         "branch": "br-" + name, "main": False, "claim": None, "open_claim": None}
    d.update(kw); l["worktrees"].append(d); return d

def link(slug, number, worktree, at=NOW - 5):
    l["links"].append({"slug": slug, "number": number, "worktree": worktree["path"], "at": at})

def row(dir, **kw):
    _n[0] += 1
    d = {"id": "s:default:%d" % _n[0], "source": "session", "pid": _n[0], "profile": "default", "label": "Lead",
         "group": "work", "role": "peer", "seat": None, "text": None, "kind": "working", "reason": "",
         "since": NOW - 100, "seen": True, "needs": False, "stale": False, "dir": dir}
    d.update(kw); w["rows"].append(d); return d

def job(dir, **kw):
    _n[0] += 1
    d = {"id": "j:fixture-%d" % _n[0], "source": "job", "pid": None, "profile": "-", "label": "Lead", "group": "-",
         "role": "worker", "seat": "work-sonnet", "text": "Fixture job text", "kind": "working", "reason": "",
         "since": NOW - 100, "seen": True, "needs": False, "stale": False, "dir": dir}
    d.update(kw); w["rows"].append(d); return d

def qrow(id, slug=S, **kw):
    d = {"slug": slug, "id": id, "state": "waiting", "kind": "idea", "who": "Lead", "text": "Fixture queue " + id,
         "file": None, "issue": None, "added": NOW - 3600, "order": None, "tier": None, "score": None, "lo": None,
         "hi": None, "terms": None, "cand": False, "age": None}
    d.update(kw); i["rows"].append(d); return d
PY

  # What runs after the snippet: write the documents, run the real model.
  cat > "$T/post.py" <<'PY'
import os
T, MODEL = sys.argv[1], sys.argv[2]
cmd = [sys.executable, "-I", "-B", MODEL, "--now", str(NOW)]
for flag, name, doc in (("--github", "g", g), ("--local", "l", l), ("--who", "w", w), ("--inbox", "i", i)):
    if doc is not None:
        with open(os.path.join(T, name + ".json"), "w") as f:
            json.dump(doc, f)
        cmd += [flag, os.path.join(T, name + ".json")]
p = subprocess.run(cmd + sys.argv[3:], stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
if p.returncode:
    sys.stderr.write(p.stderr)
    sys.exit(p.returncode)
with open(os.path.join(T, "board.json"), "w") as f:
    f.write(p.stdout)
PY
}

teardown() {
  wb_teardown
}

# board <python> [model args]: build the documents, run the model, and require
# the output to pass the board checker.
board() {
  local code="$1"
  shift
  { cat "$T/pre.py"; printf '%s\n' "$code"; cat "$T/post.py"; } |
    $WB_PY - "$T" "$WORKBOARD_LIBEXEC/model.py" "$@"
  wb_shape board "$T/board.json"
}

# check <python>: assertions on the last board, as `b`; C maps key to card,
# K(n) is a key in the first repository.
check() {
  $WB_PY - "$T/board.json" "$1" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
S = "octo-work-org/proj-one"
S2 = "octo-personal/proj-two"
NOW = 1800000000
DAY = 86400
C = {c["key"]: c for c in b["cards"]}
keys = [c["key"] for c in b["cards"]]
def K(n, slug=S): return "%s#%d" % (slug, n)
exec(sys.argv[2])
PY
}

@test "an open issue with nothing else is in the inbox, and nobody is waiting on it" {
  board 'issue(11)'
  check 'c = C[K(11)]; assert c["stage"] == "inbox" and c["form"] == "issue" and not c["unattended"]
assert c["mine"] is False and c["assigned"] is False and len(b["cards"]) == 1'
}

@test "an issue assigned to the login is in building and unattended; a session row in a linked worktree changes both" {
  board 'issue(11, assignees=["work-acct"])'
  check 'c = C[K(11)]; assert c["stage"] == "building" and c["unattended"] and c["assigned"]
assert b["health"]["unattended"] == 1'
  board 'issue(11, assignees=["work-acct"])
x = wt("w1", branch="main"); link(S, 11, x)
row(x["path"] + "/sub", id="s:default:4101", pid=4101)'
  check 'c = C[K(11)]; assert c["stage"] == "building" and not c["unattended"]
assert [s["id"] for s in c["sessions"]] == ["s:default:4101"] and c["sessions"][0]["state"] == "working"
assert [h["name"] for h in c["holders"]] == ["w1"]'
  board 'issue(11)
x = wt("w1", branch="main"); link(S, 11, x); row(x["path"])'
  check 'assert C[K(11)]["stage"] == "building"'
}

@test "an own draft pull request closing an issue is building, and the board holds one card, not two" {
  board 'issue(11, prs=[{"number": 15, "url": "u", "state": "OPEN", "draft": True, "merged_at": None, "branch": "br-15", "author": "work-acct"}])
pr(15, draft=True, checks="FAILURE", merge="DRAFT", closes=closes(11))'
  check 'assert keys == [K(11)]
c = C[K(11)]; assert c["stage"] == "building" and not c["unattended"] and c["form"] == "issue"
assert len(c["prs"]) == 1 and c["prs"][0]["checks"] == "FAILURE" and c["prs"][0]["merge"] == "DRAFT"'
  board 'issue(11); pr(15, draft=True, closes=closes(11))'
  check 'assert keys == [K(11)] and len(C[K(11)]["prs"]) == 1'
}

@test "ready is review, changes requested is building" {
  board 'issue(11); pr(15, review="REVIEW_REQUIRED", closes=closes(11))'
  check 'assert C[K(11)]["stage"] == "review"'
  board 'issue(11); pr(15, review="APPROVED", closes=closes(11))'
  check 'assert C[K(11)]["stage"] == "review"'
  board 'issue(11); pr(15, review="CHANGES_REQUESTED", closes=closes(11))'
  check 'c = C[K(11)]; assert c["stage"] == "building" and not c["unattended"]'
}

@test "merged with the issue still open is landed: trial_day 1, and 3 two days later" {
  board 'issue(11); pr(15, state="MERGED", merged_at=NOW - 100, closes=closes(11))'
  check 'c = C[K(11)]; assert c["stage"] == "landed" and c["trial_day"] == 1 and len(b["cards"]) == 1'
  board 'issue(11); pr(15, state="MERGED", merged_at=NOW - 2 * DAY, closes=closes(11))'
  check 'assert C[K(11)]["stage"] == "landed" and C[K(11)]["trial_day"] == 3'
}

@test "the trial window does not apply to an open issue with a merged pull request" {
  board 'issue(11); pr(15, state="MERGED", merged_at=NOW - 30 * DAY, closes=closes(11))'
  check 'assert C[K(11)]["stage"] == "landed" and C[K(11)]["trial_day"] == 31'
}

@test "an own pull request closing nothing is a pr card" {
  board 'pr(15, review="APPROVED", checks="SUCCESS")'
  check 'c = C[K(15)]; assert c["form"] == "pr" and c["stage"] == "review" and c["number"] == 15
assert c["author"] == "work-acct" and c["mine"] and c["title"] == "Fixture pr 15" and len(c["prs"]) == 1'
  board 'pr(15, draft=True)'
  check 'assert C[K(15)]["stage"] == "building"'
}

@test "a pull request merged 8 days ago is absent and one merged 6 days ago is landed" {
  board 'pr(15, state="MERGED", merged_at=NOW - 8 * DAY)'
  check 'assert keys == []'
  board 'pr(15, state="MERGED", merged_at=NOW - 6 * DAY)'
  check 'c = C[K(15)]; assert c["form"] == "pr" and c["stage"] == "landed" and c["trial_day"] == 7'
  board 'pr(15, state="MERGED", merged_at=NOW - 6 * DAY)' --trial-days 3
  check 'assert keys == []'
}

@test "a merged pull request whose closed issue is not in the issues takes that issue's key and title" {
  board 'pr(15, state="MERGED", merged_at=NOW - DAY, closes=closes(9, state="CLOSED"))'
  check 'c = C[K(9)]; assert keys == [K(9)] and c["form"] == "issue" and c["title"] == "Fixture title 9"
assert c["url"] == "https://example.invalid/i/9" and c["number"] == 9 and c["stage"] == "landed" and c["trial_day"] == 2'
}

@test "an open pull request whose closed issue is not in the issues stays a pr card" {
  board 'pr(15, closes=closes(9))'
  check 'assert keys == [K(15)] and C[K(15)]["form"] == "pr"'
}

@test "a worktree on a non-default branch with a session row is a local card titled by its open_claim; with no who row it is no card" {
  board 'x = wt("w1", branch="br-x", open_claim="Fixture open claim"); row(x["path"], id="s:default:4101", pid=4101)'
  check 'c = C["%s@w1" % S]; assert c["form"] == "local" and c["title"] == "Fixture open claim" and c["stage"] == "building"
assert c["number"] is None and c["url"] is None and c["author"] is None and not c["mine"]
assert [s["id"] for s in c["sessions"]] == ["s:default:4101"] and not c["unattended"] and c["takeable"] == "no"
assert c["updated_at"] == 1800000000 - 100'
  board 'wt("w1", branch="br-x", open_claim="Fixture open claim")'
  check 'assert keys == []'
}

@test "a local card is titled by the claim task, else the job text, else the branch" {
  board 'x = wt("w1", claim={"label": "L", "by": "Lead", "task": "Fixture task", "handoff": False, "started": 1}); row(x["path"])'
  check 'assert C["%s@w1" % S]["title"] == "Fixture task"
h = C["%s@w1" % S]["holders"][0]; assert h["label"] == "L" and h["by"] == "Lead" and h["task"] == "Fixture task"'
  board 'x = wt("w1"); row(x["path"], id="s:default:4101", pid=4101)'
  check 'assert C["%s@w1" % S]["title"] == "br-w1"'
}

@test "a worktree on a non-default branch holding only a job row is a local card titled by the job's text, its one session a job with the row's pid" {
  board 'x = wt("w1", branch="br-x"); job(x["path"], pid=4101, profile="default", group="work", text="Fixture worker text")'
  check 'c = C["%s@w1" % S]; assert c["title"] == "Fixture worker text" and c["stage"] == "building"
assert len(c["sessions"]) == 1 and c["sessions"][0]["source"] == "job" and c["sessions"][0]["pid"] == 4101
assert c["sessions"][0]["seat"] == "work-sonnet" and c["sessions"][0]["text"] == "Fixture worker text"
assert b["needs"] == [] and b["health"]["unjoined_jobs"] == 0'
}

@test "a job row with no dir counts in unjoined_jobs and makes no card; a stale job row counts in stale_jobs" {
  board 'job(None); job(None, stale=True)'
  check 'assert keys == [] and b["health"]["unjoined_jobs"] == 2 and b["health"]["stale_jobs"] == 1
assert b["health"]["unjoined"] == 0 and b["needs"] == []'
}

@test "a worktree on the default branch with no claim and a session row is no card, and unjoined is 1" {
  board 'x = wt("w1", branch="main"); row(x["path"])'
  check 'assert keys == [] and b["health"]["unjoined"] == 1'
  board 'row("/wb/elsewhere")'
  check 'assert keys == [] and b["health"]["unjoined"] == 1'
}

@test "a pull request whose branch equals a worktree's branch gets that worktree as its holder and the row as its session" {
  board 'issue(11); pr(15, branch="br-w1", closes=closes(11))
x = wt("w1"); row(x["path"], id="s:default:4101", pid=4101)'
  check 'c = C[K(11)]; assert keys == [K(11)] and [h["name"] for h in c["holders"]] == ["w1"]
assert [s["pid"] for s in c["sessions"]] == [4101] and c["stage"] == "review"'
}

@test "a needs row on a card sets in_needs and appears in needs with the key; one with no dir has card null; needs keeps input order" {
  board 'issue(11); pr(15, branch="br-w1", closes=closes(11)); x = wt("w1")
row(None, id="s:personal:4202", pid=4202, profile="personal", needs=True, kind="asked", reason="asked a question")
row(x["path"], id="s:default:4102", pid=4102, needs=True, kind="blocked", reason="approve a Bash call")
row(x["path"], id="s:default:4103", pid=4103)'
  check 'assert C[K(11)]["in_needs"] is True
assert [n["id"] for n in b["needs"]] == ["s:personal:4202", "s:default:4102"]
assert [n["card"] for n in b["needs"]] == [None, K(11)]
n = b["needs"][1]; assert n["pid"] == 4102 and n["kind"] == "blocked" and n["reason"] == "approve a Bash call"
assert n["label"] == "Lead" and n["profile"] == "default" and b["health"]["unjoined"] == 0'
  board 'issue(11); pr(15, branch="br-w1", closes=closes(11)); x = wt("w1"); row(x["path"])'
  check 'assert C[K(11)]["in_needs"] is False and b["needs"] == []'
}

@test "in_needs is true exactly for the cards some needs entry names, scoped or not" {
  local code='two(); issue(11); pr(15, branch="br-w1", closes=closes(11)); x = wt("w1")
issue(21, slug=S2); pr(25, slug=S2, branch="br-w2", closes=closes(21, S2)); y = wt("w2", slug=S2)
issue(22, slug=S2); z = wt("w3", slug=S2, branch="main"); link(S2, 22, z)
row(x["path"], id="s:default:4102", pid=4102, needs=True, kind="blocked")
row(y["path"], id="s:personal:4202", pid=4202, profile="personal", needs=True, kind="asked")
row(z["path"], id="s:personal:4203", pid=4203, profile="personal")'
  local same='named = {n["card"] for n in b["needs"]}
assert None not in named and {c["key"] for c in b["cards"] if c["in_needs"]} == named'
  board "$code"
  check "$same
assert named == {K(11), K(21, S2)} and not C[K(22, S2)][\"in_needs\"]"
  board "$code" --scope /wb/.claude-personal
  check "$same
assert named == {K(21, S2)} and set(keys) == {K(21, S2), K(22, S2)}"
}

@test "a row in a subdirectory of a nested worktree joins the nested one, and /w/alpha does not claim a row in /w/alpha-two" {
  board 'issue(1); issue(2); issue(3)
pr(21, branch="br-alpha", closes=closes(1)); pr(22, branch="br-alpha-two", closes=closes(2))
a = wt("alpha"); a2 = wt("alpha-two")
m = wt("proj-one", path="/wb/code/proj-one", branch="main", main=True); link(S, 3, m)
row(a2["path"] + "/sub/dir", id="s:default:4101", pid=4101)
row(a["path"], id="s:default:4102", pid=4102)
row("/wb/code/proj-one/src", id="s:default:4103", pid=4103)'
  check 'ids = lambda n: [s["pid"] for s in C[K(n)]["sessions"]]
assert ids(1) == [4102] and ids(2) == [4101] and ids(3) == [4103]'
}

@test "a worktree path is a parent only by whole components" {
  board 'issue(1); pr(21, branch="br-alpha", closes=closes(1)); a = wt("alpha")
row(a["path"] + "-two", id="s:default:4101", pid=4101)'
  check 'assert C[K(1)]["sessions"] == [] and b["health"]["unjoined"] == 1'
}

@test "a waiting queue row with no issue is a queue card in the inbox keyed <slug>~Q1" {
  board 'qrow("Q1", order=1, tier=1, score="9.5", terms="u=0 p=10 h=9 /2", cand=True, file="/wb/f.md", added=NOW - 7200)'
  check 'c = C["%s~Q1" % S]; assert c["form"] == "queue" and c["stage"] == "inbox" and c["number"] is None
assert c["title"] == "Fixture queue Q1" and c["url"] is None and c["body"] == "" and c["labels"] == []
assert c["author"] == "Lead" and not c["mine"] and not c["assigned"] and c["updated_at"] == NOW - 7200
assert c["takeable"] == "no" and not c["unattended"] and c["prs"] == [] and c["holders"] == []
assert c["queue"] == {"id": "Q1", "state": "waiting", "kind": "idea", "order": 1, "tier": 1, "score": "9.5",
                      "terms": "u=0 p=10 h=9 /2", "cand": True, "file": "/wb/f.md"}'
  board 'qrow("Q1", added=None)'
  check 'assert C["%s~Q1" % S]["updated_at"] == 0'
  board 'qrow("Q1", issue=40)'
  check 'assert C["%s~Q1" % S]["number"] == 40'
}

@test "a queue row linked to an issue card makes no second card and sets that card's queue; the first row wins" {
  board 'issue(12); qrow("Q2", issue=12, order=2, tier=2, score="12.0")'
  check 'assert keys == [K(12)] and C[K(12)]["queue"]["id"] == "Q2" and C[K(12)]["queue"]["tier"] == 2
assert C[K(12)]["stage"] == "inbox"'
  board 'issue(12); qrow("Q2", issue=12); qrow("Q9", issue=12)'
  check 'assert C[K(12)]["queue"]["id"] == "Q2"'
}

@test "a taken queue row is building and not unattended; done, dropped and parked rows make nothing" {
  board 'qrow("Q1", state="taken")'
  check 'c = C["%s~Q1" % S]; assert c["stage"] == "building" and not c["unattended"]'
  board 'issue(12); qrow("Q2", issue=12, state="taken")'
  check 'assert C[K(12)]["stage"] == "building" and not C[K(12)]["unattended"]'
  board 'qrow("Q1", state="done"); qrow("Q2", state="dropped"); qrow("Q3", state="parked")
issue(12); qrow("Q4", issue=12, state="done")'
  check 'assert keys == [K(12)] and C[K(12)]["queue"] is None'
}

@test "a queue row of a slug that is not a board repository is ignored" {
  board 'qrow("Q1", slug="octo-other/elsewhere")'
  check 'assert keys == []'
}

@test "three scored inbox cards and two unscored ones come out tier first, then score as a number, then the unscored by updated_at" {
  board 'issue(11, updated_at=NOW - 300); issue(12, updated_at=NOW - 100)
qrow("Q1", order=3, tier=2, score="9.5"); qrow("Q2", order=2, tier=2, score="12.0"); qrow("Q3", order=1, tier=1, score="3.0")'
  check 'assert keys == ["%s~Q3" % S, "%s~Q2" % S, "%s~Q1" % S, K(12), K(11)]'
}

@test "a tier 1 row with the lowest score is first, and a score that is not a number counts as 0" {
  board 'qrow("Q1", order=2, tier=2, score="99.0"); qrow("Q2", order=1, tier=1, score="0.5")'
  check 'assert keys == ["%s~Q2" % S, "%s~Q1" % S]'
  board 'qrow("Q1", order=1, tier=1, score="n/a"); qrow("Q2", order=2, tier=1, score="0.1")'
  check 'assert keys == ["%s~Q2" % S, "%s~Q1" % S]'
}

@test "takeable is ask for someone else's unassigned issue under take ask, yes under auto or auto:<label>, and no for a queue card" {
  board 'issue(11, labels=["bug"])'
  check 'assert C[K(11)]["takeable"] == "ask"'
  board 'l["repos"][0]["take"] = "auto"; issue(11)'
  check 'assert C[K(11)]["takeable"] == "yes"'
  board 'l["repos"][0]["take"] = "auto:bug"; issue(11, labels=["bug"]); issue(12)'
  check 'assert C[K(11)]["takeable"] == "yes" and C[K(12)]["takeable"] == "ask"'
  board 'l["repos"][0]["take"] = "auto"; qrow("Q1")'
  check 'assert C["%s~Q1" % S]["takeable"] == "no"'
  board 'issue(11, author="work-acct")'
  check 'assert C[K(11)]["takeable"] == "yes" and C[K(11)]["mine"]'
  board 'issue(11, assignees=["work-acct"])'
  check 'assert C[K(11)]["takeable"] == "no"'
}

@test "--scope drops the other profile's repository, its cards and its needs rows, and the health counts follow" {
  board 'two(); issue(11); issue(21, slug=S2, author="personal-acct"); job(None)
row(None, id="s:default:4102", pid=4102, needs=True, kind="blocked")
row(None, id="s:personal:4202", pid=4202, profile="personal", needs=True, kind="asked")
row("/wb/elsewhere", id="s:personal:4201", pid=4201, profile="personal")'
  check 'assert set(keys) == {K(11), K(21, S2)} and [n["id"] for n in b["needs"]] == ["s:default:4102", "s:personal:4202"]
assert b["scope"] is None and b["groups"] == ["work", "home"] and b["health"]["repos"] == 2
assert [a["account"] for a in b["health"]["accounts"]] == ["work-acct", "personal-acct"]
assert b["health"]["unjoined"] == 1 and b["health"]["unjoined_jobs"] == 1'
  board 'two(); issue(11); issue(21, slug=S2, author="personal-acct"); job(None)
row(None, id="s:default:4102", pid=4102, needs=True, kind="blocked")
row(None, id="s:personal:4202", pid=4202, profile="personal", needs=True, kind="asked")
row("/wb/elsewhere", id="s:personal:4201", pid=4201, profile="personal")' --scope /wb/.claude-personal
  check 'assert keys == [K(21, S2)] and [n["id"] for n in b["needs"]] == ["s:personal:4202"]
assert b["scope"] == "/wb/.claude-personal" and b["groups"] == ["home"]
assert [r["slug"] for r in b["repos"]] == [S2] and b["health"]["repos"] == 1 and b["health"]["cards"] == 1
assert [a["account"] for a in b["health"]["accounts"]] == ["personal-acct"]
assert b["health"]["unjoined"] == 1 and b["health"]["unjoined_jobs"] == 0'
}

@test "--scope matches a repository's profile by exact path" {
  board 'issue(11)' --scope /wb/other/.claude
  check 'assert keys == [] and b["repos"] == [] and b["groups"] == []'
}

@test "with no --who and no --inbox the board is built, panel down and inbox none" {
  board 'issue(11); w = None; i = None'
  check 'h = b["health"]; assert h["panel"] == "down" and h["panel_age"] is None and h["jobs"] == "off"
assert h["inbox"] == "none" and h["inbox_errors"] == 0 and keys == [K(11)]'
}

@test "health: panel_age, jobs, inbox errors, repo errors and the accounts come from the documents" {
  board 'issue(11); g["repos"][S]["error"] = "Fixture error"; g["accounts"]["work-acct"]["error"] = "Fixture account error"
i["errors"] = {S: "Fixture inbox error"}; i["fetched_at"] = None; w["sources"]["jobs"] = "error"'
  check 'h = b["health"]; assert h["panel_age"] == 2.0 and h["jobs"] == "error" and h["inbox_errors"] == 1
assert h["repo_errors"] == 1 and h["repos"] == 1 and h["cards"] == 1
assert h["accounts"] == [{"account": "work-acct", "fetched_at": NOW - 10.0, "interval": 60, "remaining": 5000,
                          "error": "Fixture account error"}]'
}

@test "body is cut to 4,000 characters; log is the last 20 entries of the slug's log written by a holder's label" {
  board 'issue(11, body="x" * 5000)'
  check 'assert len(C[K(11)]["body"]) == 4000'
  board 'issue(11); pr(15, branch="br-w1", closes=closes(11))
wt("w1", claim={"label": "Alpha", "by": "Lead", "task": None, "handoff": False, "started": None})
l["log"][S] = [{"at": "t%02d" % n, "who": "Alpha" if n % 5 else "Secretary", "kind": "note", "text": "Fixture %d" % n}
               for n in range(40)]'
  check 'log = C[K(11)]["log"]; assert len(log) == 20 and all(e["who"] == "Alpha" for e in log)
assert log[-1]["at"] == "t39" and log[0]["at"] == "t16"'
  board 'issue(11); l["log"][S] = [{"at": "t", "who": "Alpha", "kind": "note", "text": "x"}]'
  check 'assert C[K(11)]["log"] == []'
}

@test "cards are ordered by stage, then building with sessions first, review with failing checks first, landed newest first" {
  board 'issue(1, assignees=["work-acct"], updated_at=NOW - 10); issue(2, assignees=["work-acct"], updated_at=NOW - 50)
x = wt("w2"); link(S, 2, x); row(x["path"])
issue(3); pr(23, checks="SUCCESS", updated_at=NOW - 10, closes=closes(3))
issue(4); pr(24, checks="FAILURE", updated_at=NOW - 90, closes=closes(4))
issue(5); pr(25, state="MERGED", merged_at=NOW - DAY, closes=closes(5))
issue(6); pr(26, state="MERGED", merged_at=NOW - 2 * DAY, closes=closes(6))
issue(7)'
  check 'assert keys == [K(7), K(2), K(1), K(4), K(3), K(5), K(6)]'
}

@test "a job row on no card counts in unjoined_jobs, not unjoined, and is not in needs" {
  board 'job("/wb/elsewhere")'
  check 'assert b["health"]["unjoined"] == 0 and b["health"]["unjoined_jobs"] == 1 and b["needs"] == []'
}

@test "demo inputs at --now 1800000000: the scenario's twelve cards, flags and orders, and agreement with demo/board.json" {
  wb_demo >/dev/null
  d="$WORKBOARD_DEMO"
  run $WB_PY "$WORKBOARD_LIBEXEC/model.py" --github "$d/github.json" --local "$d/local.json" --who "$d/who.json" \
    --inbox "$d/inbox.json" --now 1800000000
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$T/board.json"
  [ "$(wc -l < "$T/board.json")" -eq 1 ]
  wb_shape board "$T/board.json"
  run $WB_PY - "$T/board.json" "$d/board.json" <<'PY'
import json, sys
got = json.load(open(sys.argv[1]))
want = json.load(open(sys.argv[2]))
assert want.pop("rev") == 1 and want.pop("build") == "fixture"
P1, P2 = "octo-work-org/proj-one", "octo-personal/proj-two"
scenario = [
    (P1 + "~Q1", "queue", "inbox"), (P1 + "#12", "issue", "inbox"), (P1 + "~Q3", "queue", "inbox"),
    (P1 + "#11", "issue", "inbox"), (P2 + "#25", "issue", "building"), (P1 + "@agent-1", "local", "building"),
    (P1 + "@agent-2", "local", "building"), (P1 + "#13", "issue", "building"), (P1 + "#14", "issue", "review"),
    (P2 + "#21", "pr", "review"), (P2 + "#24", "pr", "landed"), (P2 + "#22", "issue", "landed")]
assert [(c["key"], c["form"], c["stage"]) for c in got["cards"]] == scenario
assert [c["key"] for c in got["cards"] if c["in_needs"]] == [P1 + "#14"]
assert [c["key"] for c in got["cards"] if c["unattended"]] == [P1 + "#13"]
assert {c["key"]: c["trial_day"] for c in got["cards"] if c["trial_day"] is not None} == {P2 + "#22": 3, P2 + "#24": 2}
assert [n["id"] for n in got["needs"]] == ["s:default:4102", "s:personal:4202"]
assert [n["card"] for n in got["needs"]] == [P1 + "#14", None]
assert got["health"]["unjoined"] == 1 and got["health"]["cards"] == 12 and got["health"]["stale_jobs"] == 1
assert got == want, [k for k in want if got[k] != want[k]]
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "demo inputs under --scope: the personal profile's repository only" {
  wb_demo >/dev/null
  d="$WORKBOARD_DEMO"
  run $WB_PY "$WORKBOARD_LIBEXEC/model.py" --github "$d/github.json" --local "$d/local.json" --who "$d/who.json" \
    --inbox "$d/inbox.json" --now 1800000000 --scope "$d/.claude-personal"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$T/board.json"
  wb_shape board "$T/board.json"
  check 'assert keys == [K(25, S2), K(21, S2), K(24, S2), K(22, S2)] and b["scope"].endswith("/.claude-personal")
assert [n["id"] for n in b["needs"]] == ["s:personal:4202"] and b["groups"] == ["home"]
h = b["health"]; assert h["repos"] == 1 and h["cards"] == 4 and h["unjoined"] == 0 and h["stale_jobs"] == 0
assert [a["account"] for a in h["accounts"]] == ["personal-acct"] and h["unattended"] == 0'
}

@test "run by hand: no --who and no --inbox, --trial-days and --now are optional, a missing --local is a usage error" {
  wb_demo >/dev/null
  d="$WORKBOARD_DEMO"
  run $WB_PY "$WORKBOARD_LIBEXEC/model.py" --github "$d/github.json" --local "$d/local.json" --now 1800000000
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$T/board.json"
  wb_shape board "$T/board.json"
  run $WB_PY "$WORKBOARD_LIBEXEC/model.py" --github "$d/github.json"
  [ "$status" -eq 2 ]
}

@test "model.py parses under the oldest supported python and writes no __pycache__" {
  /usr/bin/python3 -I -B -c 'import ast,sys; [ast.parse(open(f).read()) for f in sys.argv[1:]]' "$WB_SRC/model.py"
  wb_no_pycache
}
