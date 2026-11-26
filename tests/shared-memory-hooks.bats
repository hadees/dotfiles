#!/usr/bin/env bats

# shared-memory adds the shared Claude memory's on-demand topics to a session
# by hook. These tests drive the real script under a sandboxed HOME and
# XDG_STATE_HOME with a fixture memory directory of invented topics and a stub
# claude-peer; no real path, session, repository or account appears (see
# CLAUDE.md). Every hook route must exit 0 whatever it is given.
#
# python3 is resolved to its real interpreter before HOME is sandboxed, for
# the reason tests/denyguard.bats gives (an asdf shim breaks under a fake
# HOME).

setup() {
  command -v python3 >/dev/null || skip "python3 not installed"
  REAL_PYTHON3="$(python3 -c 'import sys; print(sys.executable)')"

  mkdir -p "$BATS_TEST_TMPDIR/home"
  export HOME
  HOME="$(cd "$BATS_TEST_TMPDIR/home" && pwd -P)"
  export XDG_STATE_HOME="$HOME/state"
  export CLAUDE_CONFIG_DIR="$HOME/.claude-test"
  mkdir -p "$CLAUDE_CONFIG_DIR" "$HOME/bin" "$HOME/work"
  cd "$HOME/work"

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_PYTHON3" > "$BIN/python3"
  chmod +x "$BIN/python3"
  export PATH="$BIN:$PATH"
  # The environment Claude Code gives a session decides which topics apply.
  unset MEMORYGUARD_DEPTH CLAUDE_PEER_WORKTREE CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_PROJECT_DIR SHARED_MEMORY_CLAUDE_PEER

  SM="$BATS_TEST_DIRNAME/../bin/executable_shared-memory"
  LOG="$XDG_STATE_HOME/shared-memory/injections.tsv"

  # Invented topics: one imported, three start topics, one main topic, one
  # tool topic that the index lists and one that it does not.
  export SHARED_MEMORY_DIR="$BATS_TEST_TMPDIR/memory"
  mkdir -p "$SHARED_MEMORY_DIR/topics"
  cat > "$SHARED_MEMORY_DIR/CLAUDE.md" <<'EOF'
# Fixture memory

Topics this file does not import:

- `talking-to-sessions.md`: another session.
- `claude-peers.md` and `lead.md`: a repo with peers.
- `peer-seat.md`, `approvals.md`, `peer-lifetime.md` and `session-mail.md`: a role, a peer, mail.
- `github-accounts.md`: a first gh command.
- `commit-signing.md`: a commit that fails to sign.
- `claude-in-chrome.md`: the browser.
- `web-fetching.md`: a fetched page.
- `delegation-and-model-routing.md`: how to delegate.

@topics/always-here.md
EOF
  local t
  for t in always-here talking-to-sessions claude-peers peer-seat lead approvals peer-lifetime session-mail github-accounts commit-signing tailnet-routed-ssh claude-in-chrome web-fetching delegation-and-model-routing; do
    printf '## Fixture %s\n\nBODY-%s\n' "$t" "$t" > "$SHARED_MEMORY_DIR/topics/$t.md"
  done

  # A stub claude-peer: prints $STUB_SLOTS lines for `slots`.
  PEER="$BATS_TEST_TMPDIR/claude-peer"
  printf '#!/bin/sh\n[ "$1" = slots ] && [ -n "${STUB_SLOTS:-}" ] && printf "%%s\\n" "$STUB_SLOTS"\nexit 0\n' > "$PEER"
  chmod +x "$PEER"
  export SHARED_MEMORY_CLAUDE_PEER="$PEER"
}

start() {
  local payload=${1-}
  [ -n "$payload" ] || payload="{\"session_id\":\"s1\",\"cwd\":\"$HOME/work\"}"
  printf '%s' "$payload" | sh "$SM" hook start
}

main() {
  local payload=${1-}
  [ -n "$payload" ] || payload="{\"session_id\":\"s1\",\"cwd\":\"$HOME/work\"}"
  printf '%s' "$payload" | sh "$SM" hook main
}

tool() {
  printf '%s' "$1" | sh "$SM" hook tool
}

# The additionalContext of the one JSON object a tool hook printed.
context() {
  printf '%s' "$output" | python3 -c 'import json, sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'
}

SIGN_FAIL='{"hook_event_name":"PostToolUseFailure","session_id":"s1","tool_name":"Bash","tool_input":{"command":"git commit -m x"},"error":"Exit code 128\nerror: 1Password: failed to fill whole buffer\nfatal: failed to write commit object"}'
SSH_FAIL='{"hook_event_name":"PostToolUseFailure","session_id":"s1","tool_name":"Bash","tool_input":{"command":"cd x && ssh host true"},"error":"Exit code 255\nssh: connect to host host port 22: Connection refused"}'
CHROME='{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"mcp__claude-in-chrome__tabs_context_mcp","tool_input":{},"tool_response":"ok"}'

