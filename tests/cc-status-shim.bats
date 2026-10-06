#!/usr/bin/env bats

# The cc-status shim (dot_local/libexec/cc-status-shim/) sits between Claude
# Code's hooks and iTerm2's cc-status. Both cc-status and it2 are stubbed in
# one directory, the way iTerm2 ships them side by side: cc-status records
# the payload it was fed, it2 records its argv. No real iTerm2 is touched.

bats_require_minimum_version 1.5.0

setup() {
  STUB="$BATS_TEST_TMPDIR/utilities"
  mkdir -p "$STUB"
  printf '#!/bin/sh\ncat > "%s/fed"\n' "$BATS_TEST_TMPDIR" > "$STUB/cc-status"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/argv"\necho x >> "%s/calls"\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$STUB/it2"
  chmod +x "$STUB/cc-status" "$STUB/it2"
  # The real wiring is a symlink to the bundle; it2 is found beside its target.
  ln -s "$STUB/cc-status" "$BATS_TEST_TMPDIR/cc-status-link"
  export CC_STATUS_BIN="$BATS_TEST_TMPDIR/cc-status-link"
  export ITERM_SESSION_ID="w0t1p0:ABC-123"
  SHIM="$BATS_TEST_DIRNAME/../dot_local/libexec/cc-status-shim/executable_cc-status"
  # Config comes from git; keep the machine's own out of it.
  export HOME="$BATS_TEST_TMPDIR/home" GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
  : > "$GIT_CONFIG_GLOBAL"
  SESS="$BATS_TEST_TMPDIR/sess"
  mkdir -p "$SESS/scratchpad" "$SESS/tasks"
}

# age_file <name> <seconds>: a task output file last written that long ago.
age_file() {
  : > "$SESS/tasks/$1.output"
  python3 -c 'import os,sys,time; t=time.time()-int(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$SESS/tasks/$1.output" "$2"
}

# payload <event> <tasks-json> [extra-json-members]: a compact payload, as Claude Code writes it.
payload() { printf '{"hook_event_name":"%s","scratchpad_dir":"%s/scratchpad","background_tasks":%s%s}' "$1" "$SESS" "$2" "${3:+,$3}"; }

it2_argv() { paste -sd'|' "$BATS_TEST_TMPDIR/argv"; }
fed_tasks() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["background_tasks"],sort_keys=True))' "$BATS_TEST_TMPDIR/fed"; }

run_shim() { run sh "$SHIM"; }

@test "shim: a non-Stop event passes through byte for byte and never calls it2" {
  local p='{"hook_event_name":"PreToolUse","tool_name":"Bash","background_tasks":[{"task_id":"t1"}]}'
  run_shim <<< "$p"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]
  [ ! -e "$BATS_TEST_TMPDIR/argv" ]
}

@test "shim: Stop with nothing in flight passes through unchanged" {
  local p='{"hook_event_name":"Stop","stop_hook_active":false,"background_tasks":[]}'
  run_shim <<< "$p"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]
  [ ! -e "$BATS_TEST_TMPDIR/argv" ]
}

@test "shim: a quiet shell paints idle in amber, stores 0, and feeds cc-status an empty array" {
  age_file a 7200
  run_shim <<< "$(payload Stop '[{"task_id":"a","task_type":"local_bash","description":"tail -F build.log"}]')"
  [ "$status" -eq 0 ]
  [ "$(fed_tasks)" = "[]" ]
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|idle|--detail|idle · 1 quiet background task: tail -F build.log|--dot-color|#af8700|--text-color|#888888|--background-tasks|0" ]
}

