#!/usr/bin/env bats

# memoryguard decides where a memory note belongs: it builds a typed-choice
# request from the note, asks a backend (protocol v1), validates the answer
# itself and logs a hashed line that doubles as the cache. These tests drive
# the real script under a sandboxed HOME with a stub backend (an executable
# speaking the protocol) and a stub `claude`; no model is called and no real
# path, repository or account appears (see CLAUDE.md).
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
  export CLAUDE_CONFIG_DIR="$HOME/.claude-test"
  export XDG_STATE_HOME="$HOME/state"
  mkdir -p "$CLAUDE_CONFIG_DIR/agents" "$HOME/work"
  cd "$HOME/work"

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_PYTHON3" > "$BIN/python3"
  chmod +x "$BIN/python3"
  export PATH="$BIN:$PATH"
  unset MEMORYGUARD_BACKEND MEMORYGUARD_CLAUDE_MODE MEMORYGUARD_BACKEND_TIMEOUT

  MG="$BATS_TEST_DIRNAME/../bin/executable_memoryguard"
  LOG="$XDG_STATE_HOME/memoryguard/decisions.tsv"

  # The stub backend: counts its runs, keeps the request, answers STUB_ANSWER.
  STUB="$BATS_TEST_TMPDIR/stub-backend"
  cat > "$STUB" <<'EOF'
#!/bin/sh
cat > "$STUB_DIR/request.json"
echo run >> "$STUB_DIR/runs"
[ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"
[ -z "${STUB_EXIT:-}" ] || exit "$STUB_EXIT"
printf '%s' "$STUB_ANSWER"
EOF
  chmod +x "$STUB"
  export STUB_DIR="$BATS_TEST_TMPDIR"
  export MEMORYGUARD_BACKEND="$STUB"

  NOTE="$BATS_TEST_TMPDIR/note.md"
  printf -- '---\nname: x\n---\nthe staging box stays up for the demo\n' > "$NOTE"
}

answer() { # choice confidence
  printf '{"answers":{"destination":{"choice":"%s","confidence":%s,"reason":"because"}}}' "$1" "$2"
}

runs() { wc -l < "$STUB_DIR/runs" 2>/dev/null | tr -d ' ' || echo 0; }

# A tiny fixture repository: one CLAUDE.md heading, one rule file, one doc.
fixture_repo() {
  mkdir -p "$HOME/repo/.git" "$HOME/repo/.claude/rules" "$HOME/repo/docs"
  printf '# T\n\n## Layout\n\nThe `frobnicate` script lives in bin/frobnicate.\n' > "$HOME/repo/CLAUDE.md"
  printf -- '---\npaths:\n  - "**/bin/frobnicate"\n---\n\n# Frobnicate\n' > "$HOME/repo/.claude/rules/frobnicate.md"
  printf '# Watching things\n' > "$HOME/repo/docs/watch.md"
}

@test "memory at 0.9 is allowed and logged as ten tab-separated fields" {
  export STUB_ANSWER; STUB_ANSWER="$(answer memory 0.9)"
  run "$MG" decide "$NOTE"
  [ "$status" -eq 0 ]
  [[ "$output" == "allow-memory memory 0.9 - because" ]]
  [ "$(wc -l < "$LOG")" -eq 1 ]
  [ "$(awk -F'\t' '{print NF}' "$LOG")" -eq 10 ]
  [ "$(cut -f6 "$LOG")" = "allow-memory" ]
}

@test "another home blocks at 0.9 and only warns at 0.6" {
  export STUB_ANSWER; STUB_ANSWER="$(answer shared-memory 0.9)"
  run "$MG" decide "$NOTE"
  [ "$status" -eq 0 ]
  [[ "$output" == block\ shared-memory* ]]
  printf 'a different note\n' > "$NOTE"
  STUB_ANSWER="$(answer shared-memory 0.6)"
  run "$MG" decide "$NOTE"
  [[ "$output" == allow-unsure\ shared-memory* ]]
}

