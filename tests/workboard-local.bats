#!/usr/bin/env bats

# The work board's local reader (dot_local/libexec/workboard/local.py): fixture
# repositories made with real git, stub worktabs and claude-peer that print
# fixture rows, the document read through wb_driver. Everything lives under
# BATS_TEST_TMPDIR; no real home, registry or claim is touched. All names are
# fixtures (see CLAUDE.md).

bats_require_minimum_version 1.5.0

load helpers/workboard

setup() {
  wb_setup
  [ -f "$WB_SRC/local.py" ] || skip "local.py not built"
  wb_modules local >/dev/null
  # Real paths throughout: git prints them, so a symlinked tmp dir would not compare.
  CODE="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/code"
  mkdir -p "$CODE" "$BATS_TEST_TMPDIR/stub"
  S="$BATS_TEST_TMPDIR/stub"
  : > "$S/plan"; : > "$S/peers"; : > "$S/log"; : > "$S/calls"
  cat > "$BATS_TEST_TMPDIR/bin/worktabs" <<'SH'
#!/bin/sh
[ "$1" = plan ] && cat "$STUB/plan"
SH
  cat > "$BATS_TEST_TMPDIR/bin/claude-peer" <<'SH'
#!/bin/sh
echo "$1" >> "$STUB/calls"
case $1 in
  peers) cat "$STUB/peers" ;;
  claim) [ -f "$STUB/claim.$(basename "$2")" ] && cat "$STUB/claim.$(basename "$2")" || exit 1 ;;
  log) cat "$STUB/log" ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/worktabs" "$BATS_TEST_TMPDIR/bin/claude-peer"
  export STUB="$S" WORKBOARD_WORKTABS="$BATS_TEST_TMPDIR/bin/worktabs" WORKBOARD_CLAUDE_PEER="$BATS_TEST_TMPDIR/bin/claude-peer"
}

teardown() {
  wb_teardown
}

# mkrepo <name> <origin url or ->: a repository with one commit under $CODE.
mkrepo() {
  git init -q -b main "$CODE/$1"
  git -C "$CODE/$1" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  if [ "$2" != - ]; then git -C "$CODE/$1" remote add origin "$2"; fi
}

# plan <group> <name> <state> <dir>: one worktabs plan row.
plan() {
  printf '%s\t%s\t%s\t%s\t%s\tcd x\n' "$1" "$2" "$3" "$2" "$4" >> "$S/plan"
}

# readdoc: local.read(WB_LINKS, WB_ALSO, 1800000000) as one line in $BATS_TEST_TMPDIR/doc.json.
readdoc() {
  wb_driver "$WORKBOARD_LIBEXEC" > "$BATS_TEST_TMPDIR/doc.json" <<'PY'
import json, local
print(json.dumps(local.read(json.loads(os.environ["WB_LINKS"]), json.loads(os.environ["WB_ALSO"]), 1800000000)))
PY
}

# field <python expression over d>: printed from the document.
field() {
  $WB_PY -c 'import json,sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$BATS_TEST_TMPDIR/doc.json" "$1"
}

# claim_file <worktree name> <label> <by> <task or -> <handoff or ->
claim_file() {
  printf 'pid\t4242\nleader\t%s\nlabel\t%s\nby\t%s\ncontext\t-\ntask\t%s\nstarted\t1799990000\nhandoff\t%s\nlead-pid\t-\nlead-sid\t-\n' \
    "$CODE/main-repo" "$2" "$3" "$4" "$5" > "$S/claim.$1"
}

@test "a worktabs row gives a repository with its group and its common dir" {
  mkrepo alpha https://github.com/Octo-Work-Org/Proj-One.git
  plan work alpha ok "$CODE/alpha"
  export WB_LINKS='[]' WB_ALSO='[]'
  readdoc
  [ "$(field 'len(d["repos"])')" = 1 ]
  [ "$(field 'd["repos"][0]["slug"]')" = octo-work-org/proj-one ]
  [ "$(field 'd["repos"][0]["name"]')" = proj-one ]
  [ "$(field 'd["repos"][0]["group"]')" = work ]
  [ "$(field 'd["repos"][0]["dir"]')" = "$CODE/alpha" ]
  [ "$(field 'd["repos"][0]["common"]')" = "$CODE/alpha/.git" ]
  [ "$(field 'd["repos"][0]["account"]')" = work-acct ]
  [ "$(field 'd["repos"][0]["profile"]')" = "$HOME/.claude" ]
  wb_no_pycache
}