@test "topics: imported wins, listed pointer and unreachable are classed, exit 1 when one is neither" {
  run sh "$SM" topics
  [ "$status" -eq 1 ]
  [[ "$output" == *$'always-here\talways\t-'* ]]
  [[ "$output" == *$'claude-peers\tstart\tyes'* ]]
  [[ "$output" == *$'commit-signing\ttool\tyes'* ]]
  [[ "$output" == *$'delegation-and-model-routing\tmain\tyes'* ]]
  [[ "$output" == *$'tailnet-routed-ssh\ttool\tno'* ]]
  # the table's topic that the index imports is "always", whatever the table says
  printf '@topics/lead.md\n' >> "$SHARED_MEMORY_DIR/CLAUDE.md"
  run sh "$SM" topics
  [[ "$output" == *$'lead\talways\t-'* ]]
  printf '@topics/delegation-and-model-routing.md\n' >> "$SHARED_MEMORY_DIR/CLAUDE.md"
  run sh "$SM" topics
  [[ "$output" == *$'delegation-and-model-routing\talways\t-'* ]]
  # a topic that nothing lists, imports or hooks is unreachable
  printf '## Orphan\n' > "$SHARED_MEMORY_DIR/topics/orphan.md"
  run sh "$SM" topics
  [[ "$output" == *$'orphan\tunreachable\tno'* ]]
  # one that is only listed is a pointer
  printf -- '- `orphan.md`: nothing.\n' >> "$SHARED_MEMORY_DIR/CLAUDE.md"
  run sh "$SM" topics
  [[ "$output" == *$'orphan\tpointer\tyes'* ]]
}

@test "topics: exit 0 when every topic is imported or listed, and DIR may be an argument" {
  rm "$SHARED_MEMORY_DIR/topics/tailnet-routed-ssh.md"
  run sh "$SM" topics
  [ "$status" -eq 0 ]
  run sh "$SM" topics "$BATS_TEST_TMPDIR/nowhere"
  [ "$status" -eq 1 ]
  run env SHARED_MEMORY_DIR="$BATS_TEST_TMPDIR/nowhere" sh "$SM" topics "$SHARED_MEMORY_DIR"
  [ "$status" -eq 0 ]
}

@test "settings: the frozen block, and every command fails open under a timeout" {
  run sh "$SM" settings
  [ "$status" -eq 0 ]
  local expected
  expected="$(cat <<'EOF'
shared-memory does not edit settings.json — each profile's file is owned by
its overlay. Add these to that file's "hooks" (merging with what is there):

  "SessionStart": [
    { "hooks": [
      { "type": "command", "timeout": 10, "command": "[ -x ~/bin/shared-memory ] && exec ~/bin/shared-memory hook start || true" },
      { "type": "command", "timeout": 5, "command": "[ -x ~/bin/shared-memory ] && exec ~/bin/shared-memory hook main || true" }
    ] }
  ],
  "PostToolUse": [
    { "matcher": "Bash|Skill|SendMessage|WebFetch|mcp__claude-in-chrome__.*|mcp__postbox__.*",
      "hooks": [{ "type": "command", "timeout": 5, "command": "[ -x ~/bin/shared-memory ] && exec ~/bin/shared-memory hook tool || true" }] }
  ],
  "PostToolUseFailure": [
    { "matcher": "Bash|Skill|SendMessage|WebFetch|mcp__claude-in-chrome__.*|mcp__postbox__.*",
      "hooks": [{ "type": "command", "timeout": 5, "command": "[ -x ~/bin/shared-memory ] && exec ~/bin/shared-memory hook tool || true" }] }
  ]

SessionStart adds the messaging, Claude Peers, peer and Lead topics to a
session they apply to and, through `hook main`, the delegation rules to every
session (a subagent runs neither); the two tool events add the commit-signing,
tailnet, Claude in Chrome, peer lifetime, session mail, GitHub accounts and web
fetching topics once per session when their trigger appears. Every entry fails open, and
a topic the shared index still imports is never added.
EOF
)"
  [ "$output" = "$expected" ]
  local line n=0
  while IFS= read -r line; do
    [[ "$line" == *'"command"'* ]] || continue
    n=$((n + 1))
    [[ "$line" == *'|| true" }'* ]] || { echo "no || true: $line"; false; }
    [[ "$line" == *'"timeout"'* ]] || { echo "no timeout: $line"; false; }
  done <<< "$output"
  [ "$n" -eq 4 ]
}

@test "no route of the script can exit 2, which would block a session" {
  ! grep -nE 'exit 2|sys\.exit\(2\)|return 2' "$SM" || { echo "an exit 2 is in the script"; false; }
}

@test "hook start: never prints the main topic, in any role" {
  CLAUDE_PEER_WORKTREE="$HOME/work" run start
  [[ "$output" != *BODY-delegation-and-model-routing* ]]
  run start '{"session_id":"s1","session_title":"proj-lead"}'
  [[ "$output" == *BODY-lead* ]]
  [[ "$output" != *BODY-delegation-and-model-routing* ]]
  STUB_SLOTS=$'a\trunning' run start
  [[ "$output" == *BODY-claude-peers ]]
  [[ "$output" != *BODY-delegation-and-model-routing* ]]
}

@test "hook main: prints the header and the topic, the same in every role, and no role topic" {
  local header="shared-memory: these shared-memory topics apply to this session (a main conversation), so they are added here:"
  run main
  [ "$status" -eq 0 ]
  [ "$output" = "$header"$'\n\n## Fixture delegation-and-model-routing\n\nBODY-delegation-and-model-routing' ]
  local plain="$output"
  run main '{"session_id":"s1","session_title":"proj-lead"}'
  [ "$output" = "$plain" ]
  CLAUDE_PEER_WORKTREE="$HOME/work" run main
  [ "$output" = "$plain" ]
  STUB_SLOTS=$'a\trunning' run main
  [ "$output" = "$plain" ]
  [ "$(cut -f3,4,5 "$LOG" | sort -u)" = "$(printf 'main\tdelegation-and-model-routing\tinjected')" ]
}

