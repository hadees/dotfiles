#!/usr/bin/env bats

# The work board's working-set view and its default link: the real parts, run by
# bin/executable_workboard against three real git repositories, a `worktabs` and
# a `workset` stand-in and a `gh` that holds no token (the cards are not under
# test: which repositories a set, a scope and a link name is). Invented owners,
# repositories and set names only.

bats_require_minimum_version 1.5.0

load helpers/workboard

setup() {
  # the real node, before wb_setup sandboxes HOME out from under its asdf shim
  NODE="$(node -p process.execPath 2>/dev/null)" || NODE=""
  wb_setup
  wb_modules board model github local who inbox >/dev/null
  WB="$WB_ROOT/bin/executable_workboard"
  PAGE="$WB_ROOT/dot_local/share/workboard/board.html"
  PORT="$(wb_free_port)"
  git config --file "$GIT_CONFIG_GLOBAL" workboard.port "$PORT"
  git config --file "$GIT_CONFIG_GLOBAL" workboard.panel-url "http://127.0.0.1:$(wb_free_port)"
  git config --file "$GIT_CONFIG_GLOBAL" user.name "Fixture Author"
  git config --file "$GIT_CONFIG_GLOBAL" user.email "fixture@example.com"
  export WORKBOARD_TICK=0.1
  export WORKBOARD_LAUNCHCTL=false
  export WORKBOARD_HTML="$BATS_TEST_TMPDIR/board.html"
  printf '<!doctype html>\n<head>\n<!--workboard:token-->\n<title>fixture</title>\n</head>\n<p>board</p>\n' > "$WORKBOARD_HTML"

  CODE="$(mkdir -p "$BATS_TEST_TMPDIR/code" && cd "$BATS_TEST_TMPDIR/code" && pwd -P)"
  ALPHA="$CODE/alpha" BETA="$CODE/beta" GAMMA="$CODE/gamma" ALPHA_WT="$CODE/alpha-wt"
  make_repo "$ALPHA" octo-work-org/alpha
  make_repo "$BETA" octo-personal/beta
  make_repo "$GAMMA" octo-work-org/gamma
  git -C "$ALPHA" worktree add -q -b side "$ALPHA_WT"
  export ALPHA BETA GAMMA

  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'SH'
#!/bin/sh
exit 1
SH
  cat > "$BATS_TEST_TMPDIR/bin/worktabs" <<'SH'
#!/bin/sh
[ "$1" = plan ] || exit 2
printf 'work\talpha\tok\t-\t%s\n' "$ALPHA"
printf 'home\tbeta\tok\t-\t%s\n' "$BETA"
printf 'work\tgamma\tok\t-\t%s\n' "$GAMMA"
SH
  # `members` exits 2 when any row is not ok, and still prints every row
  cat > "$BATS_TEST_TMPDIR/bin/workset" <<'SH'
#!/bin/sh
case "$1 ${2-}" in
  "list ") printf 'pair\nsolo\nghost\n' ;;
  "members pair") printf '~/a\t%s\tok\n~/b\t%s\tok\n~/a\t%s\tduplicate\n~/gone\t\tmissing\n' "$ALPHA" "$BETA" "$ALPHA"; exit 2 ;;
  "members solo") printf '~/g\t%s\tok\n' "$GAMMA" ;;
  "members ghost") printf '~/gone\t\tmissing\n'; exit 2 ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh" "$BATS_TEST_TMPDIR/bin/worktabs" "$BATS_TEST_TMPDIR/bin/workset"
  export WORKBOARD_GH="$BATS_TEST_TMPDIR/bin/gh"
  export WORKBOARD_WORKTABS="$BATS_TEST_TMPDIR/bin/worktabs"
  export WORKBOARD_WORKSET="$BATS_TEST_TMPDIR/bin/workset"
  export WORKBOARD_CLAUDE_PEER="$BATS_TEST_TMPDIR/bin/none"
}

teardown() {
  export WORKBOARD_LAUNCHCTL=false
  "$WB" stop >/dev/null 2>&1 || true
  wb_teardown
  return 0
}

