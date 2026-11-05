# Session Status, the Claude Code integration, and Workgroups

New in 3.7. Every session can carry a **status** — a word, a coloured dot,
a text colour, an optional detail — shown as the tab's subtitle, gathered in
the **Session Status** toolbelt tool, and browsable across windows in the
**Cockpit**. Programs set it in five ways: two escape codes, the `it2` CLI, a
trigger, and `cc-status`, the hook binary behind the Claude Code integration.

Verified against the 3.7.6 bundle (menu nib, executable strings, `it2
--help`) and the 3.7.0–3.7.6 release notes. None of it has a page on
iterm2.com; the in-app help text of the Session Status tool is the only
first-party description, and it is quoted below.

## Seeing it

- **View > Toolbelt > Session Status** turns the tool on; **View > Toolbelt >
  Show Toolbelt** shows the toolbelt itself. Both are needed, and both are
  per window. From a script, the Python API's main-menu identifiers are
  `Show Toolbelt` and `Toolbelt.Session Status`:

  ```python
  for ident in ("Show Toolbelt", "Toolbelt.Session Status"):
      if not (await iterm2.MainMenu.async_get_menu_item_state(c, ident)).checked:
          await iterm2.MainMenu.async_select_menu_item(c, ident)
  ```

  Selecting toggles, so read the state first or you will close what was open.
- Each row: session name, dot, status text, detail, and a keyboard shortcut
  to jump there. Rows sort by status priority (customisable — the binary
  carries a `StatusPriority` popover), not by tab order. A gear-menu option
  hides the status *text* from tab subtitles and keeps only the dot
  (`ShowSessionStatusInTabSubtitle`).
- The bell button at the bottom of the tool is **Window > Notify on Status
  Change**: the next status change in that window raises an alert, then the
  toggle turns itself off. It is only available while the tool is open.
- **Cockpit** (`revealCockpit:` in the menu) is the cross-window view:
  group by status, window or workgroup, filter by status, and (3.7.5) a
  composer docked at the bottom that sends one command to many sessions —
  `@` picks the targets, Shift-Return sends.
- Session variables: `status` (3.7.5); app-scope counters
  `workingSessionCount` and `waitingSessionCount` for a badge or a status-bar
  interpolated string.

Statuses the app knows by name: `idle`, `working`, `waiting`, and since 3.7.5
`done` and `error`, which sort just below `waiting`. A keypress in a `done`
or `error` session marks it seen and returns it to idle. Any other word is
shown as written; where it sorts is unspecified.

## Setting it

### OSC 21337 — one status per session

The tool's own help, verbatim:

> **Control Sequence (OSC 21337):** Programs can set tab status directly:
> `printf '\e]21337;status=Working;indicator=#ffa500\a'`

Keys, separated by `;`: `status=TEXT`, `indicator=COLOR` (the dot),
`status-color=COLOR` (the text), `detail=TEXT` ("wraps up to 3 lines"). Colours
are `#RRGGBB` or xterm `rgb:RR/GG/BB`. An empty value clears that field.

### OSC 7501 — the Program Status Protocol (3.7.5)

> **Program Status Protocol (OSC 7501):** A program can report that it is
> idle, working, waiting on you, done, or failed, and can report on several
> tasks at once. A session with more than one lists up to four of them, most
> urgent first, under its own row.

Use it instead of 21337 when one program runs several things at once; each
task needing attention can post its own notification. No public spec exists;
the only wire format visible in the binary is a `7501;?` query form.

### `it2 session set-status`

`it2` is the 3.7 CLI (`Contents/Resources/utilities/it2`, put on `PATH` by
shell integration, compiled Swift). The status verbs:

```
it2 session set-status --status working --dot-color '#ff9500' \
                       --text-color '#ff9500' --detail 'building'
it2 session get-status                # JSON: status, text_color, dot_color,
                                      # detail, background_tasks, turn_open
it2 session get-background-tasks
```

