---
paths:
  - "**/dot_functions"
  - "**/dot_claude/**"
  - "**/dot_claude-shared/**"
  - "**/private_dot_claude-*/**"
  - "**/.chezmoitemplates/claude-agents/**"
  - "**/tests/claude-profiles.bats"
  - "**/tests/claude-agents.bats"
---

# Claude Code profiles

Claude Code keeps each account in its own config directory — separate login,
settings, plugins, and session history — selected by `CLAUDE_CONFIG_DIR`.
Two profiles are deployed:

| Directory | Profile | Source |
| --- | --- | --- |
| `~/.claude` | work (the default config dir; keeps the existing login, plugins, and session history) | `dot_claude/` here + the work overlay's `settings.json` and `CLAUDE.work.md` |
| `~/.claude-hadees` | personal | `private_dot_claude-hadees/` here + the personal overlay's `settings.json` |
| `~/.claude-shared` | memory imported by both, plus the agent definitions an overlay-owned profile symlinks at | `dot_claude-shared/` here |

Overlays may add further profiles (mapping, pins, and config dir all their
own); this repo neither knows nor cares which — with one exception that cost
an overlay-owned profile its subagents. The shared **agent definitions** reach a profile
through a one-line stub per profile directory, and chezmoi resolves
`.chezmoitemplates` within a single source, so an overlay-owned profile
directory cannot render them at all. It has no access to these templates. So
the same bodies are also deployed, once, to `~/.claude-shared/agents`, and
such a profile symlinks its `agents` directory at that — the
public-machinery/private-profile split the shared `CLAUDE.md` already uses.
`tests/claude-agents.bats` discovers the stub directories rather than listing
them, and pins the shared copy's existence, because a hardcoded list is what
hid an overlay profile having no `agents` directory at all. Each profile's `CLAUDE.md` is
a thin file that imports the shared memory plus
its own machine-local (and, for work, work-specific) notes. Settings are
**not** shared: neither profile's `settings.json` lives in this repo — the
work one names the private plugin marketplace, and the personal one carries
a `permissions.deny` block whose paths are work-bearing, so each comes from
its own overlay.

The `claude()` function in `.functions` picks the profile by resolving the
cwd's origin remote to a GitHub account — via the same
`credential.<url>.username` pins that drive `gh()` — then looking up
`claude.profile.<account>` in git config. That mapping lives in the overlays,
which is why no account names appear here; each overlay may also map friendly
short names and a `claude.profile.default` used when no pin matches the cwd
(unset, stray directories get plain `claude`). Override per invocation with
`CLAUDE_PROFILE=<name-or-directory> claude`, or launch a specific profile
explicitly with `claude-as <name> [args...]` — a strict passthrough that
errors out (listing the mapped names) rather than ever falling back to a
different account.

**The owner is the default, not the verdict.** A repo that should run under a
different login than its owner's account maps to gets a per-repo pin,
`claude.<owner>/<repo>.profile` (origin slug, lowercase), which outranks the
account mapping and leaves every sibling repo of that owner alone — the same
shape and precedence as `wrangler.<owner>/<repo>.profile` and
`identity.<owner>/<repo>.email`. The value is an account or alias from
`claude.profile.*`, or a literal directory (absolute or `~`-prefixed; a bare
word is only ever a mapped name): whatever `CLAUDE_PROFILE` accepts, since a pin
is that same choice made once per repo instead of once per invocation. The
resolver prints one normalised spelling, so a trailing slash or `..` in a
mapping, pin or `CLAUDE_PROFILE` still compares equal to the default directory. It is machine-local git config, so *which* repos are moved stays in
the overlays and no repo names appear here. Precedence end to end:
`CLAUDE_PROFILE` → `claude.<owner>/<repo>.profile` → `claude.profile.<account>`
→ `claude.profile.default` → bare `claude`.

A pin naming something unmapped **warns on every invocation** and then uses the
owner's account, rather than resolving quietly. That is deliberate and not
cosmetic: sessions are partitioned per config dir, so a typo'd pin would land
in another account's history and resume *nothing* instead of failing.
`claude-doctor` prints a `pin:` line above `mapping:` for the same reason —
a repo resolving somewhere its origin does not explain should say why — and
`routes` marks the pinned cell with `*` like the other routers.

