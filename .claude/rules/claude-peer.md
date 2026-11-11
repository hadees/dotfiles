---
paths:
  - "**/bin/executable_claude-peer"
  - "**/dot_config/claude-peer/**"
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

The definitions are **two more** Workgroups, never extra peers on the builtin:
peers spawn at entry and the builtin is entered on every `claude` job.
`Claude Peers` (`claudePeer.workgroup`) is Lead, the root, and the peers Alpha,
Beta and Gamma, whose commands are `claude-peer run --as <slot> --wait`.
`Claude Peers + Hermes` (`claudePeer.h`, session ids under `claudePeer.h.`) is
the same four plus a Hermes peer running `claude-peer hermes --wait`. There are
two because a pane cannot remove itself: a member whose program exits stays as
an ended pane with a restart offer, and closing a member exits the whole group,
so a repo where no Hermes profile routes must be given the definition without
the pane, chosen before entry. There is no Diff peer, and nothing is copied
from `builtin.claudeCode`; the builtin is never edited. In code `build_base`
returns the four sessions for an id prefix and `with_hermes` the twin of a
definition. `claude-peer install` writes both into the `Workgroups` key (JSON
in a data value; replace by id, else append), refuses while iTerm2 runs, and
edits the custom prefs folder's plist when `LoadPrefsFromCustomFolder` is on,
else the domain. Both are forced:
launch replaces the domain's syncable keys from the folder
(`iTermRemotePreferences.m:1636-1660`) and quit writes the folder back
(`:1768-1830`), so `defaults write` or an edit while iTerm2 runs is lost. That
plist is tracked here and rewritten by iTerm2 at every quit, so the edit is
the same drift as any save and is not committed back. `status` prints
`store:`, `iterm2:`, `workgroup:`, `hermes:` and `default:`, and inside a
repository `peers:`. It reads the store that is true at that moment: the
preferences domain while iTerm2 runs (its memory is what counts; the folder
file is only written at quit) and the store `store:` names while it is quit, so
it agrees with what `install` just wrote. `workgroup:` and `hermes:` each
compare the installed definition's sessions (identifier, name, command) with
what this version builds and say `installed, out of date (...); this version
defines N (...)` when they differ (the script changed since `install` last
ran), or `not installed`.