@test "worktabs rows that are disabled count, ones with no directory do not" {
  mkrepo alpha git@github.com:octo-work-org/proj-one.git
  mkrepo beta git@github.com:octo-personal/proj-two.git
  plan work alpha disabled "$CODE/alpha"
  plan home beta no-dir "$CODE/beta"
  plan home gone ok "$CODE/not-there"
  export WB_LINKS='[]' WB_ALSO='[]'
  readdoc
  [ "$(field '[r["slug"] for r in d["repos"]]')" = "['octo-work-org/proj-one']" ]
  [ "$(field 'd["skipped"]')" = 0 ]
  wb_no_pycache
}

@test "workboard.repo adds a repository with group -, a worktabs group is kept over it" {
  mkrepo alpha https://github.com/octo-work-org/proj-one
  mkrepo beta ssh://git@github.com/octo-personal/proj-two.git
  plan work alpha ok "$CODE/alpha"
  git config --global --add workboard.repo "$CODE/alpha"
  git config --global --add workboard.repo "$CODE/beta"
  export WB_LINKS='[]' WB_ALSO='[]'
  readdoc
  [ "$(field '[(r["slug"], r["group"]) for r in d["repos"]]')" = "[('octo-work-org/proj-one', 'work'), ('octo-personal/proj-two', '-')]" ]
  wb_no_pycache
}

@test "a linked worktree of a listed repository is not a second repository, whoever names it" {
  mkrepo alpha https://github.com/octo-work-org/proj-one
  git -C "$CODE/alpha" worktree add -q -b wt "$CODE/alpha-wt"
  plan work alpha ok "$CODE/alpha"
  plan work alpha-wt ok "$CODE/alpha-wt"
  export WB_LINKS='[]' WB_ALSO="[\"$CODE/alpha-wt\"]"
  readdoc
  [ "$(field 'len(d["repos"])')" = 1 ]
  [ "$(field 'd["repos"][0]["dir"]')" = "$CODE/alpha" ]
  wb_no_pycache
}

@test "an also directory adds a repository, a directory that is no repository adds nothing" {
  mkrepo alpha https://github.com/octo-work-org/proj-one
  mkdir "$CODE/plain"
  export WB_LINKS='[]' WB_ALSO="[\"$CODE/alpha\", \"$CODE/plain\", \"$CODE/missing\"]"
  readdoc
  [ "$(field '[(r["slug"], r["group"]) for r in d["repos"]]')" = "[('octo-work-org/proj-one', '-')]" ]
  [ "$(field 'd["skipped"]')" = 0 ]
  wb_no_pycache
}

@test "a repository with no origin is left out and counted" {
  mkrepo alpha -
  mkrepo beta /some/local/path
  mkrepo gamma https://github.com/octo-work-org/proj-one
  plan work alpha ok "$CODE/alpha"
  plan work beta ok "$CODE/beta"
  plan work gamma ok "$CODE/gamma"
  export WB_LINKS='[]' WB_ALSO="[\"$CODE/alpha\"]"
  readdoc
  [ "$(field '[r["slug"] for r in d["repos"]]')" = "['octo-work-org/proj-one']" ]
  [ "$(field 'd["skipped"]')" = 2 ]
  wb_no_pycache
}

