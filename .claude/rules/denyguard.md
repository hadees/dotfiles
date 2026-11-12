---
paths:
  - "**/bin/executable_denyguard"
  - "**/tests/denyguard.bats"
---

# Deny rules reach Bash (`denyguard`)

Claude Code's `permissions.deny` list (`Read(...)`/`Edit(...)` path rules)
binds only those two tools. Its own docs say plainly that it also catches
the handful of Bash commands it recognises as reading a path directly
(`cat`, `head`, `tail`, `sed`, `tee`) and redirection targets, but not "a
command that reads files without naming them, such as `grep -r pattern .`",
nor a script that opens files itself (permissions doc, "Read and Edit",
Warning box). Auto mode actively *prefers* Bash (`cat`, `grep`, `sed`) over
the Read tool, which makes that gap the default path rather than an exotic
one: `grep -c foo ~/code/<repo>/CLAUDE.md` against a tree a profile's deny
list names returns a count regardless.

`bin/executable_denyguard` (`~/bin/denyguard` once deployed) is a
PreToolUse hook on Bash that reads the *same* `permissions.deny` list at
hook time — no second list anywhere — maps every `Read(...)`/`Edit(...)`
entry to an absolute prefix (`~/x` → `$HOME/x`; `//x` → `/x` from the
filesystem root; `/x` → project-relative, resolved against the session's
cwd; bare `x` → gitignore any-depth), and refuses any Bash command whose
literal path tokens, glob prefixes, or cwd land inside one. It widens
coverage to every command that names a denied path in its literal text
(grep, rg, ls, find, wc, awk, diff, `git -C`, a Python file argument, an
`-exec` argument, a heredoc body — the whole command string is scanned), to
a glob that could expand into a denied tree, to a path attached to an
option (`--opt=PATH`, `key=PATH` as `dd` writes it, `@PATH` as `curl` does),
to a relative path resolved against the hook's cwd and against every directory a `cd` or
`pushd` earlier in the command line could have left the shell in, to a symlink whose target is
denied, and to a session whose cwd already is one. `denyguard check
--profile DIR PATH...` exposes the same boundary test for anything else
that needs it (a working-set opener, for one), and `denyguard settings`
prints the PreToolUse block below for a profile's `settings.json` to
paste — it never edits one, since every profile's settings file is
overlay-owned (see the "Private overlays" section of CLAUDE.md).

**An ancestor match needs a real recursion signal, in the same simple
command.** Naming a directory that happens to be an ancestor of a denied
rule is not itself a hit — `ls ~/.claude` over a profile that only denies
`~/.claude/projects/**` passes, and so does a heredoc body written as
documentation (`cat <<EOF … EOF`), which is scanned for a direct hit only,
never an ancestor guess, so prose that names a denied path passes while a
script that actually opens it still refuses. A hit fires only when that
SAME command also carries a genuine recursion signal — `find`/`rg`/`du`/…
by nature, or `-r`/`-R`/`--recursive` on `grep`/`cp`/`rm`/`ls`/… — never a
bare mention of a recursive-sounding word or a flag cluster that merely
contains the letter (`sort -nr`, `ls -ltr`). First three real firings were
all false positives of the OLD, whole-command version of this check
(2026-09-18); this narrowing is that fix.

**A glob is matched component by component, not by its literal prefix.**
`glob_reach` walks the glob's path and a denied rule's prefix together: a
component with a glob character must `fnmatchcase` the rule's component
(case-sensitive on purpose), a literal one must equal it, and a component
that is exactly `**` reaches the tree at once. Running out of the rule's
components first, or both together, is "inside" — the pattern can name the
denied tree or something in it — and is refused ("may expand into"), so
`ls ~/code/*` and `ls ~/code/octo-*/x` still refuse. Running out of the
glob's components first is "ancestor": the pattern can only name a
directory above the denied tree, so it refuses only when that same simple
command recurses (`grep -r x ~/co*`), and a data heredoc body, which never
counts as recursive, passes. Until 2026-11-11 the test was the glob's
literal directory prefix being an ancestor of any rule, so a home-anchored
pattern such as `~/.zsh*` was cut back to `$HOME` and refused whenever any
rule sat under it (found by the audit's own sessions, whose commands
mentioned such a pattern).

