---
paths:
  - "**/.github/rulesets/**"
  - "**/tests/ruleset.bats"
---

# merge-gate

`.github/rulesets/main.json` is the ruleset that stands between a pull
request and `main`. It requires the five CI checks (`test (ubuntu-latest)`,
`test (macos-latest)`, `test-bootstrap`, `test-rocky`, `test-wsl`) and
requires the branch to contain main's tip ("up to date"). It has no bypass
actor, so the owner, `--admin` and a direct push are held to it too. Main
takes only pull-request merges, so nothing was lost by that.

Why it exists: two pull requests, each green against a main that did not hold
the other, merged four seconds apart and left main red. Without the ruleset
gh merges a red or pending pull request without complaint. A merge queue
would do the same job but needs an organization-owned repository.

## What gh prints

With the ruleset on, `gh pr merge` refuses a red or pending pull request
("the base branch policy prohibits the merge") and a stale one ("the head
branch is not up to date with the base branch"), and exits non-zero. Never
`--admin`.

## Landing a pull request

    gh pr update-branch <n>
    gh pr merge <n> --auto --merge --delete-branch

`update-branch` merges main into the head; `--auto` waits for the checks and
merges by itself. Each merge makes every other open pull request stale, so
several green pull requests land one CI run (about 15 minutes) apart.

## Changing it

The test keeps the JSON and `.github/workflows/tests.yml` in step: every
context is a job id, with its matrix value as a suffix, and every job is a
context. Changing a job id or matrix value changes the JSON in the same pull
request, and the new JSON is applied just before that pull request merges
(its own checks carry the new names):

    gh api -X PUT repos/{owner}/{repo}/rulesets/<id> --input .github/rulesets/main.json

A `paths:` filter on the workflow's `pull_request:` trigger leaves a required
check unreported and the pull request unmergeable for ever; the test refuses
it.

Nothing in CI sees GitHub's side. To compare, read the live rules:

    gh api repos/{owner}/{repo}/rules/branches/main

A deliberate force-push of main needs `enforcement` set to `disabled` for
that push, and back.

## Where it does not apply

A private overlay may have no such gate: rulesets on a private repository
depend on the owner's plan, and an overlay may carry no CI. There the rule is
the habit: one pull request at a time, its branch containing the base, its
tests green on that head.
