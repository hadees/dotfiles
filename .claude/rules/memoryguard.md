---
paths:
  - "**/bin/executable_memoryguard"
  - "**/tests/memoryguard.bats"
  - "**/.chezmoitemplates/claude-agents/decide-haiku.md"
---

# Where a memory note belongs (`memoryguard`)

Claude Code's auto memory is written by the session itself, with the
ordinary Write and Edit tools, into `<config dir>/projects/<slug>/memory/`.
Nothing there checks that a note is the kind of thing memory is for, and
the instructions that say so (a shared-memory rule, the harness's own
text) did not stop notes that restate CLAUDE.md, a rule file or a closed
pull request, or stopgaps that outlived their reason. An instruction does
not check; `bin/executable_memoryguard` (`~/bin/memoryguard` once
deployed) does.

**Status: the code is complete, the hook is not on.** Nothing in this
repository wires it: every profile's `settings.json` belongs to its
overlay, so the hook runs only in a profile whose overlay has pasted in
the output of `memoryguard settings`. Until then the script is a tool
you can run by hand (`decide`, `audit`, `selftest`, `log`). The
`memguard:` line of `claude-doctor` says whether a profile is wired. The
live numbers (latency, whether the lean call works on a subscription
login, whether the refusal reaches the session) are not yet measured;
nothing below about them is more than the design.

## The shape

A `PreToolUse` hook on Write and Edit. When the target is a memory note it
builds the note's resulting text (for an Edit, the replacement applied to
the file on disk), asks one typed question, *which of seven homes does
this text belong in*, and either lets the write through or refuses it
with the destination file and section in the reason, so the session
writes it there by a normal edit. The refusal carries the answer because
a bare "this looks wrong" left the session to work out the right place,
which is the step that kept failing. The hook never writes anything but
its own log.

Who decides, in order: rules that need no model (not a memory path;
a marker; a cached answer; the size and index lints), then one small
model call per new text, then nothing. A low-confidence answer does not
escalate: it lets the write through with a note to the session and leaves
the note for the audit, where a full session and the operator look at it.

| Situation | Action | Logged as |
| --- | --- | --- |
| `MEMORYGUARD_DEPTH` set | nothing | none |
| not a memory note | nothing | none |
| under another profile's memory directory | allow | `allow-foreign` |
| `MEMORY.md` | allow; warn on size, long entries, links to missing files | `index-ok` / `index-warn` |
| an Edit that does not apply to the file on disk | allow | `allow-error` (`noapply`) |
| over `NOTE_MAX` characters | allow; warn that a note is a pointer | `allow-large` |
| `keep:` with a reason of 20+ characters | allow | `allow-keep` |
| `until:` | allow | `allow-stopgap` |
| this text decided before | replay it | `allow-memory` / `block-cached` |
| no seat, no `claude`, backend failed | allow, with a note | `allow-nobackend` / `allow-error` |
| `memory` | allow | `allow-memory` |
| `overlay`, any confidence | allow, with a note | `allow-private` |
| anything else, confidence at or above `BLOCK_AT` (0.75) | **deny** | `block` |
| anything else, below it | allow, with a note | `allow-unsure` |

