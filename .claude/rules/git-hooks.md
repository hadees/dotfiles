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
which BSD grep drops). A force-push is not visible to a hook as a flag, so
it is inferred the way git decides one is needed: the remote's commit is no
longer an ancestor of what is being pushed.

Two details are load-bearing. git hands the hook the remote's **live** sha,
read over the push connection, so on a shared branch it is routinely a
commit this clone has never fetched — the scan falls back to "everything
this remote has not got" rather than letting `rev-list` fail into an empty,
silently passing range, which is how a gate like this quietly disarms on
exactly the branches that need it. And `GIT_PUSH_CHECK=0` bypasses both
gates for one push but still **chains**: the ref list is drained before the
bypass, so `hook.pre-push.run` — where the private overlay hangs its leak
guard — runs on a forced push too. That is not this gate's to switch off.
It also has no opinion on a ref deletion. Unlike `run-local-hook` it must
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