@test "hook main: runs on every source and never runs claude-peer" {
  printf '#!/bin/sh\necho called >> "%s/peer-calls"\n' "$BATS_TEST_TMPDIR" > "$PEER"
  local src
  for src in startup resume clear compact fork; do
    run main "{\"session_id\":\"s1\",\"source\":\"$src\",\"cwd\":\"$HOME/work\"}"
    [[ "$output" == *BODY-delegation-and-model-routing ]] || { echo "no output for $src"; false; }
  done
  [ ! -e "$BATS_TEST_TMPDIR/peer-calls" ]
}

@test "hook main: a topic the index imports is not added, and is logged imported" {
  printf '@topics/delegation-and-model-routing.md\n' >> "$SHARED_MEMORY_DIR/CLAUDE.md"
  run main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cut -f3- "$LOG")" = "$(printf 'main\tdelegation-and-model-routing\timported')" ]
}

@test "hook main: a topic file that is missing is skipped" {
  rm "$SHARED_MEMORY_DIR/topics/delegation-and-model-routing.md"
  run main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook main: over 9,000 characters it names the file instead, and logs oversize" {
  { printf '## Big\n\n'; head -c 9500 /dev/zero | tr '\0' x; printf '\n'; } > "$SHARED_MEMORY_DIR/topics/delegation-and-model-routing.md"
  run main
  [ "$status" -eq 0 ]
  [ "${#output}" -lt 9000 ]
  [ "${lines[0]}" = "shared-memory: these shared-memory topics apply to this session (a main conversation), so they are added here:" ]
  [ "${lines[1]}" = "read ~/.claude-shared/topics/delegation-and-model-routing.md now: it applies to this session and is too long to add here." ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(cut -f3,5 "$LOG")" = "$(printf 'main\toversize')" ]
}

@test "hook main: silent under MEMORYGUARD_DEPTH; malformed JSON, empty stdin and a missing directory exit 0 with no output" {
  MEMORYGUARD_DEPTH=1 run main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$LOG" ]
  run main 'not json {'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run sh "$SM" hook main < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run main '["a list"]'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  SHARED_MEMORY_DIR="$BATS_TEST_TMPDIR/nowhere" run main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook main: a PATH without python3 exits 0 with no output and leaves a nopython row" {
  local nopy="$BATS_TEST_TMPDIR/nopy" t
  mkdir -p "$nopy"
  for t in cat mktemp rm date mkdir; do ln -s "$(command -v "$t")" "$nopy/$t"; done
  run env PATH="$nopy" /bin/sh "$SM" hook main <<< '{"session_id":"s1"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$(cut -f2- "$LOG")" == $'.claude-test\tmain\t-\tnopython' ]]
}

@test "hook start: a peer tab gets the messaging, peers and peer-seat topics, and neither lead nor approvals" {
  CLAUDE_PEER_WORKTREE="$HOME/work" run start
  [ "$status" -eq 0 ]
  [[ "$output" == "shared-memory: these shared-memory topics apply to this session (a Claude Peers tab), so they are added here:"$'\n\n## Fixture talking-to-sessions'* ]]
  [[ "$output" == *BODY-talking-to-sessions*BODY-claude-peers*BODY-peer-seat ]]
  [[ "$output" != *BODY-lead* ]]
  [[ "$output" != *BODY-approvals* ]]
}

@test "hook start: a -lead session title outside a peer tab selects messaging, peers, lead and approvals" {
  run start '{"session_id":"s1","session_title":"proj-lead"}'
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"(the Lead session)"* ]]
  [[ "$output" == *BODY-talking-to-sessions*BODY-claude-peers*BODY-lead*BODY-approvals ]]
  [[ "$output" != *BODY-peer-seat* ]]
  run start '{"session_id":"s1","session_title":"proj-leader"}'
  [ -z "$output" ]
}

@test "hook start: claude-peer slots listing a slot selects messaging and peers only, an empty listing none" {
  STUB_SLOTS=$'a\trunning' run start
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"(a repo with Claude Peers)"* ]]
  [[ "$output" == *BODY-talking-to-sessions*BODY-claude-peers ]]
  [[ "$output" != *BODY-peer-seat* ]]
  [[ "$output" != *BODY-lead* ]]
  [[ "$output" != *BODY-approvals* ]]
  run start
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # the project directory, not the payload's cwd, is where slots looks
  printf '#!/bin/sh\n[ "$2" = "%s" ] && echo slot\n' "$BATS_TEST_TMPDIR" > "$PEER"
  CLAUDE_PROJECT_DIR="$BATS_TEST_TMPDIR" run start
  [[ "$output" == *BODY-claude-peers* ]]
}

