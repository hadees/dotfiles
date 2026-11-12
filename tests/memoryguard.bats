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
