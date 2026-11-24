#!/usr/bin/env bats

# The work board's GitHub reader (dot_local/libexec/workboard/github.py), tested
# alone against a stub `gh` on WORKBOARD_GH that answers from the recorded
# GraphQL responses in tests/fixtures/workboard/graphql-*.json. No real GitHub
# call is made; owners, accounts and tokens are all invented (see CLAUDE.md).
# Python is driven through wb_driver, so no document crosses a command line.

bats_require_minimum_version 1.5.0

load helpers/workboard

setup() {
  wb_setup
  unset GH_TOKEN GITHUB_TOKEN GH_NO_TOKEN
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"       # every gh call's arguments, never its environment
  export GH_ENV_LOG="$BATS_TEST_TMPDIR/gh-env.log" # the GH_TOKEN each graphql call carried
  export GH_STATE="$BATS_TEST_TMPDIR/gh-state"
  export GQL="$WB_FIXTURES"
  mkdir -p "$GH_STATE"
  : > "$GH_ENV_LOG"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'SH'
#!/bin/sh
args=$(printf '%s ' "$@" | tr '\n' ' ')
if [ -n "${GH_TOKEN-}" ]; then set_=set; else set_=unset; fi
printf '%s[GH_TOKEN=%s]\n' "$args" "$set_" >> "$GH_LOG"
if [ "$1 $2 $3" = "auth token --user" ]; then
  [ "$4" = "${GH_NO_TOKEN-}" ] && exit 1
  if [ -e "$GH_STATE/expired" ]; then echo "tok2-$4"; else echo "tok-$4"; fi
  exit 0
fi
[ "$1 $2" = "api graphql" ] || exit 2
case "${GH_TOKEN-}" in
  *work-acct) name=work-acct f=graphql-work.json ;;
  *personal-acct) name=personal-acct f=graphql-personal.json ;;
  *) name=active-user f=graphql-personal.json ;;
esac
if [ "${GH_TOKEN-}" = tok-work-acct ] && [ -e "$GH_STATE/expire" ]; then
  rm "$GH_STATE/expire"; touch "$GH_STATE/expired"
  echo "gh: Bad credentials (HTTP 401)" >&2
  exit 1
fi
printf '%s\n' "${GH_TOKEN-}" >> "$GH_ENV_LOG"
case "$args" in
  *"query=query { viewer { login } }"*) printf '{"data":{"viewer":{"login":"%s"}}}\n' "$name"; exit 0 ;;
esac
cat "$GQL/$f"
if grep -q '"errors"' "$GQL/$f"; then echo "gh: Could not resolve to a Repository" >&2; exit 1; fi
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export WORKBOARD_GH="$BATS_TEST_TMPDIR/bin/gh"
  wb_modules github >/dev/null
}

PRE='
import calendar, json, os, time, github
W = {"slug": "octo-work-org/proj-one", "account": "work-acct", "intake": "all"}
G = {"slug": "octo-work-org/proj-gone", "account": "work-acct", "intake": "all"}
P = {"slug": "octo-personal/proj-two", "account": "personal-acct", "intake": "mine"}
NOW = 1800000000.0
def poll(*repos, prior=None, only=None, now=NOW):
    return github.poll({"repos": list(repos)}, prior, 1200, now, only)
def ts(s):
    return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))
'

