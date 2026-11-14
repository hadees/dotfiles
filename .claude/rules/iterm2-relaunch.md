---
paths:
  - "**/bin/executable_iterm2-relaunch"
  - "**/tests/iterm2-relaunch.bats"
  - "**/alfred/iterm2-relaunch/**"
---

# iterm2-relaunch: quit iTerm2, do the work that needs it down, bring it back

`bin/executable_iterm2-relaunch` (deployed to `~/bin/iterm2-relaunch`, macOS
only, kept off other classes in `.chezmoiignore`) quits iTerm2, runs a list of
work items while it is down, starts it again and resumes the Claude sessions. It
is a POSIX `sh` script around one `python3 -I -` heredoc, standard library only,
Python 3.9 clean. Exit codes: 0 done or handed over, 1 failed or refused, 2
usage or not macOS; the internal runner `_run` adds 3, iTerm2 did not quit and
nothing was done. Tests: `tests/iterm2-relaunch.bats`, which runs against stubs
only and never touches the real iTerm2; the seams are
`ITERM2_RELAUNCH_PREFS`, `_CLAUDE_TAB`, `_CLAUDE_PEER`, `_HEADS_UP`, `_BREW`,
`_APPLICATIONS`, `_TICK` (seconds per poll), `_ITEM_TIMEOUT` (polls any item
may take, default 600), `_DETACH=0` (run `_run` in the foreground) and `_PASS`
(more variable names the runner keeps under `env -i`; the tests' stubs read
some).
Siblings are named by absolute path because Alfred's PATH excludes `~/bin`.

**Why a quit at all.** iTerm2 reads its preferences folder once per launch and
writes it back at quit (`iTermRemotePreferences.m:1553-1561`, `:1747-1790`), so
a store written under it is overwritten, or raises "Settings ... changed since
iTerm2 started" at quit and turns composed units into false `kept`. That is why
`iterm2-prefs compose` and `install` and `claude-peer install` write only while
iTerm2 is quit; this tool is the way to have it quit on purpose.

## Items

`iterm2-relaunch [--yes] [--dry-run] [--no-restore] [--no-prompt] [--open]
[--wait <s>] [--grace <s>] <item>[,<item>...]...`; `items` prints `item<TAB>ready|nothing|
refused<TAB>detail` per item. They run in this order whatever the order given:
`prefs-install`, `prefs`, `claude-peer`, then the `brew:` items as given. A
failed item never stops the next, and iTerm2 is started and the tabs restored
whatever failed.

- `prefs-install`: `iterm2-prefs install`. Ready when the status line is not
  `composed...` and `install --dry-run` passes; refused with its message
  otherwise.
- `prefs`: `iterm2-prefs compose`. Ready with source changes waiting, `nothing`
  when in sync, refused when not composed (the detail names `prefs-install`).
