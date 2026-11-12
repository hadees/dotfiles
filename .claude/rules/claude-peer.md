---
paths:
  - "**/bin/executable_claude-peer"
  - "**/dot_config/claude-peer/**"
  - "**/tests/claude-peer.bats"
  - "**/tests/claude-peer-screen.bats"
---

# Claude peers (one tab, several Claudes)

`bin/claude-peer` puts more Claudes in **one** tab as iTerm2 Workgroup peers
(the peer bar, ⌥⇧⌘1…), each on its own worktree. A peer's shell starts in the
leader's cwd and is pinned there, so the script moves, not the shell:
`claude-peer run --as <slot> [-- claude args…]` takes the slot's worktree
`<repo>/.claude/worktrees/<slot>`, `cd`s there and runs `claude -n <repo>-<slot>`
through an interactive shell, so it is the `.functions` wrapper and, being a
directory no other session is in, raises no second-session question. A slot is a
name (`alpha`, `beta`, …; lowercase letters, digits, `-` and `_`; not `next`,
`lead`, `claude` or `hermes`, and a branch whose slug is `lead` is refused),
and its
worktree is the slot's: new, it is detached at `origin/HEAD` (the branch is
Claude's to create once it knows what it is working on), and the base is
recorded in `claude-peer.base` beside the claim, once (from `origin/HEAD`;
at creation with no remote, the main checkout's branch; delete the file to
have it written again on the next start), and `branchname.md` says what reads
it; afterwards it is
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
definition. A machine with private overlays gets two more, `Claude Peers +
Overlays` (`claudePeer.v.overlays`) and `Claude Peers + Hermes + Overlays`
(`claudePeer.v.overlays.h`), four in all: `build_overlays` returns them from the
panes' bar labels and `with_overlays` makes each from a base definition, one peer
per overlay after the others, stored by position (see **Overlay peers**). `claude-peer install` writes both into the `Workgroups` key (JSON
in a data value; replace by id, else append), refuses while iTerm2 runs, and
edits the custom prefs folder's plist when `LoadPrefsFromCustomFolder` is on,
else the domain. Both are forced:
launch replaces the domain's syncable keys from the folder
(`iTermRemotePreferences.m:1636-1660`) and quit writes the folder back
(`:1768-1830`), so `defaults write` or an edit while iTerm2 runs is lost. That
plist is tracked here and rewritten by iTerm2 at every quit, so the edit is
the same drift as any save and is not committed back. `status` prints
`store:`, `iterm2:`, `workgroup:`, `hermes:` and `default:`, `overlays:` where the
machine, the store or the state file has any, and inside a
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
`<name>/hermes`. `claude-peer here` prints the key for the directory: `overlays` when all hold,
tested in this order so the common case costs one file test (the state file
`${XDG_STATE_HOME:-~/.local/state}/claude-peer/overlays`, one line of names, written by
`install` after the definitions went in, read by `here` and by `overlay <N>`, and absent or empty otherwise; the caller is in a
repository; that repository's main checkout, by `pwd -P` (`root_of`), is the
main checkout of the repository holding `chezmoi source-path` (`public_root`); this machine
has an overlay now), else `base`, always exit 0 with no stderr. The state file is the gate:
a deployed script whose definitions are not installed yet must not send a key no trigger
matches, which would put every tab of the public source in no workgroup. The wrapper adds
`/hermes` where `hermes_profile` routes it, the gate `hermes_peer` uses. The nonce (`$EPOCHREALTIME`) makes a second launch
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
pane torn down mid-checkout leaves no half-made tree. A slot's checkout runs with
`-q`, so its first start prints nothing of git's above the pane's header, and a
checkout that fails still prints git's `fatal:` line and then `<slot>: git
worktree add failed`. `status` adds `peers: <r>
running, <w> waiting in <repo>` with the running labels when run inside a
repository, and
`leftover: <k> peer-N worktrees from the retired scratch layout (...)` when
registered `peer-N` worktrees remain; nothing uses or removes them any more
(`git worktree remove <path>`).

**A pane waits until it is told.** `claude-peer run --as <slot> --wait` is
what a slot pane runs, and makes no worktree, claim or Claude until it is
woken. With the picker on (below) the waiting screen *is* the picker, open at
once; Esc puts it away and leaves the quiet line `<Label>: Return picks a
context, c continues the last session, q leaves a shell`, where Return opens it
again. With the picker `off` the quiet line is all there is: `<Label>: Return
starts a Claude here, c continues the last session, q leaves a shell`. At the
quiet line Return starts (or picks), `c` continues with `--continue`, `q` (or
Ctrl-C) removes its wait file and leaves a plain shell, anything else asks
again; when the session ends for any reason the claim goes
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

**`start` and `stop` are the operator's and Lead's.** A session that is not
Lead runs them only when asked; `slots` and `log` only read or append, and the shared memory tells every
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

**Lead**, the one session that may start, stop and re-task its peers unasked, is in `claude-peer-handoff.md`.

**A peer is a separate project, not a helper of the leader.** It has its own
context, branch and pull requests, and plans and delegates inside itself like any
session; `start` passes its prompt through untouched, except that `--handoff` appends the
fixed hand-off note, and nothing in this
script briefs, merges or supervises a peer; Lead, a session, does (the shared
memory's `Lead` section). A tab's log lines are relayed to Lead (postbox's
`lead-news` and Stop hook), and a tab is still not briefed, merged or supervised. The one shared thing is the coordination log,
`<git common dir>/claude-peer.log`, so every worktree of the repository reads the
same file and it outlives any session. It is append-only, one line per entry,
tab-separated: `<UTC time><TAB><who><TAB><kind><TAB><text>[<TAB><path>…]`, with
tabs and newlines in text and paths written as spaces. `kind` is `claim`, `note`,
`done`, `start`, `stop`, `end`, `idle` or `gone`. `who` is the label of the slot whose worktree the
caller stands in (a live claim), else `Lead` when a live claim names the caller's
directory as its leader, else the directory's name; `log --as <name> …` overrides
it. `log claim <task> [-- <path>…]` appends a claim and then prints, for every
open claim of someone else that shares a path (equal, or one a directory prefix
of the other, paths taken relative to the repository top; `.` is all of it),
`overlap<TAB><who><TAB><their path><TAB><their task>`; it exits 0 whether or not
anything overlaps, because a claim is advisory and a non-zero exit reads as
"blocked". `log note <text>` and `log done [<text>]` append those kinds. A claim
is open until the same `who` logs `done`, or a `stop` or `end` line for that
label follows it, so a stopped or ended peer never leaves a claim open. `log
show` prints the open claims and the last 24 hours of notes, `--all` the file.
`start` and `stop` each append `<label> by <who>`. A `claim`, `note` or `done`
by anyone but `Lead` then runs `postbox lead-news <leader> <pid> <session id>`
(`CLAUDE_PEER_POSTBOX`, default `~/bin/postbox`), detached and silent, for the
leader of the caller's live claim (pid and session id its lines 9 and 10, `-`
when missing), else the main checkout; `log`'s output and status do not change. When a session in a pane
returns, the pane appends `end` as the slot's label, text `<Label> ended after
<dur>` (`dur_of`: `45s`, `12m`, `3h`, `2d`) plus ` (<task>)` when it had one; a
refused start writes none, and a pane killed outright writes none (its claim is
simply dead). The log is per repository: an
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
on). A pane writes `3` as line 2 of its wait file (the protocol); `start
--context` to a pane below 2 is exit 4 (`predates contexts; reopen its tab`),
`start --handoff` to one below 3 is exit 4 (`predates hand-offs`), a plain
`start` to it works. `pane_go` is the one place that builds the `claude` arguments, in this
order: `-n <repo>-<slot> [--continue] [definition args] [--agent A] [--model M]
[--effort E] [--append-system-prompt S] [prompt]`; it reads `PG_CTX`,
`PG_CTXNAME`, `PG_BY` and `PG_TASK` and clears them. The claim gains lines 4-7:
who started it (`Lead`, a slot label, a directory name, `pane` for Return, `-`
unknown), the context name or `-`, the task line (at most 80 characters) or `-`,
and the start time in epoch seconds; lines 1-3, `peers` and the session name are
unchanged. The pane's header line is the slot's label, then ` · started by <by>`
(not for Return) and ` · <task>`.

**Names, hand-offs, how a session ended** are in `claude-peer-handoff.md`.

The public source ships seven top-level contexts, `dot_config/claude-peer/contexts/NN-<name>.ctx`
(`ask`, `look-at`, `plan`, `prs`, `audit`, `catch-up`, `team`), which deploy on every class but
`ephemeral`. They name no account, organisation, person or private repository or skill; an
overlay's file of the same name at the owner or repository level replaces one (an overlay
may do this). A context is a launcher: it points at a skill or a document
and restates no procedure. `{owner}` and `{repo}` in `40-prs.ctx` are gh's own placeholders,
typed literally, and only `{input}` is substituted. The lookup rule is the one above: top,
`<owner>/`, `<owner>/<repo>/`, a deeper file wins by name.

**The picker.** A waiting pane shows it at once, every time it starts waiting and again
each time a session ends (`git config claude-peer.picker fzf|list|off`, read in the leader
directory when the pane starts; unset is `fzf` when `fzf` is on PATH and stdout is a terminal,
else `list`; `off` is the pre-picker pane, quiet line and all). fzf needs 0.75 or newer
(`fzf_ok`); an older one prints `fzf <version> is older than 0.75; using the list` once, and
with `list` or `off` fzf is never run. `pick_rows` builds the rows, `id<TAB>display`, the
display being the name padded to one column (8 to 16 wide), two spaces and the title:
`@fresh`, each context of the repository, `@continue`, `@resume` (`claude … --resume` alone,
so Claude's own list chooses), `@task`, `@shell`. `pane_size` reads `CLAUDE_PEER_SIZE`
(`rows cols`, the tests' handle) or `stty size`; `pane_geom` makes the block at least 58
wide (fzf keeps three columns of it, so it is 3 plus the longest display: nothing is cut
while `3 + name column + 2 + title` fits the pane), centred when the pane has 80 columns or
more, and at most 12 rows tall. fzf is called
small and flat: `--height` the block's, `--margin` the centring, no preview, no border, the
hint dim in its header (`pane_head`; a shorter one under 56 columns, and under 38 columns the hint itself is cut), `--no-mouse` so the
wheel still scrolls back through what the last session left, `FZF_DEFAULT_OPTS` unset and
only its `--color` words passed on (`fzf_colors`). `pane_art` prints the sleeper (below) above
the list and above the quiet line. Esc (130), and an fzf that ends with nothing chosen, put
the pane in the quiet state; nothing reopens fzf without a key, so a broken fzf cannot spin.
The numbered list is printed under the same left padding and read by `pane_ask`; Return
alone is row 1, a number its row, a name its context (or a built-in row by its shown name),
`c r n s` as the hint says, `q` and Ctrl-C a shell; a reader that ends with no line (no
terminal) goes quiet. A line typed at the quiet prompt that is exactly a context name starts
it. Every question (`<ask>: `, `Task: `, `Save as …`) is read by `pane_ask`, which is
`pane_block`, so a `start` request interrupts any of them (`pane_ask` then ends the
question's line, so the header of the session that follows starts a line of its own; an
open fzf and the quiet line already leave the cursor at the start of a line and get
nothing), and an empty answer or Ctrl-C
goes back to the picker (`Save as`: Return skips the save, the task still starts). fzf runs
as a background child the pane `wait`s on, with its signals reset in the subshell (the pane
ignores `TTIN` and `TTOU`); a request while it is open sends it TERM, runs `stty sane` on the
terminal and handles the request. `ctrl-t` or `ctrl-s` (or exit 1) with a typed query: that
text is the task, and `ctrl-s` also saves it; `ctrl-t` with nothing typed opens the picker
again; any other failure prints `fzf failed` once and the pane uses the numbered list from
then on. Saving writes `<root>/<owner>/<repo>/90-<name>.ctx` (`title:` the first 40
characters, a blank line, the task) and refuses, with one `not saved:` line and the task
still starting, a bad name, a name the directory already has under any prefix, or a
repository with no origin. The tests use a stub `fzf` on `PATH`; whether the real fzf works
as a background child in a workgroup pane is live check L-a/L-b.

**The sleeper.** A waiting pane draws a small figure asleep above the picker: `art_default`
is the built-in in the art format (`palette <letter> <r> <g> <b>`, `margin`, `z near|mid|far
<row> <col>`, optional `cap fixed`, `frame <name>` then pixel rows of equal width and an even
count; `.` empty, `E` a closed eye filling both pixel rows of its cell; frames `asleep`, and
`asleep-sway`, `wake-1`, `wake-2` falling back to it). `art_awk` renders two pixel rows per
character row: the same colour twice is a space on that background (a block glyph showed
seams; the operator rejected it), two colours `▀` over a background, one `▀` or `▄`, an eye a
bold `▬` in `K` on `O`; truecolor when `COLORTERM` says so, else the nearest 256-colour cell
(one awk, POSIX: drawn under mawk and gawk by the list's screen test on every CI job). The z's
are a bold `Z`, a `z` in 256-colour 250 and a dim `z`; fzf would grey the bold one under the
theme's `header` colour, which `--color=header:-1` prevents. The cap is coloured per slot
(`art_cap`: `git config claude-peer.<slot>.cap '#rrggbb'`, else the slot's place in the pool:
green, the approved blue, purple, cyan, yellow, red, from Base16 Eighties; the band is 0.7 of
it). While the figure shows, the selector matches the hat (`art_hat`, the operator's
call): fzf's `pointer` and `prompt` and the list's `<Label> ▸` take the cap's colour,
`#rrggbb` in truecolor, else the 256-colour index the art draws it in; without the figure
fzf keeps its own colours. `git config claude-peer.art false` hides it; `claude-peer.art-file <path>` replaces it,
and a file that does not parse prints `claude-peer: <path>: <reason>` and the built-in is
drawn. `pane_geom` sets `pn_lay`: `beside` at 80 columns and 16 rows or more (`✻ <Label> ·
<repo>` and a dim second line on the figure's rows 4 and 5), `under` from 30 to 79 columns
and 18 rows (those two lines below it), else `none` and every screen is the picker's own; an
unknown size is `none`. In fzf the figure is header text (`pane_head`), so fzf draws and
erases it and the list scrolls under it; `pn_w` also fits `3 + 29 + ✻ <Label> · <repo>`,
capped at the pane, and `<repo>` is cut, never the label. Above the list and in the quiet state
`pane_art` prints it under `pn_pad` and two spaces, then an empty line; in the quiet state its
second line (`⏎ picker · c continue · q shell`, or `⏎ start …` with the picker off) replaces
the quiet line. The one cursor movement: before the quiet block is drawn again (a mistyped
line) or the picker opens from it (Return), `pane_unquiet` moves up over the block, its empty
line and the typed line and erases down (`ESC[11A`, `ESC[J` beside; 13 under), so one sleeper is
ever on screen; a session started from quiet (`c`, a context name, Return with the picker off)
leaves it above the session. A pane resized between going quiet and the next key miscounts once.
**It moves inside fzf, and wakes.** No animator process: before each fzf launch (sleeper
showing, `git config claude-peer.art-seconds` over 0; default 20, read when the pane starts)
the pane writes one complete header per pose, `$pn_me.frame.0`…`.3` (z's near, near-mid, all
with the pom-pom swayed, none swayed) and `.still` (A1's header), exports
`CLAUDE_PEER_FRAMES` and `CLAUDE_PEER_ART_SECONDS`, and adds `--with-shell='sh -c'`,
`--bind='change,focus:rebind(every(1))'` and, last, `--bind='every(1):bg-transform:<tick>'`
(`PANE_TICK`): each second one `sh` and one `cat` pick the pose from `FZF_IDLE_TIME_MS`, and
once art-seconds pass without a key the header becomes `.still` and the timer unbinds, so an
idle picker forks nothing; a key or a cursor move binds it again. The once-a-second poll this
file rejects for the wait is bounded here by that limit. `pane_cleanup` and `pane_reap` take
the frame files with the wait file. Waking: `PG_WAKE` is set by `pane_fzf` around a pick that
starts a session and by the request path when the request closed an open fzf; `pane_go`
reads and clears it and, with the sleeper showing, calls `art_wake` once the slot is taken
(a refused slot draws nothing): `wake-1` (cap lifted, no z's) where fzf erased itself, 0.25 s,
up over it (`ESC[9A`, 11 under) and `wake-2` (eyes open) on top, 0.25 s, then the header line
as before. The list and the quiet state never move and never wake. A context that asks a
question wakes under its answer. The screen tests hold the figure still from `setup`
(`art-seconds 0`) and set 3 where they test the movement.
`claude-peer art [--slot] [--frame] [--z all|near|near-mid|none] [--truecolor|--256]` prints a
frame; `art --screen [--slot]` prints the quiet screen as a pane would pad it, for the terminal
or `CLAUDE_PEER_SIZE`: the operator's preview and the screen tests' reference. The figure is
the operator's approved original, not Anthropic's mascot; a private override file may differ.

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

**Overlay peers.** A tab of the public chezmoi source gets one extra pane per private
overlay of the machine, each a waiting pane of that overlay's own repository. Discovery is
`dotfiles()`'s rule, by chezmoi's own answer: every `~/.config/chezmoi/*.toml` but
`chezmoi.toml` whose `chezmoi --config <cfg> source-path` is inside a non-bare git
repository, sorted by name under `LC_ALL=C` (`overlay_list`; `claude-peer overlays` prints
`name<TAB>root<TAB>state<TAB>leader<TAB>pid`). A candidate that cannot be one is named on
stderr and skipped: no source directory, not in a git repository, the public source itself,
the same repository as an earlier config, a name already taken. The name is the config's base
name lowercased, anything outside `a-z0-9_-` turned into `-`, `o-` in front when it does not
start with a letter. No overlay name is a literal in the public source, and none is written into iTerm2's
preferences either: where the prefs folder is a git clone the `Workgroups` value sits in a
tracked plist, base64-encoded, where a text leak guard does not read. What is stored where: in
the preferences a position (id `<gid>.o.<N>`, bar label `Overlay <N>`, command
`claude-peer overlay <N>`); in the state file the names in pane order; on the terminal the name
(the pane's header, `status`, `overlays`). `claude-peer overlay <N>` is the pane command: N is
the N-th name of the state file, resolved against the overlays the machine has now, so a changed
set never re-points a pane; `overlay <name>` is the form typed by hand. It resolves the overlay at run time, `unset`s `CLAUDE_PROFILE`, `cd`s to the overlay's
main checkout and then calls `pane` with slot `overlay`, so everything a slot pane does is
reused: worktree `<overlay>/.claude/worktrees/overlay`, detached at `origin/HEAD` when new and
reused as left, the `**/.claude/worktrees/` line in that repository's `.git/info/exclude`, the
claim, the pool (a second tab of the public source finds `overlay` in use and takes the pool
from its fourth name on, as Alpha does), Return/`c`/`q`, and `claude` through an interactive
shell so the `claude()` wrapper resolves the profile from the overlay's own origin and pin,
which are read and never written. It changes directory, and does not call `run`, because `run`
takes the leader to be the directory it stands in: the claim must name the public source as
leader (line 2), or `tabname` would mark the overlay's checkout as Lead. The waiting pane's
header is the overlay's label; the claim's label, the session name `<overlay dir>-overlay` and
the Session Status row `<overlay dir> · Overlay` come from the slot. Nothing reads or prints
anything from an overlay's tree: the script touches git metadata (worktree list, `git worktree
add`) and files of its own under `.git/`, so an overlay a profile is denied is listed by path,
name and running state only. A name that no longer resolves, or a directory that cannot be
entered, prints one line and leaves a plain shell, never iTerm2's restart banner.

The two definitions are separate from the others because peers spawn at entry: panes added to
`Claude Peers` would appear in every repository's tab. The bar is the root plus the peers in
session order and ⌥⇧⌘1…8 pick by position, so the Hermes twin of the overlay group is built from
`claudePeer.h` plus the overlays, not by `with_hermes` of the first: Lead, Alpha, Beta, Gamma, then the
overlays, or Lead, Alpha, Beta, Gamma, Hermes, then the overlays. Hermes keeps ⌥⇧⌘5; ⌥⇧⌘9 is
"last", so it becomes the last overlay (iTerm2 3.7.7 source; not yet seen on a real tab). One
pair is built at `install` time for the overlays the machine has then (none: neither, and a stale
pair is removed with the state file); `install` needs iTerm2 quit, the one part of this that does.
Between a change of the overlay set and the next `install` things degrade visibly: a pane whose
overlay is gone says so and is a plain shell, a new overlay has no pane, and `status` says
`overlays: installed, out of date (...)` (as many overlays under other names is out of date
too: the state file's names must be the names now); a pane whose position has no name in the
state file says so and is a plain shell; a state file and a store that disagree get a second
`overlays:` line saying which tabs enter nothing or stay `base`. `status` says which pane is which
overlay: `overlays: installed (N panes: Overlay 1 = <Name>, …)`. From the shell `status` also
prints `overlays: entered from <public root>` and one `overlay: <name> <state> in <root>` per
overlay (`idle`, `waiting`, or `running` with the tab that leads it).

Limits. An overlay peer is in the overlay's `slots`, `peers` and log, not the leader's, so Lead's
roll-call does not announce it, and `start` and `stop` for it are run from inside the overlay.
`q` leaves the operator's own shell standing in the overlay's main checkout. The leader's exit
tears overlay peers down like any peer. A linked worktree of the public source counts as the public source;
any other repository keeps `base` and `base/hermes`.

Tests: `tests/claude-peer.bats` (stub ps/uname/defaults,
fixture plists; the real store is only touched by the operator's `install`).

**Screen tests.** `tests/claude-peer-screen.bats` draws the real waiting pane in a
detached tmux server of its own (`tmux -L cps<pid>-<n>`, its own three-line config,
never the caller's server) at fixed sizes, captures it with `capture-pane -p`
(`-e` for colours) and asserts on the screen as drawn: the harness probe (size,
`$SHELL`, glyph widths, 24-bit colour), the gate, the CI promises, and the numbered
list (centred, every row whole, a question under it, a `start` taking it, an older
fzf falling back to it), the fzf picker, and the sleeper (cell for cell against
`claude-peer art`, whole while the list scrolls, absent at 15 rows, one after Esc and
Return, and above the list). The sleeper's tests unset the `claude-peer.art false` that
`setup` sets for the rest. Waits are for text and for a still screen, never a bare
`sleep`. They need a UTF-8 locale and, in a container, an init as process 1
(`docker run --init`): the harness test and `screen_close` say so by name, and
`screen_run` fails when tmux did not make the size it was asked for. A tmux older
than 3.3 gets a fourth config line, `window-size manual`, without which it sizes a
detached session by the terminal of the client that made it; 3.3 to 3.6a must not
get it, since their server dies at `new-session` under it (`tmux_old` in the test
file). Run it with
`PATH="$(brew --prefix)/bin:$PATH" SCREEN_TESTS_REQUIRE='tmux fzf' bats tests/claude-peer-screen.bats`.
`SCREEN_TESTS_REQUIRE` lists what the caller promises is installed (`tmux`; `fzf`
for 0.75 or newer): a missing tool skips its tests, a missing promised one fails
them; each CI job promises `tmux fzf` on the line that runs the suite. No CI job takes fzf
from its image's packages: each installs the release named in `.github/fzf-version`
with `.github/install-fzf.sh`, which checks it against the release's own checksum
file, and a second step fails unless that fzf is the first on PATH. The pin moves by
editing that one line; the package lists are for machines and do not move with it.
The older-fzf test plants a stub that answers `--version` as apt's 0.44.1 does. A red test
prints the screen it saw (a column ruler, each line ended by `|`). A server left
behind by a killed bats: `pkill -f 'tmux -L cps'`.
