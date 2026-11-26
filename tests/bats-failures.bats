#!/usr/bin/env bats
# .github/bats-failures.awk: the failure report CI prints after a red bats run.
# Every test runs it joined with bats-progress.awk, in the order CI uses.

setup() {
  FAIL_AWK="$BATS_TEST_DIRNAME/../.github/bats-failures.awk"
  PROG_AWK="$BATS_TEST_DIRNAME/../.github/bats-progress.awk"
  FIX="$BATS_TEST_DIRNAME/fixtures/bats-failures"
  # CI sets the real one; a test must never append to it.
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
}

# filt [awk args] < tap : both program files, as CI runs them.
filt() { awk "$@" -f "$FAIL_AWK" -f "$PROG_AWK"; }

has() { printf '%s\n' "$output" | grep -qxF -- "$1"; }
lacks() { ! has "$1"; }

@test "bats-failures: a green run prints what bats-progress prints, and writes no summary" {
  awk -f "$PROG_AWK" <"$FIX/green.tap" >"$BATS_TEST_TMPDIR/want"
  filt <"$FIX/green.tap" >"$BATS_TEST_TMPDIR/got"
  cmp "$BATS_TEST_TMPDIR/got" "$BATS_TEST_TMPDIR/want"
  [ ! -e "$GITHUB_STEP_SUMMARY" ]
}

@test "bats-failures: every stream line is kept, in order, before the report" {
  awk -f "$PROG_AWK" <"$FIX/first.tap" >"$BATS_TEST_TMPDIR/want"
  filt <"$FIX/first.tap" >"$BATS_TEST_TMPDIR/got"
  n=$(wc -l <"$BATS_TEST_TMPDIR/want")
  head -n "$n" "$BATS_TEST_TMPDIR/got" | cmp - "$BATS_TEST_TMPDIR/want"
  [ "$(sed -n "$((n + 1))p" "$BATS_TEST_TMPDIR/got")" = "===== bats failures: 5 of 7 =====" ]
}

@test "bats-failures: the first line, the four count lines and the end marker" {
  run filt <"$FIX/first.tap"
  [ "$status" -eq 0 ]
  has "===== bats failures: 5 of 7 ====="
  has "results: 7 of 7"
  has "annotations: 5 written, 0 over the limit of 9"
  has "without a location: 1"
  has "job summary: written"
  has "===== end bats failures ====="
}

@test "bats-failures: a helper's failure shows the line of the call, the helper, and the grep line once" {
  run filt <"$FIX/first.tap"
  has "not ok 2 alpha: a poll that never comes true (10321ms)"
  has "  at tests/alpha.bats:41, in until_ok (tests/alpha.bats:20)"
  has "  \`until_ok 'grep -q ready \"\$LOG\"'' failed"
  [ "$(printf '%s\n' "$output" | grep -c '^  | grep: /tmp/x/ready.log')" -eq 1 ]
  has "  | ... 24 more lines identical to the one above"
}

@test "bats-failures: output over the cap keeps the head and the tail" {
  run filt <"$FIX/first.tap"
  has "  | line 50"
  lacks "  | line 51"
  has '  | ... 40 lines left out (the whole output is above, at "not ok 5")'
  has "  | line 91"
  has "  | line 100"
}

@test "bats-failures: a setup_file failure and a failure with no trace" {
  run filt <"$FIX/first.tap"
  has "  at tests/gamma.bats:3, in setup_file"
  has "  at (no location in the output)"
}

@test "bats-failures: one error annotation per failure, with file and line when there is one" {
  run filt <"$FIX/first.tap"
  printf '%s\n' "$output" | grep '^::' >"$BATS_TEST_TMPDIR/got"
  cat >"$BATS_TEST_TMPDIR/want" <<'EOF'
::error file=tests/alpha.bats,line=41,title=bats failed::not ok 2 alpha: a poll that never comes true%0A`until_ok 'grep -q ready "$LOG"'' failed
::error file=tests/beta.bats,line=7,title=bats failed::not ok 4 beta: compares <a> & "b" | c%0A`[ "$status" -eq 0 ]' failed
::error file=tests/beta.bats,line=15,title=bats failed::not ok 5 beta: more output than the cap%0A`false' failed
::error file=tests/gamma.bats,line=3,title=bats failed::not ok 6 setup_file failed%0A`exit 1' failed
::error title=bats failed::not ok 7 delta: a failure with no trace
EOF
  diff "$BATS_TEST_TMPDIR/got" "$BATS_TEST_TMPDIR/want"
  # and none of them comes before the end marker
  [ "$(printf '%s\n' "$output" | grep -n '^::error' | head -n 1 | cut -d: -f1)" -gt \
    "$(printf '%s\n' "$output" | grep -n '^===== end bats failures' | cut -d: -f1)" ]
}

@test "bats-failures: maxann caps the annotations and counts what it left out" {
  run filt -v maxann=3 <"$FIX/first.tap"
  [ "$(printf '%s\n' "$output" | grep -c '^::error')" -eq 3 ]
  has "::error title=bats failed::3 more failed tests are in the digest and the job summary"
  has "annotations: 3 written, 3 over the limit of 3"
}

@test "bats-failures: a percent sign in the failed command is escaped in the annotation" {
  run filt <<'TAP'
1..1
not ok 1 x
# (in test file t.bats, line 1)
#   `echo 50% of a,b: c' failed
TAP
  has "::error file=t.bats,line=1,title=bats failed::not ok 1 x%0A\`echo 50%25 of a,b: c' failed"
}