@test "hook start: postbox wired selects only the messaging topic" {
  printf '#!/bin/sh\n' > "$HOME/bin/postbox"
  chmod +x "$HOME/bin/postbox"
  run start
  [ -z "$output" ]
  printf '{"hooks":{"SessionStart":[{"hooks":[{"command":"~/bin/postbox hook start"}]}]}}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  run start
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"(postbox wired)"* ]]
  [[ "$output" == *BODY-talking-to-sessions ]]
  [[ "$output" != *BODY-claude-peers* ]]
}

@test "hook start: a native inbox socket selects only the messaging topic" {
  mkdir -p "$BATS_TEST_TMPDIR/sock"
  (cd "$BATS_TEST_TMPDIR/sock" && python3 -c 'import socket; s = socket.socket(socket.AF_UNIX); s.bind("inbox")')
  CLAUDE_CODE_MESSAGING_SOCKET="$BATS_TEST_TMPDIR/sock/inbox" run start
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"(a native inbox)"* ]]
  [[ "$output" == *BODY-talking-to-sessions ]]
  [[ "$output" != *BODY-claude-peers* ]]
  # a path that is not a socket is not an inbox
  : > "$BATS_TEST_TMPDIR/file"
  CLAUDE_CODE_MESSAGING_SOCKET="$BATS_TEST_TMPDIR/file" run start
  [ -z "$output" ]
}

@test "hook start: the conditions that are true are all named" {
  CLAUDE_PEER_WORKTREE="$HOME/work" run start '{"session_id":"s1","session_title":"x-lead"}'
  [[ "${lines[0]}" == *"(a Claude Peers tab, the Lead session)"* ]]
}

@test "hook start: a topic the index imports is never printed, and is logged imported" {
  printf '@topics/peer-seat.md\n@topics/talking-to-sessions.md\n' >> "$SHARED_MEMORY_DIR/CLAUDE.md"
  CLAUDE_PEER_WORKTREE="$HOME/work" run start
  [ "$status" -eq 0 ]
  [[ "$output" == *BODY-claude-peers ]]
  [[ "$output" != *BODY-peer-seat* ]]
  [[ "$output" != *BODY-talking* ]]
  [ "$(cut -f3,4,5 "$LOG" | sort)" = "$(printf 'start\tclaude-peers\tinjected\nstart\tpeer-seat\timported\nstart\ttalking-to-sessions\timported')" ]
  # nothing left to add: no output at all
  printf '@topics/claude-peers.md\n' >> "$SHARED_MEMORY_DIR/CLAUDE.md"
  CLAUDE_PEER_WORKTREE="$HOME/work" run start
  [ -z "$output" ]
}

@test "hook start: a topic file that is missing is skipped" {
  rm "$SHARED_MEMORY_DIR/topics/peer-seat.md"
  CLAUDE_PEER_WORKTREE="$HOME/work" run start
  [ "$status" -eq 0 ]
  [[ "$output" == *BODY-claude-peers ]]
}

@test "hook start: over 9,000 characters it names the files instead, and logs oversize" {
  { printf '## Big\n\n'; head -c 9500 /dev/zero | tr '\0' x; printf '\n'; } > "$SHARED_MEMORY_DIR/topics/talking-to-sessions.md"
  CLAUDE_PEER_WORKTREE="$HOME/work" run start
  [ "$status" -eq 0 ]
  [ "${#output}" -lt 9000 ]
  [[ "${lines[0]}" == "shared-memory: these shared-memory topics apply to this session (a Claude Peers tab), so they are added here:" ]]
  [ "${lines[1]}" = "read ~/.claude-shared/topics/talking-to-sessions.md now: it applies to this session and is too long to add here." ]
  [ "${lines[3]}" = "read ~/.claude-shared/topics/peer-seat.md now: it applies to this session and is too long to add here." ]
  [ "${#lines[@]}" -eq 4 ]
  [ "$(cut -f5 "$LOG" | sort -u)" = oversize ]
}

@test "hook start: silent under MEMORYGUARD_DEPTH" {
  MEMORYGUARD_DEPTH=1 CLAUDE_PEER_WORKTREE="$HOME/work" run start
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$LOG" ]
}

@test "hook start: malformed JSON, empty stdin and a missing directory exit 0 with no output" {
  export CLAUDE_PEER_WORKTREE="$HOME/work"
  run start 'not json {'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run sh "$SM" hook start < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run start '["a list"]'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  SHARED_MEMORY_DIR="$BATS_TEST_TMPDIR/nowhere" run start
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run sh "$SM" hook nonsense
  [ "$status" -eq 0 ]
}

@test "hook start: a PATH without python3 exits 0 with no output and leaves a nopython row" {
  local nopy="$BATS_TEST_TMPDIR/nopy" t
  mkdir -p "$nopy"
  for t in cat mktemp rm date mkdir; do ln -s "$(command -v "$t")" "$nopy/$t"; done
  run env CLAUDE_PEER_WORKTREE="$HOME/work" PATH="$nopy" /bin/sh "$SM" hook start <<< '{"session_id":"s1"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$(cut -f2- "$LOG")" == $'.claude-test\tstart\t-\tnopython' ]]
}

@test "hook start: a claude-peer that sleeps loses only the peers test, within the cap" {
  printf '#!/bin/sh\nsleep 10\necho slot\n' > "$PEER"
  run start
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf '#!/bin/sh\n' > "$HOME/bin/postbox"
  chmod +x "$HOME/bin/postbox"
  printf 'postbox hook start\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  local before=$SECONDS
  run start
  [ "$status" -eq 0 ]
  [[ "$output" == *BODY-talking-to-sessions ]]
  [ $((SECONDS - before)) -lt 8 ]
}