@test "intake, write, take and notify_lead: defaults, set values, and write = yes is false" {
  mkrepo alpha https://github.com/octo-work-org/proj-one
  mkrepo beta https://github.com/octo-personal/proj-two
  mkrepo gamma https://github.com/octo-personal/proj-three
  plan work alpha ok "$CODE/alpha"
  plan home beta ok "$CODE/beta"
  plan home gamma ok "$CODE/gamma"
  git -C "$CODE/beta" config workboard.octo-personal/proj-two.intake label:good
  git -C "$CODE/beta" config workboard.octo-personal/proj-two.write true
  git -C "$CODE/beta" config workboard.octo-personal/proj-two.take auto:safe
  git -C "$CODE/beta" config workboard.octo-personal/proj-two.notify-lead true
  git -C "$CODE/gamma" config workboard.octo-personal/proj-three.intake sideways
  git -C "$CODE/gamma" config workboard.octo-personal/proj-three.write yes
  git -C "$CODE/gamma" config workboard.octo-personal/proj-three.take maybe
  git -C "$CODE/gamma" config workboard.octo-personal/proj-three.notify-lead 1
  export WB_LINKS='[]' WB_ALSO='[]'
  readdoc
  [ "$(field '[(r["intake"], r["write"], r["take"], r["notify_lead"]) for r in d["repos"]]')" = \
    "[('mine', False, 'ask', False), ('label:good', True, 'auto:safe', True), ('mine', False, 'ask', False)]" ]
  git -C "$CODE/alpha" config workboard.octo-work-org/proj-one.intake all
  git -C "$CODE/alpha" config workboard.octo-work-org/proj-one.take auto
  git -C "$CODE/gamma" config workboard.octo-personal/proj-three.intake none
  readdoc
  [ "$(field '[(r["intake"], r["take"]) for r in d["repos"]]')" = "[('all', 'auto'), ('label:good', 'auto:safe'), ('none', 'ask')]" ]
  wb_no_pycache
}

@test "worktrees list the main checkout and a linked one with their branches, a detached one with null" {
  mkrepo alpha https://github.com/octo-work-org/proj-one
  git -C "$CODE/alpha" worktree add -q -b feat/x "$CODE/alpha-x"
  git -C "$CODE/alpha" worktree add -q --detach "$CODE/alpha-d"
  plan work alpha ok "$CODE/alpha"
  export WB_LINKS='[]' WB_ALSO='[]'
  readdoc
  [ "$(field '(d["worktrees"][0]["name"], d["worktrees"][0]["main"])')" = "('alpha', True)" ]
  [ "$(field 'sorted((w["name"], w["branch"], w["main"], w["slug"]) for w in d["worktrees"][1:])')" = \
    "[('alpha-d', None, False, 'octo-work-org/proj-one'), ('alpha-x', 'feat/x', False, 'octo-work-org/proj-one')]" ]
  [ "$(field '[w["path"] for w in d["worktrees"] if w["name"] == "alpha-x"][0]')" = "$CODE/alpha-x" ]
  # a prunable worktree (its directory gone) is left out
  rm -rf "$CODE/alpha-d"
  readdoc
  [ "$(field '[w["name"] for w in d["worktrees"]]')" = "['alpha', 'alpha-x']" ]
  wb_no_pycache
}

@test "a live claim's fields arrive, and claude-peer claim runs once per live claim, not per worktree" {
  mkrepo alpha https://github.com/octo-work-org/proj-one
  git -C "$CODE/alpha" worktree add -q -b a "$CODE/slot-a"
  git -C "$CODE/alpha" worktree add -q -b b "$CODE/slot-b"
  git -C "$CODE/alpha" worktree add -q -b c "$CODE/slot-c"
  plan work alpha ok "$CODE/alpha"
  printf '%s\t4242\t%s\tAlpha\n' "$CODE/slot-a" "$CODE/alpha" > "$S/peers"
  claim_file slot-a Alpha Lead 'Fixture task: mend the thing' handoff
  export WB_LINKS='[]' WB_ALSO='[]'
  readdoc
  [ "$(field '[(w["name"], w["claim"] is not None) for w in d["worktrees"]]')" = \
    "[('alpha', False), ('slot-a', True), ('slot-b', False), ('slot-c', False)]" ]
  [ "$(field 'd["worktrees"][1]["claim"]')" = "{'label': 'Alpha', 'by': 'Lead', 'task': 'Fixture task: mend the thing', 'handoff': True, 'started': 1799990000}" ]
  [ "$(grep -c '^claim$' "$S/calls")" = 1 ]
  [ "$(grep -c '^peers$' "$S/calls")" = 1 ]
  # a dash task is null, and no handoff word is false
  claim_file slot-a Alpha Lead - -
  readdoc
  [ "$(field 'd["worktrees"][1]["claim"]["task"]')" = None ]
  [ "$(field 'd["worktrees"][1]["claim"]["handoff"]')" = False ]
  wb_no_pycache
}

