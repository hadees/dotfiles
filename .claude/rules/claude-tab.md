---
paths:
  - "**/bin/executable_claude-tab"
  - "**/bin/executable_tabname"
  - "**/tests/claude-tab.bats"
  - "**/tests/tabname.bats"
---

# claude-tab

**`claude-tab save` and `restore` bring the tabs back after a quit.** An iTerm2
quit takes every session with it, and `claude-peer install` and `default`
require one. `save [file]` writes the live sessions to
`$XDG_STATE_HOME/claude-tab/saved.tsv` (state, not a temporary directory, so it
survives a reboot; the previous file becomes `.prev`): one row per session,
`profile_dir, session_id, cwd, label, name, tty, where, window`, in iTerm2's
tab order. It leaves out peers (`claude-peer peers`, else the `peer-N` name),
sessions with no tty, a `kind` other than `interactive`, a cwd that is gone and
an unusable session id, and counts each on stderr; with nothing to save it
exits 1 and leaves the old file alone. `restore [--dry-run] [--window <id>]
[--delay <s>] [file]` (macOS) resumes each row with `cd -- <cwd> &&
CLAUDE_PROFILE=<profile dir> claude --resume <id>`, typed with `write text` so
the login shell and the `claude` wrapper run it. The profile is explicit
because history is partitioned per profile directory.

It works in **one window**, the current one or `--window`, and never creates a
window. Empty tabs of that window are filled first (one session, not the tab
running `restore`, every foreground process a shell), new tabs are made only
when those run out, and empty tabs in other windows are counted and left alone.
It does not use `worktabs`' script, which makes one window per group: the
operator rejected that. A row whose session is already live in that profile (same
id or same cwd) is skipped, so running it twice is safe; the live check reads the
registry of every directory in the saved file's first column as well as the
pinned ones, because `iterm2-relaunch`'s runner has no `CLAUDE_CONFIG_DIR`. Restored tabs carry no
worktabs mark, so a later `worktabs start` does not recognise them, and a
session opened by `workset open` comes back without its extra directories. The
registry layout is observed, not an interface. Tests: `tests/claude-tab.bats`
(stub osascript/ps/sleep, fixture registries).

**A saved row has nine columns**, `profile_dir, session_id, cwd, label, name,
tty, where, window, status`; `status` is the registry's, `-` when it has none,
and a file without the ninth column restores as before. `save` also writes
`<file>.peers` (`cwd<TAB>slot` for each running slot peer of a saved tab's
directory, from `claude-peer slots`; it rotates to `.peers.prev` with the main
file and is absent when no peer runs) and says `noted <k> running peers in
<file>.peers` on stderr. Overlay peers never show in the leader's `slots`, so
none is noted. `restore` gained four flags: `--prompt <text>`, appended as one
shell-quoted argument to the resume command of every session whose saved status
was not `idle`; `--prompt-for <session id> <text>`, the same for that one
session, idle or not (a live one is not resumed: the text is typed into the tab
its tty belongs to, in any window, `claude-tab: told the live session <label> in
its tab`); `--no-peers`; `--peer-wait <s>` (default 60). A prompt that is empty
or holds a newline, tab or carriage return is a usage error. After the tabs,
each noted peer gets `claude-peer start <slot> --continue -- <prompt>` from its
leader's directory: exit 0 counts as started, 3 as already running, 4 means the
pane is not waiting yet (the leader's `claude` has not entered its workgroup),
so it is tried again every two seconds until `--peer-wait`; the summary is
`claude-tab: peers: <s> started, <a> already running, <f> not started`.
`--dry-run` starts no peer and lists them as `peer<TAB>-<TAB><slot><TAB><leader>`.
Nothing alive is started twice: a row whose session is live is `skip:live`.
`iterm2-relaunch` is the main caller: it runs `save` before the quit and
`restore` after, with the two prompts (`iterm2-relaunch.md`).

`bin/claude-tab` reads the other side of the same join: `list` prints one
row per live Claude Code session across every profile (from each profile's
`sessions/<pid>.json` registry, the files `claude_sessions_here` reads),
labelled by `tabname`, with the iTerm2 window and title its tty belongs to;
`focus <pid>` brings that tab forward. `list` works anywhere; `tabs` and
`focus` need macOS. Tests: `tests/claude-tab.bats`, `tests/tabname.bats`.
`save` and `restore` bring the sessions back after an iTerm2 quit (see "Claude
peers"). The tab bar reads `<repo> (claude)` during a session; the conversation topic no
longer appears there.

`bin/tabname [--role] [dir]` (`~/bin/tabname`) is the label: the git toplevel's name, or
for a linked worktree the repo, an `@`, then the worktree name, so the worktrees
under `.claude/worktrees/` stay told apart. Outside a work tree it prints
nothing and exits 1 — never 0 with empty output. It is a script so the shim and
any other tab labeller (an Alfred switcher) share one answer. The worktree
format is `git config tabname.worktree-format '{repo} <glyph>{worktree}'`; the
default is ASCII because the toolbelt renders rows in iTerm2's UI font
(`NSFont.it_toolbelt()`), where a Nerd Font private-use glyph is a tofu box
unless proven otherwise. Set a glyph only after checking it in both the Session
Status tool and the tab bar.

**Roles.** A directory is a *peer* when its own git directory holds a live
`claude-peer.claim` (line 1 a pid that answers `kill -0`, line 2 the leader's
directory, line 3 the label), a *lead* when any live claim under
`<git common dir>/worktrees/*/` names it (or its toplevel) as the leader, and
*plain* otherwise; `--role` prints `<role><TAB><label>`. `tabname` reads the
claim files itself and does not call `claude-peer`, so it works where only it
is deployed. A tab whose peers are all waiting has no claim anywhere and keeps
the plain name; it becomes a lead at its next turn end once a peer runs. The
labels are `tabname.peer-format` (default `{repo} · {peer}`, `{peer}` being the
claim's label) and `tabname.lead-format` (default `{name} ▸ Lead`, `{name}` the
plain label); `{repo}`, `{worktree}`, `{peer}` and `{name}` work in all three
formats. The two role defaults hold ordinary Unicode characters (`·`, `▸`), not
private-use glyphs; live check L5 confirms they render in the toolbelt. `it2`
has `session set-name` and no tab-title verb, so the row name and the tab title
are one string while Claude runs: the role name wins and `[group]` is left off
(`tabstatus.group-prefix true` restores it). At a shell prompt the tab title
still shows `[group] <dir>`. `claude-tab` treats a directory as a peer only when
`claude-peer peers` says so; without `claude-peer` there are none. Tests: `tests/tabname.bats`.