@test "hook start: clear and compact forget what the tool events told this session, others keep it" {
  local told="$XDG_STATE_HOME/shared-memory/told"
  mkdir -p "$told"
  printf 'main\tcommit-signing\n' > "$told/s1"
  printf 'main\tcommit-signing\n' > "$told/s2"
  run start '{"session_id":"s1","source":"startup"}'
  [ -e "$told/s1" ]
  run start '{"session_id":"s1","source":"clear"}'
  [ "$status" -eq 0 ]
  [ ! -e "$told/s1" ]
  [ -e "$told/s2" ]
  run start '{"session_id":"s2","source":"compact"}'
  [ ! -e "$told/s2" ]
}

@test "hook start: told files older than 14 days are deleted" {
  local told="$XDG_STATE_HOME/shared-memory/told"
  mkdir -p "$told"
  : > "$told/old"
  : > "$told/new"
  touch -t 202001010000 "$told/old"
  run start
  [ "$status" -eq 0 ]
  [ ! -e "$told/old" ]
  [ -e "$told/new" ]
}

@test "log: rows have five fields and no session id, and log counts them" {
  export CLAUDE_PEER_WORKTREE="$HOME/work"
  start '{"session_id":"secret-session-id"}' > /dev/null
  start '{"session_id":"secret-session-id"}' > /dev/null
  [ "$(wc -l < "$LOG" | tr -d ' ')" -eq 6 ]
  [ "$(awk -F'\t' 'NF != 5' "$LOG" | wc -l | tr -d ' ')" -eq 0 ]
  ! grep -q 'secret-session-id\|BODY' "$LOG" || { echo "the log carries content"; false; }
  [[ "$(cut -f2,3 "$LOG" | sort -u)" == $'.claude-test\tstart' ]]
  run sh "$SM" log
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'injected\tclaude-peers\t2\ninjected\tpeer-seat\t2\ninjected\ttalking-to-sessions\t2')" ]
  printf '2000-01-01T00:00:00Z\t.claude-test\tstart\tlead\terror\n' >> "$LOG"
  run sh "$SM" log
  [[ "$output" == *$'error\tlead\t1'* ]]
  run sh "$SM" log --since 7
  [ "$status" -eq 0 ]
  [[ "$output" != *error* ]]
  [[ "$output" == *$'injected\tpeer-seat\t2'* ]]
}

@test "log: nothing when there is no log" {
  run sh "$SM" log
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook tool: a failed signature adds commit-signing on PostToolUseFailure, echoing the event" {
  run tool "$SIGN_FAIL"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(list(d), sorted(d["hookSpecificOutput"]), d["hookSpecificOutput"]["hookEventName"])')" = "['hookSpecificOutput'] ['additionalContext', 'hookEventName'] PostToolUseFailure" ]
  [ "$(context | head -1)" = "shared-memory: commit-signing applies to what just happened; from the shared memory:" ]
  [[ "$(context)" == *BODY-commit-signing ]]
  [[ "$output" != *decision* ]]
  [ "$(cut -f3- "$LOG")" = "$(printf 'tool\tcommit-signing\tinjected')" ]
}

@test "hook tool: a signing string in a PostToolUse tool_response object, stdout or stderr" {
  run tool '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"command":"x"},"tool_response":{"stdout":"","stderr":"No SSH private key found for the specified public key"}}'
  [ "$status" -eq 0 ]
  [[ "$(context)" == *BODY-commit-signing ]]
  run tool '{"hook_event_name":"PostToolUse","session_id":"s2","tool_name":"Bash","tool_input":{"command":"x"},"tool_response":{"stdout":"error: op-ssh-sign said no","stderr":""}}'
  [[ "$(context)" == *BODY-commit-signing ]]
  run tool '{"hook_event_name":"PostToolUse","session_id":"s3","tool_name":"Bash","tool_input":{"command":"x"},"tool_response":"failed to write commit object"}'
  [[ "$(context)" == *BODY-commit-signing ]]
}

@test "hook tool: op-ssh-sign in a successful output adds nothing, in a failed call or beside an error line it does" {
  run tool '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"command":"git config -l"},"tool_response":{"stdout":"gpg.ssh.program=/x/op-ssh-sign\ngpg.format=ssh","stderr":""}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run tool '{"hook_event_name":"PostToolUseFailure","session_id":"s1","tool_name":"Bash","tool_input":{"command":"git config -l | grep nope"},"error":"Exit code 1\n/x/op-ssh-sign"}'
  [[ "$(context)" == *BODY-commit-signing ]]
}

@test "hook tool: a failed ssh, scp, sftp or curl adds tailnet-routed-ssh, on both events" {
  run tool "$SSH_FAIL"
  [ "$status" -eq 0 ]
  [[ "$(context)" == *BODY-tailnet-routed-ssh ]]
  run tool '{"hook_event_name":"PostToolUse","session_id":"s2","tool_name":"Bash","tool_input":{"command":"curl -s http://h/"},"tool_response":{"stdout":"","stderr":"curl: (7) Failed to connect to h port 80"}}'
  [ "$(printf '%s' "$output" | python3 -c 'import json, sys; print(json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"])')" = PostToolUse ]
  [[ "$(context)" == *BODY-tailnet-routed-ssh ]]
  local c
  for c in 'scp a h:b' 'x; sftp h' 'a | ssh h' '(ssh h)' 'echo $(curl h)' 'ssh h'; do
    run tool "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$c\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"},\"tool_response\":\"No route to host\"}"
    [[ "$(context)" == *BODY-tailnet-routed-ssh ]] || { echo "no match: $c"; false; }
  done
}

