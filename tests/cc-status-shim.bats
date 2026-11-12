#!/usr/bin/env bats

# The cc-status shim (dot_local/libexec/cc-status-shim/) sits between Claude
# Code's hooks and iTerm2's cc-status. Both cc-status and it2 are stubbed in
# one directory, the way iTerm2 ships them side by side: cc-status records
# the payload it was fed, it2 records its argv. No real iTerm2 is touched.
# lsof and ps are stubbed there too (and that directory put on PATH): they print
# lsof.out and ps.out, fixtures a test overwrites, and record their argv. So is
# tabname: proj for a cwd ending in /proj, proj@feat-x for /feat-x, else nothing
# and exit 1; a leading --role is dropped (a bare label, like an older tabname),
# unless role.out exists, whose content it prints instead. it2 also appends every argv to argv_all, one call per block.
# Both stubs record ${ITERM2_COOKIE-unset} (fed_cookie, it2_cookie); an it2 with a
# it2.fail file prints its content on stderr and exits 1, as iTerm2's refusal does.

bats_require_minimum_version 1.5.0

setup() {
  # Pin python3 while HOME is still real: an asdf shim first on PATH finds no
  # version under the fake HOME and exits 126 instead of running.
  if py="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)"; then
    mkdir -p "$BATS_TEST_TMPDIR/pybin" && ln -s "$py" "$BATS_TEST_TMPDIR/pybin/python3"
    export PATH="$BATS_TEST_TMPDIR/pybin:$PATH"
  fi
  STUB="$BATS_TEST_TMPDIR/utilities"
  mkdir -p "$STUB"
  printf '#!/bin/sh\necho "${ITERM2_COOKIE-unset}" > "%s/fed_cookie"\ncat > "%s/fed"\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$STUB/cc-status"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/argv"\nprintf "%%s\\n" "$@" >> "%s/argv_all"\necho x >> "%s/calls"\necho "${ITERM2_COOKIE-unset}" >> "%s/it2_cookie"\n[ -e "%s/it2.fail" ] && { cat "%s/it2.fail" >&2; exit 1; }\nexit 0\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$STUB/it2"
  cat > "$STUB/tabname" <<'SH'
#!/bin/sh
[ "$1" = --role ] && shift
echo "$1" >> "$(dirname "$0")/../tabname_argv"
[ -e "$(dirname "$0")/../role.out" ] && { cat "$(dirname "$0")/../role.out"; exit; }
case $1 in
  */feat-x) echo proj@feat-x ;;
  */proj) echo proj ;;
  *) exit 1 ;;
esac
SH
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/lsof_argv"\ncat "%s/lsof.out"\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$STUB/lsof"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/ps_argv"\ncat "%s/ps.out"\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$STUB/ps"
  chmod +x "$STUB/cc-status" "$STUB/it2" "$STUB/lsof" "$STUB/ps" "$STUB/tabname"
  unset WORKSET WORKTABS_GROUP ITERM2_COOKIE ITERM2_KEY
  export PATH="$STUB:$PATH"
  # By default one shell (4242) holds every output file, with a child: 3.5 s of CPU in all.
  echo 4242 > "$BATS_TEST_TMPDIR/lsof.out"
  set_cpu 1.00 2.50
  # The real wiring is a symlink to the bundle; it2 is found beside its target.
  ln -s "$STUB/cc-status" "$BATS_TEST_TMPDIR/cc-status-link"
  export CC_STATUS_BIN="$BATS_TEST_TMPDIR/cc-status-link"
  export ITERM_SESSION_ID="w0t1p0:ABC-123"
  SHIM="$BATS_TEST_DIRNAME/../dot_local/libexec/cc-status-shim/executable_cc-status"
  # Config comes from git; keep the machine's own out of it.
  export HOME="$BATS_TEST_TMPDIR/home" GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  SEATS_FILE="$XDG_STATE_HOME/tabstatus/s1.seats"
  TASKS_FILE="$XDG_STATE_HOME/tabstatus/s1.tasks"
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

# set_cpu <holder-seconds> <child-seconds>: what the ps stub reports for pid 4242 and its child 4243.
set_cpu() {
  printf '  PID  PPID      TIME\n    1     0   9:99.00\n 4242     1   0:%05.2f\n 4243  4242   0:%05.2f\n 4300     1   1:00.00\n' "$1" "$2" > "$BATS_TEST_TMPDIR/ps.out"
}

# task_state <name> <seconds-ago>: a .tasks line for task a quiet since the output file's own mtime, first seen that long ago.
task_state() {
  local mt; mt=$(python3 -c 'import os,sys; print(repr(os.stat(sys.argv[1]).st_mtime))' "$SESS/tasks/$1.output")
  mkdir -p "$(dirname "$TASKS_FILE")"
  printf '%s\t%s\t%s\t%s\n' "$1" "$mt" "$3" "$(python3 -c 'import sys,time; print(int(time.time()-int(sys.argv[1])))' "$2")" > "$TASKS_FILE"
}

# stall_payload [extra-json-members]: a Stop with one quiet shell task and a session id.
stall_payload() { payload Stop '[{"task_id":"a","task_type":"local_bash","description":"install.sh --all"}]' '"cwd":"/work/proj","session_id":"s1"'"${1:+,$1}"; }

# payload <event> <tasks-json> [extra-json-members]: a compact payload, as Claude Code writes it.
payload() { printf '{"hook_event_name":"%s","scratchpad_dir":"%s/scratchpad","background_tasks":%s%s}' "$1" "$SESS" "$2" "${3:+,$3}"; }

# seat_payload <event> <agent_type> [extra-json-members]: a hook fired inside a subagent.
seat_payload() { printf '{"hook_event_name":"%s","session_id":"s1","cwd":"/work/proj","agent_id":"ag1","agent_type":"%s"%s}' "$1" "$2" "${3:+,$3}"; }

it2_argv() { paste -sd'|' "$BATS_TEST_TMPDIR/argv"; }
fed_tasks() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["background_tasks"],sort_keys=True))' "$BATS_TEST_TMPDIR/fed"; }

run_shim() { run sh "$SHIM"; }

