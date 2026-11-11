---
paths:
  - "**/bin/executable_claude-peer"
  - "**/tests/claude-peer.bats"
---

# Claude peers (one tab, several Claudes)

`bin/claude-peer` puts more Claudes in **one** tab as iTerm2 Workgroup peers
(the peer bar, ⌥⇧⌘1…), each on its own worktree. A peer's shell starts in the
leader's cwd and is pinned there, so the script moves, not the shell:
`claude-peer run --as <slot> [-- claude args…]` takes the slot's worktree
`<repo>/.claude/worktrees/<slot>`, `cd`s there and runs `claude -n <repo>-<slot>`
through an interactive shell, so it is the `.functions` wrapper and, being a
directory no other session is in, raises no second-session question. A slot is a
name (`alpha`, `beta`, …; lowercase letters, digits, `-` and `_`), and its
worktree is the slot's: new, it is detached at `origin/HEAD` (the branch is
Claude's to create once it knows what it is working on); afterwards it is
reused in whatever state it was left, dirty or on a branch, with nothing
reset. `run <branch>` does the same on `<repo>/.claude/worktrees/<slug>` and a
branch, by `workset checkout`'s rules (ported from `worktabs`). `path` and
`plan` are the dry runs. A bare `run` is a pane of a definition that predates
slots: it prints one line and leaves a plain shell, so an installed old
definition costs three plain shells per claude tab instead of three Claudes.
The script deploys on every machine class — those three need only git; the
iTerm2 verbs refuse off macOS.

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
purpose: each claude tab starts Chat 2-4 and Hermes at once. `default builtin` switches it back. It
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
<branch>` or `run --as <slot>` then `claude --continue` resumes. The Session Status tool lists
buried peers, one row each, and a click swaps the peer in; keep *Merge
workgroup statuses* **off** (on, four Claudes are one row). Rows read `[group]
<repo>` for the leader and `<repo>@<slug>` for peers (no group prefix:
`WORKTABS_GROUP` is not inherited).

**Slots are safe to start together.** Taking a slot (`slot_checkout`) runs
under a per-repo lock, a symlink `<git common dir>/claude-peer.lock` whose
target is the holder's pid (`ln -s` is atomic; no `flock` on macOS), and a dead
holder's lock is broken. Every `run` writes a **claim**, `claude-peer.claim` in
the worktree's own git directory: line 1 the pid of the `run`, line 2 the
leader's directory (where `run` started), line 3 the label (`Alpha`; the slug
for a branch peer). `run` is not an `exec`: it runs claude as a child and
removes the claim when the child returns, however it ended, so a claim whose
pid answers `kill -0` means **a Claude is running there now**. A slot with a
live claim is refused (exit 3, `in use by the peers of <leader> (pid <n>)`);
anything else is taken as it stands. A registered slot whose directory is gone,
or a plain directory in its place, is refused with the fix in the message;
nothing is pruned for you. A `run` killed outright leaves a claim with a dead
pid, which is simply not live. `claude-peer peers [--leader <dir>] [<dir>]`
prints `worktree<TAB>pid<TAB>leader<TAB>label` for each live claim in the
repository, on every OS. Residual: breaking a stale lock is not atomic, so two
waiters racing at the instant a holder was killed can still collide; the
claim's re-read is the backstop. `git worktree add` runs immune to hangup so a
pane torn down mid-checkout leaves no half-made tree. `status` adds `peers: <r>
running, <w> waiting in <repo>` with the running labels when run inside a
repository, and
`leftover: <k> peer-N worktrees from the retired scratch layout (...)` when
registered `peer-N` worktrees remain; nothing uses or removes them any more
(`git worktree remove <path>`).

**A pane waits until it is told.** `claude-peer run --as <slot> --wait` is
what a slot pane runs: it prints `<Label>: Return starts a Claude here, c
continues the last session, q leaves a shell` and makes no worktree, claim or
Claude until it is woken. Return starts a fresh session, `c` one with
`--continue`, `q` (or Ctrl-C) removes its wait file and leaves a plain shell,
anything else asks again; when the session ends for any reason the claim goes
and the pane waits again, so a pane never ends. A waiting pane owns
`<git common dir>/claude-peer.wait/<slot>.<pid>` (line 1 the leader's
directory); the next pane to register deletes the files of dead pids. Outside a
repository the pane prints one line and leaves a plain shell. `git config
claude-peer.start auto` (read in the starting directory; the public repo sets it
nowhere) makes a pane settle `CLAUDE_PEER_SETTLE` seconds (default 2, 0
disables), start one fresh session, then wait like any other.

The wait is a trapped signal, not a poll. The pane blocks in `wait` on a
background reader of one line from `${CLAUDE_PEER_TTY:-/dev/tty}` (a long
`sleep` when there is no terminal, so only a request wakes it), and `USR1`
interrupts a trapped `wait` at once in every shell this runs under (`/bin/sh` is
bash 3.2 on macOS, dash on Linux); a trapped signal does not reliably interrupt
`read` in bash 3.2, and a once-a-second poll would fork in every pane of every
tab. Whole lines, not one keypress, because a single key needs `stty -icanon`,
a terminal state that has to be restored on every exit path. The pane ignores
`TTIN` and `TTOU`, so a reader that finds the terminal taken fails instead of
stopping and the pane falls back to request-only waiting; its claude gets them
back. TERM and HUP kill the reader and delete the wait file.

**The pool.** A pane's slot is a preference. The pool is the words of `git
config claude-peer.slots` (default `alpha beta gamma delta epsilon zeta eta theta
iota kappa lambda mu`); its first three are the bar's names. A pane takes its
own slot when no Claude runs in it, else the first free name from the pool's
fourth on, and only then a free one of the first three, so one tab is always
Alpha, Beta, Gamma under their labels and a second tab gets Delta, Epsilon,
Zeta, never a name from under the first. It prints the name it took, and `(this
pane's Alpha is in use by the peers of <leader>)` when that differs. With every
name taken it prints `all <n> slots are in use in <repo>` and `Return tries
again`, and waits. `next` is not a slot name.

**`start`, `stop` and `slots` are the operator's.** A session runs them only when
asked. `claude-peer start <slot|next> [--continue] [--leader <dir>] [--]
[prompt words…]` writes a request file (`<slot>.<pid>.start`: line 1 `fresh` or
`continue`, line 2 the slot or `-` for the pane's own rule, the rest the prompt)
beside the pane's wait file, sends `USR1` (again once a second while the file is
there; a signal that lands before the pane's `wait` begins is lost), and polls up
to `CLAUDE_PEER_START_WAIT` seconds (default 60) for a claim held by that pane.
The prompt is one argument, last, never re-parsed by a shell; `-` reads it from
stdin, and one that begins with `-` is a usage error. With several leaders'
panes waiting only those of `--leader` (default the caller's directory) are
candidates; the pane whose own slot is the one asked for wins, else the first
by label. `stop <slot> [--force]` sends TERM to the claude under the claim's pid
whose `sessions/<pid>.json` record, in `$CLAUDE_CONFIG_DIR` or a
`claude.profile.*` directory, says `idle` (that layout is observed, not an
interface); a busy or unknown session is refused unless `--force`, which stops
every process under the claim. The worktree and transcript are never touched.
`slots [<dir>]` prints `slot<TAB>running|waiting<TAB>worktree<TAB>pid<TAB>
leader<TAB>session name` for the repository. Exit codes: 0 done; 1 failed; 2
usage; 3 already in the requested state (running, not running, no slot free);
4 nothing to act on (no pane waiting); 5 refused because busy.

**The Hermes peer** is a plain shell unless a Hermes profile routes the
directory. `claude-peer hermes [--wait] [-- hermes args…]` needs no repository,
makes no worktree, writes no claim and sets no `CLAUDE_PEER_WORKTREE`; it
settles `CLAUDE_PEER_SETTLE` seconds (with `--wait`, unless `claude-peer.start`
is `auto`, it exports `CLAUDE_PEER_HERMES_WAIT=1` instead and does not settle,
`hermes_peer` asking for Return), then `exec`s an interactive shell that calls the
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