# drive <python>: PRE and the given statements, run in the module directory.
drive() {
  run wb_driver "$WORKBOARD_LIBEXEC" <<<"$PRE
$1"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# gql_copy <python statement acting on d, the work response>: a private copy of
# the recorded responses, the work one changed, and GQL pointed at it.
gql_copy() {
  export GQL="$BATS_TEST_TMPDIR/gql"
  mkdir -p "$GQL"
  cp "$WB_FIXTURES/graphql-personal.json" "$GQL/"
  $WB_PY - "$WB_FIXTURES/graphql-work.json" "$GQL/graphql-work.json" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
exec(sys.argv[3])
open(sys.argv[2], "w").write(json.dumps(d) + "\n")
PY
}

@test "two owners pinned to two accounts make two requests, each with its own token, none in an argument" {
  drive '
doc = poll(W, P)
assert sorted(doc["accounts"]) == ["personal-acct", "work-acct"]
assert doc["accounts"]["work-acct"]["login"] == "work-acct"'
  [ "$(grep -c '^auth token --user work-acct ' "$GH_LOG")" -eq 1 ]
  [ "$(grep -c '^auth token --user personal-acct ' "$GH_LOG")" -eq 1 ]
  # per account: the login request, then the one board query
  [ "$(grep -c '^tok-work-acct$' "$GH_ENV_LOG")" -eq 2 ]
  [ "$(grep -c '^tok-personal-acct$' "$GH_ENV_LOG")" -eq 2 ]
  [ "$(grep -c 'query=query(\$login: String!)' "$GH_LOG")" -eq 2 ]
  run grep -c 'tok-' "$GH_LOG"
  [ "$output" = 0 ]
}

@test "an owner with no pin makes a request with no GH_TOKEN, and no token call" {
  drive '
doc = poll({"slug": "octo-nopin/proj-three", "account": "-", "intake": "mine"})
a = doc["accounts"]["-"]
assert a["login"] == "active-user" and a["error"] is None, a
assert doc["repos"]["octo-nopin/proj-three"]["account"] == "-"'
  run grep -c -e 'auth token' -e 'GH_TOKEN=set' "$GH_LOG"
  [ "$output" = 0 ]
  [ "$(grep -c 'api graphql' "$GH_LOG")" -eq 2 ]
}

@test "an account whose token call fails makes no request, and its repositories carry the error" {
  export GH_NO_TOKEN=work-acct
  drive '
doc = poll(W, P)
err = "no token for work-acct"
assert doc["accounts"]["work-acct"]["error"] == err
assert doc["repos"][W["slug"]]["error"] == err
assert not [i for i in doc["issues"] if i["slug"] == W["slug"]]
assert doc["accounts"]["personal-acct"]["error"] is None and doc["issues"]
assert github.tally() == {"polls": 2, "poll_errors": 1, "skipped_budget": 0}'
  [ "$(grep -c 'tok-work-acct' "$GH_ENV_LOG")" -eq 0 ]
  [ "$(grep -c 'api graphql' "$GH_LOG")" -eq 2 ]  # personal's two, none for work
}

@test "the normalised document has the frozen fields: one issue, one own open pull request closing it, one merged" {
  drive '
doc = poll(W)
assert doc["v"] == 1 and list(doc) == ["v", "accounts", "repos", "issues", "prs"]
assert doc["accounts"]["work-acct"] == {"login": "work-acct", "fetched_at": NOW, "cost": 2, "remaining": 4900,
                                        "interval": 60, "error": None}
assert doc["repos"] == {W["slug"]: {"account": "work-acct", "default_branch": "main", "error": None}}
i = [x for x in doc["issues"] if x["number"] == 14][0]
assert i == {"slug": W["slug"], "number": 14, "title": "Fixture title: issue closed by 15",
             "url": "https://github.com/octo-work-org/proj-one/issues/14",
             "body": "Fixture body: Fixture title: issue closed by 15", "updated_at": ts("2026-11-20T10:00:00Z"),
             "author": "work-acct", "assignees": ["work-acct"], "labels": ["bug"],
             "prs": [{"number": 15, "url": "https://github.com/octo-work-org/proj-one/pull/15", "state": "OPEN",
                      "draft": False, "merged_at": None, "branch": "wb-alpha", "author": "work-acct"}]}
other = [x for x in doc["issues"] if x["number"] == 11][0]
assert other["author"] == "colleague-a" and other["assignees"] == [] and other["prs"] == []
o, m = doc["prs"]
assert o == {"slug": W["slug"], "number": 15, "title": "Fixture title: own open pull request",
             "url": "https://github.com/octo-work-org/proj-one/pull/15", "state": "OPEN", "draft": False,
             "branch": "wb-alpha", "updated_at": ts("2026-11-20T10:00:00Z"), "merged_at": None,
             "review": "REVIEW_REQUIRED", "merge": "BLOCKED", "checks": "FAILURE",
             "closes": [{"slug": W["slug"], "number": 14, "title": "Fixture title: issue closed by 15",
                         "url": "https://github.com/octo-work-org/proj-one/issues/14", "state": "OPEN"}]}
assert m["number"] == 16 and m["state"] == "MERGED" and m["merged_at"] == ts("2026-11-19T10:00:00Z")
assert m["updated_at"] == m["merged_at"] and m["review"] == "NONE" and m["checks"] == "NONE" and m["closes"] == []'
}

@test "the checks word: EXPECTED and PENDING are PENDING, ERROR and FAILURE are FAILURE, none is NONE" {
  drive '
f = lambda s: github._checks({"commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": s}}}]}})
assert [f(s) for s in ("EXPECTED", "PENDING", "ERROR", "FAILURE", "SUCCESS")] == \
    ["PENDING", "PENDING", "FAILURE", "FAILURE", "SUCCESS"]