# rename_only: the cwd's Stop renamed the session and painted nothing.
rename_only() {
  [ "$(wc -l < "$BATS_TEST_TMPDIR/calls")" -eq 1 ]
  [ "$(it2_argv)" = "session|set-name|proj|--session|ABC-123" ]
}

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
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|idle|--detail|idle · 1 quiet background task, quiet 120 min: tail -F build.log|--dot-color|#af8700|--text-color|#888888|--background-tasks|0" ]
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
  grep -qx 'idle · 1 quiet background task, quiet 120 min: local_bash' "$BATS_TEST_TMPDIR/argv"
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
  grep -qx 'idle · 2 quiet background tasks, quiet 120 min: first, local_agent' "$BATS_TEST_TMPDIR/argv"
  local long; long=$(printf 'x%.0s' $(seq 1 300))
  run_shim <<< "$(payload Stop "[{\"task_id\":\"a\",\"description\":\"$long\"}]")"
  # Code points, counted by python: wc -m depends on the locale (a C locale,
  # as in the Rocky CI container, counts the ellipsis as three) and the
  # detail's "·" makes a byte count wrong everywhere.
  grep -A1 '^--detail$' "$BATS_TEST_TMPDIR/argv" | tail -1 \
    | python3 -c 'import sys; s=sys.stdin.buffer.read().decode().rstrip("\n"); assert len(s)==181 and s.endswith("…"), len(s)'
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

@test "settings: valid JSON naming all eleven events, each with the bare expanded shim path, without iTerm2's it2" {
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

# settings_c: C as the rule file spells it, built from $HOME (single spaces, only the socket path quoted).
settings_c() {
  printf '%s' "p=\$(cat); [ $HOME/.local/state/iterm2/api-cookie -nt \"$HOME/Library/Application Support/iTerm2/private/socket\" ] && read -r ITERM2_COOKIE ITERM2_KEY <$HOME/.local/state/iterm2/api-cookie && [ -n \"\$ITERM2_KEY\" ] && export ITERM2_COOKIE ITERM2_KEY; printf '%s' \"\$p\" | $HOME/.config/iterm2/it2 handle-agent-hook; printf '%s' \"\$p\" | $HOME/.local/libexec/cc-status-shim/cc-status after"
}

@test "settings: with iTerm2's it2 every command is the handler, then the shim" {
  mkdir -p "$HOME/.config/iterm2"
  : > "$HOME/.config/iterm2/it2"; chmod +x "$HOME/.config/iterm2/it2"
  run sh "$SHIM" settings
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | sed -n '/^{/,/^}/p' > "$BATS_TEST_TMPDIR/settings.json"
  settings_c > "$BATS_TEST_TMPDIR/c.txt"
  python3 - "$BATS_TEST_TMPDIR/settings.json" "$BATS_TEST_TMPDIR/c.txt" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
c = open(sys.argv[2]).read()
assert len(h) == 11, sorted(h)
for ev, entries in h.items():
    for e in entries:
        for hook in e["hooks"]:
            assert hook["command"] == c, (ev, hook["command"], c)
PY
}

@test "settings: the printed line runs under sh, handing the handler and the shim the same bytes" {
  mkdir -p "$HOME/.config/iterm2" "$HOME/.local/libexec/cc-status-shim"
  printf '#!/bin/sh\ncat > "%s/handler_in"\nprintf "%%s\\n" "$@" > "%s/handler_argv"\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$HOME/.config/iterm2/it2"
  printf '#!/bin/sh\ncat > "%s/shim_in"\nprintf "%%s\\n" "$@" > "%s/shim_argv"\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$HOME/.local/libexec/cc-status-shim/cc-status"
  chmod +x "$HOME/.config/iterm2/it2" "$HOME/.local/libexec/cc-status-shim/cc-status"
  run sh "$SHIM" settings
  printf '%s\n' "$output" | sed -n '/^{/,/^}/p' > "$BATS_TEST_TMPDIR/settings.json"
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"]["Stop"][0]["hooks"][0]["command"])' "$BATS_TEST_TMPDIR/settings.json" > "$BATS_TEST_TMPDIR/cmd.sh"
  printf '{"hook_event_name":"Stop","x":"a b"}' > "$BATS_TEST_TMPDIR/payload"
  run sh -c "$(cat "$BATS_TEST_TMPDIR/cmd.sh")" < "$BATS_TEST_TMPDIR/payload"
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/payload" "$BATS_TEST_TMPDIR/handler_in"
  cmp "$BATS_TEST_TMPDIR/payload" "$BATS_TEST_TMPDIR/shim_in"
  [ "$(cat "$BATS_TEST_TMPDIR/handler_argv")" = handle-agent-hook ]
  [ "$(cat "$BATS_TEST_TMPDIR/shim_argv")" = after ]
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

@test "seat: a PreToolUse inside plan-fable is painted by the shim in its colour, and cc-status is not called" {
  run_shim <<< "$(seat_payload PreToolUse plan-fable '"tool_name":"Bash"')"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/fed" ]
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|working|--detail|plan-fable: Bash|--dot-color|#d787ff|--text-color|#d787ff" ]
}

@test "seat: every default colour, and a PostToolUse, paint the same way" {
  local pair seat col
  for pair in unstick-fable:#ff5faf review-fable:#af87ff work-sonnet:#00afaf scout-haiku:#87af5f; do
    seat=${pair%%:*} col=${pair#*:}
    run_shim <<< "$(seat_payload PostToolUse "$seat" '"tool_name":"Edit"')"
    [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|working|--detail|$seat: Edit|--dot-color|$col|--text-color|$col" ]
  done
}

@test "seat: an agent type with no colour passes through untouched" {
  local p; p=$(seat_payload PreToolUse Explore '"tool_name":"Bash"')
  run_shim <<< "$p"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]
  [ ! -e "$BATS_TEST_TMPDIR/argv" ]
}

@test "seat: PermissionRequest and Notification inside a seat pass through, waiting outranks colour" {
  local ev p
  for ev in PermissionRequest Notification; do
    p=$(seat_payload "$ev" plan-fable '"tool_name":"Bash"')
    run_shim <<< "$p"
    [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]
    [ ! -e "$BATS_TEST_TMPDIR/argv" ]
  done
}

@test "seat: tabstatus.color.<agent_type> overrides a default and adds a seat; a bad value falls back" {
  git config -f "$GIT_CONFIG_GLOBAL" tabstatus.color.plan-fable '#112233'
  git config -f "$GIT_CONFIG_GLOBAL" tabstatus.color.my-seat '#445566'
  run_shim <<< "$(seat_payload PreToolUse plan-fable '"tool_name":"Bash"')"
  grep -qx '#112233' "$BATS_TEST_TMPDIR/argv"
  run_shim <<< "$(seat_payload PreToolUse my-seat '"tool_name":"Bash"')"
  grep -qx '#445566' "$BATS_TEST_TMPDIR/argv"

  git config -f "$GIT_CONFIG_GLOBAL" tabstatus.color.plan-fable 'purple'
  run --separate-stderr sh "$SHIM" <<< "$(seat_payload PreToolUse plan-fable '"tool_name":"Bash"')"
  grep -qx '#d787ff' "$BATS_TEST_TMPDIR/argv"
  [[ $stderr == *"tabstatus.color.plan-fable"* ]]
}

@test "seat: SubagentStart records the seat, reaches cc-status, and paints working without a count" {
  local p; p=$(seat_payload SubagentStart work-sonnet)
  run_shim <<< "$p"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]
  [ "$(cat "$SEATS_FILE")" = "$(printf 'ag1\twork-sonnet')" ]
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|working|--detail|work-sonnet running|--dot-color|#00afaf|--text-color|#00afaf" ]
  run_shim <<< "$p"   # a repeat does not duplicate
  [ "$(wc -l < "$SEATS_FILE")" -eq 1 ]
}

@test "seat: SubagentStop prunes its own line only, and reaches cc-status unpainted" {
  mkdir -p "$(dirname "$SEATS_FILE")"
  printf 'ag1\tplan-fable\nag2\twork-sonnet\n' > "$SEATS_FILE"
  run_shim <<< "$(seat_payload SubagentStop plan-fable)"
  [ "$status" -eq 0 ]
  [ "$(cat "$SEATS_FILE")" = "$(printf 'ag2\twork-sonnet')" ]
  [ -e "$BATS_TEST_TMPDIR/fed" ]
  [ ! -e "$BATS_TEST_TMPDIR/argv" ]
}

@test "seat: SubagentStop of the last seat deletes the state file" {
  mkdir -p "$(dirname "$SEATS_FILE")"
  printf 'ag1\tplan-fable\n' > "$SEATS_FILE"
  run_shim <<< "$(seat_payload SubagentStop plan-fable)"
  [ ! -e "$SEATS_FILE" ]
}

@test "seat: SessionStart and SessionEnd delete the state file and still reach cc-status" {
  local ev p
  for ev in SessionStart SessionEnd; do
    mkdir -p "$(dirname "$SEATS_FILE")"
    printf 'ag1\tplan-fable\n' > "$SEATS_FILE"
    p="{\"hook_event_name\":\"$ev\",\"session_id\":\"s1\"}"
    run_shim <<< "$p"
    [ ! -e "$SEATS_FILE" ]
    [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]
    rm "$BATS_TEST_TMPDIR/fed"
  done
}

@test "seat: a Stop over an active background seat paints its colour with the active count" {
  age_file ag1 5
  mkdir -p "$(dirname "$SEATS_FILE")"
  printf 'ag1\tplan-fable\n' > "$SEATS_FILE"
  run_shim <<< "$(payload Stop '[{"task_id":"ag1","task_type":"local_agent"}]' '"cwd":"/work/proj","session_id":"s1"')"
  [ "$status" -eq 0 ]
  [ "$(fed_tasks | grep -c '"ag1"')" -eq 1 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/calls")" -eq 2 ]
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|working|--detail|plan-fable running · 1 background task running|--dot-color|#d787ff|--text-color|#d787ff|--background-tasks|1" ]
}

@test "seat: two live seats name both, in the first one's colour, counting every active task" {
  age_file ag1 5
  age_file ag2 5
  age_file sh 5
  mkdir -p "$(dirname "$SEATS_FILE")"
  printf 'ag1\twork-sonnet\nag2\tplan-fable\n' > "$SEATS_FILE"
  run_shim <<< "$(payload Stop '[{"task_id":"ag1"},{"task_id":"ag2"},{"task_id":"sh","task_type":"local_bash"}]' '"cwd":"/work/proj","session_id":"s1"')"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|working|--detail|work-sonnet, plan-fable running · 3 background tasks running|--dot-color|#00afaf|--text-color|#00afaf|--background-tasks|3" ]
}

@test "seat: a seat in the state file that is not among the active tasks paints nothing" {
  age_file sh 5
  mkdir -p "$(dirname "$SEATS_FILE")"
  printf 'gone\tplan-fable\n' > "$SEATS_FILE"
  run_shim <<< "$(payload Stop '[{"task_id":"sh","task_type":"local_bash"}]' '"cwd":"/work/proj","session_id":"s1"')"
  rename_only
}

@test "seat: a quiet seat is not painted as running; the amber idle wins" {
  age_file ag1 7200
  mkdir -p "$(dirname "$SEATS_FILE")"
  printf 'ag1\tplan-fable\n' > "$SEATS_FILE"
  run_shim <<< "$(payload Stop '[{"task_id":"ag1","task_type":"local_agent","description":"stuck"}]' '"cwd":"/work/proj","session_id":"s1"')"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|idle|--detail|idle · 1 quiet background task, quiet 120 min: stuck|--dot-color|#af8700|--text-color|#888888|--background-tasks|0" ]
}

@test "seat: a state file older than a day is ignored and removed" {
  age_file ag1 5
  mkdir -p "$(dirname "$SEATS_FILE")"
  printf 'ag1\tplan-fable\n' > "$SEATS_FILE"
  python3 -c 'import os,sys,time; t=time.time()-25*3600; os.utime(sys.argv[1],(t,t))' "$SEATS_FILE"
  run_shim <<< "$(payload Stop '[{"task_id":"ag1","task_type":"local_agent"}]' '"cwd":"/work/proj","session_id":"s1"')"
  rename_only
  [ ! -e "$SEATS_FILE" ]
}

@test "seat: a session id that is not a plain token never reaches the filesystem" {
  run_shim <<< '{"hook_event_name":"SubagentStart","session_id":"../../x","agent_id":"ag1","agent_type":"plan-fable"}'
  [ "$status" -eq 0 ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -name '*.seats')" ]
}

@test "repo: the detail never repeats the cwd's basename; the row name carries it" {
  age_file a 7200
  run_shim <<< "$(payload Stop '[{"task_id":"a","description":"tail -F build.log"}]' '"cwd":"/work/proj/"')"
  grep -qx 'idle · 1 quiet background task, quiet 120 min: tail -F build.log' "$BATS_TEST_TMPDIR/argv"
  ! grep -q '^proj' "$BATS_TEST_TMPDIR/argv" || { echo "a row named proj reached the argv log"; false; }
}

@test "explain: a seat event names the seat, its colour and the live state, and writes nothing" {
  run sh "$SHIM" explain <<< "$(seat_payload SubagentStart plan-fable)"
  [ "$status" -eq 0 ]
  [[ $output == *"seat=plan-fable colour=#d787ff state=1"* ]]
  [[ $output == *"action=passthrough+seat"* ]]
  run sh "$SHIM" explain <<< "$(seat_payload PreToolUse plan-fable '"tool_name":"Bash"')"
  [[ $output == *"action=seat-paint"* ]]
  run sh "$SHIM" explain <<< "$(seat_payload PreToolUse Explore)"
  [[ $output == *"seat=none colour=none state=0"* && $output == *"action=passthrough"* ]]
  [ ! -e "$SEATS_FILE" ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  [ ! -e "$BATS_TEST_TMPDIR/fed" ]
}

# question_payload <last-line-or-message-json-text> [tasks-json]: a Stop whose final message is the given JSON string body.
question_payload() { payload Stop "${2:-[]}" "\"cwd\":\"/work/proj\",\"last_assistant_message\":\"$1\""; }

@test "question: a Stop ending in a question paints waiting in yellow with the question as the detail, after cc-status" {
  local p; p=$(question_payload 'Done.\n\nWhich branch should I use?')
  run_shim <<< "$p"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/calls")" -eq 2 ]
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|waiting|--detail|Which branch should I use?|--dot-color|#ffd75f|--text-color|#ffd75f|--background-tasks|0" ]
}

@test "question: StopFailure is handled like Stop, and a full-width question mark counts" {
  run_shim <<< "$(payload StopFailure '[]' '"cwd":"/work/proj","last_assistant_message":"どちらにしますか？"')"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|waiting|--detail|どちらにしますか？|--dot-color|#ffd75f|--text-color|#ffd75f|--background-tasks|0" ]
}

@test "question: a message ending in a statement paints nothing, even with a question earlier" {
  local p; p=$(question_payload 'Is it ok?\n\nYes, it is.')
  run_shim <<< "$p"
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]
  rename_only
}

@test "question: with an active task the shim paints nothing and cc-status keeps the row working" {
  age_file a 5
  run_shim <<< "$(question_payload 'Which branch?' '[{"task_id":"a","task_type":"local_bash"}]')"
  [ "$(fed_tasks | grep -c '"a"')" -eq 1 ]
  rename_only
}

@test "question: beside only a quiet task the question paint wins over the amber idle" {
  age_file a 7200
  run_shim <<< "$(question_payload 'Which branch?' '[{"task_id":"a","task_type":"local_bash","description":"stuck"}]')"
  [ "$(fed_tasks)" = "[]" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/calls")" -eq 2 ]
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|waiting|--detail|Which branch?|--dot-color|#ffd75f|--text-color|#ffd75f|--background-tasks|0" ]
}

@test "question: leading bullets, quotes and spaces, and trailing spaces, are stripped" {
  run_shim <<< "$(question_payload 'Fine.\n\n> - is this right?  \n\n')"
  grep -qx 'is this right?' "$BATS_TEST_TMPDIR/argv"
}

@test "question: a long question is cut like any other detail" {
  local long; long=$(printf 'x%.0s' $(seq 1 300))
  run_shim <<< "$(question_payload "$long?")"
  grep -A1 '^--detail$' "$BATS_TEST_TMPDIR/argv" | tail -1 \
    | python3 -c 'import sys; s=sys.stdin.buffer.read().decode().rstrip("\n"); assert len(s)==181 and s.endswith("…"), len(s)'
}

@test "question: SubagentStop never paints one" {
  run_shim <<< "$(seat_payload SubagentStop plan-fable '"last_assistant_message":"Which branch?"')"
  [ ! -e "$BATS_TEST_TMPDIR/argv" ]
  run_shim <<< "$(payload SubagentStop '[]' '"cwd":"/work/proj","last_assistant_message":"Which branch?"')"
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "question: tabstatus.color.question overrides the colour; a bad value falls back with a note" {
  git config -f "$GIT_CONFIG_GLOBAL" tabstatus.color.question '#112233'
  run_shim <<< "$(question_payload 'Which branch?')"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|waiting|--detail|Which branch?|--dot-color|#112233|--text-color|#112233|--background-tasks|0" ]

  git config -f "$GIT_CONFIG_GLOBAL" tabstatus.color.question 'yellow'
  run --separate-stderr sh "$SHIM" <<< "$(question_payload 'Which branch?')"
  grep -qx '#ffd75f' "$BATS_TEST_TMPDIR/argv"
  [[ $stderr == *"tabstatus.color.question"* ]]
}

@test "question: a Stop with no question mark and no tasks passes through without it2" {
  local p; p=$(question_payload 'All done.')
  run_shim <<< "$p"
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]
  rename_only
}

@test "explain: prints question=yes with the extracted line, or question=no" {
  run sh "$SHIM" explain <<< "$(question_payload 'Done.\n\n- Which branch should I use?')"
  [[ $output == *"question=yes Which branch should I use?"* ]]
  [[ $output == *"action=passthrough+question"* ]]
  run sh "$SHIM" explain <<< "$(question_payload 'All done.')"
  [[ $output == *"question=no"* && $output == *"action=passthrough"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  [ ! -e "$BATS_TEST_TMPDIR/fed" ]
}

@test "stalled: a first sighting of a quiet shell stays quiet, with its age, and is recorded" {
  age_file a 7200
  run_shim <<< "$(stall_payload)"
  [ "$status" -eq 0 ]
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|idle|--detail|idle · 1 quiet background task, quiet 120 min: install.sh --all|--dot-color|#af8700|--text-color|#888888|--background-tasks|0" ]
  [ "$(paste -sd'|' "$BATS_TEST_TMPDIR/lsof_argv")" = "-t|--|$SESS/tasks/a.output" ]
  [ "$(paste -sd'|' "$BATS_TEST_TMPDIR/ps_argv")" = "-axo|pid,ppid,time" ]
  [ "$(wc -l < "$TASKS_FILE")" -eq 1 ]
  [ "$(cut -f1,3 "$TASKS_FILE")" = "$(printf 'a\t3.50')" ]
}

@test "stalled: quiet for stall-minutes with the same CPU and file paints waiting in red" {
  age_file a 7200
  task_state a 965 3.50
  run_shim <<< "$(stall_payload)"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|waiting|--detail|stalled 16 min: install.sh --all|--dot-color|#ff5f5f|--text-color|#ff5f5f|--background-tasks|0" ]
  [ "$(fed_tasks)" = "[]" ]
}

@test "stalled: a CPU that moved resets the clock, stays quiet and says so" {
  age_file a 7200
  task_state a 965 3.50
  set_cpu 1.00 7.50
  run_shim <<< "$(stall_payload)"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|idle|--detail|idle · 1 quiet background task, quiet 120 min: install.sh --all (cpu busy)|--dot-color|#af8700|--text-color|#888888|--background-tasks|0" ]
  [ "$(cut -f3 "$TASKS_FILE")" = "8.50" ]
  run_shim <<< "$(stall_payload)"   # nothing moved since, but the clock restarted a moment ago
  grep -qx 'idle · 1 quiet background task, quiet 120 min: install.sh --all' "$BATS_TEST_TMPDIR/argv"
}

@test "stalled: quiet for less than stall-minutes is not stalled, and the record keeps its first sighting" {
  age_file a 7200
  task_state a 300 3.50
  local before; before=$(cat "$TASKS_FILE")
  run_shim <<< "$(stall_payload)"
  grep -qx 'idle' "$BATS_TEST_TMPDIR/argv"
  [ "$(cat "$TASKS_FILE")" = "$before" ]
}

@test "stalled: a file written since the record is a new silence, not a stall" {
  age_file a 7200
  task_state a 965 3.50
  python3 -c 'import os,sys,time; t=time.time()-3600; os.utime(sys.argv[1],(t,t))' "$SESS/tasks/a.output"
  run_shim <<< "$(stall_payload)"
  grep -qx 'idle' "$BATS_TEST_TMPDIR/argv"
}

@test "stalled: nothing holds the file, so the task is stalled at once" {
  age_file a 7200
  : > "$BATS_TEST_TMPDIR/lsof.out"
  run_shim <<< "$(stall_payload)"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|waiting|--detail|stalled 120 min: install.sh --all|--dot-color|#ff5f5f|--text-color|#ff5f5f|--background-tasks|0" ]
  [ ! -e "$BATS_TEST_TMPDIR/ps_argv" ]
}

@test "stalled: an agent's symlinked output is never probed" {
  : > "$BATS_TEST_TMPDIR/agent.jsonl"
  python3 -c 'import os,sys,time; t=time.time()-7200; os.utime(sys.argv[1],(t,t))' "$BATS_TEST_TMPDIR/agent.jsonl"
  ln -s "$BATS_TEST_TMPDIR/agent.jsonl" "$SESS/tasks/a.output"
  : > "$BATS_TEST_TMPDIR/lsof.out"
  run_shim <<< "$(stall_payload)"
  grep -qx 'idle' "$BATS_TEST_TMPDIR/argv"
  [ ! -e "$BATS_TEST_TMPDIR/lsof_argv" ]
  [ ! -e "$TASKS_FILE" ]
}

@test "stalled: outranks a question in the same payload" {
  age_file a 7200
  : > "$BATS_TEST_TMPDIR/lsof.out"
  run_shim <<< "$(stall_payload '"last_assistant_message":"Which branch?"')"
  grep -qx 'stalled 120 min: install.sh --all' "$BATS_TEST_TMPDIR/argv"
  grep -qx 'waiting' "$BATS_TEST_TMPDIR/argv"
}

@test "stalled: an active task beside a stalled one keeps the row working, painted by nobody" {
  age_file a 7200
  age_file b 5
  : > "$BATS_TEST_TMPDIR/lsof.out"
  run_shim <<< "$(payload Stop '[{"task_id":"a","task_type":"local_bash"},{"task_id":"b","task_type":"local_bash"}]' '"session_id":"s1"')"
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "stalled: tabstatus.color.stalled and stall-minutes override; a bad colour falls back with a note" {
  age_file a 7200
  task_state a 400 3.50
  git config -f "$GIT_CONFIG_GLOBAL" tabstatus.color.stalled '#112233'
  git config -f "$GIT_CONFIG_GLOBAL" tabstatus.stall-minutes 5
  run_shim <<< "$(stall_payload)"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|waiting|--detail|stalled 6 min: install.sh --all|--dot-color|#112233|--text-color|#112233|--background-tasks|0" ]

  git config -f "$GIT_CONFIG_GLOBAL" tabstatus.color.stalled 'red'
  run --separate-stderr sh "$SHIM" <<< "$(stall_payload)"
  grep -qx '#ff5f5f' "$BATS_TEST_TMPDIR/argv"
  [[ $stderr == *"tabstatus.color.stalled"* ]]
}

@test "stalled: a missing lsof is unknown, never stalled" {
  age_file a 7200
  rm "$STUB/lsof"
  # PATH of just the tools the shim runs, so no lsof anywhere (Linux has it in /usr/bin).
  local t tools="$BATS_TEST_TMPDIR/tools"
  mkdir -p "$tools"
  for t in git dirname readlink cat; do ln -s "$(command -v $t)" "$tools/$t"; done
  ln -s "$(python3 -c 'import sys; print(sys.executable)')" "$tools/python3"
  PATH="$STUB:$tools" run /bin/sh "$SHIM" <<< "$(stall_payload)"
  [ "$status" -eq 0 ]
  grep -qx 'idle' "$BATS_TEST_TMPDIR/argv"
  [ ! -e "$TASKS_FILE" ]
}

@test "stalled: the record is pruned to the payload's tasks, and SessionStart and SessionEnd delete it" {
  age_file a 7200
  task_state a 300 3.50
  printf 'gone\t1.0\t1.00\t1\n' >> "$TASKS_FILE"
  run_shim <<< "$(stall_payload)"
  [ "$(cut -f1 "$TASKS_FILE")" = "a" ]
  local ev
  for ev in SessionStart SessionEnd; do
    printf 'a\t1.0\t1.00\t1\n' > "$TASKS_FILE"
    run_shim <<< "{\"hook_event_name\":\"$ev\",\"session_id\":\"s1\"}"
    [ ! -e "$TASKS_FILE" ]
  done
}

@test "explain: a quiet shell task shows its holder, CPU and verdict, and writes nothing" {
  age_file a 7200
  task_state a 965 3.50
  local before; before=$(cat "$TASKS_FILE")
  run sh "$SHIM" explain <<< "$(stall_payload)"
  [[ $output == *"task a local_bash quiet age=7200 holder=4242 cpu=3.50 stalled=yes"*"install.sh --all"* ]]
  [[ $output == *"action=rewrite+stalled"* ]]
  [ "$(cat "$TASKS_FILE")" = "$before" ]
  : > "$BATS_TEST_TMPDIR/lsof.out"
  run sh "$SHIM" explain <<< "$(stall_payload)"
  [[ $output == *"holder=none cpu=- stalled=yes"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  [ ! -e "$BATS_TEST_TMPDIR/fed" ]
}

# named_payload <event> [cwd] [extra-json-members]: a hook with a session id and a cwd, no tasks.
named_payload() { printf '{"hook_event_name":"%s","session_id":"s1","cwd":"%s"%s}' "$1" "${2:-/work/proj}" "${3:+,$3}"; }
NAMED_FILE() { printf '%s/tabstatus/s1.named' "$XDG_STATE_HOME"; }

@test "rename: the first UserPromptSubmit names the session after the repo and writes the marker" {
  local p; p=$(named_payload UserPromptSubmit)
  run_shim <<< "$p"
  [ "$status" -eq 0 ]
  [ "$(it2_argv)" = "session|set-name|proj|--session|ABC-123" ]
  [ -e "$(NAMED_FILE)" ]
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]
}

@test "rename: a second UserPromptSubmit does nothing" {
  local p; p=$(named_payload UserPromptSubmit)
  run_shim <<< "$p"
  rm "$BATS_TEST_TMPDIR/calls" "$BATS_TEST_TMPDIR/fed" "$BATS_TEST_TMPDIR/tabname_argv"
  run_shim <<< "$p"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  [ ! -e "$BATS_TEST_TMPDIR/tabname_argv" ]
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]
}

@test "rename: Stop renames after cc-status and before the paint, so the paint is the last it2 call" {
  age_file a 7200
  run_shim <<< "$(stall_payload)"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/calls")" -eq 2 ]
  [ "$(it2_argv | cut -d'|' -f1)" = "set-status" ]
  [ "$(grep -cx 'set-name' "$BATS_TEST_TMPDIR/argv_all")" -eq 1 ]
  [ "$(head -3 "$BATS_TEST_TMPDIR/argv_all" | paste -sd'|' -)" = "session|set-name|proj" ]
}

@test "rename: a plain Stop with no tasks and no question still renames" {
  run_shim <<< "$(named_payload Stop)"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/calls")" -eq 1 ]
  [ "$(it2_argv)" = "session|set-name|proj|--session|ABC-123" ]
  [ ! -e "$(NAMED_FILE)" ]
}

@test "rename: WORKSET names the set; WORKTABS_GROUP prefixes only with tabstatus.group-prefix true" {
  export WORKSET=myset WORKTABS_GROUP=grp
  run_shim <<< "$(named_payload Stop)"
  [ "$(it2_argv)" = "session|set-name|myset|--session|ABC-123" ]
  git config --global tabstatus.group-prefix true
  run_shim <<< "$(named_payload Stop)"
  [ "$(it2_argv)" = "session|set-name|[grp] myset|--session|ABC-123" ]
  unset WORKSET
  run_shim <<< "$(named_payload Stop)"
  [ "$(it2_argv)" = "session|set-name|[grp] proj|--session|ABC-123" ]
}

@test "role: a peer's row is named by tabname, without [group], and dimmed after cc-status on a plain Stop" {
  printf 'peer\tproj · Alpha\n' > "$BATS_TEST_TMPDIR/role.out"
  export WORKTABS_GROUP=grp
  run_shim <<< "$(named_payload Stop)"
  [ "$(head -5 "$BATS_TEST_TMPDIR/argv_all" | paste -sd'|' -)" = "session|set-name|proj · Alpha|--session|ABC-123" ]
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--text-color|#8a8a8a" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/calls")" -eq 2 ]
  git config --global tabstatus.group-prefix true
  run_shim <<< "$(named_payload Stop)"
  grep -qx '\[grp\] proj · Alpha' "$BATS_TEST_TMPDIR/argv_all"
}

@test "role: tabstatus.color.peer overrides the dim colour; a Stop that painted a question is not dimmed" {
  printf 'peer\tproj · Alpha\n' > "$BATS_TEST_TMPDIR/role.out"
  git config --global tabstatus.color.peer '#112233'
  run_shim <<< "$(named_payload Stop)"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--text-color|#112233" ]
  rm "$BATS_TEST_TMPDIR/argv" "$BATS_TEST_TMPDIR/argv_all" "$BATS_TEST_TMPDIR/calls"
  run_shim <<< "$(named_payload Stop /work/proj '"last_assistant_message":"Shall I go on?"')"
  [ "$(grep -c -- '--text-color' "$BATS_TEST_TMPDIR/argv_all")" -eq 1 ]
  grep -qx '#ffd75f' "$BATS_TEST_TMPDIR/argv_all"
  ! grep -qx '#112233' "$BATS_TEST_TMPDIR/argv_all" || { echo "colour #112233 reached the argv log"; false; }
}

@test "role: a lead paints nothing by default and tabstatus.color.lead when set" {
  printf 'lead\tproj ▸ Lead\n' > "$BATS_TEST_TMPDIR/role.out"
  run_shim <<< "$(named_payload Stop)"
  [ "$(it2_argv)" = "session|set-name|proj ▸ Lead|--session|ABC-123" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/calls")" -eq 1 ]
  git config --global tabstatus.color.lead '#445566'
  run_shim <<< "$(named_payload Stop)"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--text-color|#445566" ]
}

@test "role: a UserPromptSubmit renames but dims nothing" {
  printf 'peer\tproj · Alpha\n' > "$BATS_TEST_TMPDIR/role.out"
  run_shim <<< "$(named_payload UserPromptSubmit)"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/calls")" -eq 1 ]
  [ "$(it2_argv)" = "session|set-name|proj · Alpha|--session|ABC-123" ]
}

@test "role: peer and lead are paint colours, not seat names" {
  git config --global tabstatus.color.peer '#112233'
  run_shim <<< "$(seat_payload SubagentStart peer)"
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "explain: prints role= and colour=" {
  printf 'peer\tproj · Alpha\n' > "$BATS_TEST_TMPDIR/role.out"
  run sh "$SHIM" explain <<< "$(named_payload Stop)"
  [[ $output == *"name=proj · Alpha"* && $output == *"role=peer"* && $output == *"colour=#8a8a8a"* ]]
  printf 'lead\tproj ▸ Lead\n' > "$BATS_TEST_TMPDIR/role.out"
  run sh "$SHIM" explain <<< "$(named_payload Stop)"
  [[ $output == *"role=lead"* && $output == *"colour=none"* ]]
  rm "$BATS_TEST_TMPDIR/role.out"
  run sh "$SHIM" explain <<< "$(named_payload Stop)"
  [[ $output == *"role=plain"* && $output == *"colour=none"* ]]
}

@test "rename: a worktree cwd gets the worktree label" {
  run_shim <<< "$(named_payload Stop /work/proj/.claude/worktrees/feat-x)"
  [ "$(it2_argv)" = "session|set-name|proj@feat-x|--session|ABC-123" ]
  [ "$(cat "$BATS_TEST_TMPDIR/tabname_argv")" = "/work/proj/.claude/worktrees/feat-x" ]
}

@test "rename: outside a repo, without tabname, or without it2 nothing is renamed" {
  # Stop: nothing renamed, the payload still fed to cc-status.
  local p; p=$(named_payload Stop /elsewhere)
  run_shim <<< "$p"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]

  p=$(named_payload Stop)
  rm "$STUB/tabname" "$BATS_TEST_TMPDIR/fed"
  PATH="$STUB:/usr/bin:/bin" run sh "$SHIM" <<< "$p"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]

  rm "$STUB/it2" "$BATS_TEST_TMPDIR/fed"
  PATH="/usr/bin:/bin" run sh "$SHIM" <<< "$p"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]
}

