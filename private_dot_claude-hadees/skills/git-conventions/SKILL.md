---
name: git-conventions
description: Personal git workflow conventions for branching, committing, pushing, and opening PRs. Use whenever you are about to create a commit, push, force-push, open a pull request, or merge one in a personal repo (any session running in this profile). Layers on top of the commit-commands plugin (commit, commit-push-pr) — that plugin handles the mechanics; this skill supplies the house style.
---

# Personal Git Conventions

These apply to every change in a personal repo. The commit-subject dialect
below is deliberately the same one the work conventions use — one habit is
easier to keep than two — but the branching rules here are looser, and the
flavor table carries no work-domain entries.

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

## Commit subjects: Conventional Commits + emoji

Subjects follow [Conventional Commits](https://www.conventionalcommits.org/)
so the history stays machine-parseable (semantic-release, changesets,
release-please and commitlint all read it). Each subject leads with the
type-anchor emoji for its type:

```
<type-emoji> <type>: <subject>                                # minimal
<type-emoji> <type>: <flavor-emoji> <subject>                 # with flavor
<type-emoji> <type>: <flavor-emoji> <flavor-emoji> <subject>  # two flavors (the max)
<type-emoji> <type>!: <subject>                               # breaking change
```

The subject itself stays one clear imperative sentence. Semicolons are fine
when a commit legitimately carries two related changes, but prefer splitting
(see below).

### Type anchors (required, one per type)

| Anchor | Type        | When to use                                          |
| ------ | ----------- | ---------------------------------------------------- |
| ✨     | `feat:`     | New feature or capability                            |
| 🐛     | `fix:`      | Bug fix                                              |
| ♻️     | `refactor:` | Behavior-preserving rework                           |
| 📝     | `docs:`     | Docs-only changes                                    |
| ✅     | `test:`     | Tests added or updated                               |
| 🧰     | `chore:`    | Tooling, deps, repo housekeeping                     |
| ⚡     | `perf:`     | Performance improvement                              |
| 🎨     | `style:`    | Formatting with no behavior change                   |
| 👷     | `ci:`       | CI/CD changes                                        |
| 📦     | `build:`    | Build system / packaging                             |
| ⏪     | `revert:`   | Reverts a prior commit                               |

For a breaking change append `!` to the type (`✨ feat!: drop the bash 3.2
fallback`) or add a `BREAKING CHANGE:` footer; the spec recognizes both.

### Flavor gitmojis (optional)

After the colon, add a flavor emoji when it says something the type alone
doesn't — urgency, subject area, side effect. Skip it when the type already
carries the message. A second flavor (two is the cap) is for the commit where
one emoji can't say both what kind of work it was and what it touched; then
the first is the marker (⚗️ experiment or study) and the second the area.

**The full table lives in `references/flavors.md`. Read it when picking a
flavor; don't guess from memory.**

```
✨ feat: 🚩 put the new prompt behind a flag
🐛 fix: 🚑️ undo the regression that broke every shell
🧰 chore: ⬆️ bump the pinned bats version
📝 docs: 💡 explain why op-ssh-sign ignores SSH_AUTH_SOCK
✨ feat!: drop the bash 3.2 fallback
```

**Reserved as type anchors:** ✨ 🐛 ♻️ 📝 ✅ ⚡ 🎨 👷 📦 ⏪ 🧰 never appear as
flavors — they describe the *kind* of change, which the type already
captures. Reaching for one usually means the concept you want has its own
flavor: 🎨 as "figure" is 🖼️, ✅ as "validation" is 🦺. If none fits and the
anchor genuinely describes a second kind of change, the commit is doing two
things — split it.

### Validate the subject before committing

`scripts/check-subject.sh` (relative to this skill) checks a drafted subject
deterministically: anchor/type pairing, flavor membership, reserved-anchor
misuse, non-empty text. Run it on every subject you draft:

```bash
printf '%s\n' '✨ feat: 🚩 put the new prompt behind a flag' | <skill-dir>/scripts/check-subject.sh -
```

Exit 0 means valid; otherwise it prints exactly what is wrong. It also takes
a commit-message file as its argument, so it installs as a per-repo hook:

```bash
cp <skill-dir>/scripts/check-subject.sh .git/hooks/commit-msg
```

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
