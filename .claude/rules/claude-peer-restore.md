---
paths:
  - "**/bin/executable_claude-peer"
  - "**/dot_functions"
  - "**/tests/claude-peer.bats"
  - "**/tests/claude-peer-screen.bats"
---

# Claude peers: a restored pane asks before it serves

After an iTerm2 crash, iTerm2 re-creates a workgroup's peer panes with the
directory it saved, which can be another repository than the leader's. Such a
pane runs `claude-peer run --as <slot> --wait`, takes `LEADER=$(pwd -P)` and would
serve that other repository: a tab of one profile showed a Claude of another.
A pane cannot see who opened it, so the entry leaves a record and the pane
looks for it. The pane itself is in `claude-peer.md`.

**The record.** When `claude()` sends the `claudePeerEnter` key (the same
condition, claude-profiles.md), it also writes
`${XDG_STATE_HOME:-~/.local/state}/claude-peer/entered/<epoch>.<pid>`, one line,
`<epoch seconds><TAB><pwd -P>` (`$EPOCHSECONDS`, loaded for the nonce). Nothing is
printed and any failure is silent: the launch never waits on it.

**The check.** It runs only where `claude()` could have written a record: `$ITERM_SESSION_ID`
set and the enter state file (`enter_file`) readable, the gate `claude_peer_key` uses. Without
both, `pane` carries on as before the check, with no prompt. Then `pane` runs `pane_entered` first, before the `claude-peer.start
auto` branch and before the first wait-file write. A record whose directory
equals the pane's `LEADER` and whose epoch is at most `CLAUDE_PEER_ENTRY_WINDOW`
seconds before now (default 60) or at most 5 after it means a workgroup entry
opened the pane, and it carries on as ever. Otherwise `pane_restored` prints

    <Label>: no workgroup entry was recorded for this pane; it would serve <repo>.
    Return if this tab is <repo>'s, q for a shell.

The wording covers both ways a pane gets there: iTerm2 restoring it after a
crash, and a workgroup entered from Shell > Workgroups rather than by `claude`
(the operator's wording, 2026-11-15). The pane then reads one line from
`${CLAUDE_PEER_TTY:-/dev/tty}`. It writes no wait file and
no `.term` sidecar meanwhile, so `claude-peer start` finds no waiting pane and
exits 4 as it does for none. Return goes on as a normal pane; `q`, Ctrl-C or end
of input is `pane_shell`, the plain shell `q` leaves today; anything else asks
again. An overlay pane is checked too: its `LEADER` is the public source root,
which is what `claude()` records from the leader tab. `git config
claude-peer.restore-check false` turns the check off (the test setups do; the restore tests turn it on with `check_on`, which also sets the two conditions).
Each check skips unparseable files. `claude()` prunes the records over a day old
(file modified more than 24 hours ago) as it writes a new one, by the glob
qualifier `(N.mh+24)`, so a launch forks nothing for it.

Tests: `tests/claude-peer.bats` ("restore check: ...") and, for the record,
`tests/claude-profiles.bats` ("workgroup key: a launch that sends ...").

## A pane whose terminal is gone ends

When `KillJobsInServersOnQuit` is off, iTerm2 keeps jobs alive across a quit, but a relaunch
can make fresh panes instead of reattaching, leaving the old `claude-peer run --wait`
processes with no terminal (`ps` tty `??`). They ignore HUP, so they live on: fzf fails
(exit 2), the list falls back, and they stay registered as waiting panes beside the new
ones, so `slots` showed two Betas and `start` could wake a Claude nobody sees.

`pane` records at its start whether it had a terminal (`pn_had`: `${CLAUDE_PEER_TTY:-/dev/tty}`
opens for reading, `pane_tty_ok`: a character device is opened for real, since `/dev/tty`
is readable by mode with no controlling terminal; the tests' FIFO or file counts while it
exists). `pane_lost` is that record with the terminal no longer opening, and it is asked
where the pane learns it: the line reader ended with no line (the quiet wait and
`pane_ask`, so the list and every question), and fzf failed. Then the pane exits 0
without a word and its EXIT trap removes the wait file and sidecars. A pane that never
had a terminal (tests, a detached start) keeps request-only waiting.

The wait file's line 1 once held the picker's output. bash keeps what a write to a dead
terminal could not deliver (EIO) in its stdout buffer and flushes it into whatever
descriptor 1 is redirected to next, here `printf >"$pn_me"`. The pane writes that file
with `env printf`, a process of its own whose buffer is empty. As a second line of
defence `waiters`, which `slots`, `panes`, `start` and the overlay roll-call read,
skips a file whose line 1 does not start with `/`; `pane_reap` already deletes any file
whose pid is dead.

Tests: `tests/claude-peer.bats` ("a waiting pane whose terminal is gone ...", "a pane
with no terminal from the start ...", "slots, panes and start skip a wait file ...").
