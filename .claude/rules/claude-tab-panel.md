---
paths:
  - "**/bin/executable_claude-tab"
  - "**/dot_local/share/claude-tab/**"
  - "**/tests/claude-tab-panel.bats"
---

# claude-tab panel

**The needs-you list holds events, not states.** Session Status shows the
state of every session; the list holds what is in the operator's court and may
not be known to them yet, in one flat list across every tab and profile, and
leaves everything else to a count. Every rule below is decided from the
registry record (`<profile dir>/sessions/<pid>.json`: `status`, `waitingFor`,
`statusUpdatedAt`), never from a Session Status row, which is the source that
lies. The registry is an observed layout, not an interface.

`claude-tab panel tick [--state <file>] [--now <epoch>] [--focus <tty>|-|?]`
is the model: one pass over the registry, a state file, and the snapshot as
one line of JSON on stdout. It works on every OS. `panel` with no or an
unknown verb is usage (exit 2). All of it is one python program, `panel_py` in
`bin/executable_claude-tab` (standard library, `python3 -I -`, clean on 3.9),
with the mode word as its first argument; the shell passes each profile as
`--profile <dir>=<label>` and the thresholds as `--quiet <seconds>`
(`git config tabstatus.quiet-minutes` times 60, default 900) and `--finished
<seconds>` (`git config claude-tab.finished-seconds`, default 60); anything
that is not a positive integer is the default. `--life <pid>=<epoch>` is a test
handle for the sign of life of a busy session. `--focus` says which tty is in
front: a tty, `-` for no iTerm2 session, `?` for could not be asked (default).

**The registry is read a fourth time**, beside `registry_rows`,
`registry_full` and `registry_waiting`, because the panel keeps the whole
record and runs in one long-lived process. The four must keep the same filter:
only files named `<digits>.json`, a record counts when its `pid` is a positive
int that answers `os.kill(pid, 0)`, and `PermissionError` means alive. A
record whose `kind` is present and not `interactive` is headless: counted,
never a row.

**Kinds.** The condition of a session, first match wins:

| Registry `status` | Kind | Rank | Appears after (from `cond_since`) | Leaves when |
| --- | --- | --- | --- | --- |
| `waiting` | `blocked`, reason `waitingFor` | 0 | 4 s | the registry stops saying `waiting` |
| `idle`/`shell`, turn record `error` | `failed` | 1 | 4 s | the next turn starts |
| `idle`/`shell`, turn record `question` | `asked` | 1 | 4 s | the next turn starts |
| `idle` | `finished` | 2 | `--finished` (60 s) | seen, or the next turn starts |
| `shell` | `finished-bg` | 2 | `--quiet` (15 min) | seen, or the next turn starts |
| `busy`, sign of life known and `now - max(since, life) >= quiet` | `quiet` | 3 | at once | seen, or it writes again |
| any other word | `unknown: <word>` | 3 | 60 s | seen, or the word changes |

`since` is `statusUpdatedAt / 1000`; with none, the time the session was first
seen in that status. An **instance** is one `(kind, cond_since)` of one
session, and a change of either is a new instance: seen, hits, listed and
entered reset. A `busy` session with no sign of life is never called quiet (not
knowing is not stuck) and is counted in `health.life_unknown`; the sign of life
is looked up only once `since` is `--quiet` old (`--life <pid>=<epoch>`, a
test handle, overrides the lookup). The **turn record**
(`<state home>/tabstatus/<sessionId>.turn`, one line of JSON with `at`, `end`
of `question`, `error` or `plain`, `active`, `quiet`) is read only for a
session id of `[A-Za-z0-9_-]+` and only while idle or shell; it is valid when
`since - 15 <= at <= now + 5`, else there is none and the session reads as
finished. Nothing writes it yet. A turn end of a hand-off peer is Lead's, not
the operator's and is not listed (see "Who each session is"); a dialog on it
still is, because only the operator can answer one.

**Seen.** `--focus <tty>` gives the session on that tty one more look
(`hits`, capped at 2) and every other session none; `-` and `?` give none to
all. An instance with two looks and no `seen_at` is seen (`seen_focus`). A row
is listed when its delay has passed, its session has no look running (the
session in front is never listed), and it is `blocked`, `asked` or `failed`,
or unseen: those three stay listed once seen and the snapshot says
`seen: true`; the others leave. `mark_seen(pid)` is the click, for the server
to call (`seen_click`). **Starting calm**: with no usable state file (missing,
unreadable, another `v`, or `saved_at` over a day old) every `finished`,
`finished-bg`, `quiet` and `unknown` instance on the first tick counts as
seen; with one, a session not in it gets the same only when its `cond_since`
is not later than `saved_at`. The list starts quiet and lists what happens
from then on. A `blocked` instance that ends before it was ever listed is
`tally.hidden_prompts`.