@test "hook tool: a curl 404 and a connect string in a command that is not a network tool add nothing" {
  run tool '{"hook_event_name":"PostToolUseFailure","session_id":"s1","tool_name":"Bash","tool_input":{"command":"curl -f http://h/x"},"error":"Exit code 22\ncurl: (22) The requested URL returned error: 404"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run tool '{"hook_event_name":"PostToolUseFailure","session_id":"s1","tool_name":"Bash","tool_input":{"command":"echo sshd Connection refused"},"error":"Exit code 1\nConnection refused"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run tool '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Read","tool_input":{"command":"ssh h"},"tool_response":"Connection refused failed to fill whole buffer"}'
  [ -z "$output" ]
  [ ! -e "$LOG" ]
}

@test "hook tool: the Claude in Chrome tools and the claude-in-chrome skill add claude-in-chrome" {
  run tool "$CHROME"
  [ "$status" -eq 0 ]
  [[ "$(context)" == *BODY-claude-in-chrome ]]
  run tool '{"hook_event_name":"PostToolUse","session_id":"s2","tool_name":"Skill","tool_input":{"skill":"claude-in-chrome"},"tool_response":"ok"}'
  [[ "$(context)" == *BODY-claude-in-chrome ]]
  run tool '{"hook_event_name":"PostToolUse","session_id":"s3","tool_name":"Skill","tool_input":{"skill":"some:claude-in-chrome"},"tool_response":"ok"}'
  [[ "$(context)" == *BODY-claude-in-chrome ]]
  run tool '{"hook_event_name":"PostToolUse","session_id":"s4","tool_name":"Skill","tool_input":{"skill":"claude-in-chrome-notes"},"tool_response":"ok"}'
  [ -z "$output" ]
  run tool '{"hook_event_name":"PostToolUse","session_id":"s4","tool_name":"mcp__other__x","tool_input":{"note":"claude-in-chrome"},"tool_response":"ok"}'
  [ -z "$output" ]
}

# A Bash PostToolUse payload for the command $1, session $2.
bash_payload() {
  printf '{"hook_event_name":"PostToolUse","session_id":"%s","tool_name":"Bash","tool_input":{"command":%s},"tool_response":{"stdout":"","stderr":""}}' \
    "$2" "$(printf '%s' "$1" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))')"
}

@test "hook tool: claude-peer start, stop and log claim, note or done add peer-lifetime, on both events" {
  run tool '{"hook_event_name":"PostToolUseFailure","session_id":"s1","tool_name":"Bash","tool_input":{"command":"claude-peer stop alpha"},"error":"Exit code 5\nclaude-peer: alpha is busy"}'
  [ "$status" -eq 0 ]
  [[ "$(context)" == *BODY-peer-lifetime ]]
  local n=0 c
  for c in 'claude-peer start beta --handoff -- go' 'cd x && ~/bin/claude-peer log done "DONE: x"' 'claude-peer log --as beta note "keeping Beta"' 'claude-peer log claim a b' 'x=$(claude-peer stop gamma)'; do
    n=$((n + 1))
    run tool "$(bash_payload "$c" "p$n")"
    [[ "$(context)" == *BODY-peer-lifetime ]] || { echo "no match: $c"; false; }
  done
}

@test "hook tool: claude-peer slots, log show and a grep for its stop add nothing" {
  local c
  for c in 'claude-peer slots' 'claude-peer log show' 'grep -n "claude-peer stop" f' 'echo claude-peer-stop'; do
    run tool "$(bash_payload "$c" s1)"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "added for: $c"; false; }
  done
}

@test "hook tool: SendMessage, a postbox tool and am mail each add session-mail, once per session" {
  run tool '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"SendMessage","tool_input":{"to":"x"},"tool_response":"ok"}'
  [ "$status" -eq 0 ]
  [[ "$(context)" == *BODY-session-mail ]]
  run tool '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"mcp__postbox__fetch_inbox","tool_input":{},"tool_response":"ok"}'
  [ -z "$output" ]
  run tool '{"hook_event_name":"PostToolUse","session_id":"s2","tool_name":"mcp__postbox__fetch_inbox","tool_input":{},"tool_response":"ok"}'
  [[ "$(context)" == *BODY-session-mail ]]
  run tool "$(bash_payload 'am mail send x' s3)"
  [[ "$(context)" == *BODY-session-mail ]]
  run tool "$(bash_payload 'echo am mailbox' s4)"
  [ -z "$output" ]
}

