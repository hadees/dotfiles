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

**Status: the code is complete, the hooks are not on.** Nothing in this
repository wires them: every profile's `settings.json` belongs to its
overlay, so the hooks run only in a profile whose overlay has pasted in the
output of `shared-memory settings`. Until then such a profile still has the
index paragraph (below), which tells Claude where the topics are. The
`topics:` line of `claude-doctor` says whether a profile is wired. The live
checks (that the tool events fire for the `Skill` tool, that the Claude in
Chrome tools carry the name the script matches, that the environment
variables the start conditions read reach the hook, what the hooks cost per
Bash call) have not been run; nothing below about them is more than the
design.

## Three load classes

- **Always loaded**: the topics the index imports with an `@topics/<slug>.md`
  line on its own. This costs context in every session, so a topic gets one
  only if it is a rule that must be known before any tool call, such as the
  denied-paths, accounts and delegation rules. `tests/claude-agents.bats`
  holds a ceiling on this part's size. Lower it when it shrinks, never raise
  it.
- **Hook-added**: topics a hook adds when their situation shows up. Not
  imported, but listed in the index paragraph too, so a session whose hook is
  missing or broken still has a route to the file.
- **Pointer only**: topics that are only listed in the index paragraph, with
  the situation that calls for each. Claude reads the file when the task
  arises, the way Anthropic's own auto memory points at its topic files.

Which topic is in which class is not copied here, because it drifts: run
`shared-memory topics` (add a directory to read a source tree, as
`shared-memory topics dot_claude-shared`). It prints one line per topic file:
the slug, `always`, `start`, `tool`, `pointer` or `unreachable`, and whether
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
  SessionStart. `hook start` prints plain text, `hook tool` prints JSON.
- PostToolUse fires only when the tool succeeded; a failed Bash call goes to
  PostToolUseFailure, whose `error` field starts `Exit code N` and carries the
  output. Both events are wired, and `tool_text` reads the right field for
  each.
- Settings hooks also fire for tool calls made inside subagents, with an
  `agent_id` in the input. A subagent never sees SessionStart, so it gets
  none of the start topics and does get the tool ones.
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
- `session-mail` when the tool is `SendMessage` or starts `mcp__postbox__`, or
  the Bash command runs `am mail` (`MAIL_COMMAND`).

Those two read the command text only, never its output.

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

A tool topic is added once per session and agent. The told file,
`${XDG_STATE_HOME:-$HOME/.local/state}/shared-memory/told/<session id>`, holds
`<agent id or main><TAB><slug>` lines; a second hit is logged `told` and
silent. Each start hook run removes told files older than 14 days. The start
topics have no told file: SessionStart runs once per start, and a resumed
session may carry them twice (not checked).

A topic the index still imports is never added, in either hook (logged
`imported`). That is what makes the rollout order-independent: an overlay may
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
  with a timeout (10 s for SessionStart, 5 s for the tool events), so a missing
  script or a failing one is also harmless;
- under `MEMORYGUARD_DEPTH` (memoryguard's decision child) `hook` returns at
  once;
- the 3-second cap on `claude-peer slots` sits under the 10-second hook
  timeout, because a timeout discards the whole output; a slow `claude-peer`
  only costs the repo-with-peers condition.

`hook tool` runs on every Bash call, so `sh` checks the payload against the
`SIGNING` and `CONNECT` strings, the Claude in Chrome name, `claude-peer start`,
`stop` and `log`, `am mail`, `SendMessage` and `mcp__postbox__` before starting
python. The strings in the `case` in the script and the constants in the
python must be edited together.

## Wiring is each overlay's

`shared-memory settings` prints the SessionStart entry and the PostToolUse and
PostToolUseFailure entries (matcher
`Bash|Skill|SendMessage|mcp__claude-in-chrome__.*|mcp__postbox__.*`). A profile
whose settings still carry the old matcher gets `session-mail` only from
`am mail` and from the index line. It never edits a file; `docs/private-overlays.md` says where each overlay
pastes it. `claude-doctor`'s `topics:` line reports `hook: wired|partly
wired|not wired` (the settings text contains `shared-memory hook start`,
`shared-memory hook tool`, or both), whether `~/bin/shared-memory` is present,
how many topics load on demand (split into start, tool and pointer), and how
many injections the log counts, with how many were already told and how many
errored. A missing or failing script prints `?`, not a healthy zero.

## The log

`${XDG_STATE_HOME:-$HOME/.local/state}/shared-memory/injections.tsv`, append
only, five tab-separated fields: UTC time, profile label, event (`start` or
`tool`), slug, outcome (`injected`, `told`, `imported`, `oversize`, `error`,
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
  text is still in the transcript is not documented, so the start topics
  may appear twice.
- Subagents: they never run SessionStart, so they do not get the peer,
  Lead or messaging topics. Those are orchestrator rules; the tool topics
  still reach a subagent whose commit fails to sign.