**The state file** (`${XDG_STATE_HOME:-~/.local/state}/claude-tab/panel-state.json`,
mode 0600 in a 0700 directory, written through a temporary file and a rename)
holds `v`, `saved_at`, `sessions` keyed `<profile dir>|<pid>|<sessionId>` and the
tally. It is written only when something besides the tick counter changed or
`saved_at` is a minute old, so a calm list does not write every two seconds. A
write that fails is one line on stderr, and the snapshot is still printed.

**The snapshot** is `{v, generated_at, build, health, needs, others, tally}`.
`needs` is the listed rows in order of rank, then the time they entered, then
pid, and a row does not move while it lives. `others` holds every interactive
session once, grouped, each group with `needs`, `working` and `idle` counts; an
unlisted row's kind is `working`, `idle`, `idle-bg` or its condition kind. A
row is `pid, profile, label, group, role, kind, reason, since, seen, tty`;
`label`, `group`, `role` and `guid` say who the session is (below). `health` is `profiles`, `sessions`,
`headless`, `unreadable` (`<digits>.json` files that did not parse),
`focus` (`ok`, `none`, `unknown`), `turn_records`, `life_unknown`, `peer_turns`
(idle sessions hidden because another session started their last turn, below) and
`want_focus` (any instance not yet seen).