assert github._checks({"commits": {"nodes": []}}) == "NONE"
assert github._checks({"commits": {"nodes": [{"commit": {"statusCheckRollup": None}}]}}) == "NONE"
doc = poll(P)
assert doc["prs"][0]["checks"] == "PENDING" and doc["prs"][0]["draft"] is True and doc["prs"][0]["review"] == "NONE"'
}

@test "an own pull request in a repository not on the board is dropped" {
  drive '
doc = poll(W)
assert [p["number"] for p in doc["prs"]] == [15, 16]
assert all(p["slug"] == W["slug"] for p in doc["prs"])'
}

@test "a null alias with an errors entry sets that repository's error and keeps the other's issues" {
  drive '
doc = poll(W, G)
gone = doc["repos"][G["slug"]]
assert gone["error"].startswith("Could not resolve") and gone["default_branch"] is None, gone
assert doc["repos"][W["slug"]]["error"] is None
assert sorted(i["number"] for i in doc["issues"]) == [11, 14]
assert doc["accounts"]["work-acct"]["error"] is None'
}

@test "intake mine merges an issue present in both aliases once" {
  drive '
doc = poll(P)
nums = sorted(i["number"] for i in doc["issues"])
assert nums == [25, 30, 31], nums
q = github.build_query([P])
assert "assigned: issues(" in q and "created: issues(" in q and "assignee: $login" in q and "createdBy: $login" in q'
}

@test "the other intakes: all is one connection of 50, a label filters, none has no issue connection" {
  drive '
repo = lambda intake: github.build_query([{"slug": "o/n", "intake": intake}])
assert "issues(first: 50, states: OPEN" in repo("all") and "assigned:" not in repo("all")
q = repo("label:needs-triage")
assert "issues(first: 50, labels: [\"needs-triage\"], states: OPEN" in q
q = repo("none")
assert "issues(" not in q and "r0: repository(owner: \"o\", name: \"n\") { defaultBranchRef { name } }" in q
assert "totalCount" in q and "rateLimit { cost remaining }" in q'
}

@test "a repository name or label holding a quote character is encoded, not spliced" {
  drive '
q = github.build_query([{"slug": "octo-x/we\"ird", "intake": "none"},
                        {"slug": "o/n", "intake": "label:a\"b\\c"}])
assert "name: \"we\\\"ird\"" in q, q
assert "labels: [\"a\\\"b\\\\c\"]" in q, q
assert "we\"ird\"" not in q.replace("we\\\"ird", "")'
}

@test "totalCount 51 sets the account's error" {
  gql_copy 'd["data"]["viewer"]["open"]["totalCount"] = 51'
  drive '
doc = poll(W, P)
assert doc["accounts"]["work-acct"]["error"] == "more than 50 open pull requests; some are not shown"
assert doc["accounts"]["personal-acct"]["error"] is None
assert doc["issues"] and doc["prs"]'
}

