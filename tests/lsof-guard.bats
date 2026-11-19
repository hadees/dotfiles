#!/usr/bin/env bats

# bin/executable_lsof refuses non-interactive lsof calls once
# `git config lsof.guard true` is set. The script is plain sh, so these run on
# every OS; the real lsof is a stub that prints REAL and its arguments, and
# real lsof is never run. Every non-terminal case goes through `sh -c '... </dev/null'`
# because bats' own stdin can be a terminal.

setup() {
  GUARD="$BATS_TEST_DIRNAME/../bin/executable_lsof"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  : > "$GIT_CONFIG_GLOBAL"
  unset LSOF_GUARD
  export LSOF_GUARD_REAL="$BATS_TEST_TMPDIR/real-lsof"
  printf '#!/bin/sh\necho REAL "$@"\n' > "$LSOF_GUARD_REAL"
  chmod +x "$LSOF_GUARD_REAL"
  export GUARD
  # macOS has no timeout(1) unless coreutils is installed; CI's runner lacks it.
  TO=; if command -v timeout >/dev/null 2>&1; then TO="timeout 10"; fi
}

guard() {
  # A short timeout: a guard that re-executes lsof by name instead of the real
  # binary recurses until the process table fills.
  run $TO sh -c '"$GUARD" "$@" </dev/null' _ "$@"
}

@test "off by default: the real lsof runs with its arguments intact" {
  guard -t -- /tmp/a
  [ "$status" -eq 0 ]
  [ "$output" = "REAL -t -- /tmp/a" ]
  [ ! -e "$XDG_STATE_HOME/lsof-guard" ]
}

@test "lsof.guard true: refused with 69, counted, and the arguments kept" {
  git config -f "$GIT_CONFIG_GLOBAL" lsof.guard true
  guard -t -- /tmp/a
  [ "$status" -eq 69 ]
  [[ $output == *"LSOF_GUARD=off"* ]]
  [[ $output != *REAL* ]]
  count=$(ls "$XDG_STATE_HOME"/lsof-guard/*.count)
  [ "$(wc -c < "$count")" -eq 1 ]
  guard -t -- /tmp/a
  [ "$(wc -c < "$count")" -eq 2 ]
  grep -q -- '-t -- /tmp/a' "${count%.count}.last"
}

@test "lsof.guard true with LSOF_GUARD=off: the real lsof runs" {
  git config -f "$GIT_CONFIG_GLOBAL" lsof.guard true
  LSOF_GUARD=off guard -p 1
  [ "$status" -eq 0 ]
  [ "$output" = "REAL -p 1" ]
}

@test "lsof.guard true on a terminal: the real lsof runs" {
  command -v python3 >/dev/null || skip "python3 not installed"
  # pty.spawn can wait forever on a runner with no terminal to hand out.
  [ -n "$TO" ] || skip "no timeout(1) to bound pty.spawn"
  git config -f "$GIT_CONFIG_GLOBAL" lsof.guard true
  run $TO python3 -c 'import pty,sys; pty.spawn(sys.argv[1:])' "$GUARD" -p 1
  [[ $output == *"REAL -p 1"* ]] || skip "no pty here"
}

@test "an unwritable state directory still refuses with 69" {
  git config -f "$GIT_CONFIG_GLOBAL" lsof.guard true
  : > "$BATS_TEST_TMPDIR/file"
  XDG_STATE_HOME="$BATS_TEST_TMPDIR/file" guard -p 1
  [ "$status" -eq 69 ]
}
