---
paths:
  - "**/dot_git-hooks/**"
  - "**/tests/git-hooks.bats"
---

# Commit identity gate (global git hooks)

`dot_gitconfig` sets `core.hooksPath = ~/.git-hooks` (`dot_git-hooks/`).
`pre-commit` refuses a commit whose author or committer email is not one of
`identity.<account>.email` for the account the origin's owner is pinned to
(same credential pins as the wrappers; the mapping is overlay-supplied, so
a public-only clone has no opinion), or of `identity.<owner>/<repo>.email`
when that per-repo pin exists (a side project committing under its own
identity — mirrors `wrangler.<owner>/<repo>.profile`). `GIT_IDENTITY_CHECK=0` bypasses one
commit; `git-doctor` shows the verdict (`gate:`).

Above the identity gate sits the **branch gate**: `pre-commit` refuses a
commit in a claude-peer slot that has no branch yet — HEAD detached and
`branchname --state` answering `base` (a `claude-peer.base` record in the
worktree's git dir, no rebase or bisect in progress). Such a commit would
land on no branch while the prompt names the branch the slot was cut from;
the refusal names the fix, `git switch -c <type>/<slug>`. It runs **first**
because every exit of the identity gate leaves through `chain`'s `exec`;
placed after, it would never run in an unpinned repository. HEAD on a branch
is answered by `git symbolic-ref` alone, so an ordinary commit runs no helper.
It reads the state word and the ref (field 3, `refs/remotes/` or
`refs/heads/` stripped), never the label, so `branchname.detached-format`
cannot change what it says. Switches: `GIT_BRANCH_CHECK=0` for one commit,
`hook.pre-commit.branch = false` (`0`/`no`/`off`) for a repo or machine; the
two bypasses are independent of `GIT_IDENTITY_CHECK`. No helper found
(`~/bin/branchname` first, then PATH, so a stranger's unrelated `branchname`
never runs inside a commit hook) means no opinion. Not
covered: commits made by `cherry-pick`, `revert` or a rebase (the githooks
page names only `git commit` for this hook), `--no-verify`, a repository
with its own `core.hooksPath`, and a commit on the real `main` — not gated,
by decision. `git-doctor` shows it as `branch-gate:` (`on`, `on — WOULD
REFUSE: …`, `off (…)`, `inert (…)`).

`pre-push` is the other real gate there, and it refuses two publications
that cannot be taken back once a ref is on the remote: a commit still
marked **unfinished**, and a **non-fast-forward push of a protected
branch**. Mechanism here, policy in machine-local git config like
everything else opinionated in this repo — `hook.pre-push.wip = false`
turns the marker gate off, repeatable `hook.pre-push.protect` replaces the
default branch list (`main`, `master`) — so a clone with no config gets the
defaults and a stranger with a different workflow is one config line away
rather than a fork away. The marker is matched as a standalone word
anywhere in the subject, case-insensitively: Conventional Commits subjects
lead with a type, so anchoring at the start would never fire on one, and
the word boundary is what keeps `swipe` out (`[^[:alnum:]]`, not `\b`,
which BSD grep drops). A subject that starts with git's autosquash
prefixes — `fixup! `, `squash! ` or `amend! ` — counts too, anchored at the
start because that is the only place the prefix means anything; a subject
that merely mentions one passes, and the body is never read. The same
`hook.pre-push.wip = false` switches both off. A force-push is not visible
to a hook as a flag, so it is inferred the way git decides one is needed:
the remote's commit is no longer an ancestor of what is being pushed.

Two details are load-bearing. git hands the hook the remote's **live** sha,
read over the push connection, so on a shared branch it is routinely a
commit this clone has never fetched — and that state is how a gate like this
quietly disarms on exactly the branches that need it, so both gates stay
armed in it. The marker scan falls back to "everything this remote has not
got" rather than letting `rev-list` fail into an empty, silently passing
range. The force gate **refuses**: a tip missing from the object store
cannot be an ancestor of anything local, git itself rejects that push
unforced ("fetch first"), and forced it is the stale-clone-then-`--force`
sequence that drops commits nobody here has seen. It read "not fetched; no
verdict" until an audit forced a stale clone straight through it
(2026-11-11). The refusal says to fetch, after which a fast-forward passes
and a divergence gets the ordinary non-fast-forward refusal. git runs the
hook before reporting its own rejection, so a plain stale push meets the
same message; a `--force-with-lease` whose lease is stale never does — git
withholds that ref from the hook and rejects it itself. And
`GIT_PUSH_CHECK=0` bypasses both gates for one push but still **chains**:
the ref list is drained before the bypass, so `hook.pre-push.run` — where
the private overlay hangs its leak guard — runs on a forced push too. That
is not this gate's to switch off. It has no opinion on a ref deletion, and
the force gate has none on a branch the remote does not have yet. Unlike `run-local-hook` it must
not `exec` into the chain: an EXIT trap does not survive `exec`, and at one
leaked ref list per push per repo that is unbounded. Every hook name there is
a shim that first runs any `hook.<name>.run` git-config commands (repeatable,
per-repo `.git/config`; a failure blocks; each gets the hook's arguments and a
replay of its stdin — for pre-push, the refs being pushed) and then the repo's
own `.git/hooks/<name>` — via `git rev-parse --git-common-dir`, never
`--git-path hooks`, which honours `core.hooksPath` and would exec the shim
itself. Tests: `tests/git-hooks.bats` — its fixture repos must use
absolute paths for anything under `.git/`, or a relative path lands in this
clone's `.git/hooks`. Full guide: `docs/private-overlays.md`.