@test "rename: the first UserPromptSubmit is marked whatever the outcome, and the second skips python" {
  # not a repo
  local p; p=$(named_payload UserPromptSubmit /elsewhere)
  run_shim <<< "$p"
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  [ -e "$(NAMED_FILE)" ]
  rm "$BATS_TEST_TMPDIR/tabname_argv" "$BATS_TEST_TMPDIR/fed"
  run_shim <<< "$p"
  [ ! -e "$BATS_TEST_TMPDIR/tabname_argv" ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]

  # no tabname
  rm "$(NAMED_FILE)" "$STUB/tabname" "$BATS_TEST_TMPDIR/fed"
  p=$(named_payload UserPromptSubmit)
  PATH="$STUB:/usr/bin:/bin" run sh "$SHIM" <<< "$p"
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  [ -e "$(NAMED_FILE)" ]
  rm "$BATS_TEST_TMPDIR/fed"
  PATH="$STUB:/usr/bin:/bin" run sh "$SHIM" <<< "$p"
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]

  # no it2: the sh gate passes the payload through before python starts, so there is no marker to write
  rm "$(NAMED_FILE)" "$STUB/it2" "$BATS_TEST_TMPDIR/fed"
  PATH="/usr/bin:/bin" run sh "$SHIM" <<< "$p"
  [ "$status" -eq 0 ]
  [ ! -e "$(NAMED_FILE)" ]
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]
}