@test "a bad answer or a failing backend is allow-error with the matching detail, exit 3" {
  check() { # answer detail [env…]
    export STUB_ANSWER="$1"
    run "$MG" decide --json "$NOTE"
    [ "$status" -eq 3 ]
    [[ "$output" == *'"outcome": "allow-error"'* ]]
    [[ "$output" == *"\"reason\": \"$2\""* ]]
    printf 'text %s\n' "$RANDOM" > "$NOTE"
  }
  check "$(answer elsewhere 0.9)" invalid
  check '{"answers":{"destination":{"choice":"memory","confidence":"high"}}}' invalid
  check '{"answers":{}}' invalid
  check 'not json' invalid
  STUB_EXIT=1 check "$(answer memory 0.9)" exit
  unset STUB_EXIT
  MEMORYGUARD_BACKEND_TIMEOUT=1 STUB_SLEEP=5 check "$(answer memory 0.9)" timeout
}

@test "the same text is decided once; a changed word asks again; a changed frontmatter does not" {
  export STUB_ANSWER; STUB_ANSWER="$(answer shared-memory 0.9)"
  run "$MG" decide "$NOTE"
  [ "$(runs)" -eq 1 ]
  run "$MG" decide --json "$NOTE"
  [[ "$output" == *'"cached": true'* ]]
  [[ "$output" == *'"outcome": "block-cached"'* ]]
  [ "$(runs)" -eq 1 ]
  printf -- '---\nname: other\nmodified: 2026\n---\nthe staging box stays up for the demo\n' > "$NOTE"
  run "$MG" decide "$NOTE"
  [ "$(runs)" -eq 1 ]
  printf -- '---\nname: x\n---\nthe staging box stays up for the demos\n' > "$NOTE"
  run "$MG" decide "$NOTE"
  [ "$(runs)" -eq 2 ]
}

@test "the request carries v1, the seven destinations, and place criteria from the repository" {
  fixture_repo
  export STUB_ANSWER='{"answers":{"destination":{"choice":"memory","confidence":0.9},"place":{"choice":"none","confidence":0.9}}}'
  run "$MG" decide --project "$HOME/repo" "$NOTE"
  [ "$status" -eq 0 ]
  run "$REAL_PYTHON3" -c '
import json,sys
r = json.load(open(sys.argv[1]))
assert r["v"] == 1
assert sorted(r["questions"]["destination"]["criteria"]) == sorted(
    ["memory","shared-memory","rule","claude-md","docs","overlay","nowhere"])
assert sorted(r["questions"]["place"]["criteria"]) == sorted(
    ["none","claude-md:Layout","rule:frobnicate","doc:docs/watch.md"]), r["questions"]["place"]["criteria"]
' "$STUB_DIR/request.json"
  [ "$status" -eq 0 ]
}

@test "with no repository and no shared memory there is no place question" {
  export STUB_ANSWER; STUB_ANSWER="$(answer memory 0.9)"
  run "$MG" decide "$NOTE"
  [ "$status" -eq 0 ]
  run "$REAL_PYTHON3" -c '
import json,sys
assert list(json.load(open(sys.argv[1]))["questions"]) == ["destination"]' "$STUB_DIR/request.json"
  [ "$status" -eq 0 ]
}

@test "evidence is the repository line that shares two terms, labelled with its heading" {
  fixture_repo
  printf 'run `frobnicate` from bin/frobnicate\n' > "$NOTE"
  export STUB_ANSWER; STUB_ANSWER="$(answer memory 0.9)"
  run "$MG" decide --project "$HOME/repo" "$NOTE"
  run "$REAL_PYTHON3" -c '
import json,sys
s = json.load(open(sys.argv[1]))["state"]
assert "CLAUDE.md: Layout: The `frobnicate` script lives in bin/frobnicate." in s, s' "$STUB_DIR/request.json"
  [ "$status" -eq 0 ]
  printf 'nothing notable here\n' > "$NOTE"
  run "$MG" decide --project "$HOME/repo" "$NOTE"
  run "$REAL_PYTHON3" -c '
import json,sys
s = json.load(open(sys.argv[1]))["state"]
assert "frobnicate" not in s.split("NOTE:")[0], s' "$STUB_DIR/request.json"
  [ "$status" -eq 0 ]
}

@test "a place whose prefix disagrees with the destination is dropped" {
  fixture_repo
  export STUB_ANSWER='{"answers":{"destination":{"choice":"rule","confidence":0.9},"place":{"choice":"claude-md:Layout","confidence":0.9}}}'
  run "$MG" decide --json --project "$HOME/repo" "$NOTE"
  [[ "$output" == *'"place": null'* ]]
  printf 'another\n' > "$NOTE"
  STUB_ANSWER='{"answers":{"destination":{"choice":"rule","confidence":0.9},"place":{"choice":"rule:frobnicate","confidence":0.9}}}'
  run "$MG" decide --json --project "$HOME/repo" "$NOTE"
  [[ "$output" == *'"place": "rule:frobnicate"'* ]]
}

