---
paths:
  - "**/bin/executable_pane-sight"
  - "**/bin/symlink_pane-read"
  - "**/bin/symlink_pane-shot"
  - "**/bin/executable_screen-heads-up"
  - "**/tests/pane-sight.bats"
  - "**/tests/screen-heads-up.bats"
---

# pane-sight

**`pane-read <name>` prints another pane's screen as text and `pane-shot <name>`
writes a PNG of it, both behind a scope gate and an audit log.** macOS only;
`pane-read` and `pane-shot` are chezmoi symlinks to `pane-sight`, which reads
`${0##*/}`. `pane-sight why <name>` prints the resolution and the verdict
without asking the pane anything, `list` every nameable pane with its verdict,
`status [--line]` what is missing. A name is a `claude-peer` slot, a session
name, a `tabname` label, a pid or an iTerm2 session id. The calling session
uses `pane-read` and `pane-shot` before asking the operator for a screenshot.

## Why iTerm2's API and not AppleScript

A workgroup peer that is not swapped in is in no tab ("Peers that time-share a
pane are not in -sessions", `sources/TerminalView/PTYTab.m:9622-9623` at tag
`v3.7.7` of iTerm2), and AppleScript's `sessions of tab` is exactly that list
(`sources/Applescript/PTYTab+Scripting.m:26-39`), so AppleScript cannot name a
peer that is not showing, and `text of session` returns no image. The API
resolves a session id with `anySessionWithGUID:`, which also walks peer ports
and the workgroup registry (`sources/API/iTermAPIHelper.m:1709-1727`). The
grant is no wider than the hooks already use: the Automation grant that mints
the API cookie also allows `write text` and `close`, so what limits the tool is
what it sends. The tests fail on any other call.

**Three calls, and only these:** `it2 session read --session <id>`, `it2
session get-var tty|path --session <id>`, and the RPC `ScreenshotRequest`
through the `iterm2` library's `rpc.async_screenshot` (protocol 1.17; the
library's `App` is built from the session list, which holds no hidden peer, so
the RPC is called directly). The script never sends `create`, `split`,
`close`, `restart`, `write text`, `send`, `run`, `select`, `focus`, `set-var`,
`set-name` or `set-status`: iTerm2 3.7.7 can crash when a variable-changed
trigger fires while a session is being created or torn down, and a read, a
render and a `get-var` set nothing. The `it2` stub in `tests/pane-sight.bats`
exits 97 on any other verb and its teardown asserts it never saw one.

## The one-pane guarantee of a shot

**A shot is never scanned and never refused for what the pane shows, because
the only picture this tool can make is iTerm2's render of one session.** It
holds that terminal pane's cells and nothing else: no Toolbelt, no Session
Status rows, no tab bar, no neighbour pane, no other application. The operator,
2026-11-13: "we should never really be showing secrets in the terminal at all,
so really if you don't take a photo of anything but the term it should be
fine." The script has no second way to make an image: it never runs
`screencapture` or `osascript`, and `tests/pane-sight.bats` fails on a stub of
either. A change that adds one breaks the guarantee, not just a test.

**The window shot was dropped for that reason.** A window capture always holds
more than terminal panes (the title bar, every other tab's title, the peer bar,
whichever panel is open), so it cannot keep the guarantee and is not built in
any form: no `--window`, no AppleScript window id, no Screen Recording. If
window furniture ever has to be seen, that is a new brief with its own answer
to the Toolbelt, not a flag on this tool.

**`pane-read` text loses styling**: dim suggestion text reads like typed text.
Use `pane-shot` when how something looks matters.

## What the gate is, and is not

