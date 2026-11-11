---
paths:
  - "**/dot_local/libexec/cc-status-shim/**"
  - "**/tests/cc-status-shim.bats"
  - "**/tests/tabstatus.bats"
---

# Session Status shim (`cc-status`)

**Session Status rows come from Claude Code hooks, through a shim.** iTerm2
3.7 ships `cc-status`, a binary its onboarding symlinks at
`~/.config/iterm2/cc-status` and wires into every hook event of a profile's
`settings.json`; it turns each event into a row (name, status word,
optional detail of up to three lines, dot and text colours). On Stop it
reads the payload's `background_tasks` — the session's whole task registry,
which Claude Code never ages out — and keeps the row at "working" while
that array is non-empty. Measured: a backgrounded shell blocked on stdin
kept a tab "working" for 41 hours (a foreground command that outlives its
timeout moves to the background still holding its stdin pipe, and a local
session has no time limit on background commands); a subagent that never
reported back did the same with no process behind it. No hook can kill
such a task — the payload carries no pid — so the shim only stops the row
believing it.

The shim, deployed as `~/.local/libexec/cc-status-shim/cc-status`
(`dot_local/libexec/cc-status-shim/`), takes cc-status's place in each
profile's hook command. On Stop, StopFailure and SubagentStop it tells
**quiet** tasks from **active** ones by the task's output file,
`tasks/<task_id>.output` beside the payload's `scratchpad_dir` (a symlink
to the transcript for an agent): written within `tabstatus.quiet-minutes`
(git config, default 15 — above the ten-minute foreground ceiling) is
active, older is quiet, and no file to judge by counts as active, because
wrongly active only delays the idle and wrongly idle lies. Hiding every
task would be the opposite lie — a Stop over a running background agent is
what iTerm2 3.7.2 made cc-status cover — so cc-status is fed only the
active ones. When nothing is active, one `it2 set-status` paints the row
idle in amber (`tabstatus.color.quiet`, default `#af8700`; cc-status's blue
is its "waiting" colour, and a quiet row must not look like a permission
prompt) with the quiet tasks in the detail. The count stored back is **0**
on purpose: cc-status's `Notification(idle_prompt)` handler, a minute after
Stop, reads the stored count with `get-background-tasks` and repaints
"working · N background tasks running", so storing the quiet N would revive
the lie. `it2 set-status` keeps every field it is not given — a reset
sending only the status word leaves the old dot colour — so every paint
sends the full field set, and `tabstatus idle|working|waiting` sends
cc-status's colour pair (plus a zero count for idle) unless given a colour,
which makes it the manual reset for a stuck row. The shim also adds the
`id` and `status` keys cc-status reads and 2.1.289 no longer sends, and
drops the stopping agent from its own SubagentStop.

A subagent **seat** gets its own dot and text colour while it runs
(`plan-fable #d787ff`, `unstick-fable #ff5faf`, `review-fable #af87ff`,
`work-sonnet #00afaf`, `scout-haiku #87af5f`; `git config
tabstatus.color.<agent_type> '#rrggbb'` overrides one or adds a seat). The
status stays one of the three words: the Session Status tool sorts by them,
and an unknown word's place is unspecified. Hooks fired inside a subagent
carry `agent_type`; the shim paints an in-seat PreToolUse/PostToolUse itself
(cc-status would paint plain orange) and passes PermissionRequest and
Notification through, since waiting outranks a colour. Running seats are
tracked in `${XDG_STATE_HOME:-~/.local/state}/tabstatus/<session_id>.seats`
— written on SubagentStart, pruned on SubagentStop, deleted on
SessionStart/SessionEnd, ignored past a day — so a Stop over a still-running
background seat repaints its colour, not orange. The detail carries
only the status: the row name carries the repo (next paragraph).

