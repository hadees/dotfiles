#!/usr/bin/env bats

# tests/context-evals/run asks a headless `claude -p` whether a rule in the
# shared memory is still followed. These tests run it against a stub `claude`:
# CI makes no real call, and the scenarios are not .bats files, so `bats tests`
# never spends money.

RUN="$BATS_TEST_DIRNAME/context-evals/run"
SCENARIOS="$BATS_TEST_DIRNAME/context-evals/scenarios"

setup() {
  unset MEMORYGUARD_DEPTH CLAUDE_PEER_WORKTREE CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_PROJECT_DIR
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  # Records its arguments, one per line, and prints $STUB_REPLY.
  cat > "$BIN/claude" <<'STUB'
#!/bin/sh
[ -z "${STUB_FAIL:-}" ] || exit 3
printf '%s\n' "$@" >> "$STUB_ARGS"
printf '%s\n' "${STUB_REPLY:-}"
STUB
  chmod +x "$BIN/claude"
  export PATH="$BIN:$PATH" STUB_ARGS="$BATS_TEST_TMPDIR/args"

  # A one-topic memory and a scenario that passes on "alpha" and fails on "beta".
  MEM="$BATS_TEST_TMPDIR/memory"
  mkdir -p "$MEM/topics"
  printf '# Fixture\n\n@topics/always.md\n' > "$MEM/CLAUDE.md"
  printf 'ALWAYS-TEXT\n' > "$MEM/topics/always.md"
  SC="$BATS_TEST_TMPDIR/one.txt"
  printf 'name: one\nrole: plain\nfail: beta\npass: alpha\n\nWhat now?\n' > "$SC"
}

@test "the script parses and the scenarios name themselves, once" {
  sh -n "$RUN"
  [ "$(ls "$SCENARIOS" | wc -l | tr -d ' ')" -eq 5 ]
  [ "$(cat "$SCENARIOS"/*.txt | grep -c '^name: ')" -eq 5 ]
  [ "$(cat "$SCENARIOS"/*.txt | grep '^name: ' | sort -u | wc -l | tr -d ' ')" -eq 5 ]
}

@test "prints name, runs, passed and memory characters" {
  STUB_REPLY=alpha run "$RUN" --runs 3 --memory "$MEM" "$SC"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^one$'\t'3$'\t'3$'\t'[0-9]+$ ]] || { echo "$output"; false; }
}

@test "a reply that misses the pass pattern, or hits a fail pattern, is not counted" {
  STUB_REPLY=gamma run "$RUN" --runs 2 --memory "$MEM" "$SC"
  [ "$status" -eq 0 ]
  [[ "$output" == $'one\t2\t0\t'* ]]
  STUB_REPLY="alpha beta" run "$RUN" --runs 2 --memory "$MEM" "$SC"
  [ "$status" -eq 0 ]
  [[ "$output" == $'one\t2\t0\t'* ]]
}

@test "claude is called with the frozen flags, the memory as system prompt and the situation" {
  STUB_REPLY=alpha run "$RUN" --runs 1 --model haiku --memory "$MEM" "$SC"
  [ "$status" -eq 0 ]
  local args
  args="$(cat "$STUB_ARGS")"
  for f in -p --bare --no-session-persistence --max-budget-usd 0.25 --model haiku --append-system-prompt; do
    grep -qxF -e "$f" <<< "$args" || { echo "missing $f"; echo "$args"; false; }
  done
  [[ "$args" == *"ALWAYS-TEXT"* ]]
  [[ "$args" == *"What now?"* ]]
}

@test "the memory is the index with its imports expanded, then the start hook's output for the role" {
  printf '## Fixture lead\n\nLEAD-TEXT\n' > "$MEM/topics/lead.md"
  printf '## Fixture claude-peers\n\nPEERS-TEXT\n' > "$MEM/topics/claude-peers.md"
  printf '%s\n' '- `claude-peers.md` and `lead.md`: x.' >> "$MEM/CLAUDE.md"
  sed 's/^role: plain/role: lead/' "$SC" > "$BATS_TEST_TMPDIR/lead.txt"
  STUB_REPLY=alpha run "$RUN" --runs 1 --memory "$MEM" "$BATS_TEST_TMPDIR/lead.txt"
  [ "$status" -eq 0 ]
  grep -q LEAD-TEXT "$STUB_ARGS"
  grep -q ALWAYS-TEXT "$STUB_ARGS"
  : > "$STUB_ARGS"
  STUB_REPLY=alpha run "$RUN" --runs 1 --memory "$MEM" "$SC"
  [ "$status" -eq 0 ]
  grep -q ALWAYS-TEXT "$STUB_ARGS"
  ! grep -q LEAD-TEXT "$STUB_ARGS" || { echo "a plain session got the lead topic"; false; }
}

