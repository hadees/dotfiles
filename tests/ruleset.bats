#!/usr/bin/env bats

# .github/rulesets/main.json is the GitHub ruleset that keeps a red or stale
# pull request off main. GitHub's side cannot be seen from CI, so what is
# testable is the file against the workflow it names: a required check the
# workflow does not report leaves every pull request waiting for ever on
# "Expected". The workflow is read with awk (no PyYAML on every CI image), the
# JSON with python3.

ROOT="$BATS_TEST_DIRNAME/.."
RULESET="$ROOT/.github/rulesets/main.json"
WORKFLOW="$ROOT/.github/workflows/tests.yml"

# Evaluates python expression $1 against the parsed ruleset as `r`.
ruleset() {
  python3 -I -c 'import json, sys; r = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$RULESET" "$1"
}

# One required check context per line.
contexts() {
  ruleset '"\n".join(c["context"] for c in r["rules"][0]["parameters"]["required_status_checks"])'
}

# The job ids of the workflow, one per line.
job_ids() {
  awk '/^jobs:/ {on=1; next} on && /^  [A-Za-z0-9_-]+:$/ {sub(/^  /, ""); sub(/:$/, ""); print}' "$WORKFLOW"
}

@test "the ruleset targets the default branch, is active and has no bypass" {
  [ "$(ruleset 'r["target"]')" = "branch" ]
  [ "$(ruleset 'r["enforcement"]')" = "active" ]
  [ "$(ruleset 'r["bypass_actors"]')" = "[]" ]
  [ "$(ruleset 'r["conditions"]["ref_name"]["include"]')" = "['~DEFAULT_BRANCH']" ]
}

@test "the ruleset has one rule: required checks on a branch that is up to date" {
  [ "$(ruleset 'len(r["rules"])')" = "1" ]
  [ "$(ruleset 'r["rules"][0]["type"]')" = "required_status_checks" ]
  [ "$(ruleset 'r["rules"][0]["parameters"]["strict_required_status_checks_policy"]')" = "True" ]
  [ -n "$(contexts)" ]
}

@test "every required check names a job of the workflow, and its matrix value appears there" {
  local ctx job val
  while IFS= read -r ctx; do
    job="${ctx%% (*}"
    job_ids | grep -qxF "$job" || { echo "$ctx: no job '$job' in the workflow"; false; }
    if [ "$ctx" != "$job" ]; then
      val="${ctx#*(}"; val="${val%)}"
      grep -qw -- "$val" "$WORKFLOW" || { echo "$ctx: '$val' is not in the workflow"; false; }
    fi
  done < <(contexts)
}

@test "every job of the workflow is a required check" {
  local job
  while IFS= read -r job; do
    contexts | sed 's/ (.*//' | grep -qxF "$job" || { echo "job '$job' is not a required check"; false; }
  done < <(job_ids)
}

@test "the workflow runs on every pull request, so no required check goes unreported" {
  grep -q '^  pull_request:' "$WORKFLOW" || { echo "no pull_request trigger"; false; }
  ! grep -qE '^[[:space:]]+paths(-ignore)?:' "$WORKFLOW" || { echo "a paths filter leaves a required check unreported"; false; }
}