@test "the log line holds neither the note's text nor its file name" {
  export STUB_ANSWER; STUB_ANSWER="$(answer memory 0.9)"
  run "$MG" decide "$NOTE"
  ! grep -q 'staging' "$LOG"
  ! grep -q 'note.md' "$LOG"
}

# A stub `claude` that records how it was called and prints a canned envelope.
stub_claude() {
  printf -- '---\nname: decide-haiku\nmodel: haiku\n---\n\nFIXTURE BODY\nline two\n' > "$CLAUDE_CONFIG_DIR/agents/decide-haiku.md"
  cat > "$BIN/claude" <<EOF
#!$REAL_PYTHON3
import json, os, sys
json.dump({"argv": sys.argv[1:], "stdin": sys.stdin.read(),
           "depth": os.environ.get("MEMORYGUARD_DEPTH"), "cwd": os.getcwd()},
          open("$BATS_TEST_TMPDIR/claude-call.json", "w"))
sys.stdout.write(open("$BATS_TEST_TMPDIR/envelope.json").read())
EOF
  chmod +x "$BIN/claude"
  unset MEMORYGUARD_BACKEND
}

envelope() { # result-text [is_error]
  "$REAL_PYTHON3" -c '
import json,sys
json.dump({"type":"result","is_error":sys.argv[2]=="true","result":sys.argv[1],"duration_ms":900,
           "usage":{"input_tokens":10,"cache_read_input_tokens":5},
           "modelUsage":{"claude-haiku-test":{}}}, open(sys.argv[3],"w"))' \
    "$1" "${2:-false}" "$BATS_TEST_TMPDIR/envelope.json"
}

@test "claude backend, lean: the frozen command line, the seat body and model, depth set" {
  stub_claude
  envelope "$(answer memory 0.9)"
  run "$MG" decide "$NOTE"
  [ "$status" -eq 0 ]
  [[ "$output" == allow-memory* ]]
  run "$REAL_PYTHON3" -c '
import json,sys
c = json.load(open(sys.argv[1]))
assert c["argv"] == ["-p","--safe-mode","--model","haiku","--system-prompt","FIXTURE BODY\nline two",
    "--tools","","--output-format","json","--no-session-persistence","--max-turns","1"], c["argv"]
assert json.loads(c["stdin"])["v"] == 1
assert c["depth"] == "1"
assert c["cwd"].endswith("/memoryguard")' "$BATS_TEST_TMPDIR/claude-call.json"
  [ "$status" -eq 0 ]
  grep -q 'api_ms=900 tokens=15' "$LOG"
}

@test "claude backend, agent mode: the frozen command line" {
  stub_claude
  envelope "$(answer memory 0.9)"
  MEMORYGUARD_CLAUDE_MODE=agent run "$MG" decide "$NOTE"
  [ "$status" -eq 0 ]
  run "$REAL_PYTHON3" -c '
import json,sys
c = json.load(open(sys.argv[1]))
assert c["argv"] == ["-p","--agent","decide-haiku","--output-format","json","--no-session-persistence",
    "--strict-mcp-config","--permission-mode","dontAsk","--max-turns","2"], c["argv"]' "$BATS_TEST_TMPDIR/claude-call.json"
  [ "$status" -eq 0 ]
}

@test "no seat file, or no claude on PATH, is allow-nobackend without running claude" {
  stub_claude
  rm "$CLAUDE_CONFIG_DIR/agents/decide-haiku.md"
  run "$MG" decide --json "$NOTE"
  [ "$status" -eq 3 ]
  [[ "$output" == *'"outcome": "allow-nobackend"'* ]]
  [ ! -e "$BATS_TEST_TMPDIR/claude-call.json" ]
  stub_claude
  rm "$BIN/claude"
  PATH="$BIN:/usr/bin:/bin" run "$MG" decide --json "$NOTE"
  [[ "$output" == *'"outcome": "allow-nobackend"'* ]]
}

@test "an error envelope is invalid; a fenced JSON reply is accepted" {
  stub_claude
  envelope "$(answer memory 0.9)" true
  run "$MG" decide --json "$NOTE"
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "invalid"'* ]]
  envelope "$(printf '```json\n%s\n```' "$(answer memory 0.9)")"
  run "$MG" decide --json "$NOTE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"outcome": "allow-memory"'* ]]
}