@test "next_interval: 60 for cost 12, 108 for cost 36, doubled at 900 remaining, 0 at 200; the budget default and its config" {
  drive '
n = github.next_interval
assert n(12, 4900, 1200) == 60 and n(36, 4900, 1200) == 108
assert n(36, 900, 1200) == 216 and n(12, 999, 1200) == 120 and n(36, 1000, 1200) == 108
assert n(36, 300, 1200) == 216 and n(36, 299, 1200) == 0 and n(36, 200, 1200) == 0
assert github._budget(None) == 1200 and github._budget(0) == 1200 and github._budget(600) == 600'
  git config --file "$GIT_CONFIG_GLOBAL" workboard.budget 600
  drive 'assert github._budget(None) == 600'
}

@test "remaining under 300 is interval 0 and rate budget low; the next pass skips the account for an hour" {
  gql_copy 'd["data"]["rateLimit"]["remaining"] = 200'
  drive '
first = poll(W)
a = first["accounts"]["work-acct"]
assert a["interval"] == 0 and a["error"] == "rate budget low" and len(first["issues"]) == 2
second = poll(W, prior=first, now=NOW + 60)
assert second["accounts"]["work-acct"]["error"] == "rate budget low" and second["issues"] == first["issues"]
assert github.tally() == {"polls": 1, "poll_errors": 0, "skipped_budget": 1}
poll(W, prior=second, now=NOW + 3601)
assert github.tally()["polls"] == 2'
  [ "$(grep -c '^tok-work-acct$' "$GH_ENV_LOG")" -eq 3 ]  # login and query once, then the query again after the hour
}

@test "only naming one account leaves the other's part as it was in prior" {
  drive '
local = {"repos": [W, P]}
before = github.poll(local, None, 1200, NOW, None)
after = github.poll(local, before, 1200, NOW + 10, ["personal-acct"])
assert after["accounts"]["work-acct"] == before["accounts"]["work-acct"]
assert after["repos"][W["slug"]] == before["repos"][W["slug"]]
pick = lambda d: [x for x in d["issues"] + d["prs"] if x["slug"] == W["slug"]]
assert pick(after) == pick(before) and pick(after)
assert after["accounts"]["personal-acct"]["fetched_at"] == NOW + 10
nothing = github.poll(local, before, 1200, NOW + 20, [])
assert nothing == before'
  # work: login and query once; personal: login and query, then the query again
  [ "$(grep -c '^tok-work-acct$' "$GH_ENV_LOG")" -eq 2 ]
  [ "$(grep -c '^tok-personal-acct$' "$GH_ENV_LOG")" -eq 3 ]
}

@test "a second pass makes no second auth token call and no second login request" {
  drive '
poll(W, P)
poll(W, P, now=NOW + 60)
assert github.tally()["polls"] == 4'
  [ "$(grep -c '^auth token ' "$GH_LOG")" -eq 2 ]
  [ "$(grep -c 'query=query { viewer { login } }' "$GH_LOG")" -eq 2 ]
  [ "$(grep -c 'query=query(\$login' "$GH_LOG")" -eq 4 ]
}

@test "an authentication failure asks for the token again, once, and the pass still lands" {
  touch "$GH_STATE/expire"
  drive '
doc = poll(W)
assert doc["accounts"]["work-acct"]["error"] is None and len(doc["issues"]) == 2
assert github.tally() == {"polls": 1, "poll_errors": 0, "skipped_budget": 0}'
  [ "$(grep -c '^auth token --user work-acct ' "$GH_LOG")" -eq 2 ]
  [ "$(grep -c '^tok2-work-acct$' "$GH_ENV_LOG")" -eq 2 ]
}

