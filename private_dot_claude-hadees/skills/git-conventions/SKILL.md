---
name: git-conventions
description: Personal git workflow conventions for branching, committing, pushing, and opening PRs. Use whenever you are about to create a commit, push, force-push, open a pull request, or merge one in a personal repo (any session running in this profile). Layers on top of the commit-commands plugin (commit, commit-push-pr) — that plugin handles the mechanics; this skill supplies the house style.
---

# Personal Git Conventions

These apply to every change in a personal repo. They are deliberately not the
work conventions — no Conventional Commits prefixes, no emoji anchors.

## Branch + PR for non-trivial changes

- Branch name shape: `<type>/<descriptive-slug>` — e.g. `feat/claude-code-profiles`,
  `chore/split-identity-to-private-overlay`, `fix/gitconfig-https-work-identity`.
- Trivial one-file tweaks may commit directly to `main` when the repo's
  history shows that pattern; anything with more than one moving part gets a
  branch and PR, even when self-merged — the PR is the record of the work.
- **Never squash-merge.** Merge with a merge commit and clean up:
  `gh pr merge <N> --merge --delete-branch`. A repo whose history is
  deliberately linear may rebase instead (`--rebase --delete-branch`); match
  what the repo already does (`git log --oneline --merges -n 10`).
- Squash-merge earned its place hiding human WIP noise — "fix typo", "oops",
  "actually fix typo". Agent-written branches don't have that noise: the
  commits are already atomic and each message already explains its why. So
  squashing now destroys information instead of tidying it, and it silently
  undoes the atomic-commit rule below.
- GitHub creates every repo with squash enabled and has no account-wide
  switch, so it is a per-repo flip:
  `gh api -X PATCH repos/<owner>/<name> -F allow_squash_merge=false`.
- PR bodies tell the story: what changed, why, what was verified. A test plan
  section with checkboxes when there is one.

## Commit subjects: plain imperative, no prefixes

- One clear sentence in the imperative: "Split Claude Code into per-account
  profiles", "Add claude-doctor and drop underscore-prefixed helper names".
- No `feat:`/`fix:` prefixes, no emoji — that is the work dialect.
- Semicolons are fine when one commit legitimately carries two related
  changes, but prefer splitting (see below).

## Commit bodies explain the why

The subject says what; the body says why it was needed and what non-obvious
thing was learned. A future reader should not need the PR or the conversation
to understand the commit. Incidents that motivated a change belong in the
body ("the first real-world failure was silent: ...").

## Atomic commits

Each commit does one conceptual thing. Wanting "and" in the subject usually
means two commits. File moves go in their own commit, separate from edits to
the moved files, so `git log --follow` stays clean.

## Force-push safely

On feature branches use `git push --force-with-lease --force-if-includes`,
never bare `--force`. Never force-push `main`.

## Tests ride with the change

A bug fix or behavior change lands with the test that would have caught it —
"whatever went wrong becomes a test so it can't happen again."