**A refusal says how to move, not just where.** Moving a note is an edit
like any other, and a session left to itself copies the note as it is. So
every refusal (and the unsure note, and the audit's procedure) tells the
session to write the general point and leave out whatever names a person,
an account, an organisation, a host, a private repository, a
machine-specific path or port, or where a secret is kept; what names such
things stays in memory as a shorter note. A separate sentence forbids
rephrasing the note to get it past the check. `overlay` is saved, never
refused: memory is private, and most repositories have no overlay, so a
refusal toward one would leave a private fact without a reachable home.
The note says a private overlay's own docs are its home and a public
repository never is.

The index is never refused, only warned about: a refused index edit
strands a note. `BLOCK_AT` is a starting value, not a calibrated one;
moving it is one line and one test, and a value above 1 turns every
refusal into a note.

**Two exits, both counted.** `until: <YYYY-MM-DD | grep:<text>@<file> |
words>` makes the note a declared stopgap that expires (a date; a file
that now contains the text; or, for words, 14 days since the note was
last written, `STOPGAP_MAX_DAYS`). `keep: <reason>` is the operator's
override. Both are read from the text before the write, from the
frontmatter (top level or under `metadata:`) or from a body line starting
`Until:` / `Keep:`, so the gate does not depend on Claude Code keeping
the frontmatter intact. The *due* check reads the disk and does. A
refusal names both exits.

## The decision is a protocol, not a prompt

`memoryguard` sends a backend protocol v1 request, one JSON object:
`state` (the text and the lines of CLAUDE.md, rules and docs that share
terms with it) and `questions`, each a `choice` over criteria ids. The
answer is `{"answers": {<id>: {choice, confidence, reason}}}`. It is
Jev's `choice` question nearly field for field on purpose (see
`docs/watchlist.md`). The rubric, the seven homes and when each applies,
lives on `memoryguard`'s side of that line, not inside any model's prompt.
That is what makes the backend replaceable: any executable that speaks
the protocol can stand in, which is also how the tests run (a stub whose
answer comes from an environment variable). Every answer is validated
here whatever the backend says; a bad one counts as an error and the
write goes through. `MEMORYGUARD_BACKEND` or `git config
memoryguard.backend` picks the executable; the default is `claude`.

The `claude` backend runs the shared `decide-haiku` seat. The seat is a
generic "answer typed choice questions from the input alone, JSON only"
definition with a `## Decision contract` instead of a `## Report`; its
`tools: Read` exists only because the allowlist may not be empty, and the
caller runs it with no tools. It is never spawned from a conversation.

**Why `--safe-mode --system-prompt`, not `--agent`.** `memoryguard` reads
the deployed seat file and passes its body and model itself. The obvious
form, `claude -p --agent decide-haiku`, cannot give a clean context: the
subagents page says `CLAUDE.md` files and project memory "still load
through the normal message flow, even when the agent's definition sets
`omitClaudeMd`", and that field is ignored when the agent runs as the
main session agent. Every decision would then carry all of shared memory
and run the profile's SessionStart and Stop hooks inside a throwaway
session. `--bare` would avoid that but never reads OAuth credentials, so
it is unusable on a subscription login. `MEMORYGUARD_CLAUDE_MODE=agent`
(or `git config memoryguard.claudeMode`) selects the `--agent` form; it is
the fallback should the lean one fail its live check. The child is
started with `MEMORYGUARD_DEPTH=1`, so the hooks it triggers return at
once rather than recursing, and it runs in its own state directory so it
meets no repository's memory.

## Fails open, on purpose