@test "selftest prints a row per fixture and a summary, and exits 1 when an answer is invalid" {
  export STUB_ANSWER; STUB_ANSWER="$(answer rule 0.9)"
  run "$MG" selftest
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 6 ]
  [[ "$output" == *"valid 5/5  matched 1/5  median "* ]]
  [[ "$output" == *"mode lean" ]]
  [ ! -e "$LOG" ]
  STUB_EXIT=1 run "$MG" selftest
  [ "$status" -eq 1 ]
  [[ "$output" == *"valid 0/5"* ]]
}

@test "log counts outcomes and the blocks a later keep reversed" {
  mkdir -p "$(dirname "$LOG")"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  old="2020-01-01T00:00:00Z"
  row() { printf '%s\tp\ts\t%s\th%s\t%s\t-\t-\t-\t-\n' "$1" "$2" "$3" "$4"; }
  {
    row "$old" aaaaaaaa 1 block
    row "$now" bbbbbbbb 2 block
    row "$now" bbbbbbbb 3 allow-keep
    row "$now" cccccccc 4 allow-memory
  } > "$LOG"
  run "$MG" log
  [ "$status" -eq 0 ]
  [[ "$output" == *$'allow-keep\t1'* ]]
  [[ "$output" == *$'block\t2'* ]]
  [[ "$output" == *$'blocks later kept\t1'* ]]
  run "$MG" log --since 30
  [[ "$output" == *$'block\t1'* ]]
}

@test "usage errors exit 2" {
  run "$MG"
  [ "$status" -eq 2 ]
  run "$MG" decide
  [ "$status" -eq 2 ]
  run "$MG" decide "$BATS_TEST_TMPDIR/missing.md"
  [ "$status" -eq 2 ]
}

# ---- hook pre: the gate on Write and Edit ------------------------------------

# A PreToolUse payload: tool, file_path, content (Write) or old_string, new_string
# (Edit; pass "" as the second slot for a Write), cwd.
payload() {
  "$REAL_PYTHON3" -c '
import json,sys
t,f,a,b,cwd = sys.argv[1:6]
ti = {"file_path": f, "content": a} if t == "Write" else {"file_path": f, "old_string": a, "new_string": b}
print(json.dumps({"tool_name": t, "tool_input": ti, "cwd": cwd}))' "$@"
}

# The hook's answer, read back: field of hookSpecificOutput, or "-" when absent.
field() { # json field
  "$REAL_PYTHON3" -c '
import json,sys
print(json.loads(sys.argv[1]).get("hookSpecificOutput", {}).get(sys.argv[2], "-"))' "$1" "$2"
}

hook_pre() { run "$MG" hook pre <<< "$1"; }
last_outcome() { tail -1 "$LOG" | cut -f6; }

# A memory note with a body of its own, under the sandbox profile's project "proj".
MEMDIR_SUFFIX=projects/-proj/memory
note_path() { echo "$CLAUDE_CONFIG_DIR/$MEMDIR_SUFFIX/${1:-n.md}"; }
note_body() { printf -- '---\nname: n\nmetadata:\n%s  type: feedback\n---\n%s\n' "${2:-}" "$1"; }
write_note() { # body [frontmatter-extra] [file]
  payload Write "$(note_path "${3:-}")" "$(note_body "$1" "${2:-}")" "" "$HOME/work"
}

@test "hook pre: a write outside any memory directory costs no python start" {
  printf '#!/bin/sh\necho started >> "%s/py-calls"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR" "$REAL_PYTHON3" > "$BIN/python3"
  hook_pre "$(payload Write "$HOME/work/a.md" "x" "" "$HOME/work")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$BATS_TEST_TMPDIR/py-calls" ]
  [ ! -e "$LOG" ]
}

@test "hook pre: garbage on stdin is silence and exit 0, with and without /memory/" {
  hook_pre 'not json at all'
  [ "$status" -eq 0 ] && [ -z "$output" ]
  hook_pre '{"tool_name": /memory/ broken'
  [ "$status" -eq 0 ] && [ -z "$output" ]
  hook_pre '{"tool_name": "Write", "tool_input": "/memory/x"}'
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "hook pre: content that mentions /memory/ in a file elsewhere logs nothing" {
  hook_pre "$(payload Write "$HOME/work/a.md" "see /memory/n.md" "" "$HOME/work")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$LOG" ]
}

