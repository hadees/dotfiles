---
paths:
  - "**/bin/executable_worktabs"
  - "**/alfred/**"
  - "**/tests/worktabs.bats"
---

# Worktabs launcher (iTerm2 tabs, on demand)

`bin/worktabs` puts a set of terminal tabs back on screen: **one iTerm2 window
per group**, one tab per entry, each tab sitting in its directory with its
command already running. What those entries are is identity-bearing (real
paths, real group names), so — like every other router here — the machinery is
public and the list is machine-local git config from an overlay:

The command is `worktabs`; the **git config namespace stays `workspace.*`**.
Renaming it would need this repo and the private overlay applied in lockstep
on every machine before the launcher worked again, and the namespace was never
the problem — the collision was on `PATH`. The iTerm2 session marks and the
`Workspace` dynamic profile keep their old spelling for the same class of
reason: they are stamped on tabs that are already open, and renaming them
would make `start` stop recognising every running tab and duplicate the lot.

```gitconfig
[workspace "<name>"]               # <name>: letters, digits, - and _
	dir      = ~/code/<project>      # required
	command  = <command line>        # optional: run after cd; omit for a shell
	window   = <group>               # optional: which window it shares
	                                 # (default: <name> — a window of its own)
	title    = <tab title>           # optional (default: <name>); a hint —
	                                 # iTerm2 relabels tabs itself
	disabled = true                  # optional: keep the entry, skip it
```

A group is **just a label**. An earlier version derived it from the Claude Code
profile the directory resolved to, which was clever and wrong: it grouped by
whichever account owned the repo's remote, and that is not the axis anyone
sorts projects by — two side projects under one personal account still want
separate windows. Saying `window` outright is shorter, general, and expresses
the grouping people actually use. Tabs open in config order.

Two decisions carry the design:

- The tab runs the **login shell and is typed at** (iTerm2's `write text`),
  not handed a command to exec. `create tab … command "…"` does not run an
  interactive shell, so `.functions` is never sourced and any wrapper the
  command relies on silently disappears — it would run the bare binary. For
  `claude`, whose wrapper picks `CLAUDE_CONFIG_DIR` from the directory, that
  is not cosmetic: session history is partitioned per config dir, so the
  wrong one resumes nothing and starts fresh instead of failing.
- **Nothing runs at launch.** Sets open when you ask — `worktabs start`, or
  the Alfred workflow. An earlier version compiled a one-line AppleScript to
  `~/Library/Application Support/iTerm2/Scripts/AutoLaunch.scpt` so that every
  iTerm2 start reopened the whole set; that is removed. Opening every
  project's tabs on every launch is the wrong default, because iTerm2 gets
  started for all sorts of unrelated reasons and the set is a thing you want
  deliberately. `install` now writes only the dynamic profile, **and deletes
  an `AutoLaunch.scpt` a previous version left**, so upgrading a machine stops
  the old behaviour instead of leaving it running with nothing in the repo to
  explain it; `status` and `worktabs-doctor` report a stale one they will not
  touch, and neither ever removes a script somebody else wrote.
  Two findings from that route are worth not relearning. A script iTerm2 runs
  is **iTerm2 automating itself** — implicitly allowed, never recorded in TCC
  — where a LaunchAgent driving `osascript` is its own responsible process
  needing its own Automation grant, which can prompt at login with nobody
  there to answer it. Measured, not assumed: with the calling terminal's grant
  revoked, an AutoLaunch-spawned shell still created a window (`rc=0`) and no
  grant row appeared. And any such call had to be backgrounded, because
  iTerm2 runs AutoLaunch on its own AppleScript runner and a synchronous `do
  shell script` that sends events back to iTerm2 can sit behind the very
  runner it waits on.

An iTerm2 **Window Arrangement** remains the wrong tool: it restores a shell in
a directory, not a running command; it lives in `com.googlecode.iterm2.plist`,
which this repo deploys, so real project paths would leak on the next capture;
and it is edited by clicking, not provisioned by an overlay.

When `start` has to launch iTerm2 itself, it scrubs `CLAUDE_CODE_*` from the
environment first. `open` hands the caller's environment to the app it starts
and the app keeps it for its whole run, so launching iTerm2 from inside a
Claude Code session would stamp `CLAUDE_CODE_CHILD_SESSION=1` and that
session's id onto **every tab it ever opens** — and `claude` in a session
marked as a child silently stops saving transcripts. The tabs exist to run
claude, so this is data loss, not cosmetics. Observed for real: a relaunch of
iTerm2 from inside a Claude Code session left the running app carrying another
session's id, and the next `claude` started there warned that transcript
saving was off.

Re-running is safe: each tab is tagged with an iTerm2 user variable
(`user.workspaceSession`), and `start` skips an entry already on screen, adding
what is missing to that group's existing window. Reading the tag needs care —
an unset iTerm2 variable answers `missing value`, and coercing *that* to text
yields the string "missing value", which would make every untagged session
look tagged. The AppleScript **returns what it actually opened**, so a re-run
that opens nothing says so instead of reporting the whole plan as if it had.

Tabs are additionally **created with** a dedicated profile — `Workspace`, a
dynamic profile `install` writes to `~/Library/Application Support/iTerm2/
DynamicProfiles/workspace.json`. Two marks, two jobs: the tag says *which*
entry a tab is (idempotency needs the entry and its group, and a profile name
is one string), the profile says the tab is **ours at all**. The profile is the
better answer to "ours" because it is applied by the same command that creates
the session, where the tag is a step afterwards — so there is no instant when a
tab exists untagged, and a tab carrying the profile with no tag is a run that
died in between, now reported rather than silently duplicated beside. It
*inherits* rather than copies (`Dynamic Profile Parent Name: Default`), so it
cannot drift from Default the way a hand-duplicated profile would, and it
overrides nothing visible — it is a marker the script reads, not decoration.

The visible cue is the **tab title**, and it has to come from the prompt. The
launcher cannot set it: `precmd` in `.zsh_prompt` rewrites the title on every
prompt, so anything AppleScript writes is gone by the first one. iTerm2's own
`Custom Tab Title` cannot do it either — measured: it renders **once, at
session creation**, before the session has been tagged, and does not
re-evaluate when the variable appears (the variable read back correctly while
the title still rendered empty). So `start` exports `WORKTABS_GROUP` into each
tab and `precmd` prefixes the directory with `[<group>] `. It re-renders every
prompt, survives `cd`, and is simply absent in an ordinary shell. Everything
degrades: with no
profile installed, creation falls back to the default profile and the tag alone
carries idempotency, which is why `create … with profile` sits in a `try`.

Two things were measured rather than assumed here, and one killed a better
story. iTerm2 **restores nothing** across a quit on this setup (a marked window
and a plain one both gone; one fresh window on relaunch), so "user variables do
not survive restoration but profiles do" — the strongest-sounding argument for
the profile — is simply not true and is not the reason. What the test *did*
turn up is that iTerm2 opens **one window of its own** at every launch, which
worktabs neither created nor reuses; `OpenNoWindowsAtStartup` suppresses it,
and `install`/`worktabs-doctor` print that line rather than writing a
preference into a tracked file behind you.

Commands mirror `tailnet`'s shape: `list`, `groups`, `plan` (the decision
table, tab-separated), `script` (the AppleScript `start` would run — a dry
run), `start [name|group…]`, `new <entry> [branch…]` (one more tab for one entry
whether or not it is open — a second chat in the same project; the same
script as `start` with its skip switched off, so the tab lands in the
group's window and `start` still counts the entry as open), `alfred`,
`install`, `uninstall`, `status`, `dir`. A selector names either one entry
or a whole group; `new` takes exactly one entry.
`list`/`groups`/`plan`/`script`/`alfred` are pure text and work anywhere; the
acting commands refuse off macOS, and `.chezmoiignore` does not deploy the
script there. Nothing configured is ever silently ignored — a name git accepts
but this does not (`[workspace "bad name"]`) is warned about rather than
dropped during parsing. `worktabs-doctor` reports the script, iTerm2, the
profile, whether a stale launch trigger survives, and the configured entries
with which are open; `doctor` includes it. Once per machine:
`worktabs install` — which is also what clears the old trigger. Tests:
`tests/worktabs.bats` (stub osascript/open/ps/uname/osacompile; fixture names
only).

**`new <entry> <branch>…` gives each branch its own tab and worktree.** A second
Claude in the same checkout is a second writer on the live tree, so each
branch gets `<dir>/.claude/worktrees/<slug>` (`/` becomes `-`), made by the
rules `workset checkout` follows: an existing branch is checked out, a new one
is cut from `origin/HEAD` else `HEAD`, a branch checked out anywhere else is
refused, two branches that slug to the same directory (`a/b`, `a-b`) are
refused, and nothing is created if any branch is refused — validate, create,
then open. The tab is the entry's row with its dir swapped for the worktree
and is typed into the login shell like any other, so `claude` there is the
wrapper, the cwd is the worktree (no second-session question, the worktree's
own `CLAUDE.md`, a Diff peer that diffs the worktree), and the Claude Code
workgroup enters per tab as it does today. The window's Session Status tool is
then the one view over every Claude in the group (it is per window); the
Cockpit groups by window across windows. Such a tab also carries
`user.workspaceWorktree`, which is what lets `status` print a `worktrees:`
block — each directory under `<dir>/.claude/worktrees/` with its branch and
`[open]`/`[closed]`, or `(not a worktree)` — and never removes one:
`git worktree remove` is the cleanup, as for `workset`.

A tab and a Workgroup peer are two interfaces to several Claudes (the peer
one is the subsection below). What was measured about peers (v3.7.7): members
spawn in the leader's working directory and are pinned there
(`forceUseOldCWD: true`; `makeWorkgroupPeer` in `PTYSession.swift` for peers,
`WorkgroupSessionSpawner.swift` for splits and tabs); peers spawn eagerly at
entry, not on first switch; a peer's command does run in an interactive login
shell (`login … ShellLauncher --launch_shell - -i -c`), so the `create tab …
command` finding above applies to that code path only; a tab already in
`builtin.claudeCode` (where iTerm2's Claude Code onboarding puts it, via an
Enter Workgroup trigger on the `claude` job that it writes into each profile's
own prefs — machine-local, not in this repo) cannot switch; and the single
Diff follows the leader's PWD.

**Alfred front-end.** `alfred/worktabs/` is an Alfred 5 workflow — keyword
`ws` — whose Script Filter runs `worktabs alfred` (Script Filter JSON, one
item per group with its open/total count) and whose action runs `worktabs
start <group>`. `worktabs alfred-install` zips it and hands it to Alfred,
which shows its own import sheet; dropping the folder into Alfred's
preferences by hand is not a supported path. Three things shape it: Alfred
runs scripts with `/bin/zsh --no-rcs` and a fixed PATH that **excludes
`~/bin`**, so both scripts call `$HOME/bin/worktabs` by absolute path; the
filter sets `alfredfiltersresults` so the script runs once and Alfred narrows
as you type, rather than re-running per keystroke; and it passes the selection
as **argv**, not `{query}`, so there is no query escaping to get wrong. The
workflow holds no logic and therefore no identity — the group names come from
the overlay at run time. It is **not** a chezmoi target: Alfred rewrites
`info.plist` whenever the workflow is edited in its GUI, which would show as
permanent drift, so the repo keeps the source and `alfred-install` copies it.