@test "open_claim is set after a claim line, cleared by that label's done and by an end line for the label" {
  mkrepo alpha https://github.com/octo-work-org/proj-one
  git -C "$CODE/alpha" worktree add -q -b a "$CODE/slot-a"
  plan work alpha ok "$CODE/alpha"
  printf '%s\t4242\t%s\tAlpha\n' "$CODE/slot-a" "$CODE/alpha" > "$S/peers"
  claim_file slot-a Alpha Lead 'Fixture task' -
  export WB_LINKS='[]' WB_ALSO='[]'
  t=$'\t'
  printf '2027-01-01T00:00:00Z%sAlpha%sclaim%sFixture first claim\n2027-01-01T00:01:00Z%sBeta%sclaim%sFixture other label\n2027-01-01T00:02:00Z%sAlpha%sclaim%sFixture second claim%ssrc\n' \
    "$t" "$t" "$t" "$t" "$t" "$t" "$t" "$t" "$t" "$t" > "$S/log"
  readdoc
  [ "$(field 'd["worktrees"][1]["open_claim"]')" = "Fixture second claim" ]
  printf '2027-01-01T00:03:00Z%sBeta%sdone%s\n' "$t" "$t" "$t" >> "$S/log"
  readdoc
  [ "$(field 'd["worktrees"][1]["open_claim"]')" = "Fixture second claim" ]
  printf '2027-01-01T00:04:00Z%sAlpha%sdone%sfinished\n' "$t" "$t" "$t" >> "$S/log"
  readdoc
  [ "$(field 'd["worktrees"][1]["open_claim"]')" = None ]
  printf '2027-01-01T00:05:00Z%sAlpha%sclaim%sFixture third claim\n' "$t" "$t" "$t" >> "$S/log"
  readdoc
  [ "$(field 'd["worktrees"][1]["open_claim"]')" = "Fixture third claim" ]
  printf '2027-01-01T00:06:00Z%sIdeas%send%sAlpha ended after 3h\n' "$t" "$t" "$t" >> "$S/log"
  readdoc
  [ "$(field 'd["worktrees"][1]["open_claim"]')" = None ]
  # a label that merely begins with the claim's label is someone else
  printf '2027-01-01T00:07:00Z%sAlpha%sclaim%sFixture fourth claim\n2027-01-01T00:08:00Z%sIdeas%send%sAlphabet ended after 3h\n' \
    "$t" "$t" "$t" "$t" "$t" "$t" >> "$S/log"
  readdoc
  [ "$(field 'd["worktrees"][1]["open_claim"]')" = "Fixture fourth claim" ]
  # a worktree with no claim has none, whatever the log says
  [ "$(field 'd["worktrees"][0]["open_claim"]')" = None ]
  wb_no_pycache
}

@test "a stop line with six fields parses, and only the last 200 lines are read" {
  mkrepo alpha https://github.com/octo-work-org/proj-one
  plan work alpha ok "$CODE/alpha"
  t=$'\t'
  printf '2027-01-01T00:00:00Z%sLead%sstop%sAlpha by Lead%ssession=abc%sreport=logged\n' "$t" "$t" "$t" "$t" "$t" > "$S/log"
  export WB_LINKS='[]' WB_ALSO='[]'
  readdoc
  [ "$(field 'd["log"]["octo-work-org/proj-one"]')" = "[{'at': '2027-01-01T00:00:00Z', 'who': 'Lead', 'kind': 'stop', 'text': 'Alpha by Lead'}]" ]
  $WB_PY -c '
import sys
for i in range(250):
    print("2027-01-01T00:00:00Z\tLead\tnote\tline %d" % i)' > "$S/log"
  readdoc
  [ "$(field 'len(d["log"]["octo-work-org/proj-one"])')" = 200 ]
  [ "$(field 'd["log"]["octo-work-org/proj-one"][0]["text"]')" = "line 50" ]
  [ "$(field 'd["log"]["octo-work-org/proj-one"][-1]["text"]')" = "line 249" ]
  wb_no_pycache
}

@test "a link whose directory is missing is dropped" {
  mkrepo alpha https://github.com/octo-work-org/proj-one
  plan work alpha ok "$CODE/alpha"
  export WB_LINKS="[{\"slug\": \"octo-work-org/proj-one\", \"number\": 3, \"worktree\": \"$CODE/alpha\", \"at\": 1799999000}, {\"slug\": \"octo-work-org/proj-one\", \"number\": 4, \"worktree\": \"$CODE/gone\", \"at\": 1799999001}]" WB_ALSO='[]'
  readdoc
  [ "$(field '[l["number"] for l in d["links"]]')" = "[3]" ]
  [ "$(field 'd["links"][0]["worktree"]')" = "$CODE/alpha" ]
  [ ! -e "$HOME/.local/state/workboard" ]
  wb_no_pycache
}