make_repo() {
  git init -q "$1" && git -C "$1" remote add origin "https://github.com/$2.git" &&
    git -C "$1" commit -q --allow-empty -m fixture
}

# hreq PATH [Name: value]...: a GET over TCP; sets STATUS and BODY, leaves resp.body.
hreq() {
  rm -f "$BATS_TEST_TMPDIR"/resp.*
  $WB_PY - "$PORT" "$@" <<'PY' || return 1
import http.client, os, sys
port, path, rest = int(sys.argv[1]), sys.argv[2], sys.argv[3:]
c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
c.request("GET", path, headers=dict(h.split(": ", 1) for h in rest))
r = c.getresponse()
d = os.environ["BATS_TEST_TMPDIR"]
open(d + "/resp.status", "w").write(str(r.status))
open(d + "/resp.body", "wb").write(r.read())
PY
  STATUS="$(cat "$BATS_TEST_TMPDIR/resp.status")"
  BODY="$(cat "$BATS_TEST_TMPDIR/resp.body")"
}

# link_token <link>: the page token the single-use link's answer holds.
link_token() {
  hreq "${1#http://127.0.0.1:$PORT}" || return 1
  sed -n 's|.*<meta name="workboard-token" content="\([0-9a-f]*\)">.*|\1|p' <<< "$BODY"
}

