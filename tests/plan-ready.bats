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
Brief two.

### Step 3
Brief three.

### Step 4
Brief four.

### Step 5
Brief five.'
  run --separate-stderr "$PR" "$PLAN"
  [ "$status" -eq 0 ]
  [ "$(ids)" = "1 2 " ]
  [ -z "$stderr" ]
  run "$PR" "$PLAN" 1 2
  [ "$(ids)" = "3 " ]
  run "$PR" "$PLAN" 1 2 3
  [ "$(ids)" = "4 5 " ]
}

@test "a table row and the section's labelled lines all count: neither overrides the other" {
  plan_of '| Step | Needs |
|---|---|
| 1 | none |
| 2 | 1 |
| 3 | 1 |

### Step 2: b
Needs: nothing.

### Step 3: c
Precondition: the vendor key issued.

### Step 4: d
Needs: step 1.'
  run --separate-stderr "$PR" "$PLAN"
  [ "$(ids)" = "1 " ]
  run --separate-stderr "$PR" "$PLAN" 1
  [ "$(ids)" = "2 4 " ]
  [ "$stderr" = "step 3: also needs: the vendor key issued" ]
}

@test "every labelled line of a section is read, decorated or not, beside a Consumes: line and beside a table row" {
  local body table
  for body in \
    $'Consumes: step 1 schema\n\nPrecondition: the vendor key issued.' \
    $'Precondition: the vendor key issued.\n\nConsumes: step 1 schema' \
    $'Needs: step 1\n\nPrecondition: the vendor key issued.' \
    $'Needs: step 1.\n\nNeeds: the vendor key issued.' \
    $'**Needs:** step 1; the vendor key issued\n\nConsumes: step 1 schema' \
    $'**Needs**: step 1; the vendor key issued\n\nConsumes: step 1 schema' \
    $'- Needs: step 1; the vendor key issued\n\nConsumes: step 1 schema' \
    $'  Needs: step 1; the vendor key issued\n\nConsumes: step 1 schema' \
    $'Needs (outside): the vendor key issued\n\nConsumes: step 1 schema' \
    $'Depends on: the vendor key issued.\n\nConsumes: step 1 schema' \
    $'Waits for: the vendor key issued.\n\nConsumes: step 1 schema'; do
    for table in '' $'| Step | Needs |\n|---|---|\n| 2 | 1 |\n\n'; do
      plan_of "${table}### Step 1: a
Needs: nothing.

### Step 2: b
$body"
      run --separate-stderr "$PR" "$PLAN" 1
      [ "$status" -eq 2 ] || { echo "body [$body] table [$table]: status $status, output [$output]"; false; }
      [ -z "$output" ]
      [ "$stderr" = "step 2: also needs: the vendor key issued" ] || { echo "body [$body]: stderr [$stderr]"; false; }
    done
  done
}

