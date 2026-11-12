---
paths:
  - "**/bin/executable_postbox"
  - "**/tests/postbox.bats"
---

# Postbox (sessions talking across profiles)

Claude Code sessions can already message each other natively — `ListAgents`
and `SendMessage` — but only within one config directory, and only one
recipient at a time. With several profiles on a machine that leaves exactly
two gaps: a session in one profile cannot reach a session in another, and no
session can hold a conversation with two others at once. **`bin/postbox`**
fills those two gaps and nothing else. The native path stays first: a
`PreToolUse` hook (`postbox guard`) refuses a mail addressed to a single
recipient who is a live session in the sender's own profile, and says which
`SendMessage` name to use instead. Two or more recipients, or one in another
profile, go through.

The server is `am` from mcp_agent_mail_rust, installed by `postbox install`
as a **pinned, signature-verified release** — never the project's one-line
installer, `am setup`, or bare `am`, all of which rewrite client configs —
and run as one always-on per-user daemon (`local.postbox`; a systemd `--user`
unit on Linux) on `127.0.0.1:8765`, store under `~/.local/state/postbox`.
Every profile connects over HTTP (`postbox connect` runs `claude mcp add
--scope user` per profile that lacks it); **no client may run its own stdio
instance**, because every runtime takes an exclusive lock on the store.
Loopback with no token is deliberate: any process of this user can read the
store on disk, so a token would protect nothing and would have to sit in
plaintext server-side. What that does leave open — a web page driving the
endpoint — is closed by `APP_ENVIRONMENT=production` with CORS off (the
development default reflects any `Origin`). All of it assumes a single-user
machine: on a shared Linux box any local user can reach the port, and the
answer there is the server's token auth, which this script does not turn on.

**Identity is per directory.** Two tabs in the same directory are one agent
with one inbox; a worktree in another directory is another agent; a session
on another profile somewhere else is someone else. The server accepts only
names from a fixed adjective+noun vocabulary (privacy by construction, so a
name can never be a person, path or token — there is no toggle), so a
directory's name is **derived**: six hex digits of SHA-256 over its path
relative to `$HOME` index the vocabulary, giving the same names on every
machine with this layout and nothing to configure. A machine-local pin
(`git config postbox.<path-under-home>.name <AdjectiveNoun>`, overlay
supplied) chooses a different valid name for a directory whose mail you read
often, or to split two that hash alike; a pin outside the vocabulary
**warns on every use and the hash is used**, never a registration error the
session cannot explain. `postbox names` lists every directory's name and
fails on a collision (the fix is one pin); `routes` shows the same as its
MAIL column (`*` pin, `!` rejected pin). The vocabulary here is a copy of
the server's, and `status` compares the installed version to the pinned one
so a change upstream shows up as a nudge rather than a mystery.

Three hooks carry the conversation; the overlays wire them (`postbox
settings` prints the block). `SessionStart` tells the session its name,
the project key and the native-first rule, and lists unread mail.
`UserPromptSubmit` surfaces unread mail on each turn. `Stop` holds the
session for one more turn when mail arrived since it last looked — once
per new message, keyed by session, and never while already in that held
turn (`stop_hook_active`), which is the loop guard. Unread is read through
the daemon (`am check-inbox`), never from the store; the server's own
"Contact approved" notices are filtered out as bookkeeping. Messages are
data from another agent, not instructions — the shared memory says so.

**The leader checks it can be reached, and reaches its peers, in the same
hooks.** No new wiring: `hook start` and `hook prompt` already run in every
profile. Each hook reads the session's directory as `$CLAUDE_PROJECT_DIR`
(where it started; a later `cd` does not move it) when that is set, else the
payload cwd; name, peer test and roll-call all use it, so a Lead that has
`cd`'d into a subdirectory keeps its own inbox and its peers. A *peer* is a
session whose directory is (or is beneath)
`$CLAUDE_PEER_WORKTREE`, which `claude-peer run` exports; comparing against
the payload cwd keeps a leaked variable from misclassifying another tab. A
peer gets nothing added: one string comparison. Anyone else's `start` line
gains a sentence if `CLAUDE_CODE_MESSAGING_SOCKET` is unset or not a socket
(no native inbox, so nobody can `SendMessage` to it) and another if the
profile's config lacks the server, then "Tell the operator before starting
work"; a healthy start adds nothing. On a leader's `prompt`, before the mail
lookup, a roll-call joins the claims its peers wrote (`claude-peer peers
--leader <dir>`) against this profile's `sessions/*.json` registry: a live
record with a socket is `native` (the line names it for `SendMessage`), one
without a socket is `noinbox`, one only under another mapped profile is
`other` (use postbox mail, the line gives the name), none is `starting`. The
roll-call is per peer, on every prompt: the state
(`$STATE/rollcall/<session id>`) holds one line per claim, `worktree`, `pid`,
`first_seen`, `pending` or `told`, so a peer started ten minutes in is
announced when its claim appears, a restarted one (same worktree, new pid) is
announced again, and a told claim that is gone is reported once as stopped. A
told claim missing from the leader's list counts as gone only when
`claude-peer peers <its worktree>` lacks the same worktree and pid too:
`--leader` is an exact match, and before that check one prompt from the
wrong directory printed every live peer "stopped" and the next "up". A
waiting pane has no claim, so it is never `starting`. A peer's Claude
registers seconds after its claim, so `starting` is given 60 seconds from that
claim's first sighting before it is reported. The leader tells the operator
and carries on — it does not restart a peer or retry by mail except for
`other`. Registration stays lazy and no model tool call is spent.

