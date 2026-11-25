#!/usr/bin/env bats

# bin/plan-ready lists the steps of a plan whose dependencies are all verified.
# Every plan here is a small invented fixture written under the test's tmp dir.

bats_require_minimum_version 1.5.0

setup() {
  # Pin python3 while HOME is still real: an asdf shim first on PATH finds no
  # version under a fake HOME and exits 126 instead of running.
  if py="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)"; then
    mkdir -p "$BATS_TEST_TMPDIR/pybin" && ln -s "$py" "$BATS_TEST_TMPDIR/pybin/python3"
    export PATH="$BATS_TEST_TMPDIR/pybin:$PATH"
  fi
  PR="$BATS_TEST_DIRNAME/../bin/executable_plan-ready"
  PLAN="$BATS_TEST_TMPDIR/plan.md"
  T=$'\t'
}

# plan_of <text>: write the fixture plan.
plan_of() { printf '%s\n' "$1" > "$PLAN"; }

# ids: what a run printed, as one line of step ids.
ids() { cut -f1 <<< "$output" | tr '\n' ' '; }

@test "the planner's format: a Build sequence table with a Needs column, steps under ## and ### headings" {
  plan_of '## Build sequence

| Step | Repository and branch | Files | Needs |
|---|---|---|---|
| 1 | proj, `feat/a` from main | `a.txt` | none |
| 2 | proj, `feat/b` from main | `b.txt` | None. |
| 3 | proj, `feat/c` from main | `c.txt` | 1 |
| 4 | proj, `feat/d` from main | `d.txt` | 2, 3 |
| 5 | proj, `feat/e` from main | `e.txt` | steps 1 to 3 |

## Step 1
Brief one.

### Step 2
Brief two.'
  run --separate-stderr "$PR" "$PLAN"
  [ "$status" -eq 0 ]
  [ "$(ids)" = "1 2 " ]
  [ -z "$stderr" ]
  run "$PR" "$PLAN" 1 2
  [ "$(ids)" = "3 " ]
  run "$PR" "$PLAN" 1 2 3
  [ "$(ids)" = "4 5 " ]
}

@test "a table row wins over its section's Needs: line; a step without a row uses its line" {
  plan_of '| Step | Needs |
|---|---|
| 1 | none |
| 2 | 1 |

### Step 1: a
Needs: step 2.

### Step 2: b
Needs: nothing.

### Step 3: c
Needs: step 1.'
  run "$PR" "$PLAN"
  [ "$output" = "1${T}a" ]
  run "$PR" "$PLAN" 1
  [ "$(ids)" = "2 3 " ]
}

@test "table cells: bare ids, a parenthesis is ignored, row and Sign-off numbers and signed items are met, a step with letter variants means all of them" {
  plan_of '| # | Needs |
|---|---|
| 1a | none |
| 1b | none |
| 2 | 1a (the fixture); signed PR Z |
| 3 | Step 1 finished; row 14 |
| 4 | Sign-off 2 |
| 5 | 1a to 1b |
| 6 | PR Q merged |'
  run --separate-stderr "$PR" "$PLAN" 1a
  [ "$(ids)" = "1b 2 4 " ]
  [ "$stderr" = "step 6: needs unreadable" ]
  run --separate-stderr "$PR" "$PLAN" 1a 1b
  [ "$(ids)" = "2 3 4 5 " ]
}

@test "a cell with ids and an outside event is not ready: stderr says what else it needs, exit 2 when nothing else is" {
  plan_of '| Step | Needs |
|---|---|
| 1 | none |
| 2 | 1; the vendor key issued |
| 3 | 1 and the operator has rotated the token |'
  run --separate-stderr "$PR" "$PLAN" 1
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$stderr" = "step 2: also needs: the vendor key issued
step 3: also needs: the operator has rotated the token" ]
  run --separate-stderr "$PR" "$PLAN"
  [ "$status" -eq 0 ]
  [ "$(ids)" = "1 " ]
}