# parity <repo> <expected profile>: the wrapper prints <expected profile> for the repository, and so does profile_of.
parity() {
  command -v zsh >/dev/null || skip "zsh not installed"
  local slug acct want got
  slug="$(git -C "$CODE/$1" config --get remote.origin.url | sed 's|https://github.com/||')"
  want="$(cd "$CODE/$1" && zsh -c 'source "$1"; claude_profile_dir' _ "$WB_ROOT/dot_functions" 2>/dev/null)"
  got="$($WB_PY - "$slug" <<'PY'
import sys
sys.path.insert(0, __import__("os").environ["WORKBOARD_LIBEXEC"])
import local
print(local.profile_of(sys.argv[1], local.account_of(sys.argv[1].split("/")[0])))
PY
)"
  echo "wrapper: $want / board: $got / expected: $2"
  [ "$want" = "$2" ]
  [ "$got" = "$want" ]
}

@test "parity: an account mapping gives what claude_profile_dir prints" {
  mkrepo r1 https://github.com/octo-work-org/proj-one
  parity r1 "$HOME/.claude"
  wb_no_pycache
}

@test "parity: a per-repo pin to a mapped name gives what claude_profile_dir prints" {
  mkrepo r1 https://github.com/octo-work-org/proj-one
  git config --global claude.octo-work-org/proj-one.profile personal-acct
  parity r1 "$HOME/.claude-personal"
  wb_no_pycache
}

@test "parity: a per-repo pin to a ~ directory gives what claude_profile_dir prints" {
  mkrepo r1 https://github.com/octo-work-org/proj-one
  git config --global claude.octo-work-org/proj-one.profile '~/.claude-custom/'
  parity r1 "$HOME/.claude-custom"
  wb_no_pycache
}

@test "parity: no pin and no mapped owner gives claude.profile.default as claude_profile_dir does" {
  mkrepo r1 https://github.com/octo-nobody/proj-x
  git config --global claude.profile.default '~/.claude-default'
  parity r1 "$HOME/.claude-default"
  wb_no_pycache
}

@test "parity: a pin that names nothing falls back to the owner's account, as the wrapper does" {
  mkrepo r1 https://github.com/octo-work-org/proj-one
  git config --global claude.octo-work-org/proj-one.profile nonsense
  parity r1 "$HOME/.claude"
  wb_no_pycache
}

@test "profile_of: no default mapped and nothing else is ~/.claude" {
  mkrepo r1 https://github.com/octo-nobody/proj-x
  run wb_driver "$WORKBOARD_LIBEXEC" <<'PY'
import local
print(local.profile_of("octo-nobody/proj-x", "-"))
PY
  [ "$output" = "$HOME/.claude" ]
  wb_no_pycache
}

@test "slug_of reads the shapes of git_origin_slug and account_of reads the pins" {
  mkrepo r1 https://github.com/Octo-Work-Org/Proj-One.git/
  mkrepo r2 git@github-alias:Octo-Personal/Proj-Two.git
  mkrepo r3 ssh://git@host.example/octo-personal/proj-two
  mkrepo r4 justaword
  run wb_driver "$WORKBOARD_LIBEXEC" <<PY
import local
print([local.slug_of("$CODE/r%d" % i) for i in (1, 2, 3, 4)])
print(local.account_of("Octo-Work-Org"), local.account_of("octo-personal"), local.account_of("octo-nobody"))
PY
  [ "${lines[0]}" = "['octo-work-org/proj-one', 'octo-personal/proj-two', 'octo-personal/proj-two', None]" ]
  [ "${lines[1]}" = "work-acct personal-acct -" ]
  wb_no_pycache
}

@test "without worktabs and claude-peer the document still comes back, with no claims" {
  mkrepo alpha https://github.com/octo-work-org/proj-one
  git config --global --add workboard.repo "$CODE/alpha"
  export WORKBOARD_WORKTABS="$BATS_TEST_TMPDIR/none/worktabs" WORKBOARD_CLAUDE_PEER="$BATS_TEST_TMPDIR/none/claude-peer"
  export WB_LINKS='[]' WB_ALSO='[]'
  readdoc
  [ "$(field 'len(d["repos"])')" = 1 ]
  [ "$(field 'd["worktrees"][0]["claim"]')" = None ]
  [ "$(field 'd["log"]')" = "{'octo-work-org/proj-one': []}" ]
  [ ! -s "$S/calls" ]
  wb_no_pycache
}

