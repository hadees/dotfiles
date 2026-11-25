---
paths:
  - "**/bin/executable_claude-peer"
  - "**/dot_config/claude-peer/**"
  - "**/tests/claude-peer.bats"
  - "**/tests/claude-peer-screen.bats"
---

# Claude peers: the bar, the jobs record and the queue

The part of `bin/claude-peer` that sets the bar, keeps what Lead dispatched and
queues what the operator thought up. The rest of the script is in `claude-peer.md`.

## The bar

The bar is `Lead, Ideas, Agents[, Hermes]`. `build_base` returns the root and two
peers under an id prefix: `<prefix>.secretary` (label `Ideas`, command `claude-peer run
--as secretary --wait`; the slot, the session name `<repo>-secretary` and the code
keep `secretary` for now) and `<prefix>.agents` (label `Agents`, command `claude-peer
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