wait_for() {
  local i
  for i in $(seq 1 $((100 * ${TESTS_WAIT_SCALE:-1}))); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

# set_names <token>: the served board's sets as "name=slug,slug" words, sorted.
set_names() {
  hreq /b/board.json "Authorization: Bearer $1" && [ "$STATUS" = 200 ] || return 1
  $WB_PY -c 'import json, sys; d = json.load(open(sys.argv[1])); print(" ".join("%s=%s" % (n, ",".join(m)) for n, m in sorted(d["sets"].items())))' "$BATS_TEST_TMPDIR/resp.body"
}
# repo_names: the repositories of the board last fetched.
repo_names() {
  $WB_PY -c 'import json, sys; print(" ".join(sorted(r["name"] for r in json.load(open(sys.argv[1]))["repos"])))' "$BATS_TEST_TMPDIR/resp.body"
}

local_passed() {
  run "$WB" status
  [[ "$output" == *"local passes "[1-9]* ]]
}

# boot: the server, then its first local pass (the sets are read with it).
boot() {
  run "$WB" start
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  wait_for local_passed || { echo "$output"; return 1; }
}

full_token() { link_token "$("$WB" url --all)"; }
profile_token() { link_token "$(CLAUDECODE=1 CLAUDE_CONFIG_DIR="$1" "$WB" url --all)"; }

@test "the full token's board names each working set with the board's repositories that are its ok members, and the shape holds" {
  boot
  tok="$(full_token)"
  [ "$(set_names "$tok")" = "pair=octo-personal/beta,octo-work-org/alpha solo=octo-work-org/gamma" ]
  wb_shape board "$BATS_TEST_TMPDIR/resp.body"
}

@test "a profile's board holds its own repositories only, and each set is the set filtered to them" {
  boot
  [ "$(set_names "$(profile_token "$HOME/.claude-personal")")" = "pair=octo-personal/beta" ]
  [ "$(repo_names)" = beta ]
  [ "$(set_names "$(profile_token "$HOME/.claude")")" = "pair=octo-work-org/alpha solo=octo-work-org/gamma" ]
  [ "$(repo_names)" = "alpha gamma" ]
}

@test "url --set appends #s=<name>; --set with another selector is a usage error" {
  boot
  run "$WB" url --set pair
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^http://127\.0\.0\.1:$PORT/enter/[A-Za-z0-9_-]{24,}#s=pair$ ]]
  run -2 "$WB" url --set pair --repo alpha
  run -2 "$WB" url --all --set pair
}

@test "url with no flag opens on the repository of the current directory" {
  boot
  cd "$ALPHA"
  run "$WB" url
  [[ "$output" =~ /enter/[A-Za-z0-9_-]{24,}#r=alpha$ ]]
}

@test "a worktree resolves to its main checkout's repository" {
  boot
  cd "$ALPHA_WT"
  run "$WB" url
  [[ "$output" =~ /enter/[A-Za-z0-9_-]{24,}#r=alpha$ ]]
}

@test "workboard.<slug>.view set:<name> opens on that working set, and a set that is not known falls back to the repository" {
  boot
  git config --file "$GIT_CONFIG_GLOBAL" workboard.octo-work-org/alpha.view set:pair
  cd "$ALPHA"
  run "$WB" url
  [[ "$output" =~ /enter/[A-Za-z0-9_-]{24,}#s=pair$ ]]
  git config --file "$GIT_CONFIG_GLOBAL" workboard.octo-work-org/alpha.view set:nowhere
  run "$WB" url
  [[ "$output" == *"#r=alpha" ]]
}

@test "view all, --all, a view the rule does not know and a directory the board does not know" {
  boot
  cd "$ALPHA"
  git config --file "$GIT_CONFIG_GLOBAL" workboard.octo-work-org/alpha.view all
  run "$WB" url
  [[ "$output" =~ /enter/[A-Za-z0-9_-]{24,}$ ]]
  git config --file "$GIT_CONFIG_GLOBAL" workboard.octo-work-org/alpha.view repo
  run "$WB" url --all
  [[ "$output" =~ /enter/[A-Za-z0-9_-]{24,}$ ]]
  git config --file "$GIT_CONFIG_GLOBAL" workboard.octo-work-org/alpha.view nonsense
  run "$WB" url
  [[ "$output" == *"#r=alpha" ]]
  cd "$BATS_TEST_TMPDIR"
  run "$WB" url
  [[ "$output" =~ /enter/[A-Za-z0-9_-]{24,}$ ]]
  git init -q "$BATS_TEST_TMPDIR/plain"
  cd "$BATS_TEST_TMPDIR/plain"
  run "$WB" url
  [[ "$output" =~ /enter/[A-Za-z0-9_-]{24,}$ ]]
}

@test "a profile's link never names a repository the profile cannot see" {
  boot
  cd "$ALPHA"   # a work-profile repository
  run env CLAUDECODE=1 CLAUDE_CONFIG_DIR="$HOME/.claude-personal" "$WB" url
  [[ "$output" =~ /enter/[A-Za-z0-9_-]{24,}$ ]]
  run env CLAUDECODE=1 CLAUDE_CONFIG_DIR="$HOME/.claude" "$WB" url
  [[ "$output" == *"#r=alpha" ]]
}

@test "the page shows a set's repositories only, from the fragment" {
  [ -n "$NODE" ] || skip "node not installed"
  $WB_PY - "$PAGE" "$BATS_TEST_TMPDIR/page-fns.js" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
out = [re.search(r"^function %s\(.*?^}$" % name, text, re.S | re.M).group(0) for name in ("choice", "visible")]
open(sys.argv[2], "w").write("\n".join(out))
PY
  cat > "$BATS_TEST_TMPDIR/check.js" <<'JS'
const fs = require("fs");
const location = { hash: "#s=pair" };
const doc = { sets: { pair: ["octo-work-org/alpha", "octo-personal/beta"] } };
eval(fs.readFileSync(process.argv[2], "utf8") + `
const ch = choice();
const card = function (slug) { return { slug: slug, repo: slug.split("/")[1], group: "x" }; };
if (ch.s !== "pair") throw new Error("choice");
if (!visible(card("octo-work-org/alpha"), ch) || !visible(card("octo-personal/beta"), ch)) throw new Error("member hidden");
if (visible(card("octo-work-org/gamma"), ch)) throw new Error("non-member shown");
if (visible(card("octo-work-org/gamma"), { s: "nowhere" })) throw new Error("unknown set shows a card");
if (!visible(card("octo-work-org/gamma"), { s: null, g: null, r: null })) throw new Error("no filter hides a card");
`);
JS
  run "$NODE" "$BATS_TEST_TMPDIR/check.js" "$BATS_TEST_TMPDIR/page-fns.js"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "nothing in this file wrote a __pycache__" {
  wb_no_pycache
}