**The row's name is the session's name, and the shim sets it.** The Session
Status tool labels a row with `session.name` (iTerm2's `ToolStatus.swift`),
which the tab shows too. On iTerm2 3.7.5+ the Claude Code integration's
onboarding leaves a `builtin.claudeCode` workgroup (root session displayName
"Chat", peer "Diff") and, on every profile, an Enter Workgroup trigger that
fires when a job named `claude` starts. Entering renames the leader session to
the root's displayName through a `KEY_NAME` override — that is why every row
read `Chat (claude)`. The `(claude)` is the Job component of iTerm2's job-only
default title (these profiles set no `Title Components`) and is not touched
here. The workgroup's exit trigger restores the shell's own title when
`claude` quits.

So the shim renames the session back: `it2 session set-name` with `[<group>] `
(`WORKTABS_GROUP`, when set) and then `$WORKSET` (a working set is N repos, so
the set names the row) else `tabname` of the payload's `cwd`, on a session's
first UserPromptSubmit (marked by an empty `<session_id>.named` beside the seats
file, written whether or not a rename happened, deleted on
SessionStart/SessionEnd) and on every Stop and StopFailure, so
a later rename by iTerm2 heals at the end of the turn. It runs after the
cc-status call and before the paints, which keeps a paint the last `it2` call of
a turn end. Never on SessionStart: that fires before the job-start trigger may
have, and a rename landing first would be captured as the "original" title the
workgroup restores on exit. The title has control characters dropped and is cut
at 80 characters. `$WORKSET` needs no `tabname`; without it, no `tabname`, no `cwd`,
or a directory outside a repo means no rename, never an empty one (iTerm2 would
show its profile name). `set-name` is
a session-specific in-memory override: **no pref in
`com.googlecode.iterm2.plist` is part of this mechanism** — iTerm2's Claude
Code onboarding writes its workgroup (a `Workgroups` entry, `builtin.claudeCode`)
and the Enter/Exit Workgroup triggers into that plist itself, as it does every
other preference; that is iTerm2 saving, not part of this mechanism, and
clearing the root's displayName in Settings was rejected because it would be a
preference edit in the tracked plist. `cc-status explain` prints `name=` and
`rename=yes|no (<reason>)` and `marker=present|none`. A tab already stuck on `Chat (-zsh)` is fixed once
by hand: `it2 session set-name "$(tabname)"` in it, or Session > Edit Session.
Workgroup peers (`claude-peer`) are never renamed by iTerm2, so their rows are
the shim's name alone.

The `claude()` wrapper writes no title. Where `git config claude.terminal-title
false` is set (machine-local, overlay-supplied under a `mac` machine-class
guard wherever the shim is wired; default unset, so a public-only clone or a
Linux box is untouched)
it exports `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` (`''`, `0`, `false`, `no` and
`off` are normalised to unset under the gate, since Claude Code reads the
variable as a raw string and would treat `0` as disabling; outside the gate a
caller's value passes through untouched), so Claude Code's own OSC 0 titles —
its `/rename`-or-`-n` title, an AI title, a small-model title, and an empty one
on exit — never displace the repo between a title change and the next Stop. It
is gated rather than a default because it costs every machine and pays only
where the shim, iTerm2 3.7.5+ and the integration are all present. Two
documented costs: the docs say the variable also skips the request that
generates an AI session title, so `/resume` rows may show a summary or first
prompt instead (the binary gates that skip behind a feature flag, so it may not
happen), and it turns off Claude Code's OSC 7501 status reports, which the hooks
make redundant. Open `/resume` after a week and drop the config line if it
hurts; the Stop rename converges every turn either way. `claude-doctor`'s
`titles:` line shows the key and the variable. A session not launched through
the wrapper (bare `command claude`, Claude Desktop, an editor terminal) is
still renamed by the shim, but Claude's own titles may displace the name until
the next Stop.

A turn that **ends by asking the operator a question** paints `waiting` in
yellow (`tabstatus.color.question`, default `#ffd75f`) with the question as
the detail: on Stop or StopFailure with nothing active, a
`last_assistant_message` whose last non-empty line (bullets and quotes
stripped) ends in `?` or `？`. cc-status alone cannot show it — it reserves
"waiting" for PermissionRequest and AskUserQuestion, paints a plain Stop
idle, and its detail is only the message's opening ~180 characters, where a
closing question is cut off. The paint follows cc-status's and outranks the
quiet-task one; a Stop with something active stays working, and
SubagentStop never fires it.

A quiet **shell** task is **stalled** when nothing holds its output file open
any more, or when it was first seen quiet `tabstatus.stall-minutes` (git
config, default 15) ago and its holders' whole process tree has used under a
second of CPU since, the file untouched — a wedged download, not a silent
compile. It is measured without root: `lsof -t` names the holders, one `ps
-axo pid,ppid,time` (visible for every user) sums the tree's CPU, and
`<session_id>.tasks` beside the seats file keeps each task's last mtime, CPU
and first-seen-quiet time between Stops. With nothing active a stalled task
paints `waiting` in red (`tabstatus.color.stalled`, default `#ff5f5f`),
outranking the question and quiet paints; agent tasks are never probed, and a
missing `lsof` means unknown, never stalled.

Wiring is the load-bearing part. The shim is **named** `cc-status`, in a
directory off `PATH`, and its hook command is the bare absolute path with
the home directory expanded: iTerm2 3.7.3's health check accepts a hook
only if the command ends in `/cc-status` and `isExecutableFile` passes on
the literal string (verified in the app's onboarding source at that tag), so
`~`, `$HOME`, a wrapper line or another name makes the app report its
integration broken, and a Reinstall then appends a raw cc-status beside it,
which repaints "working". Master's hook lexer (`CCStatusHookCommand.swift`,
2026-10-03) will relax this, but 3.7.3 and 3.7.4 do not. The shim sits in
cc-status's own slot, never beside it — hooks for one event run in
parallel, so a second hook would race the thing it fixes — on eleven
events: the ten iTerm2 wires plus `SubagentStart`, which cc-status ignores
and the seat file relies on. Reinstall rewrites the entry back to the raw
binary and Uninstall strips it; re-applying the overlays restores it. The
overlays write the line (`cc-status settings` prints the block;
`docs/private-overlays.md`). iTerm2's own symlink at
`~/.config/iterm2/cc-status` is left alone — `ensureCCStatusSymlink`
removes anything else put there — and is where the shim finds the real
binary, with `it2` from beside it; `PATH` only carries `it2` while an
experimental iTerm2 setting is on. The shim deploys on every machine class
and exits 0 at once without the binary, which beats a hook entry that
errors on every event.

Pass-through events cost one `sh`, a `cat`, two `case` matches and a pipe
into cc-status; every Stop and StopFailure, and a session's first
UserPromptSubmit, adds one `python3` (~30 ms), a `tabname` and an `it2` start
for the rename (after the turn), a `stat` per task, one `git config
--get-regexp`, and a paint `it2` call only when nothing is active; an in-seat
tool call makes one `it2` call instead of cc-status's. It fails open to stock behaviour everywhere (no binary, `it2`,
python3 or session id, bad JSON, `it2` past five seconds) and never exits
non-zero: the row is cosmetic and must never cost a turn. It cannot see task
types that keep no output file (`monitor`, `in_process_teammate`,
`local_workflow`, `remote_agent` are unverified; a missing file reads as
active), nor a dead process behind a recently written file. The upstream
reports — the moved command keeping its stdin pipe, the hooks reference's
stale `background_tasks[].status`, cc-status reading `id`/`status` where
2.1.289 sends `task_id` — are drafts, not yet filed. `cc-status explain`
(payload on stdin) prints each task's verdict, the seat and the action,
calling nothing; `unknown` means the output file is not where it looks,
`passthrough` that the gate missed the payload. The facts the shim rests on
are `utilstr`/`binstr` lines in the skill's `manifest.txt`, so `verify.sh`
says when a point release moves them. `claude-doctor`'s `tabstatus:` line
counts the eleven events in a profile's `settings.json` that run the shim,
still run iTerm2's raw cc-status, or run neither, plus the seats live;
`iterm2-doctor`'s `cc-status:` line reads the app's symlink and where `it2`
is, never executing either. Tests: `tests/cc-status-shim.bats` (stub
cc-status and it2, side by side like the bundle ships them).

## Hook facts kept from the removed tab-triage script

**Three facts survive `bin/attend`**, the tab-triage script removed in favour
of iTerm2 3.7's own per-tab Claude Code status (it painted tabs red/amber from
Claude Code hooks and dimmed them once looked at; the dim-once-seen
distinction — "new" vs "you know about this one" — is the one thing the native
panel does not reproduce). They were measured, and they cost hours to find:

- **A hook does not inherit the tab's controlling terminal.** Claude Code
  starts hook commands detached (`ps -o tty= -p $$` answers `??`), so
  `printf … > /dev/tty` from a hook reaches nothing. The `claude` process has
  the tty and is the hook's ancestor, so walking *up* the parent chain to the
  first process with one costs 2ms, where `lsof -a -p <pid> -d 0` costs ~50ms.
- **Such a walk must report the process it stopped at, not the hook's
  parent.** Keying per-tab state on `$PPID` breaks the moment anything splices
  a shell in between: that state is keyed by pid and reaped when the pid dies,
  so it would attach a tab to a shell that exits a millisecond later and take
  the tab's state with it.
- **Reading which tab has focus needs no Automation grant — but only if you
  talk to nothing but iTerm2**, which answers `frontmost` itself (Standard
  Suite, absent from the sdef but real). The obvious `tell application
  "System Events"` is a *separate* automation target with its own per-client
  grant: it prompts on a machine that never granted it and fails forever once
  denied. Asking one app both questions is 40ms against 140ms.
