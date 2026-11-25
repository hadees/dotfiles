---
paths:
  - "**/bin/executable_claude-peer"
  - "**/dot_config/claude-peer/**"
  - "**/tests/claude-peer.bats"
  - "**/tests/claude-peer-screen.bats"
---

# Claude peers: the bar, the jobs record, the queue and the secretary pane

The part of `bin/claude-peer` that sets the bar, keeps what Lead dispatched, queues what
the operator thought up, and runs the pane to think in. The rest of the script is in
`claude-peer.md`.

## The bar

The bar is `Lead, Ideas, Agents[, Hermes]`. **Ideas is the slot `secretary`**: the
label is the operator's, while the slot, the session name `<repo>-secretary` and the code
keep `secretary`. `build_base` returns the root and two
peers under an id prefix: `<prefix>.secretary` (label `Ideas`, command `claude-peer run
--as secretary --wait`) and `<prefix>.agents` (label `Agents`, command `claude-peer
agents`). `Claude Peers` (`claudePeer.workgroup`) has three sessions and `Claude
Peers + Hermes` (`claudePeer.h`) four, Hermes last (`with_hermes` is unchanged). The
root's id, which the Enter triggers are keyed to, is `<prefix>.main` as before.

**The Agents pane** is a viewer: no slot, claim, worktree or hand-off. `claude-peer
agents` goes to the repository's main checkout (even from a linked worktree of it)
and runs `claude agents --cwd <that checkout>` through an interactive shell, so it is
the `claude()` wrapper that picks the repository's profile, exactly as for Lead. It
shows the background and forked sessions started under that repository, not Lead's
in-process subagents (those are in the jobs record below). When `claude agents` ends,
or `claude` is not on `PATH`, the pane says so in one line and waits: Return runs it
again, `q` (or end of input) leaves a plain shell, so a failing `claude` never spins.
Outside a repository it is one line and a plain shell. Unlike the Ideas pane it
starts at entry, since there is nothing to wait for.

`install` builds no overlay pair: it passes no overlay names, so a stale `Claude
Peers + Overlays` pair and the overlays state file are removed (the branch a machine
with no overlays already took) and `here` answers `base`. The overlay code
(`build_overlays`, `overlay`, the `overlays:` lines of `status`) stays until the step
that deletes it, and `status` still says `overlays: not installed` for a machine that
has overlays. `status` reports `workgroup:` and `hermes:` as `installed, out of date
(...)` until the next `install` (iTerm2 quit); a tab opened before the relaunch keeps
its older panes.

## The jobs record

Workers are subagents: no pane, no claim, no registry record, so nothing of them
survives Lead's compaction or restart. Claude Code's own events are written to
`<git common dir>/claude-peer.jobs`, beside the coordination log, by `claude-peer
job hook`, one line per event, append-only, tab-separated, tabs and newlines in
text written as spaces:
`<UTC time><TAB><who><TAB><event><TAB><agent id><TAB><agent type><TAB><text><TAB><worktree>`.

- `event` is `start` (SubagentStart), `stop` (SubagentStop; text is the
  `description` of `agent_transcript_path` with `.jsonl` replaced by `.meta.json`, empty
  when that file does not parse) or `report` (PostToolUse of `SubagentHandback`; text is
  the first line of `tool_input.message` cut to 200 characters, then a space and the
  first path in the message that holds `/claude-reports/`).