@test "a request that fails leaves the prior data and says so" {
  drive '
good = poll(W)
os.environ["WORKBOARD_GH"] = "/nonexistent/gh"
bad = poll(W, prior=good, now=NOW + 60)
a = bad["accounts"]["work-acct"]
assert a["error"] == "gh not found", a
assert bad["issues"] == good["issues"] and bad["repos"][W["slug"]]["error"] == a["error"]
assert github.tally()["poll_errors"] == 1'
}

@test "account_of reads the pin, lowercases the owner, and says - for no pin; token_for says None for -" {
  drive '
assert github.account_of("octo-work-org") == "work-acct"
assert github.account_of("OCTO-Personal") == "personal-acct"
assert github.account_of("nobody") == "-"
assert github.token_for("-") is None
assert github.token_for("work-acct") == "tok-work-acct"'
}

@test "the document passes wb_shape github, a failed account's too" {
  drive '
json.dump(poll(W, G, P), open(os.environ["BATS_TEST_TMPDIR"] + "/ok.json", "w"))
open(os.environ["BATS_TEST_TMPDIR"] + "/ok.json", "a").write("\n")'
  run wb_shape github "$BATS_TEST_TMPDIR/ok.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  export GH_NO_TOKEN=work-acct
  drive '
json.dump(poll(W, P), open(os.environ["BATS_TEST_TMPDIR"] + "/failed.json", "w"))
open(os.environ["BATS_TEST_TMPDIR"] + "/failed.json", "a").write("\n")'
  run wb_shape github "$BATS_TEST_TMPDIR/failed.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "after a pass no file under HOME or BATS_TEST_TMPDIR holds a fixture title" {
  drive 'poll(W, P)'
  run grep -rli 'fixture title' "$HOME" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  run grep -rli 'fixture body' "$HOME" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "run by hand it prints one line per account and no fixture title, body or label" {
  run $WB_PY "$WB_SRC/github.py" --local "$WB_FIXTURES/demo/local.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "work-acct · cost 2 · remaining 4900 · interval 60 · issues 2 · prs 2 · ok" ]
  [ "${lines[1]}" = "personal-acct · cost 2 · remaining 4950 · interval 60 · issues 3 · prs 1 · ok" ]
  [[ "$output" != *itle* && "$output" != *ody* && "$output" != *bug* ]]
  [ "$(grep -c 'api graphql' "$GH_LOG")" -eq 4 ]
}

@test "run by hand with a failed account prints error for it" {
  export GH_NO_TOKEN=personal-acct
  run $WB_PY "$WB_SRC/github.py" --local "$WB_FIXTURES/demo/local.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[1]}" = "personal-acct · cost 0 · remaining 0 · interval 60 · issues 0 · prs 0 · error" ]
}

@test "--fixture prints the demo document and makes no gh call; a document of other keys is refused" {
  wb_demo >/dev/null
  run $WB_PY "$WB_SRC/github.py" --fixture "$WORKBOARD_DEMO"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "$(cat "$WORKBOARD_DEMO/github.json")" ]
  [ ! -e "$GH_LOG" ]
  mkdir "$BATS_TEST_TMPDIR/odd"
  echo '{"v":1,"surplus":{}}' > "$BATS_TEST_TMPDIR/odd/github.json"
  run $WB_PY "$WB_SRC/github.py" --fixture "$BATS_TEST_TMPDIR/odd"
  [ "$status" -eq 1 ]
  [ ! -e "$GH_LOG" ]
}

@test "poll writes nothing: HOME and the module directory hold the same files after a pass" {
  find "$HOME" "$WB_SRC" | sort > "$BATS_TEST_TMPDIR/before"
  drive 'poll(W, P)'
  find "$HOME" "$WB_SRC" | sort > "$BATS_TEST_TMPDIR/after"
  diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
}

@test "the file parses under the interpreter in use" {
  run $WB_PY -c 'import ast,sys; [ast.parse(open(f).read()) for f in sys.argv[1:]]' "$WB_SRC/github.py"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "nothing in this file wrote a __pycache__ into the module directory" {
  wb_no_pycache
}