@test "hook pre: a misplaced note is refused with the id, the percentage and both exits, then from the cache" {
  export STUB_ANSWER; STUB_ANSWER="$(answer shared-memory 0.9)"
  hook_pre "$(write_note "always ask first")"
  [ "$status" -eq 0 ]
  [ "$(field "$output" permissionDecision)" = "deny" ]
  reason="$(field "$output" permissionDecisionReason)"
  [[ "$reason" == *"shared-memory (90%)"* ]]
  [[ "$reason" == *'`until:'* ]]
  [[ "$reason" == *'`keep:'* ]]
  [[ "$reason" == *"It belongs in shared memory"* ]]
  [ "$(last_outcome)" = "block" ]
  hook_pre "$(write_note "always ask first")"
  [ "$(field "$output" permissionDecision)" = "deny" ]
  [[ "$(field "$output" permissionDecisionReason)" == *"already placed: shared-memory"* ]]
  [ "$(runs)" -eq 1 ]
  [ "$(last_outcome)" = "block-cached" ]
}

@test "hook pre: until: (frontmatter or body line) lets a note through without the backend" {
  export STUB_ANSWER; STUB_ANSWER="$(answer shared-memory 0.9)"
  hook_pre "$(write_note "bridge one" "  until: 2031-01-01
")"
  [ -z "$output" ]
  [ "$(last_outcome)" = "allow-stopgap" ]
  hook_pre "$(write_note "bridge two
Until: when the fix lands")"
  [ -z "$output" ]
  [ "$(last_outcome)" = "allow-stopgap" ]
  [ ! -e "$STUB_DIR/runs" ]
}

@test "hook pre: keep: needs a reason of twenty characters; a short one is ignored" {
  export STUB_ANSWER; STUB_ANSWER="$(answer memory 0.9)"
  hook_pre "$(write_note "kept one" "  keep: the operator asked for it here
")"
  [ -z "$output" ]
  [ "$(last_outcome)" = "allow-keep" ]
  [ ! -e "$STUB_DIR/runs" ]
  hook_pre "$(write_note "kept two" "  keep: because
")"
  [ "$(last_outcome)" = "allow-memory" ]
  [ "$(runs)" -eq 1 ]
}

@test "hook pre: a memory verdict is allowed in silence" {
  export STUB_ANSWER; STUB_ANSWER="$(answer memory 0.9)"
  hook_pre "$(write_note "the staging box")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(last_outcome)" = "allow-memory" ]
}

@test "hook pre: an unsure verdict is a note to the session and grants nothing" {
  export STUB_ANSWER; STUB_ANSWER="$(answer rule 0.5)"
  hook_pre "$(write_note "maybe a rule")"
  [[ "$(field "$output" additionalContext)" == "memoryguard: saved, but this may belong in "*"(50%)"* ]]
  [ "$(field "$output" permissionDecision)" = "-" ]
  [ "$(last_outcome)" = "allow-unsure" ]
}

@test "hook pre: a failing backend saves the note and says so" {
  export STUB_ANSWER; STUB_ANSWER="$(answer memory 0.9)"
  STUB_EXIT=1 hook_pre "$(write_note "anything")"
  [[ "$(field "$output" additionalContext)" == *"(exit)"* ]]
  [ "$(field "$output" permissionDecision)" = "-" ]
  [ "$(last_outcome)" = "allow-error" ]
}

@test "hook pre: an Edit is judged on the resulting text; one that cannot apply is silent" {
  export STUB_ANSWER; STUB_ANSWER="$(answer memory 0.9)"
  mkdir -p "$(dirname "$(note_path)")"
  printf 'the staging box stays up\n' > "$(note_path)"
  hook_pre "$(payload Edit "$(note_path)" "stays up" "must keep running" "$HOME/work")"
  [ "$(runs)" -eq 1 ]
  grep -q 'must keep running' "$STUB_DIR/request.json"
  ! grep -q 'stays up' "$STUB_DIR/request.json"
  hook_pre "$(payload Edit "$(note_path)" "not in the file" "x" "$HOME/work")"
  [ -z "$output" ]
  [ "$(last_outcome)" = "allow-error" ]
  [ "$(tail -1 "$LOG" | cut -f10)" = "noapply" ]
  [ "$(runs)" -eq 1 ]
}

