---
paths:
  - "**/bin/executable_shared-memory"
  - "**/tests/shared-memory-hooks.bats"
  - "**/tests/claude-shared-memory.bats"
  - "**/dot_claude-shared/**"
---

# Shared memory on demand (`shared-memory`)

The shared Claude memory (`dot_claude-shared/`, deployed to
`~/.claude-shared`) is an index, `CLAUDE.md`, and one file per topic in
`topics/`. Every profile's `CLAUDE.md` imports the index, so whatever the
index imports is in the context of every session and every subagent.
`bin/executable_shared-memory` (`~/bin/shared-memory` once deployed) keeps
the situational topics out of that and adds each one to a session when it
applies.

**Status.** The repository wires nothing: every profile's `settings.json`
belongs to its overlay, so the hooks run only in a profile whose overlay has
pasted in the output of `shared-memory settings`. On 2026-11-25 every
profile of one deployment that imports the index was wired with `hook start`
and `hook tool` and logged injections (`shared-memory log`); `hook main`
arrives with the overlays, and until then `claude-doctor` reads `partly wired
(missing main)`. A subagent there was observed to hold the
imported topics and no start text, and to get `github-accounts` from the tool
hook on its first `gh` command, which is the design below. A public-only
clone, or a profile that is not wired, still has the index paragraph alone,
which tells Claude where the topics are. The `topics:` line of
`claude-doctor` says whether a profile is wired. What the hooks cost per Bash
call has not been measured.

## Load classes

- **Always loaded**: the topics the index imports with an `@topics/<slug>.md`
  line on its own. This costs context in every session and every subagent, so
  a topic gets one only if every seat must know it before any tool call, such
  as the denied-paths and worktree rules. `tests/claude-agents.bats` holds a
  ceiling on this part's size. Lower it when it shrinks, never raise it.
- **Main**: topics `hook main` adds to every main conversation at
  SessionStart and to no subagent, because a subagent never runs SessionStart.
  They are rules for the conversation that orchestrates. While the index
  still imports a topic, `hook main` logs it `imported` and adds nothing; the
  import is removed in a later change (PR B).
- **Start**: topics `hook start` adds to a session in a role (a Claude Peers
  tab, the Lead session, a repo with peers, postbox wired, a native inbox).
- **Tool**: topics `hook tool` adds the moment something happens (a failed
  signature, a first `gh`, a peer command).
- **Pointer only**: topics that are only listed in the index paragraph, with
  the situation that calls for each. Claude reads the file when the task
  arises, the way Anthropic's own auto memory points at its topic files.

Once the index no longer imports them, main, start and tool topics are listed
in the index paragraph too, so a session whose hook is missing or broken
still has a route to the file. The test of where a rule goes: must every seat hold it before any
tool call (always), only the conversation that orchestrates (main), a role
(start), or the moment something happens (tool).

Which topic is in which class is not copied here, because it drifts: run
`shared-memory topics` (add a directory to read a source tree, as
`shared-memory topics dot_claude-shared`). It prints one line per topic file:
the slug, `always`, `main`, `start`, `tool`, `pointer` or `unreachable`, and whether
the index lists the topic (`-` for an imported one, which needs no listing).
It exits 1 when a topic is neither imported nor listed, and
`tests/claude-shared-memory.bats` runs it on the source. A new topic file
therefore has to be imported by the index or named in its paragraph. The
paragraph has no `## ` heading and no bare `@` token: a heading would be read
by memoryguard as a section outside every topic, and an `@` would import.

Which topics a hook adds is the `TRIGGERS` table in the script, the one
place to change it.

## Why hooks