@test "rename: WORKSET renames without tabname" {
  export WORKSET=myset
  rm "$STUB/tabname"
  PATH="$STUB:/usr/bin:/bin" run sh "$SHIM" <<< "$(named_payload UserPromptSubmit)"
  [ "$status" -eq 0 ]
  [ "$(it2_argv)" = "session|set-name|myset|--session|ABC-123" ]
  [ -e "$(NAMED_FILE)" ]
}

@test "rename: WORKSET renames outside a repo" {
  export WORKSET=myset
  run_shim <<< "$(named_payload UserPromptSubmit /nowhere)"
  [ "$(it2_argv)" = "session|set-name|myset|--session|ABC-123" ]
  [ ! -e "$BATS_TEST_TMPDIR/tabname_argv" ]
}

@test "rename: control characters are stripped and the title is cut at 80" {
  export WORKSET=$'a\tb'
  run_shim <<< "$(named_payload Stop)"
  [ "$(it2_argv)" = "session|set-name|ab|--session|ABC-123" ]
  export WORKSET=$(printf 'x%.0s' $(seq 120))
  run_shim <<< "$(named_payload Stop)"
  [ "$(sed -n 3p "$BATS_TEST_TMPDIR/argv" | wc -c)" -eq 81 ]
  export WORKSET=$'\t\n'
  run_shim <<< "$(named_payload Stop)"
  [ "$(it2_argv)" = "session|set-name|proj|--session|ABC-123" ]
}