@test "bats-failures: the job summary lists the failures and escapes the stream's text" {
  filt <"$FIX/first.tap" >/dev/null
  grep -qxF '### bats: 5 of 7 failed' "$GITHUB_STEP_SUMMARY"
  grep -qF 'beta: compares &lt;a&gt; &amp; "b" | c' "$GITHUB_STEP_SUMMARY"
  [ "$(grep -c '^<pre>$' "$GITHUB_STEP_SUMMARY")" -eq 5 ]
}

@test "bats-failures: with no GITHUB_STEP_SUMMARY the report says so and the exit status is 0" {
  unset GITHUB_STEP_SUMMARY
  run filt <"$FIX/first.tap"
  [ "$status" -eq 0 ]
  has "job summary: not written (GITHUB_STEP_SUMMARY is unset)"
}

@test "bats-failures: rerun mode names what failed twice, what passed, and what was skipped" {
  run filt -v mode=rerun <"$FIX/rerun.tap"
  has "===== bats re-run: 1 failed twice, 1 passed on re-run (flaky), 1 skipped on re-run, of 3 ====="
  [ "$(printf '%s\n' "$output" | grep -c '^flaky: ')" -eq 1 ]
  has 'flaky: beta: compares <a> & "b" | c'
  [ "$(printf '%s\n' "$output" | grep -c '^skipped on re-run: ')" -eq 1 ]
  has "skipped on re-run: alpha: skipped here"
  [ "$(printf '%s\n' "$output" | grep -c '^::error .*title=bats failed twice::')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '^::warning ')" -eq 1 ]
  has '::warning title=bats flaky (passed on re-run)::beta: compares <a> & "b" | c'
  has "===== end bats re-run ====="
  grep -qxF '### bats re-run: 1 failed twice, 1 flaky, 1 skipped' "$GITHUB_STEP_SUMMARY"
}

@test "bats-failures: a stream that ends before its plan says how far it got" {
  run filt <"$FIX/short.tap"
  [ "$status" -eq 0 ]
  has "===== bats: 2 of 5 results arrived ====="
  has "::error title=bats ended early::2 of 5 results arrived"
  [ ! -e "$GITHUB_STEP_SUMMARY" ]
}

@test "bats-failures: a stream whose numbers already carry /total finds the same failures" {
  awk -f "$PROG_AWK" <"$FIX/first.tap" | filt >"$BATS_TEST_TMPDIR/prefixed"
  filt <"$FIX/first.tap" >"$BATS_TEST_TMPDIR/plain"
  sed -n '/^===== bats failures/,$p' "$BATS_TEST_TMPDIR/prefixed" >"$BATS_TEST_TMPDIR/a"
  sed -n '/^===== bats failures/,$p' "$BATS_TEST_TMPDIR/plain" >"$BATS_TEST_TMPDIR/b"
  [ -s "$BATS_TEST_TMPDIR/a" ]
  cmp "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
}

@test "bats-failures: the producer's exit status survives the pipe" {
  run bash -c 'set -eo pipefail; { cat "$1"; exit 1; } | awk -f "$2" -f "$3"; echo unreachable' _ "$FIX/first.tap" "$FAIL_AWK" "$PROG_AWK"
  [ "$status" -eq 1 ]
  [[ "$output" != *unreachable* ]]
  run bash -c 'set -eo pipefail; { cat "$1"; exit 0; } | awk -f "$2" -f "$3"' _ "$FIX/green.tap" "$FAIL_AWK" "$PROG_AWK"
  [ "$status" -eq 0 ]
}

@test "bats-failures: the real bats' locations are the ones the filter reads" {
  cat >"$BATS_TEST_TMPDIR/probe.bats" <<'EOF'
helper() {
  [ 1 -eq 2 ]
}

@test "probe plain" {
  false
}

@test "probe helper" {
  helper
}
EOF
  plain=$(grep -n '^  false$' "$BATS_TEST_TMPDIR/probe.bats" | cut -d: -f1)
  inner=$(grep -n '^  \[ 1 -eq 2 \]$' "$BATS_TEST_TMPDIR/probe.bats" | cut -d: -f1)
  call=$(grep -n '^  helper$' "$BATS_TEST_TMPDIR/probe.bats" | cut -d: -f1)
  run bash -c 'bats --timing --print-output-on-failure "$1" 2>&1 | awk -f "$2" -f "$3"; true' _ \
    "$BATS_TEST_TMPDIR/probe.bats" "$FAIL_AWK" "$PROG_AWK"
  has "===== bats failures: 2 of 2 ====="
  has "  at $BATS_TEST_TMPDIR/probe.bats:$plain"
  has "  at $BATS_TEST_TMPDIR/probe.bats:$call, in helper ($BATS_TEST_TMPDIR/probe.bats:$inner)"
}

@test "bats-failures: flaky warnings are capped like errors and all stay in the report" {
  run filt -v mode=rerun -v maxann=2 <<'TAP'
1..3
ok 1 a in 1ms
ok 2 b in 1ms
ok 3 c in 1ms
TAP
  [ "$(printf '%s\n' "$output" | grep -c '^::warning ')" -eq 2 ]
  has "::warning title=bats flaky (passed on re-run)::a"
  has "::warning title=bats flaky (passed on re-run)::2 more flaky tests are in the digest and the job summary"
  has "flaky warnings: 2 written, 2 over the limit of 2"
  [ "$(printf '%s\n' "$output" | grep -c '^flaky: ')" -eq 3 ]
}