@test "a cell that is only an outside event is unreadable; completion words and an unknown bare id are handled" {
  plan_of '| Step | Needs |
|---|---|
| 1 | none |
| 2 | the vendor key issued |
| 3 | 1 merged and deployed; step 1 verified |
| 4 | 1, 9 |'
  run --separate-stderr "$PR" "$PLAN" 1
  [ "$(ids)" = "3 " ]
  [ "$stderr" = "step 2: needs unreadable
step 4: needs unknown step 9" ]
}

@test "a Needs: line with an outside event is not ready; a Consumes: line stays lenient" {
  plan_of '### Step 1: a
Needs: nothing.

### Step 2: b
Needs: step 1 and the operator has rotated the token.

### Step 3: c
Consumes: step 1 and its fixture files.'
  run --separate-stderr "$PR" "$PLAN" 1
  [ "$(ids)" = "3 " ]
  [ "$stderr" = "step 2: also needs: the operator has rotated the token" ]
}

@test "with several tables the one with the most step rows is the Build sequence" {
  plan_of '| # | Option | Needs |
|---|---|---|
| 1 | cheap | 2 |

| Step | Needs |
|---|---|
| 1 | none |
| 2 | 1 |'
  run "$PR" "$PLAN"
  [ "$(ids)" = "1 " ]
}

@test "step ids are strings: 1b, 0 [lead], 1 — live, (PR F) and plain headings, in step order" {
  plan_of '### Step 4: plain
Needs: nothing.

### Step 3 (PR F): with a PR
Needs: nothing.

### Step 1b
Needs: step 1.

### Step 1 — live, no worker: the first
Needs: nothing.

### Step 0 [lead]: worktree
Needs: nothing.

### Step C9. a lettered id
Needs: nothing.'
  run "$PR" "$PLAN"
  [ "$status" -eq 0 ]
  [ "$output" = "0${T}worktree
1${T}the first
3${T}with a PR
4${T}plain
C9${T}a lettered id" ]
  run "$PR" "$PLAN" 1,0
  [ "$(ids)" = "1b 3 4 C9 " ]
  run "$PR" "$PLAN" 1b
  [ "$status" -eq 0 ]
}

@test "--running: those steps are never printed and do not count as verified" {
  plan_of '### Step 1: a
Needs: nothing.

### Step 2: b
Needs: step 1.

### Step 3: c
Needs: step 1.

### Step 4: d
Needs: steps 2 and 3.'
  run "$PR" "$PLAN" 1 --running 2
  [ "$(ids)" = "3 " ]
  run "$PR" "$PLAN" 1 3 --running 2
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run "$PR" "$PLAN" --running 1,2
  [ "$status" -eq 1 ]
  run "$PR" "$PLAN" 1 --running 2 3
  [ "$status" -eq 1 ]
}

@test "--help documents the usage, --running and the exit codes" {
  run "$PR" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--running"* ]]
  [[ "$output" == *"Exit 0"* ]]
}

@test "nothing: a step with no dependencies is ready, titles after (PR X): and :" {
  plan_of '### Step 1 (PR A): first
Needs: nothing. Produces: a file.

### Step 2: second
Needs: none.'
  run --separate-stderr "$PR" "$PLAN"
  [ "$status" -eq 0 ]
  [ "$output" = "1${T}first
2${T}second" ]
  [ -z "$stderr" ]
}

@test "step N, steps N and M, steps N, M and K, steps N to M" {
  plan_of '### Step 1: a
Needs: nothing.

### Step 2: b
Needs: nothing.

### Step 3: c
Needs: nothing.

### Step 4: d
Needs: nothing.

### Step 5: single
Needs: step 1.

### Step 6: pair
Needs: steps 1 and 2.

### Step 7: triple
Needs: steps 1, 2 and 3.

### Step 8: range
Needs: steps 1 to 4.'
  run "$PR" "$PLAN" 1 2 3
  [ "$status" -eq 0 ]
  [ "$output" = "4${T}d
5${T}single
6${T}pair
7${T}triple" ]
  run "$PR" "$PLAN" 1 2 3 4
  [ "$output" = "5${T}single
6${T}pair
7${T}triple
8${T}range" ]
  run "$PR" "$PLAN" 1 3 4
  [ "$output" = "2${T}b
5${T}single" ]
}

@test "a verified step is not listed again" {
  plan_of '### Step 1: a
Needs: nothing.

### Step 2: b
Needs: step 1.'
  run "$PR" "$PLAN" 1
  [ "$output" = "2${T}b" ]
}

@test "a signed reference points at another plan and counts as met" {
  plan_of '### Step 1: a
Needs: nothing.

### Step 2: b
Needs: signed step 1'"'"'s `helper`; signed steps 2 and 3; step 1.'
  run "$PR" "$PLAN" 1
  [ "$output" = "2${T}b" ]
  run "$PR" "$PLAN"
  [ "$output" = "1${T}a" ]
}

@test "the line runs on to its full stop across wrapped lines, and stops there" {
  plan_of '### Step 1: a
Needs: nothing.

### Step 2: b
Needs: step 1 and
steps 1 to 1. Produces: step 9.'
  run "$PR" "$PLAN"
  [ "$output" = "1${T}a" ]
  run "$PR" "$PLAN" 1
  [ "$output" = "2${T}b" ]
}

@test "the first Needs: line wins over Consumes:, and Consumes: is the fallback" {
  plan_of '### Step 1: a
Consumes: nothing.

### Step 2: b
Consumes: nothing.
Needs: step 1.

### Step 3: c
Needs: nothing.
Needs: step 1.'
  run "$PR" "$PLAN"
  [ "$output" = "1${T}a
3${T}c" ]
}

@test "Consumes from step N reads its references up to the first colon" {
  plan_of '### Step 1: a
Needs: nothing.

### Step 2: b
Consumes from steps 1 and 3: `thing`, step 9 and more. Produces: x.

### Step 3: c
Needs: nothing.'
  run "$PR" "$PLAN" 1
  [ "$output" = "3${T}c" ]
  run "$PR" "$PLAN" 1 3
  [ "$output" = "2${T}b" ]
}

@test "Precondition: is the fallback after Needs: and Consumes:, signed plan's steps count as met" {
  plan_of '### Step 1: a
Needs: nothing.

### Step 2: b
Precondition: step 1 deployed; the signed plan'"'"'s step 12 merged; the
operator'"'"'s go.

### Step 3: c
Precondition: nothing.

### Step 4: d
Consumes: nothing.
Precondition: step 1.'
  run --separate-stderr "$PR" "$PLAN"
  [ "$output" = "1${T}a
3${T}c
4${T}d" ]
  [ -z "$stderr" ]
  run "$PR" "$PLAN" 1
  [ "$output" = "2${T}b
3${T}c
4${T}d" ]
}

@test "a reference to a step the plan lacks is named on stderr and the step is never ready" {
  plan_of '### Step 1: a
Needs: nothing.

### Step 2: b
Needs: steps 1, 7 and 8.'
  run --separate-stderr "$PR" "$PLAN" 1
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$stderr" = "step 2: needs unknown step 7
step 2: needs unknown step 8" ]
  run --separate-stderr "$PR" "$PLAN" 1 7 8
  [ "$status" -eq 2 ]
}

@test "text other than the step titles is never printed" {
  plan_of '### Step 1: a
Needs: nothing.
SECRET-BODY-TEXT'
  run "$PR" "$PLAN"
  [[ "$output" != *SECRET-BODY-TEXT* ]]
}

@test "a missing or unparseable line is named on stderr, not ready, exit 2 when nothing else is" {
  plan_of '### Step 1: has none
Files: x.

### Step 2: garbled
Needs: the usual suspects.'
  run --separate-stderr "$PR" "$PLAN"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$stderr" = "step 1: needs unreadable
step 2: needs unreadable" ]
}

@test "an unreadable step does not hide a ready one: exit 0" {
  plan_of '### Step 1: a
Needs: nothing.

### Step 2: b
Files: x.'
  run --separate-stderr "$PR" "$PLAN"
  [ "$status" -eq 0 ]
  [ "$output" = "1${T}a" ]
  [ "$stderr" = "step 2: needs unreadable" ]
}

@test "steps found but none ready: exit 1, nothing on stderr" {
  plan_of '### Step 1: a
Needs: step 2.

### Step 2: b
Needs: step 1.'
  run --separate-stderr "$PR" "$PLAN"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "everything verified: exit 1" {
  plan_of '### Step 1: a
Needs: nothing.'
  run "$PR" "$PLAN" 1
  [ "$status" -eq 1 ]
}

@test "no steps found is never 'nothing left': exit 2 with a reason on stderr" {
  plan_of '# A plan

### Unit A: not a step
Needs: nothing.

| Option | Needs |
|---|---|
| x | none |'
  run --separate-stderr "$PR" "$PLAN"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == "no steps found"* ]]
  : > "$PLAN"
  run --separate-stderr "$PR" "$PLAN"
  [ "$status" -eq 2 ]
}

@test "headings and tables inside a code fence are not steps" {
  plan_of '### Step 1: a
Needs: nothing.

```
### Step 2: fake
Needs: nothing.

| Step | Needs |
|---|---|
| 3 | none |
```'
  run "$PR" "$PLAN"
  [ "$output" = "1${T}a" ]
}

@test "a heading of the same or a higher level ends a step's section, a deeper one does not" {
  plan_of '## Step 1: a
#### Detail
Needs: nothing.

## Notes
Needs: step 9.

## Step 2: b
Needs: step 1.'
  run "$PR" "$PLAN"
  [ "$output" = "1${T}a" ]
}

@test "usage: no plan, a missing plan, a bad step id" {
  run "$PR"
  [ "$status" -eq 64 ]
  run "$PR" "$BATS_TEST_TMPDIR/absent.md"
  [ "$status" -eq 64 ]
  plan_of '### Step 1: a
Needs: nothing.'
  run "$PR" "$PLAN" one
  [ "$status" -eq 64 ]
  run "$PR" "$PLAN" --running one
  [ "$status" -eq 64 ]
}