@test "hook tool: a command starting gh or command gh adds github-accounts once per session, on both events" {
  local n=0 c
  for c in 'gh pr list' 'command gh api user' 'gh  auth status'; do
    n=$((n + 1))
    run tool "$(bash_payload "$c" "g$n")"
    [ "$status" -eq 0 ]
    [[ "$(context)" == *BODY-github-accounts ]] || { echo "no match: $c"; false; }
  done
  run tool "$(bash_payload 'gh pr view' g1)"
  [ -z "$output" ]
  run tool '{"hook_event_name":"PostToolUseFailure","session_id":"g9","tool_name":"Bash","tool_input":{"command":"gh pr merge 3"},"error":"Exit code 1\nboom"}'
  [[ "$(context)" == *BODY-github-accounts ]]
}

@test "hook tool: gh mentioned but not run adds nothing" {
  local c
  for c in 'git ghost' 'echo gh pr list' 'ls ~/.config/gh/' 'cd x && gh pr list' 'ghx pr' 'sudo gh pr list'; do
    run tool "$(bash_payload "$c" s1)"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "added for: $c"; false; }
  done
}

@test "hook tool: one signing failure that is also an ssh failure adds both, signing first" {
  run tool '{"hook_event_name":"PostToolUseFailure","session_id":"s1","tool_name":"Bash","tool_input":{"command":"ssh h"},"error":"Exit code 255\nop-ssh-sign\nConnection refused"}'
  [[ "$(context)" == *BODY-commit-signing*BODY-tailnet-routed-ssh ]]
  [ "$(context | head -1)" = "shared-memory: commit-signing, tailnet-routed-ssh applies to what just happened; from the shared memory:" ]
}

@test "hook tool: the second hit in a session is told and silent, another agent is told again" {
  run tool "$SIGN_FAIL"
  [ -n "$output" ]
  run tool "$SIGN_FAIL"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run tool "${SIGN_FAIL/\"session_id\":\"s1\"/\"session_id\":\"s1\",\"agent_id\":\"a/b\"}"
  [[ "$(context)" == *BODY-commit-signing ]]
  run tool "${SIGN_FAIL/\"session_id\":\"s1\"/\"session_id\":\"s1\",\"agent_id\":\"a/b\"}"
  [ -z "$output" ]
  # another session is told again, and a topic that is new to this one is not blocked by the old
  run tool "${SIGN_FAIL/\"s1\"/\"s2\"}"
  [ -n "$output" ]
  [ "$(printf 'main\tcommit-signing\na_b\tcommit-signing\n')" = "$(cat "$XDG_STATE_HOME/shared-memory/told/s1")" ]
  [ "$(cut -f5 "$LOG" | sort | uniq -c | tr -s ' ' | tr '\n' ';')" = " 3 injected; 2 told;" ]
}

@test "hook tool: two hooks of one session running at once inject once" {
  local n sid pids=() out="$BATS_TEST_TMPDIR/conc"
  mkdir -p "$out"
  for n in 1 2 3 4; do
    sid="c$n"
    tool "${SIGN_FAIL/\"s1\"/\"$sid\"}" > "$out/$sid.a" &
    pids+=($!)
    tool "${SIGN_FAIL/\"s1\"/\"$sid\"}" > "$out/$sid.b" &
    pids+=($!)
  done
  wait "${pids[@]}"
  for n in 1 2 3 4; do
    [ "$(cat "$out/c$n.a" "$out/c$n.b" | grep -c BODY-commit-signing)" -eq 1 ] || { echo "session c$n"; false; }
  done
  [ "$(grep -c "injected" "$LOG")" -eq 4 ]
}

@test "hook tool: a hook waits for the session's lock, and gives the same answer once it has it" {
  local told="$XDG_STATE_HOME/shared-memory/told" out="$BATS_TEST_TMPDIR/waited" holder
  mkdir -p "$told"
  python3 -c 'import fcntl, sys, time
fd = open(sys.argv[1], "a")
fcntl.flock(fd, fcntl.LOCK_EX)
print("held", flush=True)
time.sleep(2)' "$told/s1~lock" > "$BATS_TEST_TMPDIR/held" &
  holder=$!
  until [ -s "$BATS_TEST_TMPDIR/held" ]; do sleep 0.05; done
  tool "$SIGN_FAIL" > "$out" &
  sleep 0.7
  [ ! -s "$out" ] || { echo "the hook did not wait for the lock"; false; }
  wait "$holder"
  wait $!
  grep -q BODY-commit-signing "$out"
}

@test "hook tool: a clear removes the session's lock file too" {
  local told="$XDG_STATE_HOME/shared-memory/told"
  tool "$SIGN_FAIL" > /dev/null
  [ "$(ls "$told" | wc -l | tr -d ' ')" -eq 2 ]
  start '{"session_id":"s1","source":"clear"}' > /dev/null
  [ -z "$(ls "$told")" ]
}

@test "hook tool: a payload file that cannot be written is not left in TMPDIR" {
  local tmpd="$BATS_TEST_TMPDIR/tmpd"
  mkdir -p "$tmpd"
  run sh -c 'ulimit -f 0; trap "" XFSZ; printf %s "$1" | TMPDIR="$2" sh "$3" hook tool' sh "$SIGN_FAIL" "$tmpd" "$SM"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$tmpd")" ]
}

@test "hook tool: a start hook's clear forgets what a tool hook told" {
  tool "$SIGN_FAIL" > /dev/null
  start '{"session_id":"s1","source":"compact"}' > /dev/null
  run tool "$SIGN_FAIL"
  [[ "$(context)" == *BODY-commit-signing ]]
}

