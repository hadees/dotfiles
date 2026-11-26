#!/usr/bin/env bats
# .github/bats-progress.awk: the /total CI appends to the number on bats result lines.

setup() {
  AWK="$BATS_TEST_DIRNAME/../.github/bats-progress.awk"
}

@test "bats-progress: appends the plan's total to bats' own number on ok and not ok lines" {
  run awk -f "$AWK" <<'TAP'
1..2541
ok 1137 first in 12ms
not ok 12 second in 3ms
TAP
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1..2541" ]
  [ "${lines[1]}" = "ok 1137/2541 first in 12ms" ]
  [ "${lines[2]}" = "not ok 12/2541 second in 3ms" ]
}

@test "bats-progress: a skip or todo line keeps its suffix" {
  run awk -f "$AWK" <<'TAP'
1..3
ok 1 a # skip not on this OS
not ok 2 b # TODO later
ok 3 c ok 9 # skip ok 4
TAP
  [ "${lines[1]}" = "ok 1/3 a # skip not on this OS" ]
  [ "${lines[2]}" = "not ok 2/3 b # TODO later" ]
  [ "${lines[3]}" = "ok 3/3 c ok 9 # skip ok 4" ]
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
  [ "${lines[4]}" = "ok 1/1 only" ]
}

@test "bats-progress: with no plan line nothing is changed" {
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