- `who` is the label of the basename of `CLAUDE_PEER_WORKTREE` when the hook's
  environment has it (a peer's own session), else `Lead`. `log_who` is not used: it
  answers `Lead` only while a peer holds a claim. `worktree` is the payload's `cwd`
  when its toplevel is not the repository's main checkout, else `-`.
- The hook reads one payload on stdin (python3, as `peer_py` needs it) and **prints
  nothing and exits 0 whatever happens**: no repository, bad JSON, no python3, an
  unwritable file. A SubagentStop hook that prints or exits 2 keeps the subagent
  running. A start or stop with an empty `agent_type` (Claude Code's own internal
  agents) and any event with no `agent_id` write nothing; a start of an internal agent
  would otherwise never get its stop and read as running.
- `job settings` prints the three `settings.json` entries (`SubagentStart` and
  `SubagentStop` with no matcher, `PostToolUse` matched on `SubagentHandback`, each
  `[ -x ~/bin/claude-peer ] && exec ~/bin/claude-peer job hook || true`, timeout 5).
  It edits nothing: each profile's file is its overlay's.
- `claude-peer jobs [--all | --since HOURS] [<dir>]` prints one row per agent id first
  seen in the window (default 24 hours), newest first:
  `state<TAB>agent id<TAB>who<TAB>type<TAB>started<TAB>ended<TAB>worktree<TAB>description<TAB>report`,
  `-` for a missing field. `state` is `running` (no `stop`), `ended` (a `stop`) or
  `reported` (a `stop` and a `report`). `jobs_running <who>` is the same rows asked
  one question: exit 0 when `<who>` has a `running` row in the last 24 hours.
- The `.meta.json` and its `description` are observed at Claude Code 2.1.325, not an
  interface: a change leaves the description `-`, never a missing row.

Tests: `tests/claude-peer.bats` ("job hook: ...", "jobs: ...", "jobs_running: ...",
"job settings: ..."). `jobs_running` is a shell function, so its test extracts it
from the script with `sed`.

## The queue

What the operator thinks up while Lead builds is a card in
`<git common dir>/claude-peer.queue`, beside the jobs record. Nothing is pushed
into Lead on a clock: Lead pulls the next card when `gh pr merge` returns, and
Lead never reads the queue itself. Append-only, tab-separated:
`<UTC time><TAB><id><TAB><event><TAB><who><TAB><value><TAB><text>[<TAB><file>]`;
`id` is `Q<n>` from the highest id in the file (`-` for a refusal; two adds in one
instant can share one, there is no lock), `event` is `add`, `refused`, `set`,
`take`, `done`, `drop`, `park`, `reopen`, `escalated` or `link`. A card's state is
its last `add` or `reopen` (waiting), `take` (taken), `done`, `drop` (dropped) or
`park` (parked); `set` changes its `waiting` (the operator is waiting on it), `unblocks` 0 to
9, `prio` 0 to 3 or `size` S, M, L (`?` until set).

- `queue add [--kind idea|plan|ask|unfinished] [--waiting] [--unblocks N] [--prio P]
  [--size S|M|L] [--session SID] [--as NAME] -- <one line> [<file>]` prints the id.
  The value is `<kind>:w=<0|1>:u=<N>:p=<P>:s=<S|M|L|?>[:session=<SID>]`. An `idea` or
  `plan` needs a file that meets the definition of done: the headings `## Goal`,
  `## Matters`, `## Constraints`, `## Decided`, `## Open`, `## Next` in that order,
  and a non-empty line under `Goal` and under `Next`. Otherwise exit 1, one stderr
  line naming what is missing, and a `refused` line (id `-`, the reason as text). A
  relative file is stored absolute. `who` is `--as`, else `log_who`. A bad option value is
  exit 2.
- **The wake.** Only when Lead has nothing in flight (no card `taken` and
  `jobs_running Lead` fails) does `add` write `queue: <id> is waiting and nothing is
  in flight` to the log as a `note` and call `tell_lead`. With work in flight it
  writes and wakes nothing.
- **The escalation**, with no timer of its own: `add`, and `job hook` on a `stop`
  event, look for waiting-tier cards (`waiting=1`, not `unfinished`) older than
  `git config claude-peer.queue-wait-minutes` (120; 0 never; not a number is 120)
  with no `escalated` line, and for each write that line, then a `note` by `Queue`
  (`queue: <id> has waited <n>m and it is marked waiting`) and `tell_lead`. Once per
  card, ever. It is the one push into a busy Lead; delivery waits as
  `postbox.md` describes.
- `queue list [--all] [<dir>]` prints the waiting cards in pull order, 13
  tab-separated columns: `order id tier score lo hi terms age kind who cand text
  file`. `terms` is the arithmetic (`u=20 p=10 h=7 /2`, ` size?` appended for an
  unknown size), `age` is `dur_of` form (since the last `add` or `reopen`), scores
  have one decimal, `cand` is `yes` or `-`, `file` is `-` for none. `--all` adds every
  other card after them, newest first, with the state word in the first column and
  `-` in the computed ones (a `taken` card is listed only there). `queue next [<dir>]`
  prints the candidate rows and exits 3 with none. `queue show <id>` prints the card's
  lines and, with a `session=`, how to reopen it: `claude-peer start <slot>
  --continue` when the session is the newest transcript of the card's `who` slot
  (`<root>/.claude/worktrees/<who in lower case>`, under
  `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<path, non-alphanumerics as ->`, a layout
  observed, not an interface), else `claude --resume <SID>` and the directory.
- `take`, `done`, `reopen`, `drop`, `park`, `link`: an unknown id, or a state other than
  the ones the verb applies to (`take` waiting; `done` taken; `drop` and `park` waiting or taken;
  `reopen` anything but waiting), is exit 3 with one stderr line; `drop` and `park`
  without a reason, and a bad `set` or `link`, are exit 2. `take` writes `order=<n>`,
  the card's position in `list` at that moment, so the formula's agreement with what
  was picked can be counted.
- **The pull order.** Tier 1 is `waiting=1`, tier 2 everything else, tier 3 kind
  `unfinished` (listed, never offered). Inside a tier, highest score first, then the
  older card:
  `score = (20 x min(unblocks, 3) + 10 x prio + 1 x min(hours waiting, 24)) / D`, `D`
  being 1, 2 or 4 for S, M or L. The tier is a sort key, never a term, so no age or
  size lets a card pass the one the operator is waiting on. A `?` size scores as M and has a
  range, `lo` as L and `hi` as S. The **candidates** are the cards of the first
  non-empty tier whose `hi` is at least 85 percent of the largest `lo` in that tier.
  While a card is `taken`, only tier 1 cards and cards with `unblocks` above 0 are
  considered, so a plan in flight is interrupted between its pull requests only for
  those. Weights: `git config claude-peer.queue-weights "unblocks=20 prio=10 hour=1
  hourcap=24 margin=15"` (the defaults; an unknown name or a value that is not a
  whole number is ignored with one stderr line each). It is computed in python in
  integers (hundredths), because two awks round a float apart.
- **The hook.** `queue hook` reads a PostToolUse payload and acts only for a Bash
  call whose command contains `gh pr merge`, with no `agent_id`, no
  `CLAUDE_PEER_WORKTREE`, and a `cwd` whose toplevel is the repository's main
  checkout. Otherwise, and on any error, it prints nothing and exits 0. It prints one
  JSON object (`hookSpecificOutput`, `PostToolUse`, `additionalContext`) of: a
  `taken` card named first (`queue: <id> is still taken; if this merge finished it,
  claude-peer queue done <id>.`); then, with one candidate, the card (`queue: next
  card is <id> (<kind>, score <s>: <terms>): <text>. File: <file>. Take it with ...
  Nothing worth doing is an answer: say so and stop; never invent work.` and ` <m>
  more waiting.` when m is not 0), or with several, the brief for one `scout-haiku` that
  reads only those files, so a model chooses among candidates and never over the operator's
  priority; with one candidate no model runs. Nothing at all when there is no card
  and nothing is taken.
- `queue settings` prints the one `PostToolUse` entry for the overlays (matcher
  `Bash`, `"if": "Bash(gh pr merge *)"`, timeout 5). The `if` is what keeps the hook
  off every other Bash call; without it the handler spawns on `ls`.

Tests: `tests/claude-peer.bats` ("queue add: ...", "queue list: ...", "queue next:
...", "queue take: ...", "queue verbs: ...", "queue show: ...", "queue escalation:
...", "queue hook: ...", "queue settings: ..."). Fixture cards are written `ago`
seconds back, whole hours plus ten minutes; a postbox stub records its calls.

## The secretary pane

The pane is Ideas on the bar (above) and `secretary` in the code. The cap below counts
`*-secretary` session names, which are the Ideas pane's sessions; the note and the deny
list reach every non-hand-off pane start.

Every session a pane starts that is not a hand-off (`pg_ho` is not 1: Return, a picker
row, a typed task, `c`, a plain `claude-peer start`) is the operator's secretary: one
idea per session, researched and shaped in chat, ended with one card in the queue. A
`start --handoff` is untouched, so the hand-off path (Lead's hand-offs, and the trial's
control arm) behaves as it did. `pane_go` sets `pg_sec` to 1 for a secretary start.

- **Fresh tree.** For a `fresh` start, a slot that is detached, has an empty `git
  status --porcelain` and whose `HEAD` is an ancestor of `origin/HEAD` is moved to it
  (`checkout --detach`, no fetch; a slot with no `origin/HEAD`, or commits no branch of
  the remote holds, stays). Anything else is left as it is. `HEAD` and the branch at
  start are `pg_h0` and `pg_b0`.
- **The cap.** Before a slot is taken, the live sessions named `*-secretary` are counted
  across the registry of every `profile_dirs` directory (`pane_secretaries`: name and
  pid only, the pid passing `session_same`). With `claude-peer.pane-max` (default 2; 0
  never warns; not a number is 2) or more open, the pane prints `claude-peer: <n>
  conversations are open (<names>); Return again opens another` and waits; a second
  start within 60 seconds goes ahead and logs a `note`, `pane over cap: <n+1>`. The
  stamp is the pane's own `pn_cap_t`, so another pane's Return does not count as the
  second one. The cap sits before the slot because a refusal after it would leave a
  claim. The registry layout (`sessions/<pid>.json`, its `name`) is observed, not an
  interface.
- **The arguments** follow `--permission-mode` and come before `--agent`: `--disallowedTools
  <deny list>`, then `--settings '{"crossSessionInbound":"refuse"}'`, then the seat note
  joins the system prompt. The deny list is **one** argument, because `--disallowedTools`
  is variadic and would take the prompt for a tool name; `--settings` after it is what
  ends it. `git config claude-peer.pane-deny` replaces it (default
  `Edit,NotebookEdit,SendMessage,ListAgents,Agent(work-sonnet),Agent(unstick-fable)`;
  `none` passes no deny pair; a value that starts with `-` is said once and the default
  used). A context's `system:` text and the note are one `--append-system-prompt`, the
  text first, an empty line, then the note.
- **The seat note** (`secretary_note`) is the text the operator signed, worded in the
  third person as "the operator", "they", "their" and "the operator's"; the operator
  approved that wording (2026-11-25). "The library" is left out of its research sources,
  a tool only some machines have. Only `<rname>`, the session-name prefix, is replaced. It tells the
  session to keep one idea file under `${XDG_STATE_HOME:-$HOME/.local/state}/claude-reports/<rname>/`,
  to finish with one `claude-peer queue add` (or `park` or `drop`), to write a `once`
  row to the approvals ledger for a go, and not to edit, commit, merge, dispatch
  `work-sonnet`, message another session or write `claude-peer log` lines. The tools
  that would do those are removed at launch; the note is the part no tool enforces.
- **Drift.** When the session returns and before the `end` line, a worktree with a
  branch it did not have at start, a `HEAD` other than `pg_h0`, or a non-empty `git
  status --porcelain` writes a `note` `pane drift: <branch <name>|commits|dirty> in
  <slot>`, in that order of preference. Nobody is told: the count is the signal.

Tests: `tests/claude-peer.bats` ("secretary seat: ..."). The stub shell leaves the
seat's three arguments out of what the older tests read, so they keep checking the
other arguments; `FAKE_SHELL_SEAT=1` keeps them and `FAKE_SHELL_RAW=<file>` logs one
argument per line. `FAKE_SHELL_DO` runs a command in the worktree, to commit or dirty it.

## The clock: the pane ends what is finished or forgotten

A secretary start (`pg_sec` is 1) with `claude-peer.pane-end-minutes` over 0 (default 60;
0 starts no clock; not a number is 60) gets a watcher: `pane_go` starts `pane_watch` as a
background subshell before `run_session` and `pane_unwatch` ends it, and the sleep it is in,
as soon as the session returns. `pane_cleanup` calls `pane_unwatch` too, so a killed pane
leaves neither. One process per running secretary and none for a waiting pane, whose rule
against polling is in `claude-peer.md`. A hand-off has none. `CLAUDE_PEER_TICK` is the
seconds between looks (default 60; the tests' handle). This clock **ends** the session; the
hold in `claude-peer-handoff.md` and the shared `peer-lifetime.md` (`pane-idle-minutes`, also 60) only makes `stop` refuse a
session that has not been idle that long. Two settings, two effects.

Each tick it takes `session_record` of the pane's own pid, which names the Claude under it
and its registry record, and ends the session by TERM when all of these hold:

- the record's `status` is exactly `idle`;
- `statusUpdatedAt`, in **milliseconds**, is at least the limit old;
- nobody typed at the pane's terminal in that time: its access time (`stat`, the
  `w` command's idle time), which no registry field shows, so an unsent draft keeps the
  session. A terminal that cannot be read (`stat` fails) counts as no input;
- no write to the session's transcript (`<profile dir>/projects/*/<sessionId>.jsonl`) or to
  anything under `projects/*/<sessionId>/subagents/` in that time (`find -mmin`), so a
  planner still running keeps it alive. What `status` reads while only background subagents
  run is not established, so `idle` is never trusted alone. Those paths are observed, not an
  interface: where they change, the test passes and a session is ended on `idle` alone.

The limit is `claude-peer.pane-done-minutes` (default 5) when `verdict_since` holds, else
`pane-end-minutes`. `verdict_since <label> <start>`: the queue file has an `add`, `park` or
`drop` line by that label at or after the session's start (a `refused` line is not one). A
`pane-done-minutes` of 0 keeps the long limit.

The signal is one list with `session_same` (the pid-reuse check `stop` makes), after the stop
mark `claude-peer.stop` is written with `the pane, finished` or `the pane, idle <n>m` (n the
limit). `pane_go` reads the mark as it does `stop`'s, so the end line is `<Label> ended
after <dur> (stopped by the pane, finished|idle <n>m)`; a mark left by a signal that did not
land is removed. The watcher stops after one signal. `c` racing the check is safe: a
continued session is `busy`, and the next tick does nothing.

A session the clock ended **without** a verdict gets a reminder from the pane, no model
involved: `queue add --kind unfinished --session <id> --as <Label> -- "<task or 'a
conversation'> (left unfinished)"`. It is tier 3: `queue list` shows it, Lead is never offered
it, and (unlike any other card) adding it never wakes Lead, nothing being in flight or not:
a reminder has nothing for Lead to do. `queue show <id>` prints how to reopen it; `c` at the
pane continues the last conversation.

The end line of every secretary start, however it ended, gains `<TAB>session=<id>`, the field
a `stop` line has, or `session=-` when the clock never saw the session (it looks once per
tick, so one shorter than a tick, or a start with no clock, has no id). The watcher keeps the
id in `claude-peer.stop.sid` beside the stop mark; `pane_go` reads and removes it.

Ceiling: a session that ignores TERM leaves the mark behind and the end line it writes later
is still `stopped by the pane`; `stop` removes its own mark after 15 seconds, this does not.

Tests: `tests/claude-peer.bats` ("pane clock: ...", "queue add: an unfinished card ..."). The
stub session registers itself with `reg.sh` through `FAKE_SHELL_DO`: its record is named for
the stub's pid, with a status, an age in minutes and a session id.