@test "a command that fails leaves its part empty and the document still comes back" {
  mkrepo alpha https://github.com/octo-work-org/proj-one
  plan work alpha ok "$CODE/alpha"
  printf '#!/bin/sh\nexit 3\n' > "$BATS_TEST_TMPDIR/bin/claude-peer"
  export WB_LINKS='[]' WB_ALSO='[]'
  readdoc
  [ "$(field 'len(d["repos"])')" = 1 ]
  [ "$(field 'd["worktrees"][0]["claim"]')" = None ]
  wb_no_pycache
}

@test "the document passes wb_shape local" {
  mkrepo alpha https://github.com/octo-work-org/proj-one
  git -C "$CODE/alpha" worktree add -q -b a "$CODE/slot-a"
  git -C "$CODE/alpha" worktree add -q --detach "$CODE/slot-d"
  plan work alpha ok "$CODE/alpha"
  printf '%s\t4242\t%s\tAlpha\n' "$CODE/slot-a" "$CODE/alpha" > "$S/peers"
  claim_file slot-a Alpha Lead 'Fixture task' handoff
  printf '2027-01-01T00:00:00Z\tAlpha\tclaim\tFixture task\n' > "$S/log"
  export WB_LINKS="[{\"slug\": \"octo-work-org/proj-one\", \"number\": 3, \"worktree\": \"$CODE/slot-a\", \"at\": 1799999000}]" WB_ALSO='[]'
  readdoc
  run wb_shape local "$BATS_TEST_TMPDIR/doc.json"
  [ "$status" -eq 0 ]
  [ "$(field 'd["worktrees"][1]["open_claim"]')" = "Fixture task" ]
  wb_no_pycache
}

@test "run by hand it prints one counts line, neither a claim's task nor a log line's text; the write is nowhere" {
  mkrepo alpha https://github.com/octo-work-org/proj-one
  git -C "$CODE/alpha" worktree add -q -b a "$CODE/slot-a"
  plan work alpha ok "$CODE/alpha"
  printf '%s\t4242\t%s\tAlpha\n' "$CODE/slot-a" "$CODE/alpha" > "$S/peers"
  claim_file slot-a Alpha Lead 'Fixture claim task text' -
  printf '2027-01-01T00:00:00Z\tAlpha\tclaim\tFixture log line text\n' > "$S/log"
  cd "$BATS_TEST_TMPDIR"
  run $WB_PY "$WORKBOARD_LIBEXEC/local.py"
  [ "$status" -eq 0 ]
  [ "$output" = "local: repos 1 · worktrees 2 · claims 1 · links 0 · skipped 0" ]
  [[ "$output" != *Fixture* ]]
  run $WB_PY "$WORKBOARD_LIBEXEC/local.py" --also "$CODE/alpha"
  [ "$output" = "local: repos 1 · worktrees 2 · claims 1 · links 0 · skipped 0" ]
  run $WB_PY "$WORKBOARD_LIBEXEC/local.py" --bogus
  [ "$status" -eq 2 ]
  [ ! -e "$HOME/.local/state" ]
  wb_no_pycache
}

@test "--fixture prints the demo document, and nothing live is read" {
  wb_demo >/dev/null
  : > "$S/calls"
  run $WB_PY "$WORKBOARD_LIBEXEC/local.py" --fixture "$WORKBOARD_DEMO"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$WORKBOARD_DEMO/local.json")" ]
  [ ! -s "$S/calls" ]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/out.json"
  run wb_shape local "$BATS_TEST_TMPDIR/out.json"
  [ "$status" -eq 0 ]
  mkdir "$BATS_TEST_TMPDIR/bad"
  echo '{"v": 1}' > "$BATS_TEST_TMPDIR/bad/local.json"
  run $WB_PY "$WORKBOARD_LIBEXEC/local.py" --fixture "$BATS_TEST_TMPDIR/bad"
  [ "$status" -eq 1 ]
  run $WB_PY "$WORKBOARD_LIBEXEC/local.py" --fixture "$BATS_TEST_TMPDIR/nodir"
  [ "$status" -eq 1 ]
  wb_no_pycache
}