@test "shim: an active task alongside a quiet one is fed to cc-status with id and status, and it2 is left alone" {
  age_file a 7200
  age_file b 30
  run_shim <<< "$(payload Stop '[{"task_id":"a","task_type":"local_bash","description":"old"},{"task_id":"b","task_type":"local_agent","description":"busy"}]')"
  [ "$status" -eq 0 ]
  [ "$(fed_tasks)" = '[{"description": "busy", "id": "b", "status": "running", "task_id": "b", "task_type": "local_agent"}]' ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "shim: an agent's symlinked output follows the transcript: fresh active, old quiet, dangling quiet" {
  : > "$BATS_TEST_TMPDIR/agent.jsonl"
  ln -s "$BATS_TEST_TMPDIR/agent.jsonl" "$SESS/tasks/ag.output"
  run_shim <<< "$(payload Stop '[{"task_id":"ag","task_type":"local_agent"}]')"
  [ "$(fed_tasks | grep -c '"ag"')" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]

  python3 -c 'import os,sys,time; t=time.time()-7200; os.utime(sys.argv[1],(t,t))' "$BATS_TEST_TMPDIR/agent.jsonl"
  run_shim <<< "$(payload Stop '[{"task_id":"ag","task_type":"local_agent"}]')"
  [ "$(fed_tasks)" = "[]" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/calls")" -eq 1 ]

  rm "$BATS_TEST_TMPDIR/agent.jsonl"
  rm "$BATS_TEST_TMPDIR/calls"
  run_shim <<< "$(payload Stop '[{"task_id":"ag","task_type":"local_agent"}]')"
  [ "$(fed_tasks)" = "[]" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/calls")" -eq 1 ]
}

@test "shim: a task with no output file is unknown and counts as active" {
  run_shim <<< "$(payload Stop '[{"task_id":"ghost","task_type":"monitor"}]')"
  [ "$status" -eq 0 ]
  [ "$(fed_tasks | grep -c '"ghost"')" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "shim: a payload with no scratchpad_dir leaves every task active" {
  run_shim <<< '{"hook_event_name":"Stop","background_tasks":[{"task_id":"a","task_type":"local_bash"}]}'
  [ "$status" -eq 0 ]
  [ "$(fed_tasks | grep -c '"a"')" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "shim: StopFailure is handled like Stop" {
  age_file a 7200
  run_shim <<< "$(payload StopFailure '[{"task_id":"a","task_type":"local_bash"}]')"
  [ "$status" -eq 0 ]
  [ "$(fed_tasks)" = "[]" ]
  grep -qx 'idle · 1 quiet background task: local_bash' "$BATS_TEST_TMPDIR/argv"
}

@test "shim: SubagentStop drops the agent that just stopped" {
  age_file ag1 5
  age_file b 5
  run_shim <<< "$(payload SubagentStop '[{"task_id":"ag1","task_type":"local_agent"},{"task_id":"b","task_type":"local_bash"}]' '"agent_id":"ag1"')"
  [ "$status" -eq 0 ]
  [ "$(fed_tasks | grep -c '"b"')" -eq 1 ]
  [ "$(fed_tasks | grep -c '"ag1"')" -eq 0 ]
}

@test "shim: several quiet tasks are plural, and a long detail is cut" {
  age_file a 7200
  age_file b 7200
  run_shim <<< "$(payload Stop '[{"task_id":"a","description":"first"},{"task_id":"b","task_type":"local_agent"}]')"
  grep -qx 'idle · 2 quiet background tasks: first, local_agent' "$BATS_TEST_TMPDIR/argv"
  local long; long=$(printf 'x%.0s' $(seq 1 300))
  run_shim <<< "$(payload Stop "[{\"task_id\":\"a\",\"description\":\"$long\"}]")"
  [ "$(grep -A1 '^--detail$' "$BATS_TEST_TMPDIR/argv" | tail -1 | wc -m)" -eq 182 ]   # 180 + … + newline
}

@test "shim: tabstatus config overrides the window and the colour; an invalid colour falls back with a note" {
  age_file a 600
  git config -f "$GIT_CONFIG_GLOBAL" tabstatus.quiet-minutes 5
  git config -f "$GIT_CONFIG_GLOBAL" tabstatus.color.quiet '#112233'
  run_shim <<< "$(payload Stop '[{"task_id":"a","task_type":"local_bash"}]')"
  grep -qx '#112233' "$BATS_TEST_TMPDIR/argv"

  git config -f "$GIT_CONFIG_GLOBAL" tabstatus.color.quiet 'blue'
  run --separate-stderr sh "$SHIM" <<< "$(payload Stop '[{"task_id":"a","task_type":"local_bash"}]')"
  grep -qx '#af8700' "$BATS_TEST_TMPDIR/argv"
  [[ $stderr == *"tabstatus.color.quiet"* ]]
}

@test "shim: a hung it2 costs about its timeout, and the shim still exits 0" {
  age_file a 7200
  printf '#!/bin/sh\nexec sleep 10\n' > "$STUB/it2"
  local t0=$SECONDS
  run_shim <<< "$(payload Stop '[{"task_id":"a","task_type":"local_bash"}]')"
  [ "$status" -eq 0 ]
  [ $((SECONDS - t0)) -lt 9 ]
}

@test "shim: a flag argument goes to cc-status untouched, with the payload" {
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/ccargv"; cat > "%s/fed"\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$STUB/cc-status"
  run sh "$SHIM" --agent codex <<< '{"hook_event_name":"Stop"}'
  [ "$status" -eq 0 ]
  [ "$(paste -sd' ' "$BATS_TEST_TMPDIR/ccargv")" = "--agent codex" ]
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = '{"hook_event_name":"Stop"}' ]
}

@test "explain: prints the decision and calls neither cc-status nor it2" {
  age_file a 7200
  age_file b 5
  run sh "$SHIM" explain <<< "$(payload Stop '[{"task_id":"a","task_type":"local_bash","description":"old"},{"task_id":"b","task_type":"local_agent","description":"busy"},{"task_id":"c","task_type":"monitor","description":"ghost"}]')"
  [ "$status" -eq 0 ]
  [[ $output == *"event=Stop"* ]]
  [[ $output == *"session=ABC-123"* ]]
  [[ $output == *"task a local_bash quiet age=7200"*"old"* ]]
  [[ $output == *"task b local_agent active age=5"*"busy"* ]]
  [[ $output == *"task c monitor unknown age=-"*"ghost"* ]]
  [[ $output == *"action=rewrite"* && $output != *"idle"* ]]
  [[ $output == *"cc-status=$CC_STATUS_BIN"* ]]
  [[ $output == *"it2=$STUB/it2"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/fed" ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "explain: all quiet says rewrite+idle; a non-Stop event says passthrough" {
  age_file a 7200
  run sh "$SHIM" explain <<< "$(payload Stop '[{"task_id":"a","task_type":"local_bash"}]')"
  [[ $output == *"action=rewrite+idle"* ]]
  run sh "$SHIM" explain <<< '{"hook_event_name":"PreToolUse"}'
  [[ $output == *"event=PreToolUse"* && $output == *"action=passthrough"* ]]
}

@test "settings: valid JSON naming all eleven events, each with the bare expanded shim path" {
  run sh "$SHIM" settings
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | sed -n '/^{/,/^}/p' > "$BATS_TEST_TMPDIR/settings.json"
  python3 - "$BATS_TEST_TMPDIR/settings.json" "$HOME" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
assert len(h) == 11 and "SubagentStart" in h and "SubagentStop" in h, sorted(h)
for ev, entries in h.items():
    for e in entries:
        for hook in e["hooks"]:
            assert hook["command"] == sys.argv[2] + "/.local/libexec/cc-status-shim/cc-status", (ev, hook)
PY
}

@test "shim: it2 is taken from beside the real binary, not from PATH" {
  # A different it2 on PATH must lose to the one shipped beside cc-status.
  mkdir -p "$BATS_TEST_TMPDIR/path"
  printf '#!/bin/sh\necho wrong > "%s/argv"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/path/it2"
  chmod +x "$BATS_TEST_TMPDIR/path/it2"
  age_file a 7200
  PATH="$BATS_TEST_TMPDIR/path:$PATH" run sh "$SHIM" <<< "$(payload Stop '[{"task_id":"a"}]')"
  [ "$status" -eq 0 ]
  grep -q '^set-status$' "$BATS_TEST_TMPDIR/argv"
}

@test "shim: without any it2 the payload passes through and nothing else is tried" {
  rm "$STUB/it2"
  age_file a 7200
  local p; p=$(payload Stop '[{"task_id":"a"}]')
  PATH="/usr/bin:/bin" run sh "$SHIM" <<< "$p"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]
}

@test "shim: the event name only inside message text does not count as Stop" {
  local p='{"hook_event_name":"PostToolUse","tool_response":"the \"hook_event_name\":\"Stop\" payload","background_tasks":[{"task_id":"a"}]}'
  run_shim <<< "$p"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]
  [ ! -e "$BATS_TEST_TMPDIR/argv" ]
}

@test "shim: without an iTerm2 session id it passes through" {
  unset ITERM_SESSION_ID
  age_file a 7200
  local p; p=$(payload Stop '[{"task_id":"a"}]')
  run_shim <<< "$p"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]
  [ ! -e "$BATS_TEST_TMPDIR/argv" ]
}

@test "shim: unparsable JSON passes through" {
  run_shim <<< '{"hook_event_name":"Stop","background_tasks":[oops'
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = '{"hook_event_name":"Stop","background_tasks":[oops' ]
  [ ! -e "$BATS_TEST_TMPDIR/argv" ]
}

@test "shim: no cc-status at all exits 0 and touches nothing" {
  export CC_STATUS_BIN="$BATS_TEST_TMPDIR/absent"
  run_shim <<< '{"hook_event_name":"Stop","background_tasks":[{"task_id":"a"}]}'
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/fed" ]
  [ ! -e "$BATS_TEST_TMPDIR/argv" ]
}

@test "shim: pointed at itself it exits 0 instead of recursing" {
  mkdir -p "$BATS_TEST_TMPDIR/cc-status-shim"
  cp "$SHIM" "$BATS_TEST_TMPDIR/cc-status-shim/cc-status"
  chmod +x "$BATS_TEST_TMPDIR/cc-status-shim/cc-status"
  export CC_STATUS_BIN="$BATS_TEST_TMPDIR/cc-status-shim/cc-status"
  run "$BATS_TEST_TMPDIR/cc-status-shim/cc-status" <<< '{"hook_event_name":"Stop","background_tasks":[]}'
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/fed" ]
}
