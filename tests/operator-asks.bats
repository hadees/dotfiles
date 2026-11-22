#!/usr/bin/env bats

# operator-asks counts how often a session made the operator a step. These
# tests drive the real script under a sandboxed HOME and XDG_STATE_HOME with
# fixture transcripts of invented sessions, shaped like the records Claude Code
# writes; no real text, path, session or account appears (see CLAUDE.md).
#
# python3 is resolved to its real interpreter before HOME is sandboxed, for
# the reason tests/denyguard.bats gives (an asdf shim breaks under a fake
# HOME).

bats_require_minimum_version 1.5.0

setup() {
  command -v python3 >/dev/null || skip "python3 not installed"
  REAL_PYTHON3="$(python3 -c 'import sys; print(sys.executable)')"

  mkdir -p "$BATS_TEST_TMPDIR/home"
  export HOME
  HOME="$(cd "$BATS_TEST_TMPDIR/home" && pwd -P)"
  export XDG_STATE_HOME="$HOME/state"
  export CLAUDE_CONFIG_DIR="$HOME/.claude-test"
  mkdir -p "$CLAUDE_CONFIG_DIR/projects"

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_PYTHON3" > "$BIN/python3"
  chmod +x "$BIN/python3"
  export PATH="$BIN:$PATH"

  ln -s "$BATS_TEST_DIRNAME/../bin/executable_denyguard" "$BIN/denyguard"

  OA="$BATS_TEST_DIRNAME/../bin/executable_operator-asks"
  DENIALS="$XDG_STATE_HOME/operator-asks/denials.tsv"
  PROMPTS="$XDG_STATE_HOME/operator-asks/prompts.tsv"
}

# Writes the fixture transcripts into the profile directory $1: one main
# session (every metric once or repeated), one sidechain-only record, one stale
# record, and one session of a worktree project.
fixture() {
  python3 -I - "$1" "$HOME" <<'PY'
import json, os, sys, time

root, home = sys.argv[1], sys.argv[2]


def ts(days_ago=0):
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() - days_ago * 86400))


def assistant(*content, side=False, when=0):
    return {"type": "assistant", "isSidechain": side, "timestamp": ts(when), "sessionId": "s",
            "message": {"role": "assistant", "content": list(content)}}


def text(t):
    return {"type": "text", "text": t}


def read(p):
    return {"type": "tool_use", "name": "Read", "input": {"file_path": p}}


def answer(*pairs):
    qs = [{"question": q, "options": [{"label": a}, {"label": b}]} for q, a, b, _ in pairs]
    return {"type": "user", "isSidechain": False, "timestamp": ts(), "sessionId": "s",
            "toolUseResult": {"questions": qs, "answers": {q: given for q, _, _, given in pairs}}}


main = [
    {"type": "custom-title", "customTitle": "demo-lead", "sessionId": "s"},
    {"type": "permission-mode", "permissionMode": "default", "sessionId": "s"},
    assistant(text("Type /exit in the beta pane.\nAll done.\nThis is yours to merge, not mine.\nRun `go 453` here")),
    assistant(text("Run `go 454` here\nRun `go 453` here")),
    assistant(text("Type /exit in the beta pane."), side=True),
    assistant(text("Type /exit in the old pane."), when=30),
    answer(("Which one?", "first", "second", "first")),
    answer(("Which two?", "first", "second", "second")),
    assistant(read(home + "/.claude-shared/approvals-ledger.md"), read(home + "/.claude-shared/topics/lead.md")),
    assistant(read(home + "/dot_claude-shared/topics/lead.md"), read(home + "/work/topics/lead.md")),
]
peer = [
    {"type": "permission-mode", "permissionMode": "auto", "sessionId": "p"},
    {"type": "permission-mode", "permissionMode": "default", "sessionId": "p"},
    assistant(text("nothing to see")),
]


def put(project, name, records, cwd):
    d = os.path.join(root, "projects", project)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, name + ".jsonl"), "w") as f:
        for r in records:
            f.write(json.dumps(dict(r, cwd=cwd)) + "\n")
        f.write("not json\n")


put("-home-demo", "aaaa", main, home + "/demo")
put("-home-demo--claude-worktrees-beta", "bbbb", peer, home + "/demo/.claude/worktrees/beta")
PY
}

