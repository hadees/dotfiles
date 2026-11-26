#!/usr/bin/env bats
# Probe for the CI failure output. Four tests fail on purpose, one passes.
# This file lives on branch ci/failure-output-probe only and never reaches main.

probe_helper() {
  echo "helper about to fail"
  false
}

@test "probe: a failed assertion shows the output of run" {
  echo "a line before the run"
  run sh -c 'echo from-run; exit 3'
  [ "$status" -eq 0 ]
}

@test "probe: fails once, then passes on the re-run" {
  flag="${TMPDIR:-/tmp}/ci-output-probe.flaky"
  if [ ! -e "$flag" ]; then
    : >"$flag"
    false
  fi
}

@test "probe: fails inside a helper function" {
  probe_helper
}

@test "probe: prints one line thirty times and fails" {
  for _ in $(seq 30); do echo "the same line"; done
  false
}

@test "probe: passes" {
  true
}
