#!/usr/bin/env bats
# .github/bats-progress.awk: the [done/total] prefix CI puts on bats result lines.

setup() {
  AWK="$BATS_TEST_DIRNAME/../.github/bats-progress.awk"
}

@test "bats-progress: counts ok and not ok lines against the plan" {
  run awk -f "$AWK" <<'TAP'
1..3
ok 1 first in 12ms
not ok 2 second in 3ms
ok 3 third # skip why
TAP
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1..3" ]
  [ "${lines[1]}" = "[1/3] ok 1 first in 12ms" ]
  [ "${lines[2]}" = "[2/3] not ok 2 second in 3ms" ]
  [ "${lines[3]}" = "[3/3] ok 3 third # skip why" ]
}

@test "bats-progress: passes every other line through unchanged" {
  run awk -f "$AWK" <<'TAP'
1..1
# (in test file x.bats, line 4) diagnostic
   okay is not a result line
plain output
ok 1 only
TAP
  [ "${lines[1]}" = "# (in test file x.bats, line 4) diagnostic" ]
  [ "${lines[2]}" = "   okay is not a result line" ]
  [ "${lines[3]}" = "plain output" ]
  [ "${lines[4]}" = "[1/1] ok 1 only" ]
}

@test "bats-progress: with no plan line nothing is prefixed" {
  run awk -f "$AWK" <<'TAP'
ok 1 a
not ok 2 b
TAP
  [ "${lines[0]}" = "ok 1 a" ]
  [ "${lines[1]}" = "not ok 2 b" ]
}

@test "bats-progress: a failing producer still fails a pipefail pipeline" {
  run bash -c 'set -eo pipefail; { printf "1..1\nnot ok 1 x\n"; exit 1; } 2>&1 | awk -f "$1"; echo unreachable' _ "$AWK"
  [ "$status" -eq 1 ]
  [[ "$output" != *unreachable* ]]
}
