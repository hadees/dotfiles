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
`claude.profile.*`, or a literal directory: whatever `CLAUDE_PROFILE` accepts,
since a pin is that same choice made once per repo instead of once per
invocation. It is machine-local git config, so *which* repos are moved stays in
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

**Each profile must be logged in once** with `claude auth login`; credentials
live in the macOS Keychain and cannot be copied between profiles — verified,
copying `.claude.json` does not carry a session.
