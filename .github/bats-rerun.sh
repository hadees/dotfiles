#!/usr/bin/env bash
# CI only: after a red suite step, run the tests that failed once more, one at a time.
#
#   bash .github/bats-rerun.sh [<tests path>]     default path: tests
#
# Run from the repository root, with the suite step's own environment. It reports and
# never absolves: the step it ends is red when a test failed twice or the re-run was
# declined, and the job is red either way, because the suite step before it was.
# BATS_RERUN_MAX (default 20) caps how many tests it will run again.
#
# bats' own record of the last run says which tests failed: it writes one when
# <path>/.bats/run-logs exists (the suite step makes it). "Failed" there includes
# "was not run", so a suite step that was cut off would list every test that never
# ran; the cap is what stops that, and the decline says "failed or never ran".
set -euo pipefail

path=${1:-tests}
max=${BATS_RERUN_MAX:-20}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

decline() {
  echo "re-run skipped: $1"
  echo "::notice title=bats re-run::re-run skipped: $1"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "re-run skipped: $1" >>"$GITHUB_STEP_SUMMARY"
  fi
  exit 1
}

[ -d "$path/.bats/run-logs" ] || decline "no run log ($path/.bats/run-logs is missing)"
n=$(bats --count --filter-status failed "$path" 2>/dev/null) || n=
case $n in '' | *[!0-9]*) decline "bats could not count the failed tests" ;; esac
[ "$n" -gt 0 ] || decline "the run log lists no failed test"
[ "$n" -le "$max" ] || decline "$n tests failed or never ran (limit $max)"

# no --jobs: a test that failed under load gets a quiet machine
bats --timing --print-output-on-failure --filter-status failed "$path" 2>&1 |
  awk -v mode=rerun -f "$here/bats-failures.awk" -f "$here/bats-progress.awk"
