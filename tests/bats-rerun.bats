#!/usr/bin/env bats
# .github/bats-rerun.sh: the CI step that runs a red suite's failed tests once more.
# A stub bats stands in for the real one: it prints $STUB_COUNT for --count, otherwise
# prints the file $STUB_TAP and exits $STUB_RC, logging its arguments.

setup() {
  RERUN="$BATS_TEST_DIRNAME/../.github/bats-rerun.sh"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/bats-failures"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/suite/.bats/run-logs"
  cat >"$BATS_TEST_TMPDIR/bin/bats" <<'STUB'
#!/bin/sh
echo "$*" >>"$STUB_LOG"
for a in "$@"; do
  if [ "$a" = --count ]; then
    [ -z "${STUB_COUNT_RC:-}" ] || exit "$STUB_COUNT_RC"
    echo "$STUB_COUNT"
    exit 0
  fi
done
cat "$STUB_TAP"
exit "${STUB_RC:-0}"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/bats"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  : >"$STUB_LOG"
  unset GITHUB_STEP_SUMMARY BATS_RERUN_MAX
  SUITE="$BATS_TEST_TMPDIR/suite"
}

# the stub was called with something other than --count
ran_tests() { [ -n "$(grep -v -e '--count' "$STUB_LOG")" ]; }
ran_nothing() { [ -z "$(grep -v -e '--count' "$STUB_LOG")" ]; }

@test "bats-rerun: no run log declines, exit 1, runs nothing" {
  rm -r "$SUITE/.bats"
  run bash "$RERUN" "$SUITE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"re-run skipped: no run log ($SUITE/.bats/run-logs is missing)"* ]]
  [[ "$output" == *"::notice title=bats re-run::re-run skipped: no run log"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "bats-rerun: a count of 0 declines with exit 1" {
  STUB_COUNT=0 run bash "$RERUN" "$SUITE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"re-run skipped: the run log lists no failed test"* ]]
  ran_nothing
}

@test "bats-rerun: more failed tests than the limit declines, a raised limit runs" {
  STUB_COUNT=21 run bash "$RERUN" "$SUITE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"re-run skipped: 21 tests failed or never ran (limit 20)"* ]]
  ran_nothing
  STUB_COUNT=21 BATS_RERUN_MAX=30 STUB_TAP="$FIXTURES/green.tap" run bash "$RERUN" "$SUITE"
  [ "$status" -eq 0 ]
  ran_tests
}

@test "bats-rerun: bats failing to count declines with exit 1" {
  STUB_COUNT_RC=1 run bash "$RERUN" "$SUITE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"re-run skipped: bats could not count the failed tests"* ]]
  ran_nothing
}

@test "bats-rerun: a test that fails again keeps exit 1, with bats' own arguments and no --jobs" {
  STUB_COUNT=3 STUB_TAP="$FIXTURES/rerun.tap" STUB_RC=1 run bash "$RERUN" "$SUITE"
  [ "$status" -eq 1 ]
  [ "$(tail -n 1 "$STUB_LOG")" = "--timing --print-output-on-failure --filter-status failed $SUITE" ]
  [ -z "$(grep -e '--jobs' "$STUB_LOG")" ]
  # the output went through the awk files
  [[ "$output" == *"not ok 1/3 alpha: a poll that never comes true"* ]]
}

@test "bats-rerun: a green re-run exits 0" {
  STUB_COUNT=2 STUB_TAP="$FIXTURES/green.tap" STUB_RC=0 run bash "$RERUN" "$SUITE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok 2/2 beta: passes"* ]]
}

@test "bats-rerun: a decline is appended to the job summary" {
  GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md" STUB_COUNT=0 run bash "$RERUN" "$SUITE"
  [ "$status" -eq 1 ]
  [ "$(cat "$BATS_TEST_TMPDIR/summary.md")" = "re-run skipped: the run log lists no failed test" ]
}

@test "bats-rerun: finds the awk files from another directory" {
  cd "$BATS_TEST_TMPDIR"
  STUB_COUNT=2 STUB_TAP="$FIXTURES/green.tap" run bash "$RERUN" "$SUITE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok 1/2 alpha: passes"* ]]
}

@test "ci: each suite job re-runs its failed tests under the suite's own promises" {
  local wf="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml"
  [ "$(grep -c '^        id: suite$' "$wf")" -eq 3 ]
  [ "$(grep -c "^        if: failure() && steps.suite.outcome == 'failure'$" "$wf")" -eq 3 ]
  [ "$(grep -cE "^ *mkdir -p tests/\.bats/run-logs && .*\|\| rm -rf tests/\.bats$" "$wf")" -eq 3 ]
  # a re-run line ending in || true would let a twice-failed test pass
  [ "$(grep -cE "TESTS_WAIT_SCALE=3 .*SCREEN_TESTS_REQUIRE='tmux fzf' (setsid -w )?bash \.github/bats-rerun\.sh$" "$wf")" -eq 3 ]
  [ "$(grep -E 'bash \.github/bats-rerun\.sh' "$wf" | grep -c 'NODE_TESTS_REQUIRED=1')" -eq 1 ]
  # the run-log line is above pipefail, never between it and the bats line
  [ -z "$(grep -A1 -E '^ *mkdir -p tests/\.bats/run-logs' "$wf" | grep -E ' bats --timing')" ]
  # nothing may turn a red suite green
  [ "$(grep -c 'continue-on-error' "$wf")" -eq 0 ]
}