`set-status` targets the active session unless given `--session <id>`, or
`--tmux "$TMUX" --tmux-pane "$TMUX_PANE"` from inside a tmux-integration pane.
Beyond the visible fields it stores two values the app keeps for later
queries: `--background-tasks N` (or `--background-tasks-delta ±N`, applied
atomically, clamped at zero) and `--turn-open true|false`. `--if-turn-open`
and `--if-background-tasks` make an update conditional on what is currently
stored, so a caller acting on a status it read a moment ago cannot overwrite
a newer one. `--expires-on <status>` (3.7.5) names the status to fall back to
when the work is over. `--quiet-if-unresolved` exits 0 when a tmux pane
cannot be resolved, for hooks that run on every event.

**Two traps.** `set-status` keeps every field it is not given, so a reset that
sends only `--status idle` leaves the old dot colour; send the full set. And
the flag names are derived from Swift property names, so `--background-tasks`
does not appear as a literal in the binary — `strings` will tell you it is
gone when it is not. Read `it2 session set-status --help`.

`it2` also works over SSH Integration (the request is routed back through
the conductor, behind a per-session permission prompt naming the host).

### The Set Tab Status trigger

Settings > Profiles > Advanced > Triggers: a regex on terminal output sets
status text, dot colour and text colour. 3.7 also added trigger actions
**Set Profile Setting** (pair it with Job Started / Job Ended event triggers),
**Enter Workgroup** and its exit counterpart, and event triggers that fire on
session end, a hostname change, or a variable changing.

## The Claude Code integration

Menu items **Install / Reinstall / Uninstall Claude Code Integration**; a
setup wizard (`Claude Code Integration Setup`) runs on first use. What it
installs:

- a symlink `~/.config/iterm2/cc-status` → `Contents/Resources/utilities/cc-status`,
  which the app re-creates if anything else is put there
  (`ensureCCStatusSymlink`);
- one hook entry per Claude Code hook event in `settings.json`, each running
  that symlink. `cc-status` reads the hook payload on stdin
  (`notification_type`, `permission_prompt`, `last_assistant_message`,
  `background_tasks`) and calls `it2 session set-status`;
- optionally the Enter / Exit Workgroup triggers on your profiles.

**Which `settings.json`.** The installer writes one config directory, recorded
as `NoSyncClaudeCodeConfigDirPath`. Since 3.7.5 it honours `$CLAUDE_CONFIG_DIR`
(it used to always write `~/.claude`). On a machine with several Claude Code
profiles that is one profile per install: the others get no rows until their
`settings.json` carries the hooks too.

Behaviour that changed inside 3.7, worth knowing before debugging a row:

| Version | Change |
| --- | --- |
| 3.7.0 | A Stop with background tasks still registered keeps the row at "working" (needs Claude Code 2.1.198+). That registry never ages out, which is why this repo puts a shim in front of `cc-status` — see "Session Status rows come from Claude Code hooks, through a shim" in the dotfiles `CLAUDE.md`. |
| 3.7.5 | A finished turn reports `done`, an API error `error`; Esc returns the row to idle; rows appear for Claude Code in tmux-*integration* panes, never in plain tmux. |
| 3.7.5 | The health check no longer calls a hook "broken" for `$HOME`, `~` or a wrapper script in the command, Reinstall keeps such commands instead of adding a duplicate, Uninstall leaves alone a command that also runs other programs, and a symlinked `settings.json` (chezmoi, Stow) is updated through the link instead of being replaced. |
| 3.7.5 | `cc-status --agent codex` follows Codex CLI from `~/.codex/hooks.json`; there is no installer for it. |
| 3.7.6 | A `settings.json` with a syntax error is left alone, not overwritten. |

## Workgroups