@test "hook tool: WebFetch adds web-fetching on both events, once per session and agent" {
  local ok='{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"WebFetch","tool_input":{"url":"https://example.com","prompt":"x"},"tool_response":"ok"}'
  local bad='{"hook_event_name":"PostToolUseFailure","session_id":"s2","tool_name":"WebFetch","tool_input":{"url":"https://example.com","prompt":"x"},"error":"Request failed with status code 403"}'
  run tool "$ok"
  [ "$status" -eq 0 ]
  [[ "$(context)" == *BODY-web-fetching ]]
  [[ "$output" == *'"hookEventName": "PostToolUse"'* ]]
  run tool "$ok"
  [ -z "$output" ]
  run tool "${ok/\"session_id\":\"s1\"/\"session_id\":\"s1\",\"agent_id\":\"a1\"}"
  [[ "$(context)" == *BODY-web-fetching ]]
  run tool "$bad"
  [[ "$(context)" == *BODY-web-fetching ]]
  [[ "$output" == *'"hookEventName": "PostToolUseFailure"'* ]]
  run tool "$bad"
  [ -z "$output" ]
  [ "$(cut -f3- "$LOG" | sort | uniq -c | tr -s ' ')" = "$(printf ' 3 tool\tweb-fetching\tinjected\n 2 tool\tweb-fetching\ttold')" ]
}

@test "hook tool: a Bash command that mentions WebFetch adds nothing" {
  run tool "$(bash_payload 'grep -rn WebFetch .' s1)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook tool: web-fetching imported by the index is not added, and is logged imported" {
  printf '@topics/web-fetching.md\n' >> "$SHARED_MEMORY_DIR/CLAUDE.md"
  run tool '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"WebFetch","tool_input":{},"tool_response":"ok"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cut -f3- "$LOG")" = "$(printf 'tool\tweb-fetching\timported')" ]
}

@test "hook tool: a topic the index imports is never added, and is logged imported" {
  printf '@topics/commit-signing.md\n' >> "$SHARED_MEMORY_DIR/CLAUDE.md"
  run tool "$SIGN_FAIL"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cut -f3- "$LOG")" = "$(printf 'tool\tcommit-signing\timported')" ]
}

@test "hook tool: a topic file that is missing is skipped" {
  rm "$SHARED_MEMORY_DIR/topics/commit-signing.md"
  run tool "$SIGN_FAIL"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook tool: over 9,000 characters it names the file instead, and logs oversize" {
  { printf '## Big\n\n'; head -c 9500 /dev/zero | tr '\0' x; printf '\n'; } > "$SHARED_MEMORY_DIR/topics/commit-signing.md"
  run tool "$SIGN_FAIL"
  [ "$status" -eq 0 ]
  [ "${#output}" -lt 9000 ]
  [[ "$(context)" == *"read ~/.claude-shared/topics/commit-signing.md now: it applies to what just happened and is too long to add here." ]]
  [ "$(cut -f5 "$LOG")" = oversize ]
}

@test "hook tool: a payload with none of the prefilter strings never starts python" {
  printf '#!/bin/sh\necho call >> "%s/calls"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR" "$REAL_PYTHON3" > "$BIN/python3"
  run tool '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"stdout":"a b c","stderr":""}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  [ ! -e "$XDG_STATE_HOME/shared-memory" ]
  run tool "$SIGN_FAIL"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/calls" | tr -d ' ')" -eq 1 ]
}

@test "hook tool: silent under MEMORYGUARD_DEPTH" {
  MEMORYGUARD_DEPTH=1 run tool "$SIGN_FAIL"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$LOG" ]
}

@test "hook tool: malformed JSON, no session id, a missing directory and an unknown event exit 0 with no output" {
  run tool 'not json {  failed to fill whole buffer'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run tool '["failed to fill whole buffer"]'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run sh "$SM" hook tool < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run tool "${SIGN_FAIL/\"session_id\":\"s1\",/}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run tool "${SIGN_FAIL/PostToolUseFailure/Stop}"
  [ -z "$output" ]
  SHARED_MEMORY_DIR="$BATS_TEST_TMPDIR/nowhere" run tool "$SIGN_FAIL"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook tool: a PATH without python3 exits 0 with no output and leaves a nopython row, only after a prefilter hit" {
  local nopy="$BATS_TEST_TMPDIR/nopy" t
  mkdir -p "$nopy"
  for t in cat mktemp rm date mkdir; do ln -s "$(command -v "$t")" "$nopy/$t"; done
  run env PATH="$nopy" /bin/sh "$SM" hook tool <<< "$SIGN_FAIL"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$(cut -f2- "$LOG")" == $'.claude-test\ttool\t-\tnopython' ]]
  rm "$LOG"
  run env PATH="$nopy" /bin/sh "$SM" hook tool <<< '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
  [ "$status" -eq 0 ]
  [ ! -e "$LOG" ]
}

@test "hook tool: log rows carry no session id, command or output" {
  tool "$SIGN_FAIL" > /dev/null
  [ "$(awk -F'\t' 'NF != 5' "$LOG" | wc -l | tr -d ' ')" -eq 0 ]
  ! grep -q 's1\|git commit\|1Password\|BODY' "$LOG" || { echo "the log carries content"; false; }
}
