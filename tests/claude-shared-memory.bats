#!/usr/bin/env bats

# The shared Claude memory is split into per-topic files so that no one file
# grows past what a session can read in one piece (Anthropic's guidance is
# under 200 lines per file). The index imports the topics every session needs
# with `@topics/...` and lists the rest in one paragraph; bin/shared-memory adds
# some of those by hook. An import written inside backticks is not an import,
# and one written outside them by accident would pull a file in that nobody
# listed.

load shared-memory

TOPICS="$BATS_TEST_DIRNAME/../dot_claude-shared/topics"
SM="$BATS_TEST_DIRNAME/../bin/executable_shared-memory"
LINES_MAX=200

@test "every topic is imported once or listed in the on-demand paragraph, and every import resolves" {
  local f imports
  imports="$(grep -E '^@' "$SHARED_MEMORY" | sort)"
  [ -n "$imports" ]
  [ -z "$(echo "$imports" | uniq -d)" ] || { echo "an import appears twice"; false; }
  for f in $imports; do
    [ -f "$(dirname "$SHARED_MEMORY")/${f#@}" ] || { echo "unresolved import: $f"; false; }
  done
  run sh "$SM" topics "$(dirname "$SHARED_MEMORY")"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *unreachable* ]] || { echo "$output"; false; }
  [[ "$output" != *$'\tno'* ]] || { echo "$output"; false; }
}

# The start hook picks topics by role, so each role is held to its own bound
# and to the topics it must not carry: a peer has no Lead text, a plain session
# neither.
start_bundle() {
  printf '{"session_id":"s1","source":"startup","session_title":"%s","cwd":"/x"}' "$1" | sh "$SM" hook start
}

@test "the topics a start hook adds, per role, fit their bound and hold only what the role needs" {
  local out slug spec role bound have lack
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/profile"
  export SHARED_MEMORY_DIR="$(dirname "$SHARED_MEMORY")"
  printf '#!/bin/sh\n[ "$1" = slots ] && echo "alpha running"\nexit 0\n' > "$BATS_TEST_TMPDIR/claude-peer"
  chmod +x "$BATS_TEST_TMPDIR/claude-peer"
  mkdir -p "$BATS_TEST_TMPDIR/sock"
  python3 -I -c 'import os, socket, sys; os.chdir(sys.argv[1]); socket.socket(socket.AF_UNIX).bind("inbox")' "$BATS_TEST_TMPDIR/sock"
  unset CLAUDE_PEER_WORKTREE CLAUDE_CODE_MESSAGING_SOCKET
  # role|bound|topics it holds|topics it must not hold
  for spec in "lead|7600|talking-to-sessions claude-peers lead approvals|peer-seat" \
    "peer|4000|talking-to-sessions claude-peers peer-seat|lead approvals" \
    "peers|3300|talking-to-sessions claude-peers|lead approvals peer-seat" \
    "inbox|2200|talking-to-sessions|claude-peers lead approvals peer-seat"; do
    IFS='|' read -r role bound have lack <<< "$spec"
    case "$role" in
    lead) out="$(SHARED_MEMORY_CLAUDE_PEER="$BATS_TEST_TMPDIR/claude-peer" start_bundle x-lead)" ;;
    peer) out="$(CLAUDE_PEER_WORKTREE=/x SHARED_MEMORY_CLAUDE_PEER="$BATS_TEST_TMPDIR/claude-peer" start_bundle x)" ;;
    peers) out="$(SHARED_MEMORY_CLAUDE_PEER="$BATS_TEST_TMPDIR/claude-peer" start_bundle x)" ;;
    inbox) out="$(CLAUDE_CODE_MESSAGING_SOCKET="$BATS_TEST_TMPDIR/sock/inbox" SHARED_MEMORY_CLAUDE_PEER=/nonexistent start_bundle x)" ;;
    esac
    [ "${#out}" -lt "$bound" ] || { echo "$role start bundle is ${#out} characters, bound $bound"; false; }
    for slug in $have; do
      grep -qxF "$(head -1 "$TOPICS/$slug.md")" <<< "$out" || { echo "$role start bundle lacks $slug"; false; }
    done
    for slug in $lack; do
      ! grep -qxF "$(head -1 "$TOPICS/$slug.md")" <<< "$out" || { echo "$role start bundle holds $slug"; false; }
    done
  done
}

