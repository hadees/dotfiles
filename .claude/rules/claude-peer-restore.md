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

    <Label>: iTerm2 restored this pane; it would serve <repo>.
    Return if this tab is <repo>'s, q for a shell.

and reads one line from `${CLAUDE_PEER_TTY:-/dev/tty}`. It writes no wait file and
no `.term` sidecar meanwhile, so `claude-peer start` finds no waiting pane and
exits 4 as it does for none. Return goes on as a normal pane; `q`, Ctrl-C or end
of input is `pane_shell`, the plain shell `q` leaves today; anything else asks
again. An overlay pane is checked too: its `LEADER` is the public source root,
which is what `claude()` records from the leader tab. `git config
claude-peer.restore-check false` turns the check off (the test setups do; the restore tests turn it on with `check_on`, which also sets the two conditions).
Each check deletes records whose epoch is over a day old and skips unparseable
files.

Tests: `tests/claude-peer.bats` ("restore check: ...") and, for the record,
`tests/claude-profiles.bats` ("workgroup key: a launch that sends ...").