**A second session in the same directory is asked about, not refused.** Two
sessions in one directory are two writers on one tree, and a fresh prompt
gives no sign the first is there. `claude()` therefore reads the registry
every profile keeps of its live sessions — `<config dir>/sessions/<pid>.json`,
removed on exit (observed layout, not an interface; postbox reads the same
files) — through `claude_sessions_here`, which checks **every** mapped profile
plus the directory this launch resolved to (a literal `CLAUDE_PROFILE` or
per-repo pin can sit outside every mapping), since the tree is shared
whichever login is running in it. A hit lists each
session (name, pid, status, profile) and asks `Start another here anyway?
[y/N]`. Only a launch somebody is sitting at is asked: no terminal on stdin or
stderr, `-p`/`--print`, a help or version flag, or a first argument shaped like
a subcommand (`claude mcp …` — by shape, one bare lowercase word, because a
list of the CLI's subcommands would go stale; the price is that a one-word
prompt, `claude fix`, is not asked either) passes untouched, so hooks, the
postbox courier and anything piped never block on a question nobody can
answer. It fails open, and it matches the directory exactly: a session started
in a subdirectory of the same checkout is not seen. Running several sessions
in one checkout on purpose is a workflow, not a mistake, so `git config
claude.second-session-check false` turns the question off — policy in
machine-local git config, like the push gates. `claude-doctor`'s `running:`
line lists the sessions the wrapper would find here — not whether a given
launch would be asked, which also depends on how it is invoked — and says
when the check is off. Testing the prompt
needs a pseudo-terminal, and the two obvious tools both fail on macOS — zsh's
`zpty` returns short reads, and `pty.spawn` before Python 3.10 never returns
once the child exits — so `tests/claude-profiles.bats` forks one by hand.

**The wrapper also chooses the iTerm2 Workgroup a tab enters.** After the
second-session question is passed, and only on a launch that question applies
to, `claude()` writes an OSC 1337 `SetUserVar=claudePeerEnter=<base64 of
"<key>:<nonce>">` escape to the terminal; the key comes from `claude_peer_key`
(`claude-peer here`, plus `/hermes` where `hermes_profile` routes the
directory). Nothing is sent without `$ITERM_SESSION_ID`, inside a peer
(`$CLAUDE_PEER_WORKTREE`), or without the state file `claude-peer default peers`
writes. `claude-doctor`'s `workgroup:` line shows the key or why there is none.
The mechanism is in `claude-peer.md`. On a launch that sent the key, the tab
is Lead's, so the launch becomes `claude -n <claude-peer name lead> …` (so
`<repo>-lead`, `--continue` and `--resume` included, which is what keeps the
name across `claude-tab restore`) unless an argument is `-n`, `--name` or
`--name=…`, or a live session in this directory already has that name: two
sessions with one name make a bare name undeliverable. The session list is now
read once per attended launch, whether or not the second-session question is
on, and shared with it. postbox finds Lead by process, never by this name; a
launch not made through the wrapper keeps Claude Code's own name, and a name
set with `/rename` is replaced at the next wrapper launch of that session.

**The wrapper says when hooks will spawn osascript.** On an attended launch
with `$ITERM_SESSION_ID` set and `~/.config/iterm2/it2` present, a state other
than `fresh` from `iterm2_cookie_state` prints one stderr line, `claude: no
iTerm2 API cookie for this iTerm2 run (<state>), so every hook event starts
osascript (iTerm2 issue 13189): run iterm2-cookie`. The checks before the line
are builtins, so a launch with nothing to say forks nothing (the one
`git config` read comes only after the state is not `fresh`); it never blocks.
`git config claude.iterm2-check false` silences it (machine-local, like the
other switches). `tests/claude-profiles.bats` gives its sandbox a fresh cookie
in `setup`, so only the tests about this line ever meet it. The cookie is
described in `cc-status-shim.md`.