@test "each topic a tool hook adds fits in one hook output" {
  local out slug payload
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/profile"
  export SHARED_MEMORY_DIR="$(dirname "$SHARED_MEMORY")"
  for slug in commit-signing tailnet-routed-ssh claude-in-chrome peer-lifetime session-mail github-accounts; do
    case "$slug" in
    commit-signing) payload='{"hook_event_name":"PostToolUseFailure","session_id":"s-'$slug'","tool_name":"Bash","tool_input":{"command":"git commit"},"error":"Exit code 128\nerror: 1Password: failed to fill whole buffer"}' ;;
    tailnet-routed-ssh) payload='{"hook_event_name":"PostToolUseFailure","session_id":"s-'$slug'","tool_name":"Bash","tool_input":{"command":"ssh h"},"error":"Exit code 255\nssh: Could not resolve hostname h"}' ;;
    claude-in-chrome) payload='{"hook_event_name":"PostToolUse","session_id":"s-'$slug'","tool_name":"mcp__claude-in-chrome__tabs_context_mcp","tool_input":{},"tool_response":"ok"}' ;;
    peer-lifetime) payload='{"hook_event_name":"PostToolUse","session_id":"s-'$slug'","tool_name":"Bash","tool_input":{"command":"claude-peer stop alpha"},"tool_response":"ok"}' ;;
    session-mail) payload='{"hook_event_name":"PostToolUse","session_id":"s-'$slug'","tool_name":"SendMessage","tool_input":{},"tool_response":"ok"}' ;;
    github-accounts) payload='{"hook_event_name":"PostToolUse","session_id":"s-'$slug'","tool_name":"Bash","tool_input":{"command":"gh pr list"},"tool_response":"ok"}' ;;
    esac
    out="$(printf '%s' "$payload" | sh "$SM" hook tool)"
    [ -n "$out" ] || { echo "tool hook added nothing for $slug"; false; }
    [ "${#out}" -lt 4000 ] || { echo "tool hook output for $slug is ${#out} characters"; false; }
    grep -qF "$(head -1 "$TOPICS/$slug.md")" <<< "$out" || { echo "tool hook output lacks $slug"; false; }
  done
}