@test "count prints every metric once from a fixture that holds one of each" {
  fixture "$CLAUDE_CONFIG_DIR"
  run "$OA" count
  [ "$status" -eq 0 ]
  expected="$(printf '%s\t%s\n' elsewhere 1 first-option 1 peer-mode:auto 1 prompts 0 questions 2 read:approvals-ledger.md 1 read:lead.md 1 steps 3)"
  [ "$output" = "$expected" ]
}

@test "a repeated step line counts once, and digits do not make a new one" {
  fixture "$CLAUDE_CONFIG_DIR"
  run "$OA" list
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'Run `go')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 3 ]
}

@test "list prints time, session name, kind and text, and ignores sidechain and stale records" {
  fixture "$CLAUDE_CONFIG_DIR"
  run "$OA" list
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "$(printf '\tdemo-lead\telsewhere\tType /exit in the beta pane\.$')"
  printf '%s\n' "$output" | grep -q "$(printf '\tdemo-lead\tsteps\tThis is yours to merge')"
  ! printf '%s\n' "$output" | grep -q 'old pane' || false
}

@test "--since keeps the stale record in range" {
  fixture "$CLAUDE_CONFIG_DIR"
  run "$OA" list --since 40
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'old pane'
}

@test "count reads the profile named by --dir, and counts its own log label" {
  fixture "$HOME/.other"
  mkdir -p "$XDG_STATE_HOME/operator-asks"
  printf '%s\t.other\t[Merge Without Review]\tBash\taaaa\n%s\t.claude-test\t[Merge Without Review]\tBash\taaaa\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DENIALS"
  run "$OA" count --dir "$HOME/.other"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "$(printf '^questions\t2$')"
  printf '%s\n' "$output" | grep -q "$(printf '^denied:\[Merge Without Review\]\t1$')"
}

@test "a profile the running profile denies is refused unread, by either deny form" {
  fixture "$HOME/.other"
  fixture "$HOME/.third"
  printf '{"permissions":{"deny":["Read(~/.other/projects/**)","Read(/%s/.third/**)","Bash(ls)"]}}\n' "$HOME" \
    > "$CLAUDE_CONFIG_DIR/settings.json"
  for d in "$HOME/.other" "$HOME/.third"; do
    for cmd in count list; do
      run --separate-stderr "$OA" "$cmd" --dir "$d"
      [ "$status" -eq 1 ]
      [ -z "$output" ]
      [[ "$stderr" == *"denied to this profile"* ]]
    done
  done
  fixture "$HOME/.fourth"
  run "$OA" count --dir "$HOME/.fourth"
  [ "$status" -eq 0 ]
}

# Adds to the profile directory $1 one project whose records name the working
# directory $2 and hold a step line and an answered question, so a project that
# is read shows in both verbs.
extra_project() {
  python3 -I - "$1" "$2" <<'PY'
import json, os, sys, time

root, cwd = sys.argv[1:3]
now = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
d = os.path.join(root, "projects", "-extra")
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, "cccc.jsonl"), "w") as f:
    for r in (
        {"type": "assistant", "timestamp": now, "message": {"role": "assistant", "content": [
            {"type": "text", "text": "Type /exit in the hidden pane."}]}},
        {"type": "user", "timestamp": now, "toolUseResult": {
            "questions": [{"question": "Q?", "options": [{"label": "a"}]}], "answers": {"Q?": "a"}}},
    ):
        f.write(json.dumps(dict(r, cwd=cwd) if cwd else r) + "\n")
PY
}

@test "a project whose cwd is denied is skipped in count and list, and only counted" {
  fixture "$CLAUDE_CONFIG_DIR"
  extra_project "$CLAUDE_CONFIG_DIR" "$HOME/code/octo-secret/sub"
  printf '{"permissions":{"deny":["Read(~/code/octo-secret/**)"]}}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  run --separate-stderr "$OA" count
  [ "$status" -eq 0 ]
  [ "$stderr" = "operator-asks: 1 projects skipped (denied)" ]
  printf '%s\n' "$output" | grep -q "$(printf '^questions\t2$')"
  run --separate-stderr "$OA" list
  [ "$status" -eq 0 ]
  [ "$stderr" = "operator-asks: 1 projects skipped (denied)" ]
  ! printf '%s\n' "$output" | grep -q hidden || false
  # without the rule the same project is read
  rm "$CLAUDE_CONFIG_DIR/settings.json"
  run --separate-stderr "$OA" list
  [ -z "$stderr" ]
  printf '%s\n' "$output" | grep -q hidden
}