**The same block says when iTerm2 has moved past the skill.** On an attended
launch `iterm2_skill_drift` compares the installed iTerm2's version (one read
of `Info.plist`) with the stamp in `iterm2-doctor`; a difference prints
`claude: iTerm2 <ver> is newer|older than the skill's notes (<stamp>): run
iterm2-doctor`. Both lines share one `git config claude.iterm2-check` read,
made only when at least one has something to say. `claude-doctor`'s `iterm2:`
line shows the same sentence or `matches the skill's notes`. The mechanism is in
`iterm2-skill.md`; `tests/claude-profiles.bats` sets `ITERM2_APP` to a missing
path in `setup`.

**Each profile must be logged in once** with `claude auth login`; credentials
live in the macOS Keychain and cannot be copied between profiles — verified,
copying `.claude.json` does not carry a session.

## The default directory's memory reaches every profile

Claude Code loads `./CLAUDE.md` and `./.claude/CLAUDE.md` from the working
directory **and every directory above it**, labelled project instructions. The
default config directory is `~/.claude`, so `~/.claude/CLAUDE.md` sits on the
ancestor path of every session started under the home directory, whichever
profile it runs in. A non-default profile therefore loads the default
profile's `CLAUDE.md`, its `CLAUDE.local.md`, its `CLAUDE.work.md` and (as
project rules) `~/.claude/rules/**` on top of its own memory. Observed from a
non-default profile, not inferred.

**The fix is an exclude, owned by the overlay that owns the profile.**
`claudeMdExcludes` in a profile's `settings.json` takes absolute-path globs
(picomatch, dot files matched; arrays merge across settings layers), so each
non-default profile lists the default directory's memory: `CLAUDE.md`,
`CLAUDE.local.md`, `CLAUDE.work.md` and `rules/**`, as absolute paths rendered
with `joinPath .chezmoi.homeDir`. Nothing moves and no login is touched; a
running session keeps what it loaded and picks the change up at its next
start, `/clear` or compaction. The public repo cannot write it: no
`settings.json` lives here, and the entries name which profile is which. An
exclude keeps the file out of context; it is not a sensitivity boundary, and
the file stays readable on disk.

**A profile that imports one of those files on purpose must not list it.** The
exclude test applies to user-type files too, so excluding an imported file
would drop the import. The lite profile imports the default profile's
`CLAUDE.work.md` itself, so it lists three entries, not four; once its
`CLAUDE.md` is no longer reached by ancestry, its imports are loaded only
through that import.

**`claude_memory_leaks <profile-dir>` makes a missing exclude visible.** It
prints, one per line, each of `~/.claude/CLAUDE.md` and `~/.claude/rules/**`
that would load in that profile and that its `settings.json` does not list. It
prints nothing for the default directory itself, when the cwd is not under the
home directory, or when the file or rules do not exist. "Listed" is a literal
test: the quoted absolute path appears in the settings text. It runs on every
launch, where a JSON parser costs a process; the price is that a glob-only
exclude is not recognised and still warns, and that a path inside a deny rule
does not count, so the overlays write the exact path. It looks only at those
two entries, the ones that carry the leak; a profile missing just
`CLAUDE.local.md` is not reported.

`claude()` prints one stderr line per entry before launching and never blocks
or changes the launch. `git config claude.memory-check false` turns the
warning off (machine-local policy, like the other switches). `claude-doctor`'s
`memory:` line, directly after `creds:`, says `clean`, `LEAK` (naming the
entries and where to list them), `n/a` outside the home directory, or that the
directory is the default one; it notes when the switch is off. Tests:
`tests/claude-profiles.bats`.

**Why the profile was not moved out of the default directory.** The leak is
whatever sits at `~/.claude/CLAUDE.md`, not who uses it. Moving the profile
leaves that path: the public repo deploys `dot_claude/CLAUDE.md` there on every
machine class, and Claude Code, Claude Desktop's Code tab, the statusline
plugin and several hook scripts keep using that directory, so the same exclude
would still be needed. A move would additionally cost a re-login, rewritten
absolute paths in the plugin registry, a deny-rule change in other profiles
that must land before the transcripts move, and a quiesce of every running
session.