**How a tab gets its workgroup.** The `claude` job trigger names one workgroup
per iTerm2 profile, and an iTerm2 profile says nothing about the repo, so the
choice is the `claude()` wrapper's, made before the job starts. It sets the
session variable `user.claudePeerEnter` (an OSC 1337 `SetUserVar` escape,
written to the terminal) to `<key>:<nonce>`, and one variable-changed Enter
Workgroup trigger per workgroup, matching `^<key>:`, enters it. The keys:
`claudePeer.workgroup` is `base`, `claudePeer.h` is `base/hermes`,
`claudePeer.v.<name>` is `<name>` and `claudePeer.v.<name>.h` is
`<name>/hermes`. `claude-peer here` prints the key for the directory (today
always `base`); the wrapper adds `/hermes` where `hermes_profile` routes it,
the gate `hermes_peer` uses. The nonce (`$EPOCHREALTIME`) makes a second launch
in one tab a second change; whether it enters again after the workgroup was
exited is live check L15. The wrapper sends the key only **after** the
second-session question has been passed (an `n` sends nothing and launches
nothing) and only for a launch that question applies to (an attended one, so
never under `-p`, a subcommand or a pipe), with `$ITERM_SESSION_ID` set,
`$CLAUDE_PEER_WORKTREE` unset (a peer's own Claude must not try), the state file
below readable and `~/bin/claude-peer` executable; any failure launches without
it. `claude-doctor` prints `workgroup: <key>` or `not set (<why>)` from the same
helper (`claude_peer_key`).

`claude-peer default peers` turns this on, in every profile that has the
`claude` Enter trigger: it **disables** that job trigger (kept in place,
parameter untouched), writes one variable trigger per installed workgroup of
ours, and writes `${XDG_STATE_HOME:-~/.local/state}/claude-peer/enter` (one line,
`peers`), the file the wrapper looks for. `default builtin` removes those
triggers, re-enables the job trigger aimed at `builtin.claudeCode` and removes
the file; `install` keeps the triggers matching the installed workgroups while
the file exists. The triggers are written by `claude-peer` alone, with iTerm2
quit like `install`, into the preferences: the Settings window saves this
trigger without its variable name and pattern and it never fires, so nobody is
ever asked to type one. A trigger it did not write is never touched. The cost
of disabling the job trigger: a `claude` not started through the wrapper
(`command claude`, an editor terminal) enters no workgroup, and `claude
--version` no longer does either. Because a slot pane waits, entering costs
three blocked `sh` processes per tab and no Claude, row, registry record or
worktree until a peer is started; where Hermes routes, one idle shell more.
`status` prints `default:` as `peers (<n> profiles, <k> workgroups by
variable)`, `builtin` or `mixed`, and a second line when the enter file and the
triggers disagree (the file missing means the wrapper sends nothing; iTerm2's
own Reinstall of the integration rewrites triggers). Dynamic profiles that
inherit from Default (worktabs' `Workspace`) follow Default.

Use: a plain tab, Shell > Workgroups > Claude Peers (no API, sdef or `it2`
verb enters one), then type `claude` in Lead. **Exit hazard:** the Exit
trigger is `leaderOnly`, so the leader's `claude` ending tears the group down
and terminates the peers that were started (a waiting pane has nothing to lose); worktrees and transcripts survive, `claude-peer run
<branch>` or `run --as <slot>` then `claude --continue` resumes. The Session Status tool lists
buried peers, one row each, and a click swaps the peer in; keep *Merge
workgroup statuses* **off** (on, four Claudes are one row). Rows read
`<repo> ▸ Lead` for the leader once a peer is running and `<repo> · <Label>`
for peers, both from `tabname` (see the cc-status shim paragraph on roles).

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

**`start` and `stop` are the operator's.** A session runs them only when
asked; `slots` and `log` only read or append, and the shared memory tells every
session to use them (announce a task when `slots` shows another slot running,
read `log show` before a machine-wide action). `claude-peer start <slot|next> [--continue] [--leader <dir>] [--]
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
whose `sessions/<pid>.json` record, in `$CLAUDE_CONFIG_DIR`, Claude Code's own default `~/.claude` (what an unset one means) or a
`claude.profile.*` directory, says `idle` (that layout is observed, not an
interface); a busy or unknown session is refused unless `--force`, which stops
every process under the claim. The worktree and transcript are never touched.
`slots [<dir>]` prints `slot<TAB>running|waiting<TAB>worktree<TAB>pid<TAB>
leader<TAB>session name` for the repository. Exit codes: 0 done; 1 failed; 2
usage; 3 already in the requested state (running, not running, no slot free);
4 nothing to act on (no pane waiting); 5 refused because busy.

**A peer is a separate project, not a helper of the leader.** It has its own
context, branch and pull requests, and plans and delegates inside itself like any
session; `start` passes its prompt through untouched and nothing here briefs,
merges or supervises a peer. The one shared thing is the coordination log,
`<git common dir>/claude-peer.log`, so every worktree of the repository reads the
same file and it outlives any session. It is append-only, one line per entry,
tab-separated: `<UTC time><TAB><who><TAB><kind><TAB><text>[<TAB><path>…]`, with
tabs and newlines in text and paths written as spaces. `kind` is `claim`, `note`,
`done`, `start` or `stop`. `who` is the label of the slot whose worktree the
caller stands in (a live claim), else `Lead` when a live claim names the caller's
directory as its leader, else the directory's name; `log --as <name> …` overrides
it. `log claim <task> [-- <path>…]` appends a claim and then prints, for every
open claim of someone else that shares a path (equal, or one a directory prefix
of the other, paths taken relative to the repository top; `.` is all of it),
`overlap<TAB><who><TAB><their path><TAB><their task>`; it exits 0 whether or not
anything overlaps, because a claim is advisory and a non-zero exit reads as
"blocked". `log note <text>` and `log done [<text>]` append those kinds. A claim
is open until the same `who` logs `done`, or a `stop` line for that label
follows it, so a stopped peer never leaves a claim open. `log
show` prints the open claims and the last 24 hours of notes, `--all` the file.
`start` and `stop` each append `<label> by <who>`. The log is per repository: an
action that reaches the whole machine is not visible from another repository's
log. `..` in a path is not resolved.

**Contexts** are small text files that say how a peer is started: `key: value`
header lines (`title`, `ask`, `agent`, `model`, `effort`, `system`, `mode`), an
empty line, then the body, which is the first prompt (`{input}` is replaced by
the value, or the value is appended after a blank line). They live under
`$CLAUDE_PEER_CONTEXTS`, else `~/.config/claude-peer/contexts/`, at three
levels read in this order: the top (every repository), `<owner>/`, and
`<owner>/<repo>/`, where `<owner>/<repo>` is the lowercase slug of the main
checkout's origin (`origin_slug`; a worktree shares it, a repository with no
usable origin reads the top only). A file is `[NN-]<name>.ctx`; a deeper file of
the same name replaces a shallower one and takes the later position. An invalid
file (unknown key, a value that could read as a flag, a header line without
`: `, a `repo:` key) is skipped by `context list` with a stderr line and fails
`context show`. `claude-peer context list|show|dir` only reads. `origin_slug` is
ported from the one in `bin/executable_postbox`.

`claude-peer start <slot|next> [--leader <dir>] --context <name> [value words…]`
(`-` reads the value from stdin) starts a peer from a context. `start` resolves
the context for its repository before waking anything and fails at the caller:
unknown or invalid is 1, `--context` with `--continue` is 2 (a context carries
its own mode), a context with `ask` and no value is 2. The request file is the
plain one (mode from the context, the value as the rest); a sidecar
`<slot>.<pid>.meta` (`by=…`, `context=…`) is written first, and the pane looks
the context up itself (a file deleted in between: the pane prints why and waits
on). A pane writes `2` as line 2 of its wait file; `start --context` to a pane
without it is exit 4 (`predates contexts; reopen its tab`), a plain `start` to
it works. `pane_go` is the one place that builds the `claude` arguments, in this
order: `-n <repo>-<slot> [--continue] [definition args] [--agent A] [--model M]
[--effort E] [--append-system-prompt S] [prompt]`; it reads `PG_CTX`,
`PG_CTXNAME`, `PG_BY` and `PG_TASK` and clears them. The claim gains lines 4-7:
who started it (`Lead`, a slot label, a directory name, `pane` for Return, `-`
unknown), the context name or `-`, the task line (at most 80 characters) or `-`,
and the start time in epoch seconds; lines 1-3, `peers` and the session name are
unchanged. The pane's header line is the slot's label, then ` · started by <by>`
(not for Return) and ` · <task>`.

The public source ships seven top-level contexts, `dot_config/claude-peer/contexts/NN-<name>.ctx`
(`ask`, `look-at`, `plan`, `prs`, `audit`, `catch-up`, `team`), which deploy on every class but
`ephemeral`. They name no account, organisation, person or private repository or skill; an
overlay's file of the same name at the owner or repository level replaces one (the personal
overlay does this for `audit`). A context is a launcher: it points at a skill or a document
and restates no procedure. `{owner}` and `{repo}` in `40-prs.ctx` are gh's own placeholders,
typed literally, and only `{input}` is substituted. The lookup rule is the one above: top,
`<owner>/`, `<owner>/<repo>/`, a deeper file wins by name.

**The Hermes peer** exists only in `Claude Peers + Hermes`, and is a plain shell
unless a Hermes profile routes the directory; the gate below is now the second
line of defence, speaking only when somebody enters that definition by hand
where nothing routes. `claude-peer hermes [--wait] [-- hermes args…]` needs no repository,
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

Tests: `tests/claude-peer.bats` (stub ps/uname/defaults,
fixture plists; the real store is only touched by the operator's `install`).
