---
paths:
  - "**/.github/bats-*"
  - "**/.github/workflows/tests.yml"
  - "**/tests/bats-*.bats"
  - "**/tests/fixtures/bats-failures/**"
---

# What a red CI job prints

Each bats line in `.github/workflows/tests.yml` ends
` 2>&1 | awk -f .github/bats-failures.awk -f .github/bats-progress.awk`,
after a `set -o pipefail` line, and passes `--print-output-on-failure` (a
failed test's log gains `Last output:` and the value of `$output`). The suite
step of `test`, `test-rocky` and `test-wsl` has `id: suite`. `test-macos-apply`
and `test-bootstrap` run no bats and have none of this.

## Reading a red check

- `gh run view <run>` lists each failed test as an annotation with its file
  and line, with no log to download.
- `gh run view <run> --log-failed | sed -n '/===== bats/,/===== end bats/p'`
  prints the detail. The `Run tests` step ends with a digest between
  `===== bats failures` and `===== end bats failures`: each failed test, its
  location, the failed command and its output.
- The run's summary page lists the same failed tests per job.
- Has it failed on main before? Annotations are the record:
  `gh run list --branch main --status failure --limit 20 --json databaseId
  --jq '.[].databaseId'`, then `gh run view` on each and its `X not ok` lines.

## What the filter may never do

`bats-failures.awk` reads the TAP stream and never changes, drops or reorders
a line of it: it has no rule that prints a stream line or assigns `$0`, and
the print rule stays in `bats-progress.awk`. It always exits 0, so
`pipefail` carries bats' status. A green run prints nothing more than before,
writes no file and emits no workflow command. POSIX awk only (the jobs run
gawk, mawk and macOS's awk), and every variable begins `bf_`, because the two
files are one awk program.

## Limits, and where each is counted

- 9 annotations a step, errors and warnings each (`maxann`; GitHub keeps 10
  of each, and the runner's own "exit code 1" is one error). The rest are
  counted in the digest.
- 60 output lines a failed test in the digest (`maxlines`), after runs of
  identical lines fold to one; the first 50 and last 10 are kept.
- 25 itemised failed tests in the job summary (`maxsum`).
- 20 tests re-run (`BATS_RERUN_MAX` in `.github/bats-rerun.sh`). More failed
  than that is a broken build, not a flake, and is not re-run.

## The re-run

A step `Re-run the failed tests` runs only after a red suite step, with the
suite's own promises, serially and with a 10-minute limit.
`.github/bats-rerun.sh` asks bats for `--filter-status failed`, which reads
the run log bats writes under `tests/.bats/run-logs` (git-ignored; the suite
step makes the directory, and where the checkout cannot hold bats' file names
there is no log and the re-run declines with `no run log`). A test that fails
again is marked `failed twice`; one that passes is marked `flaky (passed on
re-run)`, with a warning annotation.

The job is red either way: the suite step has no `continue-on-error`, and a
pass on re-run never turns a check green. The re-run step is red when a test
failed twice or the re-run declined, and green when every failed test passed
on its own. Its `--log-failed` holds the digest only while it is red; the
flaky warnings are always in `gh run view`. A job whose every failure is
labelled flaky still counts as one red run.

## The helpers' words

`until_ok` (both bats files that define it) prints, on giving up, `until_ok:
gave up after <n> tries: <command>` and, when the last try wrote to stderr,
`until_ok: stderr of the last try:` and that text; earlier tries' stderr is
dropped on purpose. `UNTIL_OK_TRIES` overrides the number of tries. A failed
test's teardown prints `--- pane-<tag>.out (last 40 lines)`
(`tests/claude-peer.bats`) or `--- screen at teardown <cols>x<rows>`
(`tests/claude-peer-screen.bats`).

## Not built

A test-report action needs a write token and third-party code; the JUnit
report has no file or line in it; the failed tests' directories as an
artifact would be stale by the end of the job. Do not add them unasked.