@test "hook pre: the refusal names the section, the rule file, or another repository" {
  fixture_repo
  mkdir -p "$HOME/.claude-shared"
  printf '# S\n\n## Delegation\n\ntext\n' > "$HOME/.claude-shared/CLAUDE.md"
  printf '#!/bin/sh\necho /src/dot_claude-shared/CLAUDE.md\n' > "$BIN/chezmoi"; chmod +x "$BIN/chezmoi"
  slug="$(printf '%s' "$HOME/repo" | tr -c 'A-Za-z0-9' '-')"
  inrepo() { payload Write "$CLAUDE_CONFIG_DIR/projects/${2:-$slug}/memory/n.md" "$(note_body "$1")" "" "$HOME/repo"; }
  export STUB_ANSWER='{"answers":{"destination":{"choice":"shared-memory","confidence":0.9},"place":{"choice":"shared:Delegation","confidence":0.9}}}'
  hook_pre "$(inrepo "one")"
  reason="$(field "$output" permissionDecisionReason)"
  [[ "$reason" == *'shared memory, /src/dot_claude-shared/CLAUDE.md, section "Delegation"'* ]]
  [[ "$reason" != *"another repository"* ]]
  printf '#!/bin/sh\nexit 1\n' > "$BIN/chezmoi"
  STUB_ANSWER='{"answers":{"destination":{"choice":"shared-memory","confidence":0.9},"place":{"choice":"none","confidence":0.9}}}'
  hook_pre "$(inrepo "one b")"
  [[ "$(field "$output" permissionDecisionReason)" == *"in shared memory, the chezmoi source of ~/.claude-shared/CLAUDE.md."* ]]
  STUB_ANSWER='{"answers":{"destination":{"choice":"rule","confidence":0.9},"place":{"choice":"rule:frobnicate","confidence":0.9}}}'
  hook_pre "$(inrepo "two")"
  reason="$(field "$output" permissionDecisionReason)"
  [[ "$reason" == *"$HOME/repo/.claude/rules/frobnicate.md."* ]]
  [[ "$reason" != *"another repository"* ]]
  hook_pre "$(inrepo "three" "-elsewhere")"
  [[ "$(field "$output" permissionDecisionReason)" == *"another repository"* ]]
}

@test "hook pre: MEMORY.md only ever warns, and a clean index is silent" {
  export STUB_ANSWER; STUB_ANSWER="$(answer shared-memory 0.9)"
  mkdir -p "$(dirname "$(note_path)")"
  printf 'x\n' > "$(note_path a.md)"
  idx() { payload Write "$(note_path MEMORY.md)" "$1" "" "$HOME/work"; }
  hook_pre "$(idx "- [A](a.md) — short")"
  [ -z "$output" ]
  [ "$(last_outcome)" = "index-ok" ]
  hook_pre "$(idx "$(printf -- '- [A](a.md) — %0300d' 0)")"
  [[ "$(field "$output" additionalContext)" == *"1 entries over 200"* ]]
  [ "$(last_outcome)" = "index-warn" ]
  hook_pre "$(idx "$(for i in $(seq 120); do printf -- '- [A](a.md) — %060d\n' "$i"; done)")"
  [[ "$(field "$output" additionalContext)" == *"MEMORY.md would be "* ]]
  hook_pre "$(idx "- [B](b.md) — gone")"
  [[ "$(field "$output" additionalContext)" == *"Entries link missing files: b.md."* ]]
  [ "$(field "$output" permissionDecision)" = "-" ]
  [ ! -e "$STUB_DIR/runs" ]
}

@test "hook pre: a note under another profile's directory is allowed untouched" {
  export STUB_ANSWER; STUB_ANSWER="$(answer shared-memory 0.9)"
  hook_pre "$(payload Write "$HOME/.claude-other/projects/-p/memory/n.md" "$(note_body x)" "" "$HOME/work")"
  [ -z "$output" ]
  [ "$(last_outcome)" = "allow-foreign" ]
  [ ! -e "$STUB_DIR/runs" ]
}

@test "hook pre: a note over twelve thousand characters is flagged, not judged" {
  export STUB_ANSWER; STUB_ANSWER="$(answer shared-memory 0.9)"
  hook_pre "$(write_note "$(head -c 13000 /dev/zero | tr '\0' x)")"
  [[ "$(field "$output" additionalContext)" == *"A note is a pointer"* ]]
  [ "$(last_outcome)" = "allow-large" ]
  [ ! -e "$STUB_DIR/runs" ]
}

