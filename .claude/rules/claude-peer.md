---
paths:
  - "**/bin/executable_claude-peer"
  - "**/tests/claude-peer.bats"
---

# Claude peers (one tab, several Claudes)

`bin/claude-peer` puts more Claudes in **one** tab as iTerm2 Workgroup peers
(the peer bar, ⌥⇧⌘1…), each on its own worktree. A peer's shell starts in the
leader's cwd and is pinned there, so the script moves, not the shell:
`claude-peer run [branch] [-- claude args…]` makes or reuses
`<repo>/.claude/worktrees/<slug>` by `workset checkout`'s rules (ported from
`worktabs`), `cd`s there and `exec`s an interactive shell running `claude`, so
it is the `.functions` wrapper and, being a directory no other session is in,
raises no second-session question. With no branch it makes (or, when clean
and still detached, reuses) a scratch worktree `peer-N` detached at
`origin/HEAD`: the branch is Claude's to create once it knows what it is
working on, so no branch exists for no reason. `path` and `plan` are the dry
runs. The
script deploys on every machine class — those three need only git; the iTerm2
verbs refuse off macOS.

The definition is a **second** Workgroup, `Claude Peers` (Chat, Diff, Chat 2-4,
Hermes; the Chat peers' command is `claude-peer run`, the last one's
`claude-peer hermes`), never extra peers on the builtin:
peers spawn at entry and the builtin is entered on every `claude` job.
`claude-peer install` writes it into the `Workgroups` key (JSON in a data
value), refuses while iTerm2 runs, and edits the custom prefs folder's plist
when `LoadPrefsFromCustomFolder` is on, else the domain. Both are forced:
launch replaces the domain's syncable keys from the folder
(`iTermRemotePreferences.m:1636-1660`) and quit writes the folder back
(`:1768-1830`), so `defaults write` or an edit while iTerm2 runs is lost. That
plist is tracked here and rewritten by iTerm2 at every quit, so the edit is
the same drift as any save and is not committed back. `status` prints
`store:`, `iterm2:`, `workgroup:` and `builtin:`. `workgroup:` compares the
installed definition's sessions (identifier, name, command) with what
`build()` would write now over the same store and says `installed, out of date
(...); this version defines N (...)` when they differ: the script gained a
session, or the builtin Diff it copies changed, since `install` last ran.

`claude-peer default peers` makes it the default instead. It points every
profile's Enter Workgroup trigger (the one iTerm2's onboarding fires on a
`claude` job) from `builtin.claudeCode` at `claudePeer.workgroup`, so every
claude tab enters Claude Peers. That is the eager-spawn trade above, taken on
purpose: each claude tab starts Chat 2-4 and Hermes at once, three more
Claudes, each in its own scratch `peer-N` worktree, plus the Hermes pane. `default builtin` switches it back. It
needs iTerm2 quit, as `install` does, and moves only triggers aimed at one of
the two workgroups. `status` prints a `default:` line that reads `builtin`,
`peers` or `mixed`. iTerm2's own Reinstall of the integration rewrites these
triggers, and `mixed` or `builtin` afterwards is the sign that happened.
Dynamic profiles that inherit from Default (worktabs' `Workspace`) follow
Default.

Use: a plain tab, Shell > Workgroups > Claude Peers (no API, sdef or `it2`
verb enters one), then type `claude` in Chat. **Exit hazard:** the Exit
trigger is `leaderOnly`, so the leader's `claude` ending tears the group down
and terminates the peers; worktrees and transcripts survive, `claude-peer run
<branch>` then `claude --continue` resumes (a scratch peer: `cd` into its
`peer-N` and `claude --continue`, since a dirty one is skipped, not reused). The Session Status tool lists
buried peers, one row each, and a click swaps the peer in; keep *Merge
workgroup statuses* **off** (on, four Claudes are one row). Rows read `[group]
<repo>` for the leader and `<repo>@<slug>` for peers (no group prefix:
`WORKTABS_GROUP` is not inherited).

**Scratch peers are safe to start together.** With `default peers` the
scratch path is the normal one, and Chat 2-4 start in the same instant
(iTerm2 spawns every peer in one loop at entry), so it is built for that.
`scratch_checkout` runs under a per-repo lock, a symlink
`<git common dir>/claude-peer.lock` whose target is the holder's pid (`ln -s`
is atomic; no `flock` on macOS), and a dead holder's lock is broken. Every
`run` also writes a **claim**, `claude-peer.claim` in the worktree's own git
directory: line 1 the pid of the `run` (`exec` keeps it, so it becomes the
shell that parents claude), line 2 the leader's directory. A claim whose pid
answers `kill -0` means the worktree is **in use**, and a scratch peer skips it
as it skips a dirty one. Claims are never deleted; a dead pid is simply not
live, and the file goes with the worktree. `claude-peer peers [--leader <dir>]
[<dir>]` prints `worktree<TAB>pid<TAB>leader` for each live claim in the
repository, on every OS. Residual: breaking a stale lock is not atomic, so two
waiters racing at the instant a holder was killed can still collide; the
claim's re-read is the backstop. The iTerm2 Enter trigger matches the job name
only, so `claude --version` in a tab enters the group too: a scratch peer
therefore settles `CLAUDE_PEER_SETTLE` seconds (default 2, 0 disables) before
it makes anything, so a short job costs nothing, and runs `git worktree add`
immune to hangup so a pane torn down mid-checkout leaves no half-made tree.
Outside a repository a scratch peer prints one line and leaves a plain shell
(a branch argument still dies). `status` adds `scratch: <n> peer-N worktrees
in <repo> (<a> in use, <k> kept: dirty, on a branch or directory gone, <f>
free)` when run inside a repository.

**The Hermes peer** is a plain shell unless a Hermes profile routes the
directory. `claude-peer hermes [-- hermes args…]` needs no repository, makes no
worktree, writes no claim and sets no `CLAUDE_PEER_WORKTREE`; it settles
`CLAUDE_PEER_SETTLE` seconds, then `exec`s an interactive shell that calls the
zsh function `hermes_peer` (see `hermes.md`: the gate is
`hermes_profile`, so no account name is tested here) and then stays a shell
whatever that did, so the pane ends at a prompt, never at iTerm2's restart
banner. A shell without `hermes_peer` (the installed definition is newer than
the deployed functions) says so and stays a shell. Where `hermes.worktree` is
on, each Hermes start fetches the base branch and creates
`<toplevel>/.worktrees/hermes-<id>` plus a branch, removed at exit unless it
holds unpushed commits (leftovers are reaped by the next start once a day old),
and Hermes appends `.worktrees/` to the tracked `.gitignore` of whichever
checkout the leader stands in, once, if that line is missing (Hermes 0.19.0
`cli.py`). The Hermes peer has no Session Status row (rows come from Claude
Code hooks) and is not part of the leader's roll-call.

**One Diff only, and it is the leader's.** Peers of peers never spawn and the
git poller follows the leader's PWD, so a peer's uncommitted work is visible
only from inside its Chat; its commits show by typing `main..<branch>` in the
Diff's base selector. Tests: `tests/claude-peer.bats` (stub ps/uname/defaults,
fixture plists; the real store is only touched by the operator's `install`).