@test "a step with several table rows: every row's Needs cell counts, and an empty one is unreadable" {
  plan_of '| Step | Repo | Needs |
|---|---|---|
| 1 | r | none |
| 2 | repoA | 1; the vendor key issued |
| 2 | repoB | — |
| 3 | repoA | 1 |
| 3 | repoB | 1 |
| 4 | repoA | 1 |
| 4 | repoB | |
| 5 | repoA | 1 |
| 5 | repoB |'
  run --separate-stderr "$PR" "$PLAN" 1
  [ "$(ids)" = "3 " ]
  [ "$stderr" = "step 2: also needs: the vendor key issued
step 4: needs unreadable
step 5: needs unreadable" ]
}

@test "a second column headed like a needs label counts too" {
  plan_of '| Step | Needs | Blocked by |
|---|---|---|
| 1 | none | none |
| 2 | 1 | the vendor key issued |
| 3 | 1 | — |'
  run --separate-stderr "$PR" "$PLAN" 1
  [ "$(ids)" = "3 " ]
  [ "$stderr" = "step 2: also needs: the vendor key issued" ]
}

@test "table cells: bare ids and completion words are met, a step with letter variants means all of them" {
  plan_of '| # | Needs |
|---|---|
| 1a | none |
| 1b | none |
| **2** | 1a |
| 3 | Step 1 finished; 1a verified, done |
| 5 | 1a to 1b |'
  run --separate-stderr "$PR" "$PLAN" 1a
  [ "$(ids)" = "1b 2 " ]
  [ -z "$stderr" ]
  run --separate-stderr "$PR" "$PLAN" 1a 1b
  [ "$(ids)" = "2 3 5 " ]
}

@test "strict reading: only this plan's verified steps are met; every other shape withholds the step and names what is left" {
  local cell want
  while IFS='|' read -r cell want; do
    plan_of "| Step | Needs |
|---|---|
| 1 | none |
| 2 | $cell |"
    run --separate-stderr "$PR" "$PLAN" 1
    [ "$status" -eq 2 ] || { echo "cell [$cell]: status $status, output [$output]"; false; }
    [ -z "$output" ]
    [ "$stderr" = "step 2: also needs: $want" ] || { echo "cell [$cell]: stderr [$stderr]"; false; }
  done <<'CELLS'
1 (after the vendor key is issued)|(after the vendor key is issued)
1. Then the vendor key issued|Then the vendor key issued
Step 1 merged. The operator logs in first|merged. The operator logs in first
1 merged|merged
1 merged and deployed; step 1 verified|merged deployed
1; signed step 9|signed step 9
1; signed plan's steps 2 and 3|signed plan's steps 2 and 3
Step 1 finished; Sign-off 14|Sign-off 14
step 1's fixture and the vendor key issued|'s fixture the vendor key issued
1; signed contract from the client|signed contract from the client
1; row 3 and 4|row 3 and 4
1; Sign-off 3 struck|Sign-off 3 struck
CELLS
  plan_of '### Step 1: a
Needs: nothing.

### Step 2: b
Needs: step 1. The operator must log in first.

### Step 3: c
Needs: step 1 (and the vendor key).

### Step 4: d
Precondition: step 1 merged and the vendor key issued.'
  run --separate-stderr "$PR" "$PLAN" 1
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$stderr" = "step 2: also needs: The operator must log in first
step 3: also needs: (and the vendor key)
step 4: also needs: merged the vendor key issued" ]
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

@test "a cell that is only an outside event is named too; an unknown bare id is named" {
  plan_of '| Step | Needs |
|---|---|
| 1 | none |
| 2 | the vendor key issued |
| 3 | 1 finished; step 1 verified |
| 4 | 1, 9 |'
  run --separate-stderr "$PR" "$PLAN" 1
  [ "$(ids)" = "3 " ]
  [ "$stderr" = "step 2: also needs: the vendor key issued
step 4: needs unknown step 9" ]
}

@test "a Needs: line with an outside event is not ready; a Consumes: line is read for its step references only" {
  plan_of '### Step 1: a
Needs: nothing.

### Step 2: b
Needs: step 1 and the operator has rotated the token.

### Step 3: c
Needs: nothing.

Consumes: step 1 and its fixture files.'
  run --separate-stderr "$PR" "$PLAN"
  [ "$(ids)" = "1 " ]
  run --separate-stderr "$PR" "$PLAN" 1
  [ "$(ids)" = "3 " ]
  [ "$stderr" = "step 2: also needs: the operator has rotated the token" ]
}

@test "a Consumes: line alone never shows a step ready: what a step consumes is not all it can need" {
  plan_of '### Step 1: a
Consumes: nothing.

### Step 2: b
Needs: nothing.

### Step 3: c
Consumes: step 2 and its fixture files.'
  run --separate-stderr "$PR" "$PLAN" 2
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$stderr" = "step 1: needs unreadable
step 3: needs unreadable" ]
}

@test "several tables with a Needs column: all hold steps, and a step with rows in two of them is withheld" {
  plan_of '| # | Option | Needs |
|---|---|---|
| 1 | cheap | none |
| 7 | dear | none |

| Step | Needs |
|---|---|
| 1 | none |
| 2 | 1; the vendor key issued |
| 3 | none |

| Step | Needs |
|---|---|
| 2 | none |'
  run --separate-stderr "$PR" "$PLAN" 1
  [ "$(ids)" = "3 7 " ]
  [ "$stderr" = "step 2: rows in more than one table with a Needs column" ]
  run --separate-stderr "$PR" "$PLAN" 3 7
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "a row of a steps table that does not name one step stops the run: nothing is printed" {
  local row
  for row in '| 2, 3 | 1; the vendor key issued |' '| 2 to 3 | 1 |' '| | 1 |' '| 2 | 1 | the vendor key issued |'; do
    plan_of "| Step | Needs |
|---|---|
| 1 | none |
$row

### Step 2: b
Consumes: step 1 schema"
    run --separate-stderr "$PR" "$PLAN"
    [ "$status" -eq 2 ] || { echo "row [$row]: status $status, output [$output]"; false; }
    [ -z "$output" ]
    [ "$stderr" = "line 4: a table row that does not name one step" ] || { echo "row [$row]: stderr [$stderr]"; false; }
  done
  plan_of '| Step | Files | Needs |
|---|---|---|
| 1 | `a \| b` | none |'
  run --separate-stderr "$PR" "$PLAN"
  [ "$(ids)" = "1 " ]
  [ -z "$stderr" ]
}

@test "a labelled needs line outside every step section stops the run: its step was not recognised" {
  plan_of '| Step | Needs |
|---|---|
| 1 | none |
| 2 | 1 |

### 2. b
Needs: step 1; the vendor key issued.'
  run --separate-stderr "$PR" "$PLAN" 1
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$stderr" = "line 7: a Needs: line outside every step section" ]
}

@test "a Step heading that names more than one step stops the run" {
  plan_of '| Step | Needs |
|---|---|
| 1 | none |
| 2 | 1 |
| 3 | 1 |

### Step 2 and 3: b
Needs: step 1; the vendor key issued.'
  run --separate-stderr "$PR" "$PLAN" 1
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$stderr" = "line 7: a heading that names more than one step" ]
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
Needs: nothing.

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

@test "a signed step is another plan's: withheld in a Needs: line, passed over in a Consumes: line" {
  plan_of '### Step 1: a
Needs: nothing.

### Step 2: b
Needs: signed step 1; step 1.

### Step 3: c
Needs: nothing.

Consumes: signed step 1'"'"'s `helper`; step 1.'
  run --separate-stderr "$PR" "$PLAN" 1
  [ "$output" = "3${T}c" ]
  [ "$stderr" = "step 2: also needs: signed step 1" ]
  run --separate-stderr "$PR" "$PLAN"
  [ "$output" = "1${T}a" ]
}

@test "a needs line runs on across wrapped lines to a blank line; text after a full stop is an outside need" {
  plan_of '### Step 1: a
Needs: nothing.

### Step 2: b
Needs: step 1 and
steps 1 to 1.

### Step 3: c
Needs: step 1. Then the key issued

### Step 4: d
Needs: nothing.
Consumes: step 1. Produces: step 9.'
  run --separate-stderr "$PR" "$PLAN" 1
  [ "$(ids)" = "2 4 " ]
  [ "$stderr" = "step 3: also needs: Then the key issued" ]
}

@test "every Needs: and Consumes: line counts, and a labelled line ends the one before it" {
  plan_of '### Step 1: a
Needs: nothing.

### Step 2: b
Consumes: nothing.
Needs: step 1.

### Step 3: c
Needs: nothing.

Needs: step 1.

### Step 4: d
Needs: step 1
Consumes: the schema of step 3 (and of step 2). Step 5 writes it too. Produces: step 9.

### Step 5: e
Needs: nothing.'
  run --separate-stderr "$PR" "$PLAN"
  [ "$(ids)" = "1 5 " ]
  [ -z "$stderr" ]
  run "$PR" "$PLAN" 1 5
  [ "$(ids)" = "2 3 " ]
  run "$PR" "$PLAN" 1 5 3
  [ "$(ids)" = "2 " ]
  run "$PR" "$PLAN" 1 5 3 2
  [ "$(ids)" = "4 " ]
}

@test "Consumes from step N reads its references up to the first colon" {
  plan_of '### Step 1: a
Needs: nothing.

### Step 2: b
Needs: nothing.
Consumes from steps 1 and 3: `thing`, step 9 and more. Produces: x.

### Step 3: c
Needs: nothing.'
  run "$PR" "$PLAN" 1
  [ "$output" = "3${T}c" ]
  run "$PR" "$PLAN" 1 3
  [ "$output" = "2${T}b" ]
}

@test "Precondition: is read strictly and counts beside Consumes:" {
  plan_of '### Step 1: a
Needs: nothing.

### Step 2: b
Precondition: step 1 finished.

### Step 3: c
Precondition: nothing.

### Step 4: d
Consumes: nothing.
Precondition: step 1.

### Step 5: e
Precondition: step 1 deployed; signed step 12 merged.'
  run --separate-stderr "$PR" "$PLAN"
  [ "$output" = "1${T}a
3${T}c" ]
  [ "$stderr" = "step 5: also needs: deployed; signed step 12 merged" ]
  run --separate-stderr "$PR" "$PLAN" 1
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
Needs:'
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

@test "steps found but no candidates: exit 1, nothing on stderr" {
  plan_of '### Step 1: a
Needs: nothing.

### Step 2: b
Needs: step 1.'
  run --separate-stderr "$PR" "$PLAN" --running 1
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "a step that needs itself, or a cycle among unverified steps, goes to stderr and is never listed" {
  plan_of '### Step 1: a
Needs: nothing.

### Step 2: b
Needs: step 2.

### Step 3: c
Needs: step 4.

### Step 4: d
Needs: steps 3 and 5.

### Step 5: e
Needs: step 3.

### Step 6: f
Needs: step 1.'
  run --separate-stderr "$PR" "$PLAN" 1
  [ "$status" -eq 0 ]
  [ "$(ids)" = "6 " ]
  [ "$stderr" = "step 2: needs itself
steps 3, 4, 5: cycle" ]
  run --separate-stderr "$PR" "$PLAN" 1 6
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  # a cycle is only a cycle among steps not yet verified
  run --separate-stderr "$PR" "$PLAN" 1 6 4
  [ "$(ids)" = "3 " ]
  plan_of '### Step 1: a
Needs: step 2.

### Step 2: b
Needs: step 1.'
  run --separate-stderr "$PR" "$PLAN"
  [ "$status" -eq 2 ]
  [ "$stderr" = "steps 1, 2: cycle" ]
}

@test "a section a fence swallowed: its step needs itself, and a table step with no section of its own is named" {
  plan_of '| Step | Needs |
|---|---|
| 1 | none |
| 2 | 1 |
| 3 | 1 |

### Step 1: a
Needs: nothing.

```
### Step 2: b
Needs: step 1.

### Step 3: c
Needs: step 3.'
  run --separate-stderr "$PR" "$PLAN" 1
  [ "$status" -eq 0 ]
  [ "$(ids)" = "2 3 " ]
  [ "$stderr" = "step 2: no section of its own
step 3: no section of its own" ]
  plan_of '### Step 1: a
Needs: nothing.

```
### Step 2: b
Needs: step 1.'
  run --separate-stderr "$PR" "$PLAN"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$stderr" = "step 1: needs itself" ]
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
Consumes: step 9.

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