@test "hook pre: inside the decider's own session (MEMORYGUARD_DEPTH) nothing happens" {
  export STUB_ANSWER; STUB_ANSWER="$(answer shared-memory 0.9)"
  MEMORYGUARD_DEPTH=1 hook_pre "$(write_note "anything")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$LOG" ]
}

@test "hook pre: autoMemoryDirectory in the profile's settings is gated too" {
  printf '{"autoMemoryDirectory": "%s/auto-mem"}' "$HOME" > "$CLAUDE_CONFIG_DIR/settings.json"
  export STUB_ANSWER; STUB_ANSWER="$(answer shared-memory 0.9)"
  hook_pre "$(payload Write "$HOME/auto-mem/n.md" "$(note_body "auto")" "" "$HOME/work")"
  [ "$(field "$output" permissionDecision)" = "deny" ]
  [ "$(last_outcome)" = "block" ]
}

# ---- hook bash: Bash writes into a memory directory go through the Write tool --

# A PreToolUse payload for the Bash tool.
bash_payload() {
  "$REAL_PYTHON3" -c '
import json,sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))' "$1" "$HOME/work"
}

hook_bash() { run "$MG" hook bash <<< "$(bash_payload "$1")"; }

@test "hook bash: a write into a memory directory is refused and logged without hashes" {
  M="$(dirname "$(note_path)")"
  for cmd in \
    "echo x >> $M/MEMORY.md" \
    "sed -i '' s/a/b/ $M/n.md" \
    "cat <<EOF > $M/n.md" \
    "cd $M && printf x > n.md" \
    "cp /tmp/n.md $M/" \
    "echo x | tee '$M/n.md'" \
    "echo x > ~/.claude-test/projects/-proj/memory/n.md" \
    "perl -pi -e 's/a/b/' \$CLAUDE_CONFIG_DIR/projects/-proj/memory/n.md" \
    "sudo mv /tmp/n.md $M/n.md"; do
    hook_bash "$cmd"
    [ "$status" -eq 0 ]
    [ "$(field "$output" permissionDecision)" = "deny" ] || { echo "not refused: $cmd"; false; }
    [[ "$(field "$output" permissionDecisionReason)" == "memoryguard: write memory notes with the Write or Edit tool"* ]]
    [ "$(last_outcome)" = "bash-block" ]
  done
  [ "$(tail -1 "$LOG" | cut -f3-5 | tr '\t' ' ')" = "-proj - -" ]
  [ ! -e "$STUB_DIR/runs" ]
}

@test "hook bash: reads, rm, and paths that are not a memory directory pass in silence" {
  M="$(dirname "$(note_path)")"
  for cmd in \
    "cat $M/n.md" \
    "grep -l x $M/*.md" \
    "rm $M/n.md" \
    "ls $M" \
    "echo x > /tmp/memory/n.md" \
    "ls $M 2>&1" \
    "cat $M/n.md 2>/dev/null" \
    "echo x > $HOME/.claude-other/projects/-p/memory/n.md" \
    "grep -c cp $M/n.md"; do
    hook_bash "$cmd"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "refused: $cmd"; false; }
  done
  [ ! -e "$LOG" ]
}

@test "hook bash: a command with no /memory/ does not start python; garbage is silence" {
  printf '#!/bin/sh\necho started >> "%s/py-calls"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR" "$REAL_PYTHON3" > "$BIN/python3"
  hook_bash "echo x > $HOME/work/a.md"
  [ "$status" -eq 0 ] && [ -z "$output" ]
  [ ! -e "$BATS_TEST_TMPDIR/py-calls" ]
  run "$MG" hook bash <<< '{"tool_name": "Bash", "tool_input": /memory/ broken'
  [ "$status" -eq 0 ] && [ -z "$output" ]
  run "$MG" hook bash <<< '{"tool_name": "Bash", "tool_input": "/memory/x"}'
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "settings prints the three hook commands, each failing open" {
  run "$MG" settings
  [ "$status" -eq 0 ]
  [ "$(grep -c '"command": ".* || true"' <<< "$output")" -eq 3 ]
  [[ "$output" == *"memoryguard hook pre || true"* ]]
  [[ "$output" == *"memoryguard hook bash || true"* ]]
  [[ "$output" == *"memoryguard hook start || true"* ]]
  run "$MG" hook start <<< '{}'
  [ "$status" -eq 0 ] && [ -z "$output" ]
}