@test "rename: SubagentStop and in-seat events never rename" {
  run_shim <<< "$(payload SubagentStop '[{"task_id":"a"}]' '"cwd":"/work/proj","session_id":"s1","agent_id":"zz"')"
  run_shim <<< "$(seat_payload PreToolUse plan-fable '"tool_name":"Bash"')"
  run_shim <<< "$(seat_payload Stop plan-fable)"
  run_shim <<< "$(seat_payload UserPromptSubmit plan-fable)"
  [ ! -e "$BATS_TEST_TMPDIR/tabname_argv" ]
  ! grep -qx 'set-name' "$BATS_TEST_TMPDIR/argv_all" || { echo "set-name reached the argv log"; false; }
}

@test "rename: SessionEnd never renames; SessionStart and SessionEnd delete the marker" {
  local ev
  for ev in SessionStart SessionEnd; do
    mkdir -p "$(dirname "$(NAMED_FILE)")"
    : > "$(NAMED_FILE)"
    run_shim <<< "$(named_payload "$ev")"
    [ ! -e "$(NAMED_FILE)" ]
  done
  rm -f "$BATS_TEST_TMPDIR/argv_all"
  run_shim <<< "$(named_payload SessionEnd)"
  [ ! -e "$BATS_TEST_TMPDIR/calls" ] || ! grep -qx 'set-name' "$BATS_TEST_TMPDIR/argv_all"
}