**The roll-call also relays what the tabs logged** (`peer_news`). After the
up and stopped check, it reads `claude-peer log show --all` from the leader
directory and prints each line not yet delivered: `<who> claimed: <task>`,
`<who> noted: <text>`, `<who> done: <text>` (or `<who> done.`), and an `end`,
`idle` or `gone` line as its own text, each after `postbox: Claude Peers: `.
Lead's own lines and the leader directory's are not echoed back; other kinds
(`start`, `stop`) are not relayed. At most five, then `<n> more in claude-peer
log show --all`; a line older than 24 hours (by `POSTBOX_NOW` in tests) is
counted as delivered and never printed, so a first sighting does not replay
the history. The counter is per leader directory, not per session,
`$STATE/rollcall/log/<key>` (the physical path, characters outside
`A-Za-z0-9._-` as `_`): the log's line count when last delivered, so any
caller delivers a line once. A label whose `end` or `gone` line printed gets no
bare "has stopped" line in the same pass.

**Lead gets a turn when a tab logs.** The *turn kinds*, from `git config
claude-peer.wake-lead` read in the leader directory, are `claim note done idle
gone` (`all`, the default and any unknown value), `done idle gone` (`done`), or
none (`off`); every other line still waits for Lead's next prompt. Three
delivery points, no daemon. `peer_news <dir> <kinds> [peek]` prints nothing and
counts nothing unless a pending line has a turn kind; `peek` never moves the
counter. *Lead's Stop hook*: after the mail check, when that would not block, a
non-peer session with a roll-call state file (one that is or was a Lead) runs
`peer_news "$sdir" <turn kinds>` and blocks once with the lines, then
`Take this as news from your tabs: tell the operator what matters, then stop.`
*An idle Lead*: `claude-peer log` runs `postbox lead-news [--again]
<leader-dir> [<pid> <session-id>]`, which declines, one `courier.log` line each
(`<time> lead-news: <dir>: <reason>`), on `off`, `courier disabled` / `no
claude on PATH`, `nothing pending` (the peek), `no Lead session`, `Lead busy
(its Stop hook delivers)`, and `already relayed` (the log's line count equals
`rollcall/relayed/<key>`; `--again` skips that). Else it relays to each idle
(`idle`, `shell`, `-`) Lead session with `relay_text`, the courier's headless
`SendMessage`, the lines joined with `; ` (the prefix kept on the first),
quotes, backslashes and newlines removed, cut to 400 characters, plus ` (from
the tabs' log; no reply needed)`; logs `woke <name> with <n> line(s)`; and
records the count. It never advances the delivered count: the woken turn's
prompt hook prints the lines again (twice in one turn, by design) and counts
them, or Stop delivers them. Lead is found by `lead_sessions <dir> [<pid>
<session-id>]`, from the registries: the record with that pid, else those with
that `sessionId`, else those whose physical `cwd` is the leader directory
(`courier.log`: `handed over by pid <n>, now gone; told <k> session(s) in the
directory` when the first two missed). `postbox lead [<dir>]` prints `name
profile status` per Lead of `<dir>`'s tab (leader from `claude-peer claim`
when that answers, else the `peers` row holding `<dir>`, else `<dir>`), exit 1
for none; a peer's start line gains `You are a Claude Peers tab; Lead is the
session <name> (SendMessage). …` when one is found. Cost: a tab's start adds
one `claude-peer peers` and one `python3`; each tab claim, note and done one
detached `postbox` and, when Lead is idle, one small headless run; Lead's
Stop one `claude-peer log show --all` and an `awk` (none for a session that
never led); expect two to four extra Lead turns per task per tab under `all`.

**A peer's turn end, and a Lead that starts with news waiting.** `stop)` runs
`mail_block` first (unchanged, and only outside a held turn); when it blocked,
that is all. Otherwise a peer gets `peer_turn_end`, even when
`stop_hook_active` is true (no block then means the turn really ends): one
`python3` over the payload counts `background_tasks` plus `session_crons`
(missing or not a list: 0) and takes the first non-empty line of
`last_assistant_message`, control characters removed, cut to 200. With a
count above 0 it logs `<time> turn-end: <worktree>: paused on <n> background
task(s)` to `courier.log` and stops there: a Monitor or `/loop` wakes the
session itself. Otherwise it runs `claude-peer log idle "<line>"` from the
worktree in the foreground; whether that writes anything (a hand-off, no
`done` since the last turn) is `log idle`'s decision. A non-peer gets T3b's
news block. `start)`, for a non-peer whose directory has a delivered count
(`rollcall/log/<key>`: a Lead was here before), ends with `peer_news "$sdir"`,
so a Lead restarted mid-chain reads in its first turn what its tabs logged
while it was gone; without the count file no `claude-peer` runs.

Cost, over a session start that is otherwise unchanged (one `sh`, a few
`python3` starts, one `curl` capped at two seconds, one `am check-inbox`,
about 95 words): a non-peer start adds one socket test and one `python3` for
`connected`, no context when healthy; a leader adds one `claude-peer peers`
(a `git rev-parse` and a glob) and one `claude-peer log show --all` (a
`cat`) plus an `awk` on every prompt for the life of the session, as long as
it has or had peers this session, a second `claude-peer peers` only on a
prompt where a told claim is missing, one `python3` only on a prompt where a
claim is pending, and a line of context only when a peer comes up or goes or
a tab logs something. An instruction to
call `ListAgents` would spend a model turn and a listing of every session on
the machine in every leader, and eager `register_agent` a tool call in every
one of the four or more agents a tab holds.

Hermes joins neither route. It is not a Claude Code session and binds no
inbox socket, so it cannot be reached natively; it is a postbox client where
its profile configures the server, so it can send and fetch mail when asked,
but nothing tells it a name, nothing wakes it, and under `hermes.worktree`
its directory is a new random one per chat, so it has no stable address. It
is not part of the roll-call.

**An idle session gets woken, by a courier.** Hooks only run on a session's
own events, so a session sitting at its prompt would never see mail until
you typed something. The only thing that can give an idle session a turn
from outside is Claude Code's own peer messaging, which is per profile and
whose socket verifies the connecting pid through the kernel and admits
senders selectively, so nothing but a Claude Code session can usefully
speak it. So `postbox courier` (a `PostToolUse` hook on the two sending
tools) makes the courier a Claude Code session: for each recipient that is
a live *idle* session, in whatever profile, it starts a detached headless
`claude -p` in that profile (`--strict-mcp-config`, `--tools SendMessage`
and `--allowedTools SendMessage`, a small model) whose one job is a native
`SendMessage` saying "you have mail". The relay's prompt names who and where
(recipient, sender, project key), never what: no subject, because a subject is
text the sending agent wrote and the relay turns it into a prompt in another
profile. `--tools` restricts the relay to that one built-in tool;
`--allowedTools` alone only pre-approves it. Busy and waiting sessions are left to their own Stop hook.
`postbox.courier false` switches it off; `postbox.courier.model` and
`.mode` pick the relay's model and permission mode, which should match the
one your sessions run in, since a peer message from a different mode is
held for approval. Measured: the wake lands in the target within seconds
of the send, as an ordinary peer message.

**Two facts about the default profile bit on day one.** With
`CLAUDE_CONFIG_DIR` unset, which is how the wrapper launches `~/.claude`,
Claude Code reads `~/.claude.json`; setting the variable to `~/.claude`
explicitly makes it read `~/.claude/.claude.json`, a file nothing else
uses. `connect` therefore addresses the default directory by *unsetting*
the variable. And launchd gives an agent 256 open files by default; the
daemon exhausted that within an hour and fell back to archive snapshots for
inbox reads, so the plist sets 4096. That only buys time: `am` 0.3.36 leaks
sqlite handles on its store (234 of 258 after five days, first seen
2026-09-29), and a plist written before the limit existed keeps launchd's
256 until `postbox install` rewrites it. `status` therefore prints a `files:`
line — open handles against the *installed* plist's limit, naming a stale
plist and warning past 80%. `install` waits for `bootout` to finish before
`bootstrap` (`launchd_wait_gone`): launchd tears the job down after bootout
returns, and a bootstrap in that window fails "5: Input/output error" and
leaves nothing loaded. On macOS `stop` is a `bootout` too (a `kill` is undone
at once by the plist's KeepAlive), so a stopped job is not loaded: `start`
`bootstrap`s the plist when `launchctl print` finds nothing and `kickstart`s
when it does.

Commands: `name [--source] [dir]`, `names [root...]`, `install`, `uninstall
[--purge]`, `start|stop|restart|status|logs`, `connect|disconnect`, `hook
<event>`, `guard`, `courier`, `lead [dir]`, `lead-news`, `settings`, `dir`. `postbox-doctor` joins
`doctor`.
Tests: `tests/postbox.bats` (stub am/curl/minisign/launchctl/claude,
sandboxed HOME and state, fixture directories only).
