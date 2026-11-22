---
paths:
  - "**/bin/executable_claude-peer"
  - "**/dot_config/claude-peer/**"
  - "**/tests/claude-peer.bats"
  - "**/tests/claude-peer-screen.bats"
---

# Claude peers: Lead and hand-offs

The part of `bin/claude-peer` that makes a handed-over step report back, and the
session that hands steps over. The rest of the script is in `claude-peer.md`.

**Lead** is one session per leader directory, known by its name. `claude()`
gives the launch that enters the workgroup the name `claude-peer name lead`
prints, Claude Code passes it to SessionStart hooks as `session_title`, and
`postbox hook start` prints `postbox: you are Lead of <dir> (session
<name>)…` when the two agree and the session is not a peer. Nothing else makes
a session Lead: a launch outside the wrapper, a second session in the
directory, a peer and a subagent are not, and `claude -n "$(claude-peer name
lead)"` is the by-hand form. Lead's to stop or re-task is a slot whose
`leader` in `slots` is its directory and whose claim says `by Lead`
(`claude-peer claim <worktree>`); a `by pane` claim is the operator's own
start. `stop` is the guard (**Stop**, below), so Lead never forces unasked. Re-tasking is a message to an
idle peer, or `stop` then `start --handoff`. The Hermes pane has no claim and
no `start`, so Lead uses Hermes only by `hermes -z "<task>"` through the
wrapper. Overlay peers and peers of another profile are not Lead's. The merge
gate is in `merge-gate.md`.

**Stop.** `stop <slot> [--force]` finds the claude under the claim's pid by its
registry record, `sessions/<pid>.json` in `$CLAUDE_CONFIG_DIR`, Claude Code's own
default `~/.claude` (what an unset one means) or a `claude.profile.*` directory
(that layout is observed, not an interface), and sends it TERM. Without `--force`
it accepts `idle`, and `shell` (at its prompt with a background task) once the
label has logged `done` since the claim's start (line 7, else the record's
`startedAt`); anything else, or no record, is refused with exit 5. With or
without `--force` it refuses a record whose `name` is not `session_name` of the
slot, and one whose `procStart` is not `ps -o lstart=` of the pid (spaces
squeezed), checked in the one list that signals, so a pid reused since is never
signalled; a record without `procStart` is not checked. `--force` with no record
signals every process under the claim, but only when the claim's pid is a
`claude-peer` process. Every refusal prints one line and first writes a `note`
`stop refused: <Label> <reason>`; a stop's `stop` line ends
`<TAB>session=<id or -><TAB>report=logged|none`, and a hand-off stopped with
`report=none` prints one stderr line naming the `--continue --handoff` start that
asks for the report. Readers take field 4 of a `stop` line as the label. The
worktree and transcript are never touched.

A slot with no live claim is still found when its worktree is gone (`orphan_of`):
a pane whose `<slot>.<pid>.term` sidecar survives in the common dir, with no wait
file of the same stem (so it is in a session) and no live claim, and a session
under it whose record is named for the slot. It is stopped by the same rules, with
no stop mark, and its line ends `<TAB>worktree=gone`. **The pane clock** holds a
pane-started peer (claim line 4 `pane`, line 9 `-` or empty, or any orphan) from a
caller that is a Claude session (numeric `CLAUDE_PID`), without `--force`: it is
refused until the record's `statusUpdatedAt` (milliseconds) is
`claude-peer.pane-idle-minutes` old (default 60, a non-number is 60, 0 turns the
clock off), and a record with no such time is refused. A shell that is not a
Claude session, and a hand-off claim, are never held.

**Names.** `session_name` is the one place a session name is composed,
`<repo>-<slot>`. `claude-peer name <slot|lead> [<dir>]` prints the name a role
gets there: a slot's, or Lead's, `<repo>-lead` in the main checkout and
`<repo>-<worktree>-lead` in a linked worktree (so two leaders of one
repository never share one); exit 1 outside a repository. `claude()` gives a
workgroup tab's launch that name (claude-profiles.md).

**Hand-offs.** `start --handoff` is Lead's way to hand a step to a peer. It is
refused with exit 2 and one line, waking nothing, with neither a prompt nor a
context, from inside a peer (`CLAUDE_PEER_WORKTREE` set), or without a numeric
`CLAUDE_PID` (it must run from a Claude session, whose Bash inherits it). The
`.meta` gains `lead_pid=` and `lead_sid=` (`CLAUDE_CODE_SESSION_ID`, `-` when
unset or odd) whenever `CLAUDE_PID` is a number outside a peer, and `handoff=1`
with the flag; `pane_go` reads `PG_HANDOFF`, `PG_LEADPID`, `PG_LEADSID` and the
claim gains lines 8-10, `handoff` or `-`, the pid or `-`, the session id or `-`
(a start from the pane writes `-` three times). With `PG_HANDOFF` and a
prompt, `pane_go` appends an empty line and `handoff_note`, a fixed paragraph
(only the directory varies) saying the session is stopped once Lead has read the
report and telling the peer to write it under
`${XDG_STATE_HOME:-$HOME/.local/state}/claude-reports/<rname>/` (`$rname`, the
session-name prefix, not the slot) with the headings Asked, State, Decided, Learned,
Open and Session (`peer-lifetime.md` in the shared topics says what goes under each)
and end with `claude-peer log done "<STATUS>: …"`; a context's body gets it after
substitution. A plain start
with a prompt or context from a Claude session warns on stderr `not a
hand-off: nobody is told when <Label> finishes (--handoff)`; stdout and the
exit status do not change. `claude-peer claim [<dir>]` prints the live claim
as ten `key<TAB>value` rows (`pid leader label by context task started
handoff lead-pid lead-sid`, `-` for a missing line), exit 1 without one.
`log idle [<text>]` is for a handed-over peer's Stop hook: outside a live
hand-off claim it writes nothing; otherwise it writes `<Label> stopped after
<dur> without logging done[: <text>]` (text cut to 200) unless this label
logged `done` or `note` strictly after the turn mark, `claude-peer.turn` beside
the claim (missing: the claim's line 7), and sets the mark to now either way.
`log --as <name> idle <text>` writes the line as given. `idle` closes no
claim; every written line calls `lead-news` with the claim's lines 9 and 10.
`run_session` removes the mark with the claim, `write_claim` a stale one.
How a session ended is one of three lines, chosen by `pane_go` after
`run_session` returns. `cmd_stop` writes the stop mark, `claude-peer.stop`
beside the claim (who asked), after its busy check and before the first
signal, and removes it when the session does not exit in time; with the mark
there the line is `end` with ` (stopped by <who>)` and nobody is told (the
mark goes). Without it, a hand-off is `gone` with the plain end line's text, and `lead-news`
is called with lines 9 and 10, so Lead's own `stop; start` never wakes it.
Anything else is the plain `end` line. `gone` closes that label's claims as `end` does.
A file is used because `stop` logs only after the claim is gone, so the log's
order cannot tell a requested stop from an ending; `write_claim` removes a
stale mark. Once the claim is seen, `start --handoff` also leaves postbox's
stall clock running, detached (`handoff-check <leader> <worktree> <pane pid>
<lead pid> <lead sid>`), unless `claude-peer.stall-minutes` is 0 or postbox is
absent; `start`'s output and status do not change.