**Who each session is**, `who(cwd)`, all inside `panel_py`. `label` and `role`
are what `tabname --role <cwd>` prints (`<role><TAB><label>`; the script is
passed as `--tabname`, the shell's `$TABNAME`); no tabname, a failure or an empty
answer is the base name of the directory and `plain`, silently. `group` is the
base name of the directory holding `git rev-parse --path-format=absolute
--git-common-dir`, so a repository's linked worktrees share one group, else the
base name of the directory. `handoff` is true only for a `peer` whose own git
directory's `claude-peer.claim` has `handoff` as its line 8; any failure is
false, because a wrong false adds a row and a wrong true hides one. A peer's
`label` always carries its slot (line 3 of the same claim): `tabname.peer-format`
is the operator's to set and `{repo}` alone makes every peer of a repository read
like the repository, so a label that lacks the slot gets ` · <slot>` added. The answer
is kept per directory for 60 seconds (roles move with claims, and `tabname` per
session per tick would be a process tree each), the two `rev-parse` answers for
the life of the process. `guid` is the `ITERM_SESSION_ID` of the process's
start-up environment as `guid_of` reads it (`ps eww`), read once per session and
kept in the state; `null` without one. A busy session's sign of life is the newest
mtime among its transcript (`<profile dir>/projects/*/<sessionId>.jsonl`) and the
files directly under `<sessionId>/subagents/` beside it; only names and mtimes
are read, never a line. The project directory is found by listing `projects/`
once and kept; a session with none is retried once a minute and, with no
transcript to judge by, is never called quiet. The claim and transcript layouts
are observed, not interfaces: if either moves, hand-off peers list their turn
ends or `quiet` never fires (`health.life_unknown` counts the latter).

**A turn another session started is not the operator's move.** An idle or shell
session whose last turn began with a message from another session (a cross-session
message, a mail wake, a roll-call) is not listed as `finished`, `asked`,
`failed` or `finished-bg`, the same as a hand-off peer's; it counts in
`health.peer_turns`. A dialog on it (`blocked`) and `quiet` still list. The signal
is the transcript's own: the last `type: user` entry that is not a tool result and
not a sidechain's and that carries `origin.kind` (else `turnOrigin`), read from
the last 4 MiB of `<sessionId>.jsonl` and kept per file stamp, so an idle session
costs one `stat` a tick. `origin.kind` of `peer` is the cross-session case (every
`SendMessage` and the postbox courier's wake arrive as one; observed on
1,800 entries of one profile); `human` is the operator typing; `task-notification`
(a background task finishing) and anything unknown stay listed, because a wrong
hide costs a missed turn. Only the one word is kept, never a line. The ceiling: the
last such entry decides, so mail landing in the middle of a turn the operator
started hides it; no transcript, no such entry or a read that fails lists. The
layout is observed, not an interface: if `origin` moves, `peer_turns` stays 0
while mail-driven turns show up in `Your move` again.

**The process, `claude-tab panel serve [--port <n>]`** (macOS; foreground). The
tick above, as a function in a loop: one pass every `CLAUDE_TAB_PANEL_TICK`
seconds (default 2, a test handle), the last snapshot kept in memory, the state
file written when something changed or a minute passed (against what was last
written, not the previous tick). The port is `--port`, else `git config
claude-tab.panel-port`, else 47600, bound to `127.0.0.1` only; a port in use is
one line and exit 1. It prints `claude-tab: panel on http://127.0.0.1:<port>/`
once the first tick is done. The profile directories are read once at start,
so a profile created later is seen after the next restart. One tick that
raises is one line on stderr and the loop goes on; `generated_at` then stops
moving, which is what the page's stale banner reads.

**Endpoints.** `GET /snapshot.json` (503 before the first tick), `GET /health`
(`{ok, pid, build}`), `GET /` (the file `$CLAUDE_TAB_PANEL_HTML`, else
`~/.local/share/claude-tab/panel.html`, read on each request, with a CSP that
allows only inline script and style and fetches to itself; a missing file is
500 naming the path), `POST /seen` and `POST /go` with the body `pid=<digits>`.
Everything else is 404 and nothing is read from a path in the request. Every
request whose `Host` is not `127.0.0.1:<port>` or `localhost:<port>` is 403
(DNS rebinding: a page on another name resolving to loopback still sends its
own `Host`). A POST needs the header `X-Claude-Tab: 1`, which a cross-site
form cannot send and a cross-origin `fetch` may not add without a preflight
the server never answers; and a pid that is in the current snapshot, else 404.
Both POSTs call `mark_seen`; `/go` then runs `focus <pid>` through
`$CLAUDE_TAB_SELF` (a test handle; else this script under `/bin/sh`) with ten
seconds, and answers 200 `{"ok": true}` or 409 with the last line of its
stderr.

**The focus read.** On a tick whose previous snapshot had `want_focus` and
only while iTerm2 is in `ps`, one `osascript -` of `front_tty_script`: iTerm2
alone, three seconds at most, printing the tty of the current session of the
current window, `-` when iTerm2 is not frontmost. A failure, a timeout or an
answer that is neither is `?` and `tally.focus_failures`; every read is
`tally.focus_reads`. With nothing unseen no read runs, so a calm list asks
iTerm2 nothing. The tell: `focus unknown` with failures climbing in `status`
means macOS is asking for a grant, and rows then clear by click and by
typing only.

**It follows its own code and outlives iTerm2.** When the script's mtime
differs from the one read at start it saves its state and `exec`s `/bin/sh
<script> panel serve --port <port>`; `build` is that mtime, so the page can
reload itself. The server is the process that was started (`panel_py` execs
python), so the pid in `panel.pid` survives the replacement. A server started
from a script that is not the deployed copy (`--deployed`, default
`$CLAUDE_TAB_DEPLOYED`, else `~/bin/claude-tab`; "not" means `realpath`
differs, and with no deployed file nothing is compared) hands itself to the
deployed copy, tested again on every tick, and logs one line in `panel.log`:
`<script> is gone; continuing as <deployed>`, or `<deployed> changed; leaving
<script> for it` (the deployed mtime differs from the one read at start: a
deploy landed, or the copy appeared later). With the script gone and no
deployed copy it logs `<script> is gone; serving on with the code already
loaded` once and ticks on. It ends only on `stop`, `uninstall`, a signal or
logout, not with iTerm2: iTerm2 loads the Toolbelt tool's view once, at
creation (`ToolWebView.m:124-128`), with no retry, so the server has to be
listening already when iTerm2 starts. The focus read still runs only while
iTerm2 is in `ps`.

**A live look at a branch.** `panel start` from a checkout takes the real port
and the real state directory and serves that checkout's code. It says so in one
line on stderr after `panel started` (`following <script>, not <deployed>; it
leaves at the next deploy`), it hands over at the next deploy or when the
checkout is removed, and the tidy end is `claude-tab panel stop` then
`~/bin/claude-tab panel start`. On 2026-11-22 such a server was left running,
ignored every deploy, and died five days later with its worktree, leaving the
view blank.

**`start`, `stop`, `snapshot`, `status`.** `start` does nothing when `/health`
already answers on the port; else it runs `serve` detached (a double fork and a
session of its own, HUP ignored, ported from `iterm2-prefs`), appends its output
to `<state dir>/panel.log` (rotated to `.prev` past 262144 bytes), waits up to
five seconds for `/health`, writes `<pid> <port>` to `panel.pid` from the answer
and prints `claude-tab: panel started on http://127.0.0.1:<port>/`; when this call
started it from a script that is not the deployed copy, a second line on stderr says
which it follows. `stop`
sends TERM to the pid of `panel.pid` when `ps` shows `serve` and `claude-tab`
in its command, removes the file, exit 3 when nothing runs. `snapshot` prints
the running server's `/snapshot.json` (python `urllib` without proxies, exit 3
when nothing answers). `status` prints `server:`, `data:`, `focus:`, `needs:`
and `tally:` lines, then `tool:` (`installed` with the marker, else `not installed`); exit 3
and `server: not running` when nothing answers.
The invariant anyone can check while a prompt is open: the pids of
`claude-tab attention` rows waiting four seconds or more are exactly the
`blocked` rows of `panel snapshot`.

