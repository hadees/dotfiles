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
id or same cwd) is skipped, so running it twice is safe. Restored tabs carry no
worktabs mark, so a later `worktabs start` does not recognise them, and a
session opened by `workset open` comes back without its extra directories. The
registry layout is observed, not an interface. Tests: `tests/claude-tab.bats`
(stub osascript/ps/sleep, fixture registries).