@test "two memory directories give two memory sizes" {
  local big="$BATS_TEST_TMPDIR/big"
  cp -R "$MEM" "$big"
  head -c 3000 /dev/zero | tr '\0' x >> "$big/topics/always.md"
  STUB_REPLY=alpha run "$RUN" --runs 1 --memory "$MEM" "$SC"
  local a="${output##*$'\t'}"
  STUB_REPLY=alpha run "$RUN" --runs 1 --memory "$big" "$SC"
  [ "$((${output##*$'\t'} - a))" -ge 3000 ]
}

@test "pad puts filler lines before or after the memory" {
  local first last line
  line="$(head -n 1 "$BATS_TEST_DIRNAME/context-evals/filler-rules.txt")"
  sed 's/^role: plain/role: plain\npad: 5 first/' "$SC" > "$BATS_TEST_TMPDIR/first.txt"
  sed 's/^role: plain/role: plain\npad: 5 last/' "$SC" > "$BATS_TEST_TMPDIR/last.txt"
  STUB_REPLY=alpha run "$RUN" --runs 1 --memory "$MEM" "$BATS_TEST_TMPDIR/first.txt"
  [ "$status" -eq 0 ]
  first="$(awk -v l="$line" 'index($0, l) { print NR; exit }' "$STUB_ARGS")"
  [ "$(awk '/ALWAYS-TEXT/ { print NR; exit }' "$STUB_ARGS")" -gt "$first" ]
  : > "$STUB_ARGS"
  STUB_REPLY=alpha run "$RUN" --runs 1 --memory "$MEM" "$BATS_TEST_TMPDIR/last.txt"
  [ "$status" -eq 0 ]
  last="$(awk -v l="$line" 'index($0, l) { print NR; exit }' "$STUB_ARGS")"
  [ "$(awk '/ALWAYS-TEXT/ { print NR; exit }' "$STUB_ARGS")" -lt "$last" ]
}

@test "the five real scenarios run against the real memory and print their rows" {
  STUB_REPLY=nothing run "$RUN" --runs 1 "$SCENARIOS"/*.txt
  [ "$status" -eq 0 ]
  [ "$(grep -c . <<< "$output")" -eq 5 ]
  [[ "$output" == *$'secretary-go\t1\t0\t'* ]]
  [[ "$output" == *$'handback-stop\t1\t0\t'* ]]
  [[ "$output" == *$'relayed-go\t1\t0\t'* ]]
  [[ "$output" == *$'four-kinds\t1\t0\t'* ]]
  [[ "$output" == *$'ready-steps\t1\t0\t'* ]]
}

@test "each real scenario passes a good reply and fails a bad one" {
  STUB_REPLY="claude-peer stop Alpha; merge 12; token; approvals-ledger; queue add; I start steps 2 and 3 together" run "$RUN" --runs 1 "$SCENARIOS"/*.txt
  [ "$status" -eq 0 ]
  [ "$(grep -c $'\t1\t1\t' <<< "$output")" -eq 5 ]
  STUB_REPLY="claude-peer stop merge token, but type /exit in the pane; in my tab; you need to restart it; work-sonnet; step 2 now and step 3 after step 2, one at a time" run "$RUN" --runs 1 "$SCENARIOS"/*.txt
  [ "$status" -eq 0 ]
  [ "$(grep -c $'\t1\t0\t' <<< "$output")" -eq 5 ]
}

@test "ready-steps: matching ignores case, and a reply that says not one at a time is not failed" {
  local sc="$SCENARIOS/ready-steps.txt"
  STUB_REPLY="Steps 2 and 3 together, not one at a time" run "$RUN" --runs 1 "$sc"
  [ "$status" -eq 0 ]
  [[ "$output" == $'ready-steps\t1\t1\t'* ]]
  STUB_REPLY="Steps 2 and 3 together, then Step 3 after Step 2" run "$RUN" --runs 1 "$sc"
  [[ "$output" == $'ready-steps\t1\t0\t'* ]]
  STUB_REPLY="Steps 2 and 3 together, one at a time" run "$RUN" --runs 1 "$sc"
  [[ "$output" == $'ready-steps\t1\t0\t'* ]]
  STUB_REPLY="Steps 2 and 3, one at a time" run "$RUN" --runs 1 "$sc"
  [[ "$output" == $'ready-steps\t1\t0\t'* ]]
}

@test "a harness error exits 1: no scenario, bad runs, a failing claude" {
  run "$RUN"
  [ "$status" -eq 1 ]
  run "$RUN" --memory "$MEM" "$BATS_TEST_TMPDIR/nowhere.txt"
  [ "$status" -eq 1 ]
  run "$RUN" --runs 0 --memory "$MEM" "$SC"
  [ "$status" -eq 1 ]
  STUB_FAIL=1 run "$RUN" --runs 1 --memory "$MEM" "$SC"
  [ "$status" -eq 1 ]
  [[ "$output" == *"claude failed"* ]]
}