**The Toolbelt tool, and keeping the process up.** `register [--quiet]` runs
the one registration through iTerm2's Python runtime (the last executable of
`iterm2env/versions/*/bin/python3` and `uv/venvs/*/bin/python3` under its
Application Support directory, `CLAUDE_TAB_PANEL_PYTHON` first; none is one
line naming Scripts > Manage > Install Python Runtime, exit 1):
`tool.async_register_web_view_tool(connection, <name>, "local.claude-tab.panel",
True, "http://127.0.0.1:<port>/")` under a ten-second alarm. The name is `git
config claude-tab.panel-name`, else `Needs You`; a name equal to a built-in
tool's is refused by iTerm2 and shows as the interpreter's last line. It needs a
fresh API cookie as `api_cookie_env` judges it (the same clause `it2_focus` uses:
one in the environment, else the cookie file newer than iTerm2's socket) and
never starts the library without one, because the library would then ask iTerm2
through AppleScript and a stale cookie leaves no tool and no message. It needs no
terminal and no Claude session: the interpreter runs with stdin from
`/dev/null`, so the `claude` wrapper, launchd or an AutoLaunch script all work,
and a Claude session's own Bash is the one place the permission classifier has
refused it. Registering again with the same arguments reloads every open copy.
iTerm2 keeps the tool (`NoSyncDynamicTools`, registered again at every launch),
so a registration is needed once, and again only when the view loaded while
nothing listened.

`install` is `start`, `register --quiet`, then the marker `panel.installed` in
the state directory (one line, the port) and two lines saying where the tool is
and that the Toolbelt must be showing; a failure before the marker leaves none.
`uninstall` is `stop` and removing the marker (iTerm2 has no call that removes a
registration, so the tool is unticked by hand). `ensure` is silent: nothing
without the marker, nothing while `/health` answers, else `start`, wait up to ten
seconds for a fresh cookie (an iTerm2 restart has the wrapper minting one at the
same moment; `CLAUDE_TAB_PANEL_COOKIE_WAIT` is the test handle for the step),
then `register --quiet`; each failure is one line in `panel.log`. `claude()`
(`.functions`) starts it on an attended launch in an iTerm2 session
(`ITERM_SESSION_ID`) when the marker exists and `~/bin/claude-tab` is
executable, with all three streams off the terminal as the cookie mint; a machine
that never installed the panel pays one file test. **The first install is one
line the operator types in an iTerm2 shell: `claude-tab panel install`**; after
that every attended `claude` launch keeps it up.

**The page** is `dot_local/share/claude-tab/panel.html`, one file with no
external resource and no framework, deployed to
`~/.local/share/claude-tab/panel.html` on macOS only (`.chezmoiignore`). It
polls `/snapshot.json` every 2 seconds and draws the `needs` list in up to
three sections (`Blocked on you`, `Your move`, `Check`) with a closed `<n>
others` disclosure over the sessions by group; a click on a row posts `/go`
(`claude-tab focus`, whose `reveal` route lands in a buried peer's pane), the
`✓` posts `/seen`, a 409's `error` shows in the status line for ten seconds.
A row's reason is shortened (`permission prompt` reads `prompt`) so the name
keeps the width; the tooltip holds the whole word. Text reaches the page only
through `textContent` (a label is a directory's name), and the test refuses `innerHTML`, `document.write`, `eval`, any
`http:`, `https:` or `//` address and any private-use glyph. Rows are updated in
place by pid and kind, so a poll neither resets a hover nor re-fades a row. It
looks like the Toolbelt's neighbours: Base16 Eighties on `#282828` (a step
lighter than the terminal, to sit level with the Toolbelt's grey panels) in a
monospace face by default, a light variant under `prefers-color-scheme: light`,
and the kind colours of Session Status (`blocked` blue, `asked` yellow,
`failed` red, `quiet` amber, `finished` green, everything else grey). The
list greys after 6 seconds without an answer (`no data for <N>s`) and is
replaced after 30 by `Not updating since <HH:MM>.` and the command that
starts the server; a failed snapshot is followed by a `/health` probe so a
server that is starting says so. A changed `build` reloads the page. Open
groups and the `others` disclosure are kept in `localStorage`. The test names
every kind of the snapshot, so a renamed kind fails there and not on the screen.

**The tell.** A snapshot whose `health.sessions` is 0 while `claude-tab list`
prints rows, or a row of kind `unknown`, means the registry's words moved.
Tests: `tests/claude-tab-panel.bats` (fixture registries, `--now`, `--focus`,
state under `BATS_TEST_TMPDIR`; the server tests start it on a free port with a stub
`osascript`, `ps` and `uname`).