@test "a denied project's cwd is checked in another profile read by --dir" {
  fixture "$HOME/.other"
  extra_project "$HOME/.other" "$HOME/code/octo-secret"
  printf '{"permissions":{"deny":["Read(~/code/octo-secret/**)"]}}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  run --separate-stderr "$OA" list --dir "$HOME/.other"
  [ "$status" -eq 0 ]
  [ "$stderr" = "operator-asks: 1 projects skipped (denied)" ]
  ! printf '%s\n' "$output" | grep -q hidden || false
  printf '%s\n' "$output" | grep -q 'beta pane'
}

@test "a denyguard that exits 2 for a project denies it, whatever else it says" {
  fixture "$CLAUDE_CONFIG_DIR"
  extra_project "$CLAUDE_CONFIG_DIR" "$HOME/stubbed"
  mkdir "$BATS_TEST_TMPDIR/stub"
  cat > "$BATS_TEST_TMPDIR/stub/denyguard" <<'EOF'
#!/bin/sh
for a; do case "$a" in */stubbed) exit 2 ;; esac; done
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/stub/denyguard"
  PATH="$BATS_TEST_TMPDIR/stub:$PATH" run --separate-stderr "$OA" list
  [ "$status" -eq 0 ]
  [ "$stderr" = "operator-asks: 1 projects skipped (denied)" ]
  ! printf '%s\n' "$output" | grep -q hidden || false
  printf '%s\n' "$output" | grep -q 'beta pane'
}

@test "a project whose records name no cwd is skipped" {
  fixture "$CLAUDE_CONFIG_DIR"
  extra_project "$CLAUDE_CONFIG_DIR" ""
  run --separate-stderr "$OA" list
  [ "$stderr" = "operator-asks: 1 projects skipped (denied)" ]
  ! printf '%s\n' "$output" | grep -q hidden || false
}

@test "without denyguard nothing is read, in either verb" {
  fixture "$CLAUDE_CONFIG_DIR"
  rm "$BIN/denyguard"
  for cmd in count list; do
    PATH="$BIN:/usr/bin:/bin" run --separate-stderr "$OA" "$cmd"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"could not be checked"* ]]
  done
}

@test "hook denied writes the reason label, tool name and session id, never the command text" {
  run "$OA" hook denied <<'EOF'
{"reason":"[Merge Without Review] gh pr merge 12 --admin secret-token","tool_name":"Bash","tool_input":{"command":"gh pr merge 12 secret-token"},"session_id":"abc-123","cwd":"/x/y"}
EOF
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(wc -l < "$DENIALS" | tr -d ' ')" -eq 1 ]
  grep -q "$(printf '\t.claude-test\t\[Merge Without Review\]\tBash\tabc-123$')" "$DENIALS"
  ! grep -q -e secret-token -e merge -e /x/y "$DENIALS" || false
}

@test "hook prompt writes the tool name and session id and nothing else" {
  run "$OA" hook prompt <<'EOF'
{"tool_name":"mcp__demo__thing","tool_input":{"command":"secret-token"},"session_id":"abc-123"}
EOF
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q "$(printf '\t.claude-test\tmcp__demo__thing\tabc-123$')" "$PROMPTS"
  ! grep -q secret-token "$PROMPTS" || false
}