**`pane-sight` is the sanctioned route and the record, not a sandbox.** A
session with Bash can call `it2` or the `iterm2` library itself, so nothing
here stops one that means to. Two things are in scope because they are cheap
and because the record is worthless without them: nothing may fail open with
nobody trying (a profile started by directory, a terminal `ps` cannot list),
and no single word in front of the sanctioned command may change its answer.
A constructed environment (a home directory built for the purpose, a `ps` of
one's own first on `PATH`) is as much work as calling `it2` and is out of
scope, as `.claude/rules/denyguard.md` says of itself. Hard enforcement is not
built here: a `denyguard` pattern for `it2 session read` would give it a second
kind of rule (it reads path rules from `permissions.deny` and nothing else, on
purpose), and command patterns already have a home in each profile's
`Bash(...)` deny rules, which the overlays own.

**Inputs.** The script reads its judges and helpers from fixed places and from
no variable: `$HOME/bin/claude-peer`, `$HOME/bin/denyguard`,
`$HOME/bin/tabname`, `$HOME/.functions`, `zsh` and the system tools from
`PATH`, `it2` at `$HOME/.config/iterm2/it2` (iTerm2's Claude Code integration
links it there; the bundle path is not a fallback) and iTerm2's files under
`$HOME/Library/Application Support`. The test seams for these were removed, not
gated: a copy that honours seams and can still reach the real `it2` is the same
hole one `cp` further away, and honouring them only off the deployed copy needs
the script to learn where it is deployed from `HOME`, the environment it is
trying not to trust. The tests run in a sandboxed `HOME` with every judge at its
real place inside it, so none is needed, and a test fails if the script's text
names one again. Only `PANE_SIGHT_PYTHON` and `PANE_SIGHT_TIMEOUT` are read;
neither judges. `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_COUNT` and
`GIT_CONFIG_PARAMETERS` are unset before `git` is first asked, so the pins the
route question reads are the machine's own. The audit log is under
`$HOME/.local/state`; `XDG_STATE_HOME` is not consulted.

**The caller.** The claim is `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`, normalised.
The command's ancestors are walked from its own pid with `ps -o ppid=` (at most
40 steps, ending at pid 0, pid 1 or an empty answer); an ancestor is a
registered session of directory X when `X/sessions/<pid>.json` is a live record
of that pid, X being the claim, any directory the profile list holds, or the
ancestor's own `CLAUDE_CONFIG_DIR`. The nearest registered ancestor's directory
decides: a claim that differs from it is refused `caller-mismatch`, and an
ancestor whose `ucomm` is `claude` that no registry holds, met before any
registered one, is refused `caller-unknown` (its line names the pid). With no
registered ancestor (a shell the operator typed in) the caller is the claim. A
pid held by registries of several directories, one of them not the claim,
counts as that other directory, so a registry made to hold the claim's own copy
of a record changes nothing. A caller refusal comes before any name is
resolved: `read` and `shot` write a best-effort audit row with kind and label
`-`, `why` and `list` print the line and exit 3. A Bash tool call's parent chain
is the shell, then the session's `claude`; a nested `claude -p` is its own
registered session and decides for its own Bash.

## Resolution and scope

Resolution order, first match wins: an iTerm2 session id (a UUID, with or
without its `w<n>t<n>p<n>:` prefix); a pid, as a registry session or a
`claude-peer panes` row; a `claude-peer` slot of the caller's repository (a
running pane wins; several waiting ones are narrowed to the caller's own
leader); a live registry session by name or `tabname` label. More than one is
exit 4. A pane whose process has no terminal is never a candidate, and a
waiting pane opened before `claude-peer` recorded its session id is exit 4
("reopen its tab"). A session id works only where a session of this profile
runs on its terminal: `get-var path` is not set on this machine, so a bare id
with no session behind it has no directory and is refused `no-directory`. A
`get-var` answer is a JSON string (`"\/dev\/ttys010"`) and is decoded.

Scope is decided on the pane's terminal before iTerm2 is asked for any content
(for a bare id the two `get-var` calls are the only ones before it):

1. **who is on the terminal must be knowable**: if either `ps` call fails or
   prints nothing, if the python reading them fails, or if the target's own pid
   is missing from its terminal's list, the pane is refused `no-processes` (a
   bare id has no pid of its own, so only an empty list refuses it);
2. **evidence of somebody else's Claude on the terminal** refuses, any one of
   three kinds, from the registry of every profile directory (the caller's,
   the default one, each `claude.profile.*` value and each per-repo
   `claude.<owner>/<repo>.profile` pin whose value is a directory: a profile
   started by `CLAUDE_PROFILE=<dir>` or `claude-as <dir>` is in none of the
   others) and from two `ps` calls on the terminal (`-o pid=,ucomm=` and
   `-Eww -o pid=,command=`):
   - a registry row of another directory whose pid is on the terminal is
     `other-profile`, with that directory's label;
   - a process on the terminal whose environment shows a `CLAUDE_CONFIG_DIR`
     (the last such word, normalised) that is not the caller's is
     `other-profile` too. A session's children carry the variable, so this
     holds even where `ps` hides the `claude` process's own environment, and
     it finds a profile directory no config names;
   - a process whose `ucomm` is exactly `claude` and that is not one of this
     profile's own registry rows is `unknown-session`, whose line names its
     pid. A session that is still starting is refused for a moment;
3. the directories of this profile's own sessions on the terminal, or the
   target's own with none, must pass `denyguard check --profile <caller>` (one
   definition of that boundary); exit 1 is `denied`, any other status or no
   executable is `deny-unknown`;
4. with none of this profile's sessions on the terminal, the profile `claude`
   would use in that directory is asked of the wrapper's own
   `claude_profile_dir` in a zsh of its own: another profile is `other-route`,
   no answer is `route-unknown`;
5. an empty directory is `no-directory`.

**Left open by design:** a Claude Code whose process is not named `claude`,
under a profile directory nothing names, where `ps` shows no environment (rule
2 and `caller-unknown`); a pane that displays another session without running
it (a `tmux` client, an `ssh`); a constructed `HOME` or `PATH`; and any session
that skips this tool. A `CLAUDE_CONFIG_DIR` whose value holds a space is split
by `ps` into words and read cut at the space; cut, it matches no known profile,
which is doubt, and refuses (`other-profile` on a terminal, `caller-unknown` for
an ancestor). It can pass only where the part before the space is itself the
caller's directory.