Imports do not save anything: Claude Code's memory page says imported files
are "expanded and loaded into context alongside the CLAUDE.md that references
them", and that imports "don't reduce its context cost"
(https://code.claude.com/docs/en/memory). Path-scoped rules load on Read,
Write or Edit of matching files, and these topics are about situations (a
failed signature, a peer tab), not files. Skills are out because their
descriptions are dropped from the listing without warning
(`docs/claude-delegation-notes.md`). A hook is the one deterministic trigger
for a situation. Facts about the hooks, from
https://code.claude.com/docs/en/hooks, which the design rests on:

- `additionalContext` is honoured on SessionStart, PostToolUse and
  PostToolUseFailure among others; plain stdout becomes context on
  SessionStart. `hook start` and `hook main` print plain text, `hook tool` prints JSON.
- PostToolUse fires only when the tool succeeded; a failed Bash call goes to
  PostToolUseFailure, whose `error` field starts `Exit code N` and carries the
  output. Both events are wired, and `tool_text` reads the right field for
  each.
- Settings hooks also fire for tool calls made inside subagents, with an
  `agent_id` in the input. A subagent never sees SessionStart, so it gets
  none of the main or start topics and does get the tool ones.
- SessionStart carries `source` (startup, resume, clear, compact, fork) and
  `session_title` when one is set, and is re-run after compaction
  (https://code.claude.com/docs/en/context-window).
- A non-zero exit other than 2 is a non-blocking error, and a hook that runs
  past its timeout has its output discarded.

## What it adds, and when

`shared-memory hook start`, on SessionStart, picks topics from five
conditions, each checked without a model:

- a Claude Peers tab: `CLAUDE_PEER_WORKTREE` is set;
- the Lead session: the payload's `session_title` ends in `-lead`;
- a repo with Claude Peers: `claude-peer slots <dir>` prints at least one line
  within 3 seconds (`SHARED_MEMORY_CLAUDE_PEER` names a different
  executable; `<dir>` is `CLAUDE_PROJECT_DIR` when it is a directory, else the
  payload's `cwd`);
- postbox wired: `~/bin/postbox` is executable and the profile's
  `settings.json` contains `postbox hook start`;
- a native inbox: `CLAUDE_CODE_MESSAGING_SOCKET` names a socket.

The topics are chosen by role:

| Topic | Added when |
| --- | --- |
| `talking-to-sessions` | any of the five conditions |
| `claude-peers` | any of the first three |
| `peer-seat` | a Claude Peers tab |
| `lead`, `approvals` | the Lead session and not a Claude Peers tab |

`shared-memory hook main`, also on SessionStart, has no condition: it runs no
`claude-peer`, keeps no state and adds the same text to every main
conversation, whatever its title or worktree. Its output is the line
`shared-memory: these shared-memory topics apply to this session (a main
conversation), so they are added here:` and then the text of each slug of
`MAIN_ORDER`. It runs on every `source`, like `hook start`, and `hook start`
never prints a `MAIN_ORDER` topic.

A slug whose file does not exist is skipped, so a role's topic costs nothing
until its file lands. The output opens with a `shared-memory:` line naming the
true conditions, then the topic texts in `START_ORDER`. On `clear` and
`compact` the session's told file is deleted, because the tool topics were
summarised away.

`shared-memory hook tool`, on PostToolUse and PostToolUseFailure, adds:

- `commit-signing` when a Bash result holds one of the `SIGNING` strings
  (1Password's "failed to fill whole buffer" and the like);
- `tailnet-routed-ssh` when the Bash command runs `ssh`, `scp`, `sftp` or
  `curl` (`NET_COMMAND`) and the result holds one of the `CONNECT` strings, so
  a curl that returns a 404 adds nothing;
- `claude-in-chrome` on the first call of a `mcp__claude-in-chrome__*` tool,
  or of the `Skill` tool with `claude-in-chrome` (possibly
  plugin-prefixed) as the skill;
- `peer-lifetime` when the Bash command runs `claude-peer start`, `stop`, or
  `log claim|note|done` (`PEER_COMMAND`; `slots` and `log show` add nothing);
- `web-fetching` when the tool is exactly `WebFetch`, whatever the result, so a
  session's or subagent's first WebFetch brings the fallback rule.
- `session-mail` when the tool is `SendMessage` or starts `mcp__postbox__`, or
  the Bash command runs `am mail` (`MAIL_COMMAND`).
- `github-accounts` when the Bash command starts with `gh ` or `command gh `
  (`GH_COMMAND`), so a session's first `gh` command brings the wrapper rules;
  `cd x && gh ...` and `sudo gh ...` do not match. It was imported until 2026-11-22,
  when always-loaded memory had to fit its 16,200 ceiling.
- `issues` when the Bash command runs `gh issue create`, `new`, `edit` or
  `comment`, or `workboard add` (`ISSUE_WRITE`);
- `issue-reading` when it runs `gh issue view`, `list`, `status` or `develop`,
  or `workboard take`, `show` or `list` (`ISSUE_READ`). Both match anywhere in
  the command line, so `cd x && gh issue view 3` matches where
  `github-accounts` does not; a session's first `gh issue` command adds
  `github-accounts` and one of them in one output.

Those four read the command text only, never its output.

The result is one `additionalContext` JSON object. The payload carries the
topic text and nothing else: no `decision`, no `permissionDecision`.

## The cap, and saying it once

Claude Code caps one hook output at 10,000 characters and, over it, hands
Claude a file path and a short preview and does not ask it to read the file.
`INJECT_MAX` is 9,000, and a topic bundle that would pass it is replaced by
one line per topic telling Claude to read the file (logged `oversize`).
`tests/claude-shared-memory.bats` holds every start bundle and every tool
topic under the same limit, so a topic that grows past it fails there before
it falls back in a session.

The main bundle is a second hook command, so the 10,000 cap applies to it on
its own: "Claude Code measures each string on its own, even when several hooks
run for the same event" (the hooks page). It has no allowance beyond that, and
no test yet holds it under 9,000 or holds the always-loaded text plus the
bundle at or under 16,200, the total a main conversation carries; PR B adds
that test.

A tool topic is added once per session and agent. The told file,
`${XDG_STATE_HOME:-$HOME/.local/state}/shared-memory/told/<session id>`, holds
`<agent id or main><TAB><slug>` lines; a second hit is logged `told` and
silent. Each start hook run removes told files older than 14 days. The start
and main topics have no told file: SessionStart runs once per start, and a
resumed session may carry them twice (see "What it cannot see").

A topic the index still imports is never added, in any of the three hooks
(logged `imported`). That is what makes the rollout order-independent: an overlay may
wire the hooks before the public change that stops the import has merged, and
nothing loads twice.

## Fail open

A hook that fails must not stop a session, so `hook` has no non-zero exit and
none may be added (the same stance as `memoryguard hook`, and the reverse of
`denyguard`, which has to fail closed):

- every `hook` route returns 0: bad JSON, an empty payload, a missing
  directory and any exception caught around the body, which is logged
  `error`;
- no python3: `hook` logs `nopython` from `sh` and exits 0;
- the settings entries are `[ -x ~/bin/shared-memory ] && exec ... || true`
  with a timeout (10 s for `hook start`, 5 s for `hook main` and the tool events), so a missing
  script or a failing one is also harmless;
- under `MEMORYGUARD_DEPTH` (memoryguard's decision child) `hook` returns at
  once;
- the 3-second cap on `claude-peer slots` sits under the 10-second hook
  timeout, because a timeout discards the whole output; a slow `claude-peer`
  only costs the repo-with-peers condition.

`hook tool` runs on every Bash call, so `sh` checks the payload against the
`SIGNING` and `CONNECT` strings, the Claude in Chrome name, `claude-peer start`,
`stop` and `log`, `am mail`, a command starting `gh `, `gh issue `, `workboard add`, `take`, `show` and `list`, `SendMessage`, `WebFetch` and `mcp__postbox__` before starting
python. The strings in the `case` in the script and the constants in the
python must be edited together.

## Wiring is each overlay's

`shared-memory settings` prints the SessionStart entry, which holds two
commands (`hook start` with a 10-second timeout, `hook main` with 5), and the
PostToolUse and PostToolUseFailure entries (matcher
`Bash|Skill|SendMessage|WebFetch|mcp__claude-in-chrome__.*|mcp__postbox__.*`).
It never edits a file; `docs/private-overlays.md` says where each overlay
pastes it. A profile on the old block keeps working: without `hook main`,
once the index stops importing the delegation topic (PR B), it has that topic
by its pointer line only, and with the old matcher
it gets `session-mail` only from `am mail` and from the index line, and no
`web-fetching` at all. `claude-doctor`'s `topics:` line reports `hook:
wired`, `partly wired (missing <names>)` or `not wired` (the names are `start`,
`main` and `tool`, those the settings text lacks of `shared-memory hook start`,
`shared-memory hook main` and `shared-memory hook tool`), whether
`~/bin/shared-memory` is present, how many topics load on demand (split into
main, start, tool and pointer), and how many injections the log counts, with
how many were already told and how many errored. A missing or failing script
prints `?`, not a healthy zero.

## The approvals topic and its ledger

`approvals` is a start topic for the Lead session. The ledger it points at,
`~/.claude-shared/approvals-ledger.md` (source
`dot_claude-shared/create_approvals-ledger.md`), is machine-local: chezmoi
creates it once, header only, and never overwrites it, and it ships with no row
because a row in the source would be an approval nobody gave. It sits beside the
index and outside `topics/`, so `shared-memory topics`, memoryguard's section
map and the size tests do not read it. It is not imported: an import would
load every row into every session and subagent. Rows are written only by the
session the operator typed to, the case Claude Code's "Instruction Poisoning"
rule exempts. A row steers a session and cannot clear a permission-classifier
block; the lever for that is an `autoMode.allow` entry in that profile's
overlay.

## The log

`${XDG_STATE_HOME:-$HOME/.local/state}/shared-memory/injections.tsv`, append
only, five tab-separated fields: UTC time, profile label, event (`start`,
`main` or `tool`), slug, outcome (`injected`, `told`, `imported`, `oversize`, `error`,
`nopython`). It never holds a session id, tool input or output, or topic
text: the directory is readable by every profile, so a work profile's
sessions must not be characterised there (memoryguard's log keeps to the
same rule). The told files are the exception on the file name only: each is
named for a session id and holds slugs. `shared-memory log [--since DAYS]`
prints `outcome`, `slug` and a count. A trigger that never fires shows as no
`injected` row for its slug.

## What it cannot see

- An ssh or curl run through `command ssh`, `tailnet-as` or a script: the
  command text does not match `NET_COMMAND`, so the tailnet topic is not
  added. The same goes for anything that hides the command name.
- A signing failure whose text is not one of the `SIGNING` strings, and a
  connection failure whose text is not a `CONNECT` string. The topic is then
  not added, and the index paragraph is the route.
- A resumed session: SessionStart runs again and whether the first run's
  text is still in the transcript is not documented, so the start and main
  topics may appear twice (in one deployment's transcripts, nine of 107
  start bundles followed another with no compaction between them, counted
  2026-11-25).
- A launch with hooks off has neither memory nor bundle: only the index
  paragraph's route to the files.
- Subagents: they never run SessionStart, so they do not get the main, peer,
  Lead or messaging topics. Those are orchestrator rules; the tool topics
  still reach a subagent whose commit fails to sign.

## The context practice file

`dot_claude-shared/context-practice.md` (deployed beside the index as
`~/.claude-shared/context-practice.md`) is what `context-sonnet` reads: a
stamp (the Claude Code version and date it was checked against), a budget
table, and one `### P<n>` entry per practice with its source and rank,
evidence (`measured`, `documented` or `anecdotal`), the date checked, what was
measured here, and a status. It is not a topic and is imported by nothing: an
import would load it into every session and subagent, and `shared-memory
topics` reads only `topics/`. A practice is `adopted` only with a `Here:`
result from this machine's sessions; everything else is a `candidate`, which
the seat treats as a note and never as a finding. A local result that
contradicts a practice makes it `demoted`, with a line under `## Changes`.
`tests/claude-shared-memory.bats` pins the schema.

Web quotes in it were re-fetched from the pages on the stamp date; paper
quotes carry their PDF page. An entry whose quote is not grounded says `quote
pending`. The seat ends a review with a `REFRESH:` line when the stamp names
another Claude Code version than the installed one or an entry was checked
more than 90 days ago; a refresh re-fetches the rank 1 pages, reads the
changelog between the two versions for memory, rules, skills, hooks,
compaction and subagents, updates the entries and the stamp, and adds a
`Changes` line for each one that moved.