@test "a hook payload that is not JSON writes nothing and exits 0" {
  for which in denied prompt; do
    run "$OA" hook "$which" <<'EOF'
this is { not json
EOF
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  [ ! -e "$DENIALS" ]
  [ ! -e "$PROMPTS" ]
}

@test "a hook exits 0 and prints nothing when the state directory cannot be written" {
  mkdir -p "$HOME/ro"
  : > "$HOME/ro/file"
  XDG_STATE_HOME="$HOME/ro/file" run "$OA" hook denied <<'EOF'
{"reason":"[Merge Without Review]","tool_name":"Bash"}
EOF
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "count counts the hook rows as denied and prompts" {
  fixture "$CLAUDE_CONFIG_DIR"
  printf '{"reason":"[Merge Without Review]","tool_name":"Bash","session_id":"aaaa"}' | "$OA" hook denied
  printf '{"tool_name":"Bash","session_id":"aaaa"}' | "$OA" hook prompt
  printf '{"tool_name":"Edit","session_id":"bbbb"}' | "$OA" hook prompt
  run --separate-stderr "$OA" count
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  printf '%s\n' "$output" | grep -q "$(printf '^denied:\[Merge Without Review\]\t1$')"
  printf '%s\n' "$output" | grep -q "$(printf '^prompts\t2$')"
}

@test "count tallies a hook row only for a session of an allowed project, and reports rows with no session id" {
  fixture "$CLAUDE_CONFIG_DIR"
  extra_project "$CLAUDE_CONFIG_DIR" "$HOME/code/octo-secret/sub"
  printf '{"permissions":{"deny":["Read(~/code/octo-secret/**)"]}}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  # cccc is the denied project's session, dddd is in no project at all
  for sid in aaaa cccc dddd; do
    printf '{"reason":"[Merge Without Review]","tool_name":"Bash","session_id":"%s"}' "$sid" | "$OA" hook denied
    printf '{"tool_name":"Bash","session_id":"%s"}' "$sid" | "$OA" hook prompt
  done
  # a payload with no session id, and rows written before the id was logged
  printf '{"reason":"[Merge Without Review]","tool_name":"Bash"}' | "$OA" hook denied
  printf '{"tool_name":"Bash"}' | "$OA" hook prompt
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\t.claude-test\t[Merge Without Review]\tBash\n' "$now" >> "$DENIALS"
  printf '%s\t.claude-test\tBash\n' "$now" >> "$PROMPTS"
  run --separate-stderr "$OA" count
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "$(printf '^denied:\[Merge Without Review\]\t1$')"
  printf '%s\n' "$output" | grep -q "$(printf '^prompts\t1$')"
  [[ "$stderr" == *"operator-asks: 4 hook log rows without a session id not counted"* ]]
  [[ "$stderr" == *"1 projects skipped (denied)"* ]]
  # without the rule the denied project's session counts too
  rm "$CLAUDE_CONFIG_DIR/settings.json"
  run --separate-stderr "$OA" count
  printf '%s\n' "$output" | grep -q "$(printf '^denied:\[Merge Without Review\]\t2$')"
}

@test "a rule denyguard cannot evaluate is named on the projects-tree check, then everything is refused" {
  fixture "$CLAUDE_CONFIG_DIR"
  printf '{"permissions":{"deny":["Read(./.env)"]}}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  for cmd in count list; do
    run --separate-stderr "$OA" "$cmd"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"denyguard: Read(./.env) cannot be evaluated without a session cwd"* ]]
    [[ "$stderr" == *"could not be checked, not read"* ]]
  done
}

@test "an unevaluable rule on a per-project check prints no denyguard line, and a denied tree names nothing" {
  fixture "$CLAUDE_CONFIG_DIR"
  extra_project "$CLAUDE_CONFIG_DIR" "$HOME/stubbed"
  mkdir "$BATS_TEST_TMPDIR/stub"
  cat > "$BATS_TEST_TMPDIR/stub/denyguard" <<'EOF'
#!/bin/sh
for a; do case "$a" in */stubbed) echo "denyguard: Read(./.env) cannot be evaluated without a session cwd" >&2; exit 2 ;; esac; done
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/stub/denyguard"
  PATH="$BATS_TEST_TMPDIR/stub:$PATH" run --separate-stderr "$OA" count
  [ "$status" -eq 0 ]
  [ "$stderr" = "operator-asks: 1 projects skipped (denied)" ]
  # a tree that is denied outright prints denyguard's path line nowhere
  printf '{"permissions":{"deny":["Read(/%s/**)"]}}\n' "$CLAUDE_CONFIG_DIR" > "$CLAUDE_CONFIG_DIR/settings.json"
  run --separate-stderr "$OA" count
  [ "$status" -eq 1 ]
  [ "$stderr" = "operator-asks: $CLAUDE_CONFIG_DIR is denied to this profile or could not be checked, not read" ]
}

@test "settings prints both hook entries and edits nothing" {
  run "$OA" settings
  [ "$status" -eq 0 ]
  [[ "$output" == *'"PermissionDenied"'*'operator-asks hook denied || true'* ]]
  [[ "$output" == *'"PermissionRequest"'*'operator-asks hook prompt || true'* ]]
  [[ "$output" == *'"timeout": 5'* ]]
  [ ! -e "$XDG_STATE_HOME" ]
}

@test "a bad command or option prints usage and exits 64" {
  run "$OA"
  [ "$status" -eq 64 ]
  run "$OA" count --since x
  [ "$status" -eq 64 ]
}