A workgroup turns one session into a cluster: split panes, tabs or "peers"
with their own name, command and toolbar, entered and left as a unit
(**Enter Workgroup** / **Exit Workgroup**, `nextWorkgroupPeer:` /
`previousWorkgroupPeer:` to move between peers). The Claude Code workgroup
adds **Diff** and **Code Review** peers; review comments become **Clippings**
(**Show Clippings**, ⌥⇧⌘G since 3.7.4), which can be sent back to Claude Code
— automatically when idle, if *Auto Send Clippings When Idle* is on.
`it2 session add-clipping` and `archive-clippings` drive the list from a
script. The workgroup toolbar can show an **AI Usage** gauge: Claude
subscription usage read through the `claude` CLI, using `CLAUDE_CONFIG_DIR`
from your shell.

The Session Status tool's *Merge workgroup statuses* collapses a workgroup's
peers into one row.

Read from the v3.7.7 source (the stamp is still 3.7.6, refresh pending):

- A peer's command is wrapped in an interactive login shell, so shell
  functions apply: `PTYSession.swift:2214-2217` calls
  `ITAddressBookMgr.commandByWrapping(inLoginShell:)`, which is
  `/usr/bin/login -f[q]pl <user> <ShellLauncher> --launch_shell - -i -c
  <command>` (`ITAddressBookMgr.m:848-861`).
- Members spawn in the leader's working directory at entry and are pinned there
  (`forceUseOldCWD: true`, `WorkgroupSessionSpawner.swift:299-330, 400-415`),
  so a Diff peer keeps diffing the repo the workgroup was opened on.
- The Session Status tool is per window, and *Merge workgroup statuses*
  collapses a workgroup to its visible peer (`ToolStatus.swift:58-60, 926-933,
  1043-1067`).

Distinct from this repo's `workset` (a set of git worktrees one Claude Code
session spans) and `worktabs` (tabs opened by group): a workgroup is an
iTerm2 layout around one session, and knows nothing about git worktrees.

## Floating panes (3.7.5)

Panes that float over the split layout: **New Floating Pane with Current
Profile**, plus a *Floating Panes* menu (Bring to Front, Send to Back, Dock
Floating Pane, Hide Floating Panes, Move Floating Pane Up/Down/Left/Right).
Saved in arrangements. From AppleScript, `create floating pane` on a session
(`with profile`, `command`) — the one 3.7 addition to the dictionary. tmux
integration maps them to tmux floating panes (tmux 3.7+; moving one needs
3.8).

## The Companion app

An iPhone app that pairs by QR code (**Pair Companion Device**, settings
under **Companion Device Settings**) over a Noise-encrypted channel through a
relay: browse sessions, watch live output, type, answer warnings, and
receive status-change and AI-chat notifications (`it2 notify <title>
<body>`). Since 3.7.5 pairing does not require AI ("Terminal viewing &
control only"). The pairing identity is kept in the Keychain beside the AI
keys; relay state is `NoSyncCompanion*`, so it never reaches a custom prefs
folder. Like the AI plugin, the code ships as a separately signed plugin
(`com.googlecode.iterm2.iTermCompanion`) that the setup wizard installs.

## Docs vs. the binary (3.7.6)

| Claim | Reality |
| --- | --- |
| There is documentation for any of this | None on iterm2.com. The Session Status tool's help text (`ToolStatus.HelpMarkdown`) and the release notes are all there is. |
| The help text says to add the trigger in "Prefs > Profiles > Advanced > Triggers" | Stale "Prefs"; everything else in 3.7 says Settings. |
| `it2tip`, the app's own feature tour | Has not one entry for Session Status, Workgroups, floating panes, the Cockpit or the Companion; it lists the same 123 titles as 3.6.11. |
| `--background-tasks` is a flag of `it2 session set-status` | It is, but the literal is absent from the binary; ArgumentParser derives it from `_backgroundTasks`. |
| Release notes: "Shell > New Floating Pane with Current Profile" | The item exists with that title; this record did not confirm its parent menu. |
