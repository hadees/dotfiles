# Reads bats' TAP output (stderr merged) and, at the end, prints a digest of the
# failed tests, one workflow annotation per failure, and a job summary.
# Used by every CI step that runs bats:
#   bats ... 2>&1 | awk -f .github/bats-failures.awk -f .github/bats-progress.awk
# Inputs: standard input; optional awk variables mode (empty or rerun), maxann,
# maxlines, maxsum; environment GITHUB_STEP_SUMMARY.
# It must come before bats-progress.awk on the command line, must never print a
# stream line or assign to $0 (bats-progress.awk owns the print rule), and all its
# variable names begin bf_.