**Every doubt refuses**, for `denyguard`'s reason: a check that could not run
and was read as a pass is the failure that matters. There is no bypass flag; a
flag a session can pass is not a boundary. **What the scope cannot see** is
what a pane displays: it judges by directory and by session profile, so an
`ssh` into another machine in an allowed directory is read. A refusal is exit
3, names the pane and the reason, reads nothing, and is final; it is never
retried through `it2`, `osascript` or `screencapture`. Before reading, the
binding check compares the terminal iTerm2 reports for the session id with the
one scope judged (`failed:binding`, exit 1), so the content is of the pane the
verdict was about.

## `read` and `shot`

**`read`** takes the whole screen from `it2 session read` (never `--lines`: it
counts trailing blank rows), strips trailing whitespace and blank lines, masks
the whole screen, then keeps the last `--lines` (default 60, 1 to 500).
Scrollback is never read: it would hand over more than the operator sees on
that pane. **The masks are a counting net, not a refusal and not a guarantee**:
secret-shaped strings (key blocks, tokens, JWTs, bearer values, `name=value`
secrets) become `[masked:<tag>]`, and the count on stderr and in the audit row
is the only thing that tells the operator one is sitting on a terminal. Text
is re-quoted (a log note, a message, a pull request body) and a picture is
not, which is why only text is masked. To take the masks out, delete `mask`
(`MASK_PY`) and its tests; nothing else reads them.

**`shot` order:** the Python runtime is found (before iTerm2 is asked anything,
or iTerm2 offers a dialog to install one), then resolve, scope, `bind_check`,
the render, the audit row, the path on stdout and nothing else, the peer note,
and pruning to the 20 newest. The default file is
`$TMPDIR/pane-sight/<label>-<UTC stamp>.png` (directory 0700, file 0600, a
`-<pid>` suffix when the same second is taken); `--out <file>` must not exist
and is never pruned. `shot` never runs `it2 session read`. Exit codes: 0 done;
1 failed (iTerm2 not reachable, no runtime, `not drawn`, audit log not
writable); 2 usage or not macOS; 3 refused by scope; 4 no such pane, more than
one, or one that cannot be addressed. 5 was the secret refusal of a shot, is
retired, and must not be reused. **`not drawn`** is iTerm2 returning no image;
for a peer that has never been shown it may have nothing to draw ("click its
Session Status row once and try again"), and the tool does not switch peers by
script.

## The audit log and the peer note

`$HOME/.local/state/pane-sight/audit.log` (directory 0700, file 0600): one tab-separated row per `read` or `shot` that reached a target or
a refusal: time, verb, result, kind, label, caller (`CLAUDE_CODE_SESSION_ID`),
detail (`lines=<n> masked=<m>`, or `bytes=<n> file=<path>`, plus `noted=1`).
Never content. Results are `ok`, `refused:<code>` and `failed:<code>`, the codes
being `it2`, `no-session`, `not-drawn`, `render`, `binding` (and `read`, `mask`
for a read). A refusal's code is one of `other-profile`, `unknown-session`,
`no-processes`, `denied`, `deny-unknown`, `other-route`, `route-unknown`,
`no-directory`, or, before any name is resolved, `caller-mismatch` and
`caller-unknown`. **The `ok` row is written before anything is printed**: if it
cannot be written nothing is shown (a shot's file is removed) and the exit is
1. A refusal's row is best effort. After an `ok` on a peer, `claude-peer log
note "<verb> of <label>'s pane"` is written from the caller's directory, unless
the log already holds a `noted=1` row for that caller, label and verb in the
last ten minutes. `pane-sight status` counts the rows; `iterm2-doctor`'s
`panes:` line is `pane-sight status --line`.

## `screen-heads-up`

`screen-heads-up "<what>" <seconds>` warns the operator before something takes
the screen. Exit 0 go, 1 not now, 2 usage, 3 could not ask (not macOS, no
notifier), 4 another heads-up is waiting. **The countdown proceeds unless
"Not now" is chosen** (the operator's decision, 2026-11-13): a
`terminal-notifier` notice carries a "Not now" button, the helper counts its
own `<seconds>` ticks, and only the exact answer `Not now`, or
`screen-heads-up --not-now` from elsewhere, ends it early. A closed or clicked
notice, a notifier that exited and an empty answer keep counting. `--free`
says the screen is free and opens the app that was in front at the ask again;
`--status` counts its log under `$XDG_STATE_HOME/screen-heads-up/`. Nothing in
`pane-sight` calls it, because nothing in `pane-sight` takes the screen; the
relaunch tool is its first caller. A Focus mode or banners-only notifications
hide the notice and the helper cannot know, so macOS Notification settings for
the notifier should be Alerts.

## The bench: evaluated, not built

A hidden second iTerm2 (`-suite <name>`, its own settings domain, socket and
instance lock) would give live UI tests a place to run without touching the
operator's own, and a Parall shortcut passing `-suite` would add the bundle id
a Desktop assignment needs. Both rest on facts only a live run settles
(first-run dialogs, how a client authenticates to the second instance, whether
the Dock follows the shortcut), so nothing is built on them. `pane-sight`
records a pane's `IT2_SUITE` and passes it on, so a session in such an
instance is named, gated, read and pictured like any other.