# session_start_names <label> <expected title> <runner>: a SessionStart names the row once, paints nothing, writes no marker.
session_start_names() {
  [ -n "$1" ] && printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/role.out"
  "$3" <<< "$(named_payload SessionStart)"
  [ "$(it2_argv)" = "session|set-name|$2|--session|ABC-123" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/calls")" -eq 1 ]
  [ ! -e "$(NAMED_FILE)" ]
}

@test "rename: SessionStart names a peer, a lead and a plain cwd, in legacy and after mode" {
  local run
  for run in run_shim run_after; do
    rm -f "$BATS_TEST_TMPDIR"/{argv,argv_all,calls}
    session_start_names $'peer\tproj · Alpha' "proj · Alpha" $run
    rm -f "$BATS_TEST_TMPDIR"/{argv,argv_all,calls}
    session_start_names $'lead\tproj ▸ Lead' "proj ▸ Lead" $run
    rm -f "$BATS_TEST_TMPDIR"/{argv,argv_all,calls} "$BATS_TEST_TMPDIR/role.out"
    session_start_names "" proj $run
  done
}

@test "rename: SessionStart in a set names the row after the set, in both modes" {
  export WORKSET=myset
  session_start_names "" myset run_shim
  rm -f "$BATS_TEST_TMPDIR"/{argv,argv_all,calls}
  session_start_names "" myset run_after
}

@test "rename: SessionStart outside a repo renames nothing and still passes the payload on" {
  local p; p=$(named_payload SessionStart /elsewhere)
  run_shim <<< "$p"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  [ "$(cat "$BATS_TEST_TMPDIR/fed")" = "$p" ]
}