- `claude-peer`: `claude-peer install`, then `claude-peer default peers` only
  when `claude-peer status` ends its `default:` line with exactly that (the
  mixed `default peers|builtin` line is the operator's to choose). Ready when
  `prefs-install` is itself ready in the same run, or `status` asks for
  `claude-peer install`, or its `default:` line asks for `default peers`.
  It comes after the two prefs items because `Workgroups` and the Enter
  triggers are reserved keys no preferences fragment may carry: `claude-peer
  install` writes them into the store iTerm2 loads, which `iterm2-prefs
  install` repoints. The runner waits up to 30 polls for a live
  compose-at-quit waiter (`compose-at-quit.pid`) before the first item and
  again before iTerm2 starts (`compose-at-quit: waited for its waiter`): the
  waiter and the items read, change and write the same files.
- `brew:<cask>`: `brew upgrade --cask <cask>`, for a cask that wants the
  terminal and its Claude sessions down (`claude-code@latest`). The token must
  match `^[a-z0-9][a-z0-9@._+-]*$` (no `/`, no `..`: Homebrew's own alphabet,
  checked in the C locale) and be named by `brew list --cask -1` before any
  `brew info` is run for it. Offered: `claude-code@latest`,
  `claude-code` and every value of `git config --get-all iterm2-relaunch.brew`,
  so `git config --add iterm2-relaunch.brew <cask>` is how a cask joins. Refused
  when it is not an installed cask, when it updates itself (`auto_updates`:
  iTerm2's own cask is one, its Homebrew record only looks stale and its updater
  restarts without killing sessions), or when it has a `pkg` or `installer`
  artifact (a password prompt the runner cannot answer).

Every item runs under a bound of `_ITEM_TIMEOUT` polls: a hung one is killed
with its children (`pgrep -P`, children first), logged `<item>: timed out after
<n>s`, counted failed (`<item>: exit 124`), and the next item and the start of
iTerm2 go ahead.

With iTerm2 running, the consent comes first (below); then the front judges
every item: a refused one stops everything, a `nothing` one is dropped, and
when none is left it prints `nothing to do; iTerm2 left running`. With a
`brew:` item it runs `brew update` first (a failure warns and uses the cached
state) and `brew fetch --cask` for each ready one before the quit, so iTerm2
is down for seconds, not for a download; a failed fetch refuses with `<item>:
download failed`. A current cask is `nothing` in the front but stays actionable
in the Alfred list, because only the front looks upstream.

**Passwords are ruled out, not handled.** The runner has no terminal, stdin is
`/dev/null` and `SUDO_ASKPASS` is unset, so a `sudo` that wants a password fails
at once and the item is logged failed. No askpass helper, and no sudo session:
every brew run resets the sudo timestamp. Every brew call runs from `$HOME` with
`HOMEBREW_NO_ASK=1` and `HOMEBREW_NO_AUTO_UPDATE=1`. Every item is polled
through an exit-status file (`item.rc`), not `kill -0`, because a finished child
stays a zombie under dash; a timeout kills the command and its descendants as
`pgrep -P` sees them (a `ponytail:` comment says a daemonised one may finish).

Which upgrades go through here: a session looks at what is outdated (the
Homebrew MCP tools where attached, else `update`), upgrades everything that does
not need the terminal down, and offers a relaunch only for what is left. The MCP
server runs inside a Claude session and dies with iTerm2, so it can never do
the `claude-code` upgrade; the detached runner does.

## The sequence

Front (no side effect before it is sure): flags and item names, then a live
runner refuses (`a relaunch is already under way (pid <n>)`), then, with iTerm2
running, the consent (`--yes`, or `[y/N]` on a terminal; with neither: `this
quits iTerm2 and ends every session in it; pass --yes once the operator has
agreed`, a no: `not quitting`), all of it before `brew update` or `brew fetch`
has run, then the items judged and `--dry-run` printing `would:` lines and
stopping (it asks nothing). With iTerm2 **not running** nothing is quit and
nothing is asked: the items run at once in the foreground and iTerm2 is left
closed (operator decision: opening an app nobody asked for is not this
command's job), `iTerm2 was not running; <n> items done, <f> failed; left it
closed`, exit 1 if an item failed; `--open` starts it afterwards (`started
it` / `could not start it`, after a wait for a compose-at-quit waiter). With it
running: `brew fetch`, an Apple-event probe, then `claude-tab
save` (a failed save, or no `claude-tab`, means restore is off, since restoring
the old file would bring back last week's tabs), then `run.log` rotates to
`run.log.prev`, then the runner is handed over. The caller is usually a Claude
session that the quit kills, so the hand-over is verified: the front returns only
once `run.pid` names a live pid and `run.log` has `start:`, and prints `runner
<pid> has the work (<items>) and asks iTerm2 to quit in <grace>s`, `log: <path>`
and `to call it off before iTerm2 is asked: iterm2-relaunch cancel`. Every
refusal after the flag parse is also a `refused:` line of the log.

Runner (`_run <wait> <grace> <restore> <prompt> <caller id|-> <item>...`, defaults
`--wait 120`, `--grace 5`), in this order: `start:` line; `quit: in <grace>s`;
the heads-up; the Apple-event probe; `defaults export` of the whole preferences
domain to `domain-before-quit.plist`; `quit: asking`; the AppleScript `quit` in
the background; `quit: asked`; a bounded poll for the process to go; `quit:
exited after <n>s`; the clean-shutdown mark; the items; iTerm2 started; the
restore; `done: <n> items, <f>
failed, restore <ok|skipped|failed>`. `free_screen` runs just before `done:`, so
`done:` is the last line.

- **Cancelling, and no trap.** From the start until `quit: asking` a TERM or INT
  (what `cancel` sends) only sets a flag the heads-up and grace waits check; the
  runner then logs `cancelled: before iTerm2 was asked to quit`, removes
  `run.pid` and exits 3. The flag is checked once more right after `quit:
  asking`, and never again: from the moment the quit is asked until `launch:` is
  logged the runner cannot be called off, and `cancel` refuses on `quit: asking`
  as on `quit: asked`. An `EXIT` trap starts iTerm2 once if the runner ends
  after the quit was asked and `launch:` was never logged (`launch: the runner
  ended early; starting iTerm2`), so a quit that was asked never leaves the
  operator without it. A handler, not `trap ''`: an ignored signal would be
  inherited by every item and the timeout's `kill` could not stop one.
- **The runner's environment.** The front starts the runner under `env -i` with
  an allowlist: `HOME PATH LANG XDG_STATE_HOME`, `LC_*`, every `ITERM2_RELAUNCH_*`
  seam and what `clean_open` passes on. What the runner starts (`claude-tab
  restore`, then `claude-peer start`) would otherwise record the caller's
  `CLAUDE_PID` and `CLAUDE_CODE_SESSION_ID` in a restarted peer's claim as Lead.
  The caller's id reaches the runner as an argument.
- **A process in a session of its own.** iTerm2 ends a job with `killpg` on the
  job's group (`iTermMultiServerJobManager.m:520,552`), so a process that called
  `setsid`, forked again and ignores SIGHUP survives. That is `detach`, fifteen
  lines of Python, with `closerange` so bats and Alfred stop waiting; no launchd
  job and no Alfred needed.
- **The heads-up.** Before it asks iTerm2 to quit, and again before the restore
  types into the window, the runner calls `screen-heads-up "<what>" <grace>`
  (exit 0 go, 1 not now, 3 could not ask, 4 another heads-up is waiting): a
  countdown that proceeds unless the operator answers "Not now". Not now before
  the quit logs `aborted: not now; nothing done` and exits 3; before the restore
  it logs `restore: not now; run: claude-tab restore`. Exit 4 is asked again up
  to 30 times, then counts as not now. A missing helper (`heads-up: no helper;
  waited <grace>s`) or exit 3 or 2 is waited out and logged. After a go,
  `screen-heads-up --free "<text>" --no-restore` runs on every way out
  (`--no-restore`: the helper's own would `open` the front app again and start a
  missing iTerm2 with the runner's environment). `iterm2-relaunch cancel` is the
  same "not now" for a session or a typed command: it tells a waiting helper
  `--not-now`, else kills the runner, and refuses once `quit: asked` is in the
  log (`too late: iTerm2 has been asked to quit`); with no runner it says `no
  relaunch is under way`.
- **The AppleScript `quit`, in the background.** A synchronous one blocks for as
  long as iTerm2's own "Quit iTerm2?" alert is open, so the runner polls for the
  process instead, up to `<wait>` seconds, then kills the `osascript`, logs
  `aborted: iTerm2 still running after <wait>s; nothing done` and exits 3. The
  alert (`applicationShouldTerminate`, `iTermApplicationDelegate.m:1038-1177`)
  appears only for a reason, with `PromptOnQuit` off that is closing more than
  one session while "Confirm closing multiple sessions" is on; Cancel in it still
  calls everything off. Nothing skips it for one quit (`it2 app quit --force`
  skips only `it2`'s own question, a signal skips the save of the preferences),
  and nothing here depends on it: the consent is the yes in chat or the Return
  in Alfred. Its text says which world the quit is in, "All sessions will be
  closed" or "Sessions will be restored automatically when iTerm2 is relaunched".
- **The probe first.** A runner that cannot send Apple events must find out
  before it has asked for anything: `aborted: cannot send Apple events to iTerm2;
  nothing done`, exit 3.
- **The saved domain and the clean-shutdown mark.** iTerm2 3.7.7 has crashed on
  scripted session changes, so after the exit the runner reads iTerm2's own
  `NoSyncLastShutdownWasClean` (set at `iTermApplicationDelegate.m:1167`, after
  the windows close and just before the preferences are written). `quit: clean`,
  or `quit: not clean (...)` with the command that lists what the store lacks:
  `iterm2-prefs capture --from <state>/domain-before-quit.plist --all`. The items
  still run, because the store as iTerm2 last saved it is a consistent input.
- **`clean_open` and the allowlist.** `open` hands its own environment to the app
  it starts and the app keeps it for its whole run, so every tab would inherit a
  Claude session's variables (`worktabs.md`). `clean_open` resolves `open` on the
  caller's PATH, then runs it under `env -i` with `HOME`, a fixed `PATH` and only
  `USER LOGNAME SHELL DISPLAY COMMAND_MODE __CF_USER_TEXT_ENCODING` passed
  through, and `TMPDIR` from `getconf DARWIN_USER_TEMP_DIR` and `SSH_AUTH_SOCK`
  from `launchctl getenv SSH_AUTH_SOCK` (both read-only), the caller's own only
  when that answer is empty. Both iTerm2 and, for `alfred-install`, Alfred are
  started this way.
- **The restore is watched.** The runner polls `claude-tab restore --dry-run`
  until it passes (iTerm2 may sit in a first-launch question with no window), asks
  the heads-up, then runs `claude-tab restore`. If the iTerm2 it started is no
  longer the one running afterwards it logs `restore: iTerm2 exited during the
  restore (crash?); started it again, restored nothing further` and does not loop.
  `restore: failed; run: claude-tab restore` is the by-hand fallback.

## What a relaunch ends, and what comes back

Quitting ends every session in iTerm2, the caller's included, unless jobs
survive the quit (below). Back, by `claude-tab restore` (`claude-tab.md`): each
saved Claude tab by `cd -- <cwd> && CLAUDE_PROFILE=<profile> claude --resume
<id>` with the saved profile, plus a one-line prompt when its status was not
`idle`; the session that started the relaunch gets its own prompt naming the log
(`--prompt-for`); slot peers that were running by `claude-peer start <slot>
--continue -- <prompt>`. Overlay peers are not restarted (running anything inside
an overlay is not this tool's business): their panes come back waiting and `c`
continues. Plain shells and `worktabs` marks do not come back; a restored tab
carries no `worktabs` mark, and a `workset open` session comes back without its
extra directories. `--no-prompt` sends no prompts; `--no-restore` neither
saves nor restores the tabs. The prompts say "carry on", and the caller's says to
read the log, run `iterm2-relaunch status`, check each item (`iterm2-prefs
status`, `claude-peer status`, `claude --version` after an upgrade) and report.
The caller id is `CLAUDE_CODE_SESSION_ID`; if that is not the registry's id the
caller simply gets the everyone prompt.

## Keeping sessions alive across a quit (findings)

Nothing here sets it; the runner reads the advanced setting once for a note and
never writes it, because the key is one iTerm2 syncs, it changes every ⌘Q, and it
is the operator's choice.

- Jobs survive a quit when `shouldLeaveSessionsRunningOnQuit` holds
  (`iTermController.m:177-186`, used at `:209-220`): jobs run in servers and
  window contents are restored (both default on), windows will be restored at
  the next launch (`NSQuitAlwaysKeepsWindows` on, startup not "open no windows"
  or "open arrangement"), and either Sparkle is restarting the app or the
  advanced setting `killJobsInServersOnQuit` is off
  (`iTermAdvancedSettingsModel.m:663`, "User-initiated Quit (⌘Q) of iTerm2 will
  kill all running jobs", default on). A running iTerm2 does see that setting
  change (`:102-123`, `:1016-1037`).
- Then windows are restored at the next launch and their sessions reattach to
  the still-running jobs; workgroups are rebuilt first and leftover servers are
  adopted into a window (`iTermApplicationDelegate.m:1766-1778`, `:1998-2012`).
  A shutdown still ends them; Option-quit still kills.
- So with the setting off a relaunch is: iTerm2 exits (the runner still sees the
  process go, since the jobs live in `iTermServer` processes), the items run,
  iTerm2 starts, its windows come back attached to the same jobs. A `claude-code`
  upgrade is installed but every session that kept running is still the old
  binary until restarted; the front prints `note: jobs survive a quit on this
  machine, so running Claude sessions keep the old <cask> until restarted` and the
  log has `<item>: <n> Claude sessions kept running through the upgrade and stay
  on <before> until each is restarted`.
- No session is started twice: `claude-tab restore` skips a row whose session is
  live in that profile, by id or by directory (`skip:live`, the registry's pid
  test, which holds while windows are still reattaching), and `claude-peer
  start` refuses a slot with a live claim (exit 3, counted as already running).
  A surviving session gets no prompt, except the caller, which is told in its
  own tab. The log says `restore: <n> sessions were still running and were left
  as they are`, and a restore in which every row was alive is `restore ok`.
- `worktabs.md` records an older measurement of "restores nothing"; what iTerm2
  restores by itself after a quit is not settled, and `claude-tab restore` fills
  empty tabs of the front window first and makes new tabs after, either way.

## The log, `status`, state

State is `${XDG_STATE_HOME:-$HOME/.local/state}/iterm2-relaunch/` (0700, files
0600): `run.log`, `run.log.prev`, `run.pid`, `domain-before-quit.plist`. Lines
are `<UTC time> <event>: <detail>`: `start:`, `quit:` (`in <grace>s`, `asking`, `asked`, `exited`, `clean`), `heads-up:`, `aborted:`, `compose-at-quit:`,
`<item>: exit <n>` (a brew item adds `<item>: <before> -> <after>` and, on a
timeout, `<item>: timed out after <n>s`), `launch: started|not seen after
30s|failed`, `restore:`, `cancelled:`, `refused:`, `done:`. `status` prints
`runner: <pid> running|none`, `last: <last log line>` and `log: <path>`. A log
that ends before a `launch:` line means the runner did not survive the quit.

## The Alfred front

`alfred/iterm2-relaunch/info.plist`, bundle id `local.iterm2-relaunch.alfred`,
keyword `irelaunch`. The Script Filter runs `"$HOME/bin/iterm2-relaunch" alfred`
(one line of JSON from the rows of `items`, no `brew update`, so it is quick,
and exit 0 always); Return runs `"$HOME/bin/iterm2-relaunch" --yes "$1"`. Rows:
one per item, a `nothing` prefs or `claude-peer` row and any refused row are not
valid, a current cask stays valid, and with two or more ready rows a first
"Everything that is ready (<n> items)" row carries their comma list. The
workflow holds no logic. Like `worktabs.md`'s, it is not a chezmoi target
(Alfred rewrites `info.plist`), and `iterm2-relaunch alfred-install [<dir>]`
zips it and hands it to Alfred, whose import sheet the operator confirms:
`handed iTerm2-Relaunch.alfredworkflow to Alfred; confirm the import in its
window`, then `then the keyword is "irelaunch"`. With no `Alfred*.app` in
`${ITERM2_RELAUNCH_APPLICATIONS:-/Applications}` or `~/Applications` it stops
with `Alfred is not installed; nothing built` before it makes a temp directory;
a zip or an open that fails removes the one it made.
Alfred's own first use of Apple events on iTerm2 may raise macOS's Automation
question once.