Unlike `denyguard`, this is a convenience and not the sensitivity
boundary, the same position as `workset guard`: an outage that blocked
every Write in every profile would cost more than the notes it guards.
Every path out of the script is exit 0: a missing `python3`, an
unreadable payload, a bug (a catch-all swallows it and prints nothing), a
missing seat or `claude`, a backend that times out (`BACKEND_TIMEOUT`,
20 s; the child's whole process group is killed), exits non-zero or
answers garbage. Each is allowed and counted, so a profile that is wired
but has no seat does not look healthy: it logs `allow-nobackend`, and
`claude-doctor` says `seat: missing`. The wiring entries end in `|| true`
for the same reason. A hook that times out does not block either, which
is why the entries carry their own `timeout`.

## What it cannot see

- A write by a program that computes the path at run time, or through a
  variable other than `~` and `$HOME`; `hook bash` is lexical, like
  `denyguard`. `hook start` counts the notes no decision covers whatever
  route wrote them.
- A note placed wrongly with high confidence: Haiku's confidence is not
  calibrated. `memoryguard log` ends with `blocks later kept`, the notes
  refused and then saved again with `keep:`, which is the false-refusal
  signal; read it before moving `BLOCK_AT`.
- A paraphrase of something the evidence lines miss. Evidence is lines
  that share two terms with the note (backticked spans, and words with
  `/`, `_`, `-`, a digit or an inner capital); a restatement in other
  words is judged by the model alone.
- Whether a destination repository is public. The hook says the same
  thing for every home, and it is not the boundary between a private value
  and a public file: the wording above, the push-time leak guard and the
  review of the pull request are.
- The refusal text for a cached refusal carries no "It belongs in" line:
  the home is not logged, only the criteria id.

**A known false refusal.** `hook bash` refuses a Bash command that names a
path under a memory directory and also carries a write signal (`>`,
`>>`, `tee`, `cp`, `mv`, `dd`, `install`, `truncate`, `sed -i`,
`perl -i`). The test is lexical, so `cat <memory>/n.md > /tmp/copy` is
refused: the redirect is a write signal and the memory path is in the
command, though the write is elsewhere. The refusal says reading, and
deleting with `rm`, are fine; read the note with the Read tool instead.
`rm` passes because the cleanup needs it, and a redirect inside quotes
counts too. A relative path is not resolved
against the cwd, only an explicit `cd <memory>` or an absolute, `~` or
`$HOME` path is recognised.

**Prefilters.** The `sh` wrapper keeps `python3` from starting on
ordinary writes: `hook pre` needs `/memory/` in the payload, `hook bash`
needs `/memory` (a `cd <memory> && printf x > n.md` has no trailing
slash). A profile that sets `autoMemoryDirectory` has notes at a path
that need not contain `memory`, so the wrapper also lets a payload
through when the profile's `settings.json` mentions that key. Without it
a note there would never be gated. The cost of an ordinary Write is then
one `sh` start, about 5 ms; a note pays the model call (a few seconds,
estimated, not yet measured) once, because the answer is cached by the
note's body.

## Stopgaps and the audit

`hook start` (SessionStart, no model call) prints, only when true, at
most three plain lines: stopgaps past their condition, an index over its
budget (`INDEX_MAX` 8,000 characters, `LINE_MAX` 200 per entry), and
`UNPLACED_MIN` (3) or more notes that no decision covers (written before
the hook, or outside the Write tool). The project's memory directory is
found from the hook payload's `transcript_path` first, then from the main
checkout's slug (so a worktree session finds it), then
`autoMemoryDirectory`. A note is *placed* when it carries a marker or its
body hash has a logged allow; Claude Code rewrites the frontmatter after
the write, so the hash covers the body only.

`memoryguard audit` counts; `--all` does so for every project of the
current profile and reads no other profile; `--mark-kept FILE…` records
that the operator kept a note. `audit --propose` asks the backend about
every unmarked note, four at a time, ignores the cache, and prints the
procedure and a table: **proposals only**. It changes no file. The
procedure it prints says nothing is moved without the operator's yes, a
move is a normal edit on that repository's usual branch and pull
request, and the note and its index line are then deleted.

## The log and the cache

`${XDG_STATE_HOME:-$HOME/.local/state}/memoryguard/decisions.tsv`, append
only, ten tab-separated fields. It holds a profile label, a project slug,
the first 8 hex of the note name's hash, the first 16 hex of the body's
hash, an outcome and the numbers, and never note text, a note name or a
reason: it sits in a directory every profile can read, and a work
profile's notes must not be characterised there. The reason is shown once,
in the refusal, to the session that wrote the note. The log is also the
cache (see the table for which outcomes replay). `memoryguard log
[--since DAYS]` prints a count per outcome and `blocks later kept`.
`RUBRIC_V` is part of the hash: changing the rubric or the texts a refusal
carries bumps it and empties the cache.

Cost per decision, from the design and not yet measured: 2 to 5k input
tokens of Haiku in lean mode, a few seconds, a fraction of a cent. Notes
are written a handful of times a day.

## Wiring is each overlay's

`memoryguard settings` prints the three entries (Write|Edit and Bash on
`PreToolUse`, plus `SessionStart`), each `[ -x ~/bin/memoryguard ] &&
exec ~/bin/memoryguard hook … || true`. It never edits a file. A profile
whose overlay does not also give it the shared agent definitions has no
seat and allows everything. `claude-doctor`'s `memguard:` line reports
`hook: wired|not wired` (the settings text contains `memoryguard hook
pre`), whether `~/bin/memoryguard` is present, whether the seat is
deployed, and the log's counts. (It is not called `memory:`, which is the
line about the default directory's memory leaking in.)

Tests: `tests/memoryguard.bats` (sandboxed `HOME` and state directory,
stub backend, stub `claude` that records its arguments; invented names
only) and the `memguard:` test in `tests/claude-profiles.bats`.
