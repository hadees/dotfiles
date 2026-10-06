#!/usr/bin/env bats

# The cc-status shim (dot_local/libexec/cc-status-shim/) sits between Claude
# Code's hooks and iTerm2's cc-status. Both cc-status and it2 are stubbed in
# one directory, the way iTerm2 ships them side by side: cc-status records
# the payload it was fed, it2 records its argv. No real iTerm2 is touched.

setup() {
  STUB="$BATS_TEST_TMPDIR/utilities"
  mkdir -p "$STUB"
  printf '#!/bin/sh\ncat > "%s/fed"\n' "$BATS_TEST_TMPDIR" > "$STUB/cc-status"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/argv"\n' "$BATS_TEST_TMPDIR" > "$STUB/it2"
  chmod +x "$STUB/cc-status" "$STUB/it2"
  # The real wiring is a symlink to the bundle; it2 is found beside its target.
  ln -s "$STUB/cc-status" "$BATS_TEST_TMPDIR/cc-status-link"
  export CC_STATUS_BIN="$BATS_TEST_TMPDIR/cc-status-link"
  export ITERM_SESSION_ID="w0t1p0:ABC-123"
  SHIM="$BATS_TEST_DIRNAME/../dot_local/libexec/cc-status-shim/executable_cc-status"
}

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

@test "shim: Stop with background tasks paints idle, then details the tasks" {
  local p='{"hook_event_name":"Stop","stop_hook_active":false,"background_tasks":[{"task_id":"a","task_type":"local_bash","description":"tail -F build.log"},{"task_id":"b","task_type":"local_agent","description":"review PR"}]}'
  run_shim <<< "$p"
  [ "$status" -eq 0 ]
  # cc-status saw an empty array, so it paints the row like any finished turn.
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["background_tasks"]==[] and d["hook_event_name"]=="Stop"' "$BATS_TEST_TMPDIR/fed"
  [ "$(paste -sd'|' "$BATS_TEST_TMPDIR/argv")" = "set-status|--session|ABC-123|--detail|2 background tasks: tail -F build.log, review PR|--dot-color|#5f87ff|--background-tasks|2" ]
}

@test "shim: one task is singular" {
  run_shim <<< '{"hook_event_name":"Stop","background_tasks":[{"task_id":"a","task_type":"local_bash"}]}'
  [ "$status" -eq 0 ]
  grep -qx '1 background task: local_bash' "$BATS_TEST_TMPDIR/argv"
}

@test "shim: it2 is taken from beside the real binary, not from PATH" {
  # A different it2 on PATH must lose to the one shipped beside cc-status.
  mkdir -p "$BATS_TEST_TMPDIR/path"
  printf '#!/bin/sh\necho wrong > "%s/argv"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/path/it2"
  chmod +x "$BATS_TEST_TMPDIR/path/it2"
  PATH="$BATS_TEST_TMPDIR/path:$PATH" run sh "$SHIM" <<< '{"hook_event_name":"Stop","background_tasks":[{"task_id":"a"}]}'
  [ "$status" -eq 0 ]
  grep -q '^set-status$' "$BATS_TEST_TMPDIR/argv"
}

@test "shim: without any it2 the payload passes through and nothing else is tried" {
  rm "$STUB/it2"
  local p='{"hook_event_name":"Stop","background_tasks":[{"task_id":"a"}]}'
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
  local p='{"hook_event_name":"Stop","background_tasks":[{"task_id":"a"}]}'
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
