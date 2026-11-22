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

@test "the topics a start hook adds fit in one hook output" {
  local out slug
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/profile"
  export SHARED_MEMORY_DIR="$(dirname "$SHARED_MEMORY")" SHARED_MEMORY_CLAUDE_PEER=/nonexistent
  out="$(printf '%s' '{"session_id":"s1","source":"startup","session_title":"x-lead","cwd":"/x"}' | sh "$SM" hook start)"
  [ "${#out}" -lt 9000 ] || { echo "start hook output is ${#out} characters"; false; }
  for slug in talking-to-sessions claude-peers lead; do
    grep -qxF "$(head -1 "$TOPICS/$slug.md")" <<< "$out" || { echo "start hook output lacks $slug"; false; }
  done
}

@test "each topic a tool hook adds fits in one hook output" {
  local out slug payload
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/profile"
  export SHARED_MEMORY_DIR="$(dirname "$SHARED_MEMORY")"
  for slug in commit-signing tailnet-routed-ssh claude-in-chrome; do
    case "$slug" in
    commit-signing) payload='{"hook_event_name":"PostToolUseFailure","session_id":"s-'$slug'","tool_name":"Bash","tool_input":{"command":"git commit"},"error":"Exit code 128\nerror: 1Password: failed to fill whole buffer"}' ;;
    tailnet-routed-ssh) payload='{"hook_event_name":"PostToolUseFailure","session_id":"s-'$slug'","tool_name":"Bash","tool_input":{"command":"ssh h"},"error":"Exit code 255\nssh: Could not resolve hostname h"}' ;;
    claude-in-chrome) payload='{"hook_event_name":"PostToolUse","session_id":"s-'$slug'","tool_name":"mcp__claude-in-chrome__tabs_context_mcp","tool_input":{},"tool_response":"ok"}' ;;
    esac
    out="$(printf '%s' "$payload" | sh "$SM" hook tool)"
    [ -n "$out" ] || { echo "tool hook added nothing for $slug"; false; }
    [ "${#out}" -lt 9000 ] || { echo "tool hook output for $slug is ${#out} characters"; false; }
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
    '**Every seat reports the same way**' '**Do not change what is being researched.**'; do
    grep -qF -- "$p" <<< "$exp" || { echo "always loaded: no '$p'"; false; }
  done
  for p in '**Effort is fixed in the agent file' "**Each profile's \`settings.json\` is owned" '**The wrapper exports four defaults**' \
    '**Cache discipline.**' '**Metering on Max**' '**Lever order, Anthropic' 'Measurements behind these rules'; do
    grep -qF -- "$p" <<< "$flat" || { echo "delegation-reference: no '$p'"; false; }
    ! grep -qF -- "$p" <<< "$exp" || { echo "always loaded still holds '$p'"; false; }
  done
}