@test "explain: prints name= and rename= with the reason" {
  run sh "$SHIM" explain <<< "$(named_payload Stop)"
  [[ $output == *"name=proj"* && $output == *"rename=yes"* && $output == *"marker=none"* ]]
  run sh "$SHIM" explain <<< "$(named_payload PreToolUse)"
  [[ $output == *"name=none"* && $output == *"rename=no (event)"* ]]
  mkdir -p "$(dirname "$(NAMED_FILE)")"
  : > "$(NAMED_FILE)"
  run sh "$SHIM" explain <<< "$(named_payload UserPromptSubmit)"
  [[ $output == *"rename=no (already named)"* && $output == *"marker=present"* ]]
  run sh "$SHIM" explain <<< "$(named_payload Stop /elsewhere)"
  [[ $output == *"name=none"* && $output == *"rename=no (not a repo)"* ]]
  rm "$(NAMED_FILE)"
  run sh "$SHIM" explain <<< "$(named_payload UserPromptSubmit)"
  [[ $output == *"rename=yes"* ]]
  [ ! -e "$(NAMED_FILE)" ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "explain: marker= is none before the first prompt (explain never writes) and present after a real run" {
  local p; p=$(named_payload UserPromptSubmit)
  run sh "$SHIM" explain <<< "$p"
  [[ $output == *"marker=none"* ]]
  [ ! -e "$(NAMED_FILE)" ]
  run_shim <<< "$p"
  run sh "$SHIM" explain <<< "$p"
  [[ $output == *"marker=present"* && $output == *"rename=no (already named)"* ]]
}

# The API cookie: iterm2-cookie writes "<cookie> <key>" under $HOME; a fresh one
# (newer than iTerm2's socket) is handed to cc-status and it2, anything else is not.
# cookie_file <content> <fresh|stale>: the cookie, newer or older than the socket.
cookie_file() {
  COOKIE_DIR="$HOME/.local/state/iterm2"
  local sock="$HOME/Library/Application Support/iTerm2/private/socket"
  mkdir -p "$COOKIE_DIR" "$(dirname "$sock")"
  printf '%s\n' "$1" > "$COOKIE_DIR/api-cookie"
  : > "$sock"
  python3 -c 'import os,sys,time; t=time.time()+(60 if sys.argv[1]=="fresh" else -60); os.utime(sys.argv[2],(t,t))' "$2" "$COOKIE_DIR/api-cookie"
  python3 -c 'import os,sys,time; t=time.time()-3600; os.utime(sys.argv[1],(t,t))' "$sock"
  [ "$2" = fresh ] || python3 -c 'import os,sys,time; t=time.time()-7200; os.utime(sys.argv[1],(t,t))' "$COOKIE_DIR/api-cookie"
}
uncookied_bytes() { wc -c < "$HOME/.local/state/iterm2/uncookied" 2>/dev/null || echo 0; }

@test "cookie: a fresh file reaches both the stub cc-status and the stub it2, and nothing is counted" {
  cookie_file "ck1 key1" fresh
  run_shim <<< "$(payload PreToolUse '[]')"
  [ "$(cat "$BATS_TEST_TMPDIR/fed_cookie")" = ck1 ]
  run_shim <<< "$(named_payload Stop)"
  [ "$(sort -u "$BATS_TEST_TMPDIR/it2_cookie")" = ck1 ]
  [ ! -e "$HOME/.local/state/iterm2/uncookied" ]
}

@test "cookie: a fresh file with the socket missing is used" {
  cookie_file "ck1 key1" fresh
  rm "$HOME/Library/Application Support/iTerm2/private/socket"
  run_shim <<< "$(payload PreToolUse '[]')"
  [ "$(cat "$BATS_TEST_TMPDIR/fed_cookie")" = ck1 ]
}

@test "cookie: a stale file reaches neither program and each event is counted" {
  cookie_file "ck1 key1" stale
  run_shim <<< "$(payload PreToolUse '[]')"
  [ "$(cat "$BATS_TEST_TMPDIR/fed_cookie")" = unset ]
  run_shim <<< "$(named_payload Stop)"
  [ "$(sort -u "$BATS_TEST_TMPDIR/it2_cookie")" = unset ]
  [ "$(uncookied_bytes)" -eq 2 ]
}

@test "cookie: no file, the same, and the state directory is created for the count" {
  run_shim <<< "$(payload PreToolUse '[]')"
  [ "$(cat "$BATS_TEST_TMPDIR/fed_cookie")" = unset ]
  run_shim <<< "$(payload PreToolUse '[]')"
  [ "$(uncookied_bytes)" -eq 2 ]
}

@test "cookie: one already in the environment is left alone and nothing is counted" {
  cookie_file "ck1 key1" fresh
  ITERM2_COOKIE=envck run_shim <<< "$(payload PreToolUse '[]')"
  [ "$(cat "$BATS_TEST_TMPDIR/fed_cookie")" = envck ]
  [ ! -e "$HOME/.local/state/iterm2/uncookied" ]
}

@test "cookie: a one-word or empty file exports nothing" {
  cookie_file "ck1" fresh
  run_shim <<< "$(payload PreToolUse '[]')"
  [ "$(cat "$BATS_TEST_TMPDIR/fed_cookie")" = unset ]
  cookie_file "" fresh
  run_shim <<< "$(payload PreToolUse '[]')"
  [ "$(cat "$BATS_TEST_TMPDIR/fed_cookie")" = unset ]
  [ "$(uncookied_bytes)" -eq 2 ]
}

@test "cookie: an it2 refused with Authentication failed sets the file aside" {
  cookie_file "ck1 key1" fresh
  echo "Authentication failed" > "$BATS_TEST_TMPDIR/it2.fail"
  run_shim <<< "$(named_payload Stop)"
  [ ! -e "$COOKIE_DIR/api-cookie" ]
  [ "$(cat "$COOKIE_DIR/api-cookie.rejected")" = "ck1 key1" ]
}

@test "cookie: any other it2 failure leaves the file where it is" {
  cookie_file "ck1 key1" fresh
  echo "connection refused" > "$BATS_TEST_TMPDIR/it2.fail"
  run_shim <<< "$(named_payload Stop)"
  [ -e "$COOKIE_DIR/api-cookie" ]
  [ ! -e "$COOKIE_DIR/api-cookie.rejected" ]
}

@test "cookie: a refusal with no cookie in play renames nothing" {
  cookie_file "ck1 key1" stale
  echo "Authentication failed" > "$BATS_TEST_TMPDIR/it2.fail"
  run_shim <<< "$(named_payload Stop)"
  [ -e "$COOKIE_DIR/api-cookie" ]
  [ ! -e "$COOKIE_DIR/api-cookie.rejected" ]
}

@test "explain: cookie= names the state and never writes the uncookied count" {
  run sh "$SHIM" explain <<< "$(named_payload Stop)"
  [[ $output == *"cookie=absent"* ]]
  cookie_file "ck1 key1" stale
  run sh "$SHIM" explain <<< "$(named_payload Stop)"
  [[ $output == *"cookie=stale"* ]]
  cookie_file "ck1 key1" fresh
  run sh "$SHIM" explain <<< "$(named_payload Stop)"
  [[ $output == *"cookie=fresh"* ]]
  ITERM2_COOKIE=envck run sh "$SHIM" explain <<< "$(named_payload Stop)"
  [[ $output == *"cookie=env"* ]]
  mv "$COOKIE_DIR/api-cookie" "$COOKIE_DIR/api-cookie.rejected"
  run sh "$SHIM" explain <<< "$(named_payload Stop)"
  [[ $output == *"cookie=rejected"* ]]
  [ ! -e "$COOKIE_DIR/uncookied" ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

# after: `cc-status after` runs behind iTerm2's own handler. It never calls the hook, needs no real
# cc-status, and writes set-status fields only as the rule file's table allows. Stop and StopFailure
# payloads carry session_id and cwd so the rename also happens (and is argv_all's first call).
run_after() { run sh "$SHIM" after; }
after_stop() { payload "${1:-Stop}" "${2:-[]}" '"cwd":"/work/proj","session_id":"s1"'"${3:+,$3}"; }
# status_flags: the number of --status flags among everything it2 was given.
status_flags() { { grep -cx -- '--status' "$BATS_TEST_TMPDIR/argv_all" || true; } 2>/dev/null; }

@test "after: a PreToolUse outside a seat starts neither python nor it2" {
  run_after <<< '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  [ ! -e "$BATS_TEST_TMPDIR/fed" ]
}

@test "after: never the hook, whatever the event, and it needs no real cc-status" {
  export CC_STATUS_BIN="$BATS_TEST_TMPDIR/absent"
  local ev
  for ev in SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse PermissionRequest Notification Stop StopFailure SubagentStart SubagentStop; do
    run_after <<< "$(after_stop "$ev" '[{"task_id":"a"}]' '"agent_id":"ag1","agent_type":"plan-fable","tool_name":"Bash"')"
    [ "$status" -eq 0 ]
    run_after <<< "$(after_stop "$ev")"
    [ "$status" -eq 0 ]
  done
  [ ! -e "$BATS_TEST_TMPDIR/fed" ]
  ! grep -qx 'handle-agent-hook' "$BATS_TEST_TMPDIR/argv_all" || { echo "handle-agent-hook reached the argv log"; false; }
}

@test "after: a plain Stop sends only the rename" {
  run_after <<< "$(after_stop)"
  rename_only
}

@test "after: Stop with one active and one quiet task only corrects the count" {
  age_file a 7200
  age_file b 30
  run_after <<< "$(after_stop Stop '[{"task_id":"a","task_type":"local_bash","description":"old"},{"task_id":"b","task_type":"local_agent","description":"busy"}]')"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--detail|1 background task running|--background-tasks|1" ]
  [ "$(status_flags)" -eq 0 ]
}

@test "after: Stop with only active tasks writes nothing but the rename" {
  age_file b 30
  run_after <<< "$(after_stop Stop '[{"task_id":"b","task_type":"local_agent","description":"busy"}]')"
  rename_only
}

@test "after: Stop with all quiet tasks paints idle in amber, count 0" {
  age_file a 7200
  run_after <<< "$(after_stop Stop '[{"task_id":"a","task_type":"local_agent","description":"quietly"}]')"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|idle|--detail|idle · 1 quiet background task, quiet 120 min: quietly|--dot-color|#af8700|--text-color|#888888|--background-tasks|0" ]
}

@test "after: a stalled task paints waiting in red, count 0" {
  age_file a 7200
  echo > "$BATS_TEST_TMPDIR/lsof.out"
  run_after <<< "$(after_stop Stop '[{"task_id":"a","task_type":"local_bash","description":"install.sh"}]')"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|waiting|--detail|stalled 120 min: install.sh|--dot-color|#ff5f5f|--text-color|#ff5f5f|--background-tasks|0" ]
}

@test "after: a closing question on Stop paints waiting in yellow, count 0" {
  run_after <<< "$(after_stop Stop '[]' '"last_assistant_message":"Done.\n\nWhich branch?"')"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|waiting|--detail|Which branch?|--dot-color|#ffd75f|--text-color|#ffd75f|--background-tasks|0" ]
}

@test "after: StopFailure ending in a question never writes a status; all quiet it paints idle" {
  run_after <<< "$(after_stop StopFailure '[]' '"last_assistant_message":"Which branch?"')"
  rename_only
  [ "$(status_flags)" -eq 0 ]
  age_file a 7200
  rm "$BATS_TEST_TMPDIR/argv_all" "$BATS_TEST_TMPDIR/calls"
  run_after <<< "$(after_stop StopFailure '[{"task_id":"a","task_type":"local_agent","description":"quietly"}]')"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|idle|--detail|idle · 1 quiet background task, quiet 120 min: quietly|--dot-color|#af8700|--text-color|#888888|--background-tasks|0" ]
  rm "$BATS_TEST_TMPDIR/argv_all" "$BATS_TEST_TMPDIR/calls"
  run_after <<< "$(after_stop StopFailure '[{"task_id":"a","task_type":"local_agent","description":"quietly"}]' '"last_assistant_message":"Retry?"')"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--status|idle|--detail|idle · 1 quiet background task, quiet 120 min: quietly|--dot-color|#af8700|--text-color|#888888|--background-tasks|0" ]
}

@test "after: a Stop over a running background seat repaints its colours and count, no status" {
  mkdir -p "$(dirname "$SEATS_FILE")"
  printf 'ag1\tplan-fable\n' > "$SEATS_FILE"
  age_file ag1 30
  run_after <<< "$(after_stop Stop '[{"task_id":"ag1","task_type":"local_agent"}]')"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--detail|plan-fable running · 1 background task running|--dot-color|#d787ff|--text-color|#d787ff|--background-tasks|1" ]
  [ "$(status_flags)" -eq 0 ]
}

@test "after: a peer's plain Stop sends exactly the peer text colour" {
  printf 'peer\tproj · Alpha\n' > "$BATS_TEST_TMPDIR/role.out"
  run_after <<< "$(after_stop)"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--text-color|#8a8a8a" ]
}

@test "after: the contract: no event but Stop and StopFailure ever sends --status" {
  local ev
  for ev in SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse PermissionRequest Notification SubagentStart SubagentStop; do
    run_after <<< "$(after_stop "$ev")"
    run_after <<< "$(after_stop "$ev" '[{"task_id":"a"}]' '"agent_id":"ag1","agent_type":"plan-fable","tool_name":"Bash"')"
  done
  [ "$(status_flags)" -eq 0 ]
}

@test "after: no it2, or no session id: exit 0 and nothing recorded" {
  rm "$STUB/it2"
  run_after <<< "$(after_stop)"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  printf '#!/bin/sh\necho x >> "%s/calls"\n' "$BATS_TEST_TMPDIR" > "$STUB/it2"; chmod +x "$STUB/it2"
  ITERM_SESSION_ID= run_after <<< "$(after_stop)"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "after: explain after names the mode and the fields it would write, calling nothing" {
  run sh "$SHIM" explain after <<< "$(after_stop)"
  [[ $output == *"mode=after"* ]]
  [[ $output == *"writes=name"$'\n'* || $output == *"writes=name" ]]
  run sh "$SHIM" explain after <<< "$(after_stop Stop '[]' '"last_assistant_message":"Which branch?"')"
  [[ $output == *"writes=name,status,detail,dot,text,count"* ]]
  run sh "$SHIM" explain after <<< '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
  [[ $output == *"writes=none"* ]]
  run sh "$SHIM" explain <<< "$(after_stop)"
  [[ $output == *"mode=legacy"* ]]
  [[ $output != *"writes="* ]]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

# after, mid-turn: a seat's tool calls and its start repaint its colours with the handler's expiry,
# and SubagentStop corrects only the count (or the count and a detail), never a status word.
EXPIRY_ARGV='--expires-on|progress-end|--then-status|idle|--then-dot-color|#00d75f|--then-text-color|#888888|--then-detail|'
# no_python: a python3 stub that records its start, then runs the real one.
no_python() {
  printf '#!/bin/sh\necho x >> "%s/py_calls"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR" "$(command -v python3)" > "$STUB/python3"
  chmod +x "$STUB/python3"
}
sub_stop() { payload SubagentStop "$1" '"session_id":"s1","agent_id":"ag1"'"${2:+,$2}"; }

@test "after: an in-seat PreToolUse and PostToolUse repaint the seat colour with the expiry, no status" {
  local ev
  for ev in PreToolUse PostToolUse; do
    rm -f "$BATS_TEST_TMPDIR/argv" "$BATS_TEST_TMPDIR/calls"
    run_after <<< "$(seat_payload "$ev" plan-fable '"tool_name":"Bash"')"
    [ "$(it2_argv)" = "set-status|--session|ABC-123|--detail|plan-fable: Bash|--dot-color|#d787ff|--text-color|#d787ff|$EXPIRY_ARGV" ]
    [ "$(wc -l < "$BATS_TEST_TMPDIR/calls")" -eq 1 ]
  done
  [ "$(status_flags)" -eq 0 ]
  ! grep -qx -- '--background-tasks' "$BATS_TEST_TMPDIR/argv_all" || { echo "--background-tasks reached the argv log"; false; }
}

@test "after: an in-seat tool call with no tool name shows the seat alone" {
  run_after <<< "$(seat_payload PreToolUse work-sonnet)"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--detail|work-sonnet|--dot-color|#00afaf|--text-color|#00afaf|$EXPIRY_ARGV" ]
}

@test "after: SubagentStart of a seat sends the seat text and colours with the expiry" {
  run_after <<< "$(seat_payload SubagentStart plan-fable)"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--detail|plan-fable running|--dot-color|#d787ff|--text-color|#d787ff|$EXPIRY_ARGV" ]
  [ "$(status_flags)" -eq 0 ]
}

@test "after: in-seat PermissionRequest and Notification record nothing" {
  run_after <<< "$(seat_payload PermissionRequest plan-fable)"
  run_after <<< "$(seat_payload Notification plan-fable)"
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "after: the gate sends hooks of a seat to python, and a SubagentStop without tasks starts none" {
  no_python
  run_after <<< "$(seat_payload PreToolUse scout-haiku '"tool_name":"Read"')"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/py_calls")" -eq 1 ]
  run_after <<< "$(seat_payload SubagentStart scout-haiku)"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/py_calls")" -eq 2 ]
  rm "$BATS_TEST_TMPDIR/py_calls" "$BATS_TEST_TMPDIR/calls"
  run_after <<< '{"hook_event_name":"SubagentStop","agent_id":"ag1","background_tasks":[]}'
  run_after <<< '{"hook_event_name":"SubagentStop","agent_id":"ag1"}'
  [ ! -e "$BATS_TEST_TMPDIR/py_calls" ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "after: a SubagentStop listing only the stopped agent sends exactly the zero count" {
  run_after <<< "$(sub_stop '[{"task_id":"ag1","task_type":"local_agent"}]')"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--background-tasks|0" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/calls")" -eq 1 ]
}

@test "after: a SubagentStop beside an active task sends the detail, the count and the expiry" {
  age_file b 30
  run_after <<< "$(sub_stop '[{"task_id":"ag1","task_type":"local_agent"},{"task_id":"b","task_type":"local_bash"}]')"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--detail|1 background task running|--background-tasks|1|$EXPIRY_ARGV" ]
  [ "$(status_flags)" -eq 0 ]
}

@test "after: a SubagentStop beside only a quiet shell sends exactly the zero count" {
  age_file a 7200
  run_after <<< "$(sub_stop '[{"task_id":"ag1","task_type":"local_agent"},{"task_id":"a","task_type":"local_bash"}]')"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--background-tasks|0" ]
}

@test "after: a SubagentStop with a running seat among the active sends the seat colours, count and expiry" {
  mkdir -p "$(dirname "$SEATS_FILE")"
  printf 'ag2\tplan-fable\n' > "$SEATS_FILE"
  age_file ag2 30
  run_after <<< "$(sub_stop '[{"task_id":"ag1","task_type":"local_agent"},{"task_id":"ag2","task_type":"local_agent"}]')"
  [ "$(it2_argv)" = "set-status|--session|ABC-123|--detail|plan-fable running · 1 background task running|--dot-color|#d787ff|--text-color|#d787ff|--background-tasks|1|$EXPIRY_ARGV" ]
  [ "$(status_flags)" -eq 0 ]
}

@test "after: a SubagentStop whose list holds one active task and not the stopped agent sends nothing" {
  age_file b 30
  run_after <<< "$(sub_stop '[{"task_id":"b","task_type":"local_bash"}]')"
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "after: explain after names the mid-turn writes" {
  run sh "$SHIM" explain after <<< "$(seat_payload PreToolUse plan-fable '"tool_name":"Bash"')"
  [[ $output == *"writes=detail,dot,text,expiry"* ]]
  run sh "$SHIM" explain after <<< "$(sub_stop '[{"task_id":"ag1","task_type":"local_agent"}]')"
  [[ $output == *"writes=count"$'\n'* || $output == *"writes=count" ]]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

# stale_fixture: old per-session files (eight days), a fresh one, and a file other tools keep there.
stale_fixture() {
  local d="$XDG_STATE_HOME/tabstatus" f
  mkdir -p "$d"
  for f in old.named old.tasks old.seats keep.txt; do
    : > "$d/$f"
    python3 -c 'import os,sys,time; t=time.time()-8*86400; os.utime(sys.argv[1],(t,t))' "$d/$f"
  done
  : > "$d/fresh.named"
}

@test "sweep: SessionStart removes per-session state files older than seven days and nothing else" {
  stale_fixture
  run_shim <<< "$(payload SessionStart '[]' '"cwd":"/work/proj","session_id":"s1"')"
  [ "$status" -eq 0 ]
  local d="$XDG_STATE_HOME/tabstatus" f
  for f in old.named old.tasks old.seats; do
    [ ! -e "$d/$f" ]
  done
  [ -e "$d/fresh.named" ]
  [ -e "$d/keep.txt" ]
}

@test "sweep: explain mode and other events remove nothing" {
  stale_fixture
  run sh "$SHIM" explain <<< "$(payload SessionStart '[]' '"cwd":"/work/proj","session_id":"s1"')"
  run_shim <<< "$(payload Stop '[]' '"cwd":"/work/proj","session_id":"s1"')"
  local d="$XDG_STATE_HOME/tabstatus" f
  for f in old.named old.tasks old.seats keep.txt fresh.named; do
    [ -e "$d/$f" ]
  done
}