@test "each topic starts with its own ## heading and imports nothing" {
  local f
  for f in "$TOPICS"/*.md; do
    [[ "$(head -1 "$f")" == '## '* ]] || { echo "$f: first line is not a ## heading"; false; }
  done
  # A bare @path outside backticks is an import (inside a code span or a
  # code block it is not). Neither the topics nor the index's own prose may
  # hold one beyond the index's import lines.
  python3 -I - "$TOPICS" "$SHARED_MEMORY" <<'PY' || { echo "a topic or the index holds a bare @ import"; false; }
import glob, re, sys
bad = []
for f in sorted(glob.glob(sys.argv[1] + "/*.md")) + [sys.argv[2]]:
    fenced = False
    for n, line in enumerate(open(f, encoding="utf-8").read().split("\n"), 1):
        if f == sys.argv[2] and re.fullmatch(r"@topics/\S+\.md", line):
            continue
        if line.lstrip().startswith("```"):
            fenced = not fenced
        elif not fenced and re.search(r"(^|\s)@\S", re.sub(r"`[^`]*`", "", line)):
            bad.append("%s:%d: %s" % (f, n, line))
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
}

@test "every shared-memory file is under $LINES_MAX lines" {
  local f n
  for f in "$SHARED_MEMORY" "$TOPICS"/*.md; do
    n="$(wc -l < "$f")"
    [ "$n" -lt "$LINES_MAX" ] || { echo "$f is $n lines, limit under $LINES_MAX"; false; }
  done
}

@test "the expansion keeps the index's title and intro, then the sections in import order" {
  local exp
  exp="$(shared_memory_expanded)"
  [[ "$exp" == '# Shared user memory'* ]]
  [ "$(grep -c '^## ' <<< "$exp")" -eq "$(grep -c '^@' "$SHARED_MEMORY")" ]
  ! grep -q '^@' <<< "$exp" || { echo "an import line survived the expansion"; false; }
}

@test "gpt-seats is a pointer-only topic: listed once in the index, not imported, with its trigger and every qualifying phrase" {
  local topic="$TOPICS/gpt-seats.md" exp flat p
  [ "$(grep -c '^- `gpt-seats.md`:' "$SHARED_MEMORY")" -eq 1 ]
  ! grep -q '^@topics/gpt-seats.md' "$SHARED_MEMORY" || { echo "gpt-seats is imported"; false; }
  [ "$(grep -c '^@topics/delegation-and-model-routing.md$' "$SHARED_MEMORY")" -eq 1 ]
  [ "$(sh "$SM" topics "$(dirname "$SHARED_MEMORY")" | awk '$1=="gpt-seats" {print $2}')" = pointer ]
  [ "$(wc -l < "$topic")" -lt "$LINES_MAX" ]
  ! grep -q 'gpt-seats' "$SM" || { echo "a hook trigger names gpt-seats"; false; }
  # The index trigger is part of what every session loads; the protocol is not.
  exp="$(shared_memory_expanded | tr '\n' ' ' | tr -s ' ')"
  grep -qF 'before dispatching any `gpt-*` agent, after a `plan-fable` that ended in failure, incomplete output or on a substituted model' <<< "$exp" || { echo "index: no gpt-seats trigger"; false; }
  ! grep -qF 'GPT_HANDOVER' <<< "$exp" || { echo "the GPT protocol is always loaded"; false; }
  flat="$(tr '\n' ' ' < "$topic" | tr -s ' ')"
  for p in 'additional planner' 'owns its revisions' 'claude_gpt_ready MODEL' 'GPT_ROUTE_ERROR reason=helper-error' \
    'seven_day_overage_included' "You've hit your Fable limit" 'Fable limit reached' 'model_requires_usage_credits' \
    'consent_unanswered' 'GPT_HANDOVER attempted=1 dispatched=1 unavailable=0 reason=fable-limit' \
    'GPT_HANDOVER attempted=1 dispatched=0 unavailable=1 reason=route-unavailable' \
    'reason=not-fable-limit' 'reason=unclassified' 'GPT_PLAN outcome=' 'Do not try another `gpt-*` model' \
    '`claude-code-guide` with `model: opus`' 'no `resume`' 'Assess only the supplied Claude-behaviour assumptions' \
    '"verdicts"' 'GPT_ADVISOR dispatched=' 'outcome=<empty|agree|revise|unknown|unavailable|protocol-error>'; do
    grep -qF -- "$p" <<< "$flat" || { echo "gpt-seats: no '$p'"; false; }
  done
}

@test "the delegation rules stay always loaded; the reference half is a pointer-only topic with its trigger" {
  local ref="$TOPICS/delegation-reference.md" exp flat p
  [ "$(grep -c '^- `delegation-reference.md`:' "$SHARED_MEMORY")" -eq 1 ]
  ! grep -q '^@topics/delegation-reference.md' "$SHARED_MEMORY" || { echo "delegation-reference is imported"; false; }
  [ "$(sh "$SM" topics "$(dirname "$SHARED_MEMORY")" | awk '$1=="delegation-reference" {print $2}')" = pointer ]
  [ "$(head -1 "$ref")" = '## Delegation and model routing: reference' ]
  ! grep -q 'delegation-reference' "$SM" || { echo "a hook trigger names delegation-reference"; false; }
  exp="$(shared_memory_expanded | tr '\n' ' ' | tr -s ' ')"
  flat="$(tr '\n' ' ' < "$ref" | tr -s ' ')"
  grep -qF 'before changing a Claude Code setting, agent definition, model, effort or cache behaviour, or reading `/usage`' <<< "$exp" || { echo "index: no delegation-reference trigger"; false; }
  # Every rule that steers the main conversation stays in every session.
  for p in 'is the orchestrator and, for a dependent chain, the implementer' '**Five shared definitions**' \
    '**A big idea is chit-chat first' 'builds it:** read the plan here' '**Escalation is a rule, not a mood.**' \
    '**Every seat reports the same way**' '**Do not change what is being researched.**' \
    '**I am never a step.**' 'Never hand me steps to run or type' 'Ask for that go once' \
    'no step asks again for what a row names' 'the steps it needs are verified here' \
    'independent steps together' 'each in its own worktree' 'A step waits only for what it needs' \
    'spawn every step that is ready'; do
    grep -qF -- "$p" <<< "$exp" || { echo "always loaded: no '$p'"; false; }
  done
  # The serial wording is gone, not just outvoted: the old sentences left in
  # beside the new ones would still satisfy the pins above.
  for p in 'dispatched in plan order' 'each verified here before the next spawns' 'spawn, wait for the report'; do
    ! grep -qF -- "$p" <<< "$exp" || { echo "always loaded still holds '$p'"; false; }
  done
  # gpt-seats is added when a plan-gpt plan is accepted, beside the rule above.
  gpt=$(tr '\n' ' ' < "$TOPICS/gpt-seats.md" | tr -s ' ')
  for p in 'dispatched in order' 'one-step-per-worker sequencing'; do
    ! grep -qF -- "$p" <<< "$gpt" || { echo "gpt-seats still holds '$p'"; false; }
  done
  for p in '**Effort is fixed in the agent file' "**Each profile's \`settings.json\` is owned" '**The wrapper exports four defaults**' \
    '**Cache discipline.**' '**Metering on Max**' '**Lever order, Anthropic' 'Measurements behind these rules'; do
    grep -qF -- "$p" <<< "$flat" || { echo "delegation-reference: no '$p'"; false; }
    ! grep -qF -- "$p" <<< "$exp" || { echo "always loaded still holds '$p'"; false; }
  done
}

# The practice file the context review seat reads: not a topic, imported by
# nothing, and every entry carries its source, evidence, date, local result
# and status in a fixed order. Prints one line per problem.
practice_problems() {
  awk '
    function bad(m) { print NR ": " m }
    function date_ok(s) { return s ~ /^[0-9][0-9][0-9][0-9]-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$/ }
    function close_block() {
      if (inblock && n != 5) bad(blk ": expected 5 keys, found " n)
      if (status == "adopted" && here ~ /^untested/) bad(blk ": adopted with no local result")
    }
    /^@/ { bad("a line starting @ would import") }
    /^Stamp:/ { stamp++; if ($0 !~ /^Stamp: checked against Claude Code [0-9.]+ on [0-9-]+\.$/) bad("malformed stamp") }
    /^### / { close_block(); inblock = 1; n = 0; status = ""; here = ""; blk = $0; if ($0 !~ /^### P[0-9]+\. /) bad(blk ": heading is not ### P<n>.") ; next }
    /^## / { close_block(); inblock = 0; next }
    inblock && /^- / {
      split($0, kv, ": "); key = substr(kv[1], 3); val = substr($0, length(kv[1]) + 3)
      want = (n == 0) ? "Source" : (n == 1) ? "Evidence" : (n == 2) ? "Checked" : (n == 3) ? "Here" : "Status"
      n++
      if (key != want) { bad(blk ": key " n " is " key ", expected " want); next }
      if (key == "Source" && val !~ /; rank [1-4]$/) bad(blk ": Source does not end in rank 1-4")
      if (key == "Evidence" && val !~ /^(measured|documented|anecdotal)$/) bad(blk ": Evidence is " val)
      if (key == "Checked" && !date_ok(val)) bad(blk ": Checked is not a date")
      if (key == "Here") { here = val; if (val !~ /^untested/ && !date_ok(substr(val, 1, 10))) bad(blk ": Here is neither untested nor dated") }
      if (key == "Status") { status = val; if (val !~ /^(adopted|candidate|demoted)$/) bad(blk ": Status is " val) }
    }
    /^- [0-9-]+: / && !inblock { if (!date_ok(substr($0, 3, 10))) bad("Changes line has no date") }
    END { close_block(); if (stamp != 1) bad("expected one Stamp line, found " stamp+0) }
  ' "$1"
}

@test "the context practice file follows its schema and is not a topic" {
  local f="$BATS_TEST_DIRNAME/../dot_claude-shared/context-practice.md"
  [ -f "$f" ]
  [ -z "$(practice_problems "$f")" ] || { practice_problems "$f"; false; }
  [ "$(grep -c '^### P' "$f")" -gt 0 ]
  [ ! -e "$TOPICS/context-practice.md" ]
  ! grep -q 'context-practice' "$SHARED_MEMORY" || { echo "the index names the practice file"; false; }
}

@test "the practice schema check catches an adopted entry with no local result and a bad rank" {
  local f="$BATS_TEST_DIRNAME/../dot_claude-shared/context-practice.md" bad="$BATS_TEST_TMPDIR/bad.md"
  awk '/^- Status: candidate$/ && !d { print "- Status: adopted"; d = 1; next } { print }' "$f" > "$bad"
  [[ "$(practice_problems "$bad")" == *"adopted with no local result"* ]]
  awk '/; rank [1-4]$/ && !d { sub(/rank [1-4]$/, "rank 9"); d = 1 } { print }' "$f" > "$bad"
  [[ "$(practice_problems "$bad")" == *"rank 1-4"* ]]
}

# A role topic is listed in the index once, never imported, loaded by the class
# its role needs, opens with its heading and keeps the phrases a session acts on.
# Args: slug, class, heading, then the phrases.
role_topic_checks() {
  local slug="$1" class="$2" heading="$3" flat p
  shift 3
  [ "$(grep -c -F "\`$slug.md\`" "$SHARED_MEMORY")" -eq 1 ] || { echo "$slug is not listed exactly once in the index"; false; }
  ! grep -q "^@topics/$slug.md" "$SHARED_MEMORY" || { echo "$slug is imported"; false; }
  [ "$(sh "$SM" topics "$(dirname "$SHARED_MEMORY")" | awk -v s="$slug" '$1==s {print $2}')" = "$class" ]
  [ "$(head -1 "$TOPICS/$slug.md")" = "$heading" ]
  flat="$(tr '\n' ' ' < "$TOPICS/$slug.md" | tr -s ' ')"
  for p in "$@"; do
    grep -qF -- "$p" <<< "$flat" || { echo "$slug: no '$p'"; false; }
  done
}

@test "approvals is a start topic with the standing approvals and the ledger rules" {
  role_topic_checks approvals start '## Approvals I have already given' \
    'costing at most $0.25 each' 'opens the bump PR and merges it once green' 'Before I go to sleep' \
    'Only the session I typed an approval to writes its row' 'acts on the row, not on the message' \
    'One session asks' 'offer me a row'
}

@test "peer-lifetime is a tool topic with the report headings and the stop guard" {
  role_topic_checks peer-lifetime tool '## How long a peer lives (start, stop, keep)' \
    '`Asked`' '`State`' '`Decided`' '`Learned`' '`Open`' '`Session`' 'is the whole guard' 'keeping <Label>' \
    '--continue --handoff' 'type no `/exit`' 'claude-peer context list'
}

@test "github-accounts is a tool topic, added on a session's first gh command, with the wrapper rules" {
  role_topic_checks github-accounts tool '## GitHub accounts (gh CLI)' \
    '**Run `gh` plain' 'never prefix it with `GH_TOKEN=`' 'gh-doctor'
}

@test "session-mail is a tool topic with the routes, names and threads" {
  role_topic_checks session-mail tool '## Session mail: routes, names, threads' \
    'look first with `ListAgents`' 'register_agent' 'pass the full recipient list'
}

@test "peer-seat is a start topic for a peer tab" {
  role_topic_checks peer-seat start '## When you are a peer' 'keep Lead told' 'postbox lead'
}

@test "lead keeps its own rules: the approvals moved out and the harness bullet reads as signed" {
  local flat
  flat="$(tr '\n' ' ' < "$TOPICS/lead.md" | tr -s ' ')"
  ! grep -qF 'costing at most $0.25' <<< "$flat" || { echo "lead.md still holds the standing approvals"; false; }
  ! grep -qF 'never a peer I started at its pane' <<< "$flat" || { echo "lead.md still bars the pane-started peer"; false; }
  grep -qF 'never `--force` unasked' <<< "$flat"
}

# The ledger holds the operator's approvals as machine-local rows. It ships as
# a header only: a row in the source would be an approval nobody gave.
@test "the approvals ledger ships as a header-only create_ file beside the index, outside topics" {
  local src="$BATS_TEST_DIRNAME/../dot_claude-shared"
  [ -f "$src/create_approvals-ledger.md" ]
  [ ! -e "$src/approvals-ledger.md" ] || { echo "a plain-named twin would be overwritten on every apply"; false; }
  [ ! -e "$TOPICS/approvals-ledger.md" ] || { echo "the ledger under topics/ is read as a topic"; false; }
  grep -qxF '| id | given | for | covers | limit | until | words |' "$src/create_approvals-ledger.md"
  ! grep -qE '^\| *S[0-9]' "$src/create_approvals-ledger.md" || { echo "a row ships in the source"; false; }
  ! grep -qE '^## ' "$src/create_approvals-ledger.md" || { echo "a heading would be read as a section"; false; }
  ! grep -qE '^@' "$src/create_approvals-ledger.md" || { echo "an @ line would import"; false; }
}
