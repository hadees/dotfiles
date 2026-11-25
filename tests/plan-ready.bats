#!/usr/bin/env bats

# bin/plan-ready lists the steps of a plan whose dependencies are all verified.
# Every plan here is a small fixture written under the test's tmp dir.

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

@test "nothing: a step with no dependencies is ready, titles after (PR X): and :" {
  plan_of '### Step 1 (PR A): first
Needs: nothing. Produces: a file.

### Step 2: second
Needs: nothing.'
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
  run --separate-stderr "$PR" "$PLAN" 1
  [ "$output" = "3${T}c" ]
  run "$PR" "$PLAN" 1 3
  [ "$output" = "2${T}b" ]
}

@test "Precondition: is the fallback after Needs: and Consumes:, signed plan's steps count as met" {
  plan_of '### Step 1: a
Needs: nothing.

### Step 2: b
Precondition: step 1 deployed; the signed plan'"'"'s step 12 merged; his
go for it.

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

@test "nothing ready and nothing unreadable: exit 1" {
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

@test "headings inside a code fence are not steps" {
  plan_of '### Step 1: a
Needs: nothing.

```
### Step 2: fake
Needs: nothing.
```'
  run "$PR" "$PLAN"
  [ "$output" = "1${T}a" ]
}

@test "usage: no plan, a missing plan, a non-numeric step" {
  run "$PR"
  [ "$status" -eq 64 ]
  run "$PR" "$BATS_TEST_TMPDIR/absent.md"
  [ "$status" -eq 64 ]
  plan_of '### Step 1: a
Needs: nothing.'
  run "$PR" "$PLAN" one
  [ "$status" -eq 64 ]
}

@test "the peer-model plan, when present, lists the steps that need nothing" {
  local real="$HOME/.local/state/claude-reports/dotfiles/plan-fable-peer-model.md"
  [ -f "$real" ] || skip "no peer-model plan on this machine"
  run --separate-stderr "$PR" "$real"
  [ "$status" -eq 0 ]
  [ "$(cut -f1 <<< "$output" | tr '\n' ' ')" = "1 5 7 " ]
  run --separate-stderr "$PR" "$real" 1 2
  [ "$(cut -f1 <<< "$output" | tr '\n' ' ')" = "3 5 7 8 " ]
}
