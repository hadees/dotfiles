---
paths:
  - "**/bin/executable_workset"
  - "**/tests/workset.bats"
---

# Working sets (`workset`) — one session over several repos

A **working set** is a named group of repos one Claude Code session works as
a single codebase: N git worktrees on one branch, opened together and torn
down together, with the session launched in the primary member's worktree
and every other member added via `--add-dir`. Like `workspace.*` (worktabs)
and `routes.root`, membership is machine-local git config the overlays
supply — the public repo names no set and no member:

```gitconfig
[workset "<name>"]                 # <name>: letters, digits, - and _
	member   = ~/code/<repo>         # repeatable, ordered; the first entry
	                                 # that survives real-path dedupe is the
	                                 # PRIMARY (its worktree is where the
	                                 # session launches; every other member's
	                                 # worktree is added with --add-dir)
	profile  = <account|alias|dir>   # optional; what CLAUDE_PROFILE accepts.
	                                 # Absent: every member must resolve to
	                                 # the same Claude profile directory
	note     = <one line>            # repeatable; printed in the session's
	                                 # opening brief — landing order, which
	                                 # artifact must stay green, that kind of
	                                 # choreography
	disabled = true                  # optional; keep the entry, skip it
```

`bin/executable_workset` owns config, worktrees and two hooks (`list`,
`members`, `plan`, `checkout`, `status`, `close`, `hook start`, `guard`,
`settings`); `workset()`, `workset_profile()` and `workset-doctor()` in
`.functions` decide which profile a set runs under and open it. `workset
open <name> <type>/<slug>` resolves the profile, creates or reuses the
worktrees, then launches `claude` — the wrapper, so `CLAUDE_CONFIG_DIR`, the
browser pin, the cache TTLs and the subagent-model default all still
apply — cd'd into the primary's worktree with
`CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` and `--add-dir` for the
rest, so every member's own `CLAUDE.md` loads too (confirmed present in the
installed CLI: seven references to that variable name in the 2.1.274
binary; documented in the memory page's "Load from additional directories"
and the permissions page's directories table — `additionalDirectories` in a
tracked `.claude/settings.json`, by contrast, loads neither `CLAUDE.md` nor
skills, and would put sibling members' real paths into whichever repo held
the file, which for a set spanning the public clone is the one thing that
file must never do). `workset profile <name>` prints the resolver's answer
alone; every other subcommand passes straight through to the script.

**The profile rule is read-only, never a pin.** A set runs under exactly one
Claude profile: either every member resolves to the same
`claude_profile_dir`, or `workset.<name>.profile` names one explicitly (same
vocabulary `CLAUDE_PROFILE` and a per-repo `claude.<owner>/<repo>.profile`
pin accept). Either way, before anything opens, every member's real path is
checked against that profile's `permissions.deny` rules via `denyguard
check` — one definition of that boundary, the same one Bash is fenced by,
never a second scanner. A member a rule covers, a heterogeneous set with no
explicit `profile`, or a rule `denyguard` cannot evaluate, all refuse (exit
3 or 4) rather than opening anything, and the remedy is always **drop the
member, or run a smaller set** — never a per-repo profile pin. The tier a
repo sits in is a sensitivity boundary the tool reads; adjusting it to make
a set homogeneous would be the tool writing the very thing it exists to
check. `workset-doctor` and the `routes` `SET` column report this same
verdict for every configured set (a set name with a trailing `!` there means
`workset_profile` refused it on this machine), so none of the three can ever
disagree.

**`plan` answers `conflict` before `checkout` creates anything.** A member
whose worktree directory is free but whose branch is already checked out in
any of its worktrees (`git worktree list --porcelain`, the live checkout
included) is a conflict too, so `checkout` refuses before touching the earlier
members instead of failing partway through.

**Isolation is a hook plus instruction, not a sandbox.** Claude Code's own
worktree-isolation checks (blocking `git -C` into the launch repo,
unparsable commands refused) apply only to a `--worktree`/`EnterWorktree`
session, and only for the repo it was launched from — a working set opens a
plain session in an ordinary `git worktree add` directory, so none of that
applies to any of its N members. What stands in for it: a `PreToolUse` hook
on `Edit|Write|NotebookEdit` (`workset guard`) refuses a write to a member's
**live checkout** while `$WORKSET` is set, naming the worktree to use
instead; a `SessionStart` hook (`workset hook start`) prints the set's
brief — every member's worktree and the live path it stands for, the
set's `note` lines, and a fixed reminder to land in member order and revert
forward, never rewrite, if a later member is rejected after an earlier one
merged. Both hooks fail open (`[ -x ~/bin/workset ] && … || true`) — they
are conveniences, not the sensitivity boundary; Bash is not parsed by either
of them, and is fenced separately by `denyguard`, wired fail-closed.

**Distinct from a `workspace.*` group.** Worktabs groups repos into windows
by however the operator sorts tabs, which is not the same axis a working
set groups by — the same trio of repos can be split across two worktabs
windows (say, one per Claude profile) while still being one working set
for a single session, and a worktabs entry can simply run `workset open
<name> <branch>` as its `command` with no code of its own. Postbox identity
is unchanged too: a set session is still just the agent named by whichever
directory it is standing in (its primary's worktree), since `postbox`
resolves a name per directory and never lists worktrees separately.

**What this does not do.** There is no cross-repo transaction — a set can
land k of its members before k+1 is rejected, and `workset status` (every
worktree's dirty/ahead/behind/remote state) is what makes that visible, not
something that prevents it. `workset close` never `--force`s a worktree
away: it refuses a dirty one, refuses one whose commits are not on the
remote, and only deletes the local branch once merged. A worktree left
behind by an `open` with no matching `close` is loud (`status`,
`workset-doctor`), never silently reclaimed. Tests: `tests/workset.bats`
(sandboxed HOME, fixture repos, the real `denyguard` — never a stub of it —
so the profile and deny checks are exercised for real; no real path, repo,
profile or account name).