**A recursion that names no path starts where the command stands.**
`find`, `fd`, `rg`, `ag`, `ack`, `du` and `tree`, `grep -r` and `ls -R`
search the directory they are in when given no path (`implicit_cwd`; never
for a call carrying `--help` or `--version`). Whether the command was given
a path is decided by position and existence (`names_root`), never by a word
looking like one: an option's value (`rg -g '*.py' gizmo`, `find -name
'*.md'`, `tree -P '*.py'`) and the search pattern itself (`rg gizmo/x`, `rg
NOTES` with a file of that name beside it) both look like paths. `find`'s
first word after its leading `-H -L -P -O -D` options is a root by
position. For the rest, a word after the options (or after a lone `--`) is a
root when it has a glob character or exists; the first one of a
pattern-first command (`grep`, `rg`, `ag`, `ack`, `fd`) is the pattern, and
one straight after an option may be that option's value, so neither counts
(`--files`, `-r` and the other recursive flags take none; `du`, `tree` and
`ls` guard only after a `--long` option or one ending in `P` or `I`, so `du
-sh src` still names `src`). When no root is named, every base `scan` holds
is tried as the directory it recurses from: one that is a strict ancestor of
a denied prefix refuses ("`rg` recurses from `<base>`, an ancestor of
`<rule>`; name an existing directory under it, after the pattern"). Unlike
a named directory, there is no exemption for `$HOME` or `/`. A root that
does not exist yet is not a root (`rg x newdir/` is refused). A heredoc body
line read as a command gets the same test, and its refusal adds "pass prose
through cat". `rg` and `ack` fed by a pipe and given no path read stdin,
not the directory, and are exempt; `grep -r`, `find`, `du`, `tree`, `fd` and
`ls -R` ignore stdin and are not. A glob with no slash is dropped everywhere else, because a bare star is
also a markdown bullet, a SQL column list and a product; under a recursive,
non-data command it is resolved against each base and matched like any
other glob, so `cp -r * dest` from above a denied tree refuses, and it
counts as the path the command was given (`grep -r x *.md` passes).

**A heredoc is only the lines between an opener and its terminator.** The
line that opens one is a command line like any other: it is scanned whole,
minus the `<<WORD` operator itself, so a redirect, an argument or a chained
command written after the marker (`cat <<EOF > path`, `cat <<EOF && cmd`,
`grep -r x <<EOF dir`) is read exactly as it would be before it. `<<WORD`
opens a heredoc only when a later line is exactly `WORD` (whitespace
stripped for `<<-`); with no terminator it opens nothing and every line
keeps the full rule set. `<<<` is a here-string and never opens one — its
text is scanned like any other argument — and neither does a shift inside
`$(( ))`. Being read as a heredoc only ever relaxes the scan (the data body
above), so every doubtful case falls to the strict side. Until 2026-11-11
the scan stopped at the marker: whatever followed `<<` on that line went
unread, here-strings and shifts included, which let `cat <<EOF > <denied
path>` through — the most common way an agent writes a file.

**A `cd` becomes a further base for what follows.** `scan` keeps `bases`,
starting as `[cwd]`; a `cd` or `pushd` simple command adds its target
(`cd_targets`: absolute as written, else joined to each base already
listed, `~` or no argument being home), and every later token is resolved
against every base, so `cd ~/code && cat octo-secret/x` from elsewhere
refuses. The list only grows: a subshell's `cd` is not undone at its
closing parenthesis, because modelling that could resolve a later token
against the wrong directory, and keeping every directory the line ever
stood in is the strict reading. A target containing `$` or a backtick, and
`cd -`, add nothing. A relative `cd` is joined to every base already
listed, so the list doubles at each one (after `cd a; cd b` a shell is in
`a/b`, after `(cd a); cd b` in `b`, and the scan cannot tell which), and
`MAX_BASES = 64` holds six descending relative `cd`s; sibling hops
(`cd ../b`) collapse when normalised, an absolute target adds one, and a
directory already listed is counted once. A command line that would take
the list past 64 is refused, not followed part of the way: the denial
reads "changes directory in more ways than denyguard follows (limit 64)"
and its log line has `(cd limit)` in the rule column, which makes the
limit countable. A profile with no deny rules is never refused for it.
Every resolved path is judged once, however many bases produce it.

**What it cannot see.** This is a lexical guard, not a sandbox: a shell
variable other than `$HOME` (so a `cd` to one, too), `$(...)` output
(likewise a `cd` to a command substitution), a per-command directory flag
such as `-C <dir>`, a script file's own
contents, `find <parent> -exec` without a recursive tell, `eval`, base64,
or any program that computes the path at run time all pass through unseen.
Heredoc reading has two soft spots of its own: a `<<WORD` inside a quoted
string still counts as an opener when a later line happens to be exactly
`WORD` (and its lines get the data reading if that line starts with
`cat`/`tee`/`printf`), and a delimiter with characters outside
`[A-Za-z0-9_]`, or a second heredoc opened on the same line, is not
recognised — its body is read as ordinary commands, which is strict, not
blind.
A value glued to a short option with no separator (`-f` immediately
followed by the path) is not read either: only the text after an `=` or a
leading `@` is tried as a path.
`ls` of a slash-less glob without `-R` (one directory level, names only) is
likewise not examined.
An option's separate value that names an existing file is taken for a root
(`rg -t py NOTES`, `tree -o FILE`, `du -X FILE`).
A pattern glued to its short option (`-ePAT`) is not recognised as one.
`ag` fed by a pipe is refused though it reads stdin (not verified, so not
exempted).
False positives of the same test: an option between the pattern and the root
hides the root (`rg foo --hidden src`: put options first, or write `--`
before the roots).
One gap is worth stating separately because a rule's *shape* invites
over-trust: a token containing a glob is matched only against rules that
carry a directory prefix, so a bare any-depth rule (`Read(**/*.env)`) does
not catch `cat *.env` — the rule looks like it covers the case and does
not.
It guards the accidental and default case — Bash preferred over Read — not
a determined command. OS-level enforcement exists: the Bash sandbox's
`sandbox.filesystem.denyRead` applies to "all commands running inside the
sandbox, including their child processes." That is deliberately **not**
this change — it needs the sandbox on, and it changes what a session can
do with paths it *is* allowed to read too — and is recorded here as the
upgrade path if the lexical gaps above ever cost more than that setup
would.

**Fails closed, on purpose — the one place in this repo that does.** The
tailnet wrappers fail open because routing there is an optimisation and
the command is the point; here the *refusal* is the point, and a guard
that silently becomes a no-op would leave the operator believing the hole
is closed, which is worse than the hole itself. Missing python3, a python3
that exists but cannot start (the wrapper turns any `hook` status other
than 0 or 2 into 2; `check` keeps its own 1), an unreadable/unparsable
`settings.json`, one of the wrong shape (top level, `permissions` or
`deny` of the wrong type, a non-string rule), a payload that is not a JSON
object, and any internal error: exit 2, which blocks the tool call
outright (hooks reference §3 — exit 2 blocks unconditionally, with or
without JSON on stdout). An ABSENT `permissions.deny` reads as zero rules
and allows — that is the correct reading of an empty list, not a failure.
A command line that changes directory in more ways than the scan follows
(`MAX_BASES`, above) is refused too, as an ordinary JSON deny: the scan
knows it has stopped looking, and silence there would be the same lie.
The one way this still fails open is documented by Claude Code itself and
cannot be fixed from here: a hook that TIMES OUT does not block ("don't
count on a stalled hook to act as a gate" — hooks reference §4). So the
script does no network, no subprocesses, and stats only paths it has not
already ruled on lexically; the wiring's `timeout: 10` exists only so a
wedged mount cannot hold a whole turn for the 600s default.

**Cost**: one `sh -c`, one `python3` start, a JSON parse of the settings
file, and a few dozen `lstat`s — about 25–35ms per Bash call, on every Bash
call in every profile it is wired into (hooks run inside subagents too).
Denials are appended to
`${XDG_STATE_HOME:-$HOME/.local/state}/denyguard/denied.log` (`ts \t
profile-label \t rule \t fragment`) — a count of the mechanism acting, not
part of the gate; a failed append is ignored. `claude-doctor`'s `deny:`
line reports the rule count, whether the hook is wired and fail-closed (as
opposed to a `|| true` that silently defangs it), whether `~/bin/denyguard`
is on PATH, and how many denials it has logged.

This script only ships the mechanism: wiring `denyguard settings`'s output
into a profile's `settings.json` is a separate change, since that file is
overlay-owned. Tests: `tests/denyguard.bats` (sandboxed HOME, fixture repos
and rules — no real path, repo, profile or account name; the shape a rule
takes is `Read(~/code/<repo>/**)`, never the operator's own).
