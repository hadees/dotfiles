# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Personal dotfiles managed by **chezmoi**, targeting macOS, Linux, WSL, and
disposable remote boxes. Shell configuration (zsh-first; `.bash_profile`
auto-upgrades bash sessions to zsh), macOS system defaults, and a Homebrew
bundle. A **machine class** chosen once at `chezmoi init` (`mac` / `linux` /
`wsl` / `ephemeral`, answerable non-interactively with
`--promptString machineClass=<class>`) drives all per-machine templating:
`ephemeral` deploys shell config only (no identity, no secrets), `wsl` adds
1Password's ssh.exe forwarding pattern, `mac` pins chezmoi's `sourceDir` to
`~/code/dotfiles` so the clone is the source of truth.

Source naming follows chezmoi conventions: `dot_zshrc` deploys to
`~/.zshrc`, `private_dot_extra.tmpl` renders to `~/.extra` (mode 0600),
`bin/executable_has-glyphs` to `~/bin/has-glyphs`, `create_` files are
written only when missing. Repo-level files (`.gitignore`, `.macos`,
`.github`, dot-prefixed in general) are invisible to chezmoi; non-dot
repo files are excluded via `.chezmoiignore`.

## Installation

```bash
# Fresh machine (no root needed)
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply hadees

# Disposable box — applies, then removes chezmoi and all traces of itself
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --one-shot hadees

# Development clone (this Mac)
chezmoi init --source ~/code/dotfiles --apply

# Day-to-day: edit in ~/code/dotfiles, then
chezmoi diff && chezmoi apply    # or just `dotfiles`, which also applies
                                 # any private overlays (see below)

# Apply macOS system preferences (requires sudo; run manually, chezmoi
# never touches it). Optionally set a machine name first:
COMPUTER_NAME="My-Mac" ./.macos

# Install Homebrew packages (macOS)
brew bundle
```

`bootstrap.sh` is a deprecated wrapper that just calls
`chezmoi init --source . --apply`; it will be removed.

## Running tests

Tests use [bats-core](https://github.com/bats-core/bats-core). Install it first (`brew install bats-core`), then:

```bash
# Run all tests
bats tests

# Run a single test file
bats tests/macos.bats
bats tests/bootstrap.bats
```

`bats` must run under **bash ≥ 4**: macOS's `/bin/bash` 3.2 does not fail a
test on a failing `[[ ]]` unless it is the test's last command, so mid-test
assertions are silently skipped. `tests/shell.bats` refuses to run under it.
A shell that sourced `.exports` already has Homebrew's `bin` first on PATH
(so its bash 5 wins), and CI's macOS job does the same; elsewhere use
`PATH="$(brew --prefix)/bin:$PATH" bats tests`.

To *run* the dotfiles rather than test them — render a machine class into a
sandbox `$HOME`, drive the resulting zsh (prompt, wrappers, doctors) one-shot
or under tmux, stack overlays, or see what a real apply would change — use
the `/run-dotfiles` skill (`.claude/skills/run-dotfiles/driver.sh`); each
overlay carries a matching `run-<overlay>` skill that stacks itself on it.
Skill directories are dot-prefixed, so chezmoi never deploys them.

CI (`.github/workflows/tests.yml`) runs the suite on `ubuntu-latest`,
`macos-latest`, Rocky Linux 9 (container), and WSL Ubuntu (windows runner).
The macOS job additionally executes `.macos` for real and asserts settings
stuck (`tests/macos-apply.bats`) — safe there because runners are throwaway
VMs; the test skips everywhere else unless `MACOS_APPLY_OK=1` is set.

## Architecture

### Shell loading order (zsh)

`.zshrc` sources these files in order when present: `~/.path`, `~/.zsh_prompt`, `~/.exports`, `~/.aliases`, `~/.functions`, `~/.extra`

- **`~/.path`** — machine-local PATH additions (not in repo)
- **`~/.extra`** — machine-local overrides and secrets (not in this repo; comes from the private overlay)
- **`.exports`** — environment variables
- **`.aliases`** — shell aliases
- **`.functions`** — shell functions
- **`.zsh_prompt`** — custom two-line prompt with git status indicators (`+` staged, `!` unstaged, `?` untracked, `$` stashed)

### Key files

- **`.chezmoi.toml.tmpl`** — config template; prompts once for the machine class and pins `sourceDir` to the clone on macs
- **`.chezmoiignore`** — target paths chezmoi must not manage (repo-level files everywhere; macOS GUI config off-mac; identity/secrets on `ephemeral`)
- **`bootstrap.sh`** — deprecated wrapper around `chezmoi init --source . --apply`
- **`.macos`** — macOS `defaults write` settings; reads `$COMPUTER_NAME` env var for machine-specific naming
- **`Brewfile`** — Homebrew formulae, casks, and Mac App Store apps (macOS only; `.chezmoiscripts/darwin/` runs `brew bundle` when it changes)
- **`packages-apt.txt`** — Debian/Ubuntu/WSL package list (`.chezmoiscripts/linux/` installs it when it changes; skips gracefully without apt or sudo)
- **`bin/`** — personal scripts added to `$PATH`
- **Claude Code statusline** — lives in a private skills marketplace repo (skill `claude-statusline`), not here. Install once per machine with `/claude-statusline`; the plugin's session-start hook keeps the installed copies in `~/.claude` current after that. `~/.claude/settings.json` comes from the work overlay, so on a machine without that overlay there is no statusLine command to be dead.
- **`init/`** — one-time setup scripts
- **`theme/`** — Base16 Eighties color themes (darkened bg `#1a1a1a`) for iTerm2, Terminal.app, and Alfred; VSCode uses the `bsides.Theme-Base16-Eighties` extension installed by `.macos`. Terminal apps (bat, delta, fzf, k9s, vim) use `base16-256`/`base16-eighties` and inherit the iTerm palette.

### Commit identity gate (global git hooks)

`dot_gitconfig` sets `core.hooksPath = ~/.git-hooks` (`dot_git-hooks/`).
`pre-commit` refuses a commit whose author or committer email is not one of
`identity.<account>.email` for the account the origin's owner is pinned to
(same credential pins as the wrappers; the mapping is overlay-supplied, so
a public-only clone has no opinion), or of `identity.<owner>/<repo>.email`
when that per-repo pin exists (a side project committing under its own
identity — mirrors `wrangler.<owner>/<repo>.profile`). `GIT_IDENTITY_CHECK=0` bypasses one
commit; `git-doctor` shows the verdict (`gate:`). Every hook name there is
a shim that first runs any `hook.<name>.run` git-config commands (repeatable,
per-repo `.git/config`; a failure blocks) and then the repo's own
`.git/hooks/<name>` — via `git rev-parse --git-common-dir`, never
`--git-path hooks`, which honours `core.hooksPath` and would exec the shim
itself. Tests: `tests/git-hooks.bats` — its fixture repos must use
absolute paths for anything under `.git/`, or a relative path lands in this
clone's `.git/hooks`. Full guide: `docs/private-overlays.md`.

### Commit signing

Commits are signed with **SSH-format signatures via 1Password**, not GPG.
Signing is entirely machine-local: the tracked `.gitconfig` does NOT enable
it, so a fresh machine defaults to unsigned commits instead of failing on a
missing signer. Each machine opts in via untracked files:

- `~/.gitconfig.local` (from the private overlay) and any per-identity include
  it pulls in set `commit.gpgsign = true`, `gpg.format = ssh`,
  `gpg.ssh.program = .../op-ssh-sign`, and
  `user.signingkey = ~/.ssh/*.pub`.
- `~/.ssh/config` points `IdentityAgent` at the 1Password agent socket; the
  private keys live in 1Password and never touch disk. The `.pub` files are
  just selectors.

On a machine without 1Password (e.g. a remote Linux box), nothing needs
disabling — signing is simply never enabled there. To sign on a remote you
keep around, forward your local 1Password SSH agent over the connection and
set `user.signingkey` to the literal public key (not `op-ssh-sign`, which
only exists locally). There is **no GPG keypair** in this setup despite the
`gpgsign` name.

When signing breaks, read the next section before touching any config — the
usual failure is transient and not a misconfiguration at all.

### 1Password

1Password is load-bearing in three unrelated places — it holds the SSH keys,
it signs every commit, and it is where `~/.extra`'s secrets come from at
apply time — over **three connections that fail independently**:

1. the `op` CLI → the desktop app via `~/.config/op/op-daemon.sock`, gated by
   `op signin` and a session that lapses;
2. `ssh` and git-over-ssh → the agent socket named by `~/.ssh/config`'s
   `IdentityAgent` (macOS: inside the app's group container — `~/.1password/
   agent.sock` is the **Linux** path, and this repo deliberately names the
   real one);
3. `op-ssh-sign` → its own connection to the app.

Treating those as one channel is the source of nearly every wasted hour here.
Verified: **`op-ssh-sign` never reads `SSH_AUTH_SOCK`** (it signs with the
variable unset, at the launchd default, and pointed at a nonexistent path),
and **`ssh-add` never reads `~/.ssh/config`** (it speaks only to
`$SSH_AUTH_SOCK`, which under Claude Code's Bash tool is macOS's launchd
agent). So `ssh-add -l` listing keys is not evidence a commit will sign, and
"The agent has no identities" is not evidence anything is broken.

The concrete symptom that costs time: `git commit` dying with
`error: 1Password: failed to fill whole buffer` / `fatal: failed to write
commit object` while the agent lists keys and the app is running. That string
is inside `op-ssh-sign` (Rust's `read_exact` error) and means the app's reply
came up short — locked, approval unanswered, or restarting. It clears on
unlock/approve + retry with **no config change**, which is itself the proof
that nothing is misconfigured. Never respond by committing unsigned or
turning `commit.gpgsign` off.

`onepassword-doctor` reports all three channels separately (`ssh -G` for the
`IdentityAgent`, `$SSH_AUTH_SOCK` on its own line), whether `~/.extra`
mentions a routed token (**names only, never a value**), and a `skill:` line
comparing the notes' version stamp to what is installed. `doctor` runs it
last. Versions come off the install without executing anything — the CLI is a
**cask**, so `bin_trace` reads it out of the Caskroom path, and the app's
version comes from its `Info.plist`.

The long form lives in the **`onepassword` skill**
(`.claude/skills/onepassword/`, dot-prefixed so chezmoi never deploys it):
the triage table, the `op` command surface and secret-reference grammar, the
SSH agent in depth (`agent.toml`, the OpenSSH six-key limit), and 1Password's
own release cadence and changelog locations. `VERSIONS` in that directory is
the stamp the doctor compares against — **bump it only together with
re-verifying the claims**, since a bumped stamp over stale prose silences the
nudge without fixing anything. Tests: `tests/onepassword.bats` (stub
op/ssh/ssh-add, sandboxed HOME; no vault or network touched).

### Package lists

CLI tools are declared per-OS — `Brewfile` (macOS), `packages-apt.txt`
(Debian/Ubuntu/WSL). **When adding or removing a tool, update every list
where it's available**, using each distro's native package name (e.g.
Ubuntu's `bat` package installs the binary as `batcat`; the shell config's
`command -v` guards tolerate the difference). If a tool exists on one
platform only, note it in the list file. Homebrew is deliberately not used
on Linux. The install scripts re-run automatically on `chezmoi apply`
whenever their list's hash changes; the `ephemeral` machine class never
runs them.

### Machine-local customization

Add `~/.extra` (from the private overlay, or hand-written) for per-machine overrides. Add `~/.path` for per-machine PATH entries. The `.macos` script skips the computer name block if `$COMPUTER_NAME` is unset.

### Private overlays

**This repo is public and must stay identity-free.** Anything that names a
person, an account, an organization, or a private repo lives in **private
chezmoi overlays** — additional chezmoi configs in `~/.config/chezmoi/*.toml`,
each pointing at its own source clone. `docs/private-overlays.md` is the
full manual (building an overlay, loading it, what goes where, the leak
test, the add-an-account checklist); this section is the summary. Ownership
follows content:

- the **personal overlay** (`hadees/dotfiles-private`, cloned to
  `~/code/dotfiles-private`) carries the personal identity;
- a **work overlay** (a private repo owned by the work account, deliberately
  unnamed here) carries the work identity; a machine used for work clones it,
  others never see it.

| Target | Overlay | What makes it private |
| --- | --- | --- |
| `~/.gitconfig.local` | personal | name/email, personal account pin, personal `claude.profile` / `wrangler.profile` mappings |
| `~/.gitconfig.work` (+ the identity file it routes to) | work | work account, work org pins, work identity routing, work `claude.profile` / `wrangler.profile` mappings |
| `~/.claude/settings.json` | work | names the private plugin marketplace repo |
| `~/.claude/CLAUDE.work.md` | work | work account/org notes, imported by `~/.claude/CLAUDE.md` |
| `~/.config/<vendor>/env` files | personal | third-party account names and 1Password vault paths |
| `~/.extra` (0600) | personal | machine-local secrets from 1Password |

chezmoi allows one source directory per config file, so each overlay is its
own config file pointing at its own source, and each sets `persistentState`
explicitly (all configs live in `~/.config/chezmoi/` and would otherwise
share one state database). The `dotfiles` function in `.functions` applies
the public source, then every overlay config whose source clone exists; see
each overlay's README for its one-time init.

The public `.gitconfig` ends by including `~/.gitconfig.local` and
`~/.gitconfig.work`; git silently skips whichever is absent, so identity is
purely a function of which overlays a machine carries.

**Consequences to keep in mind when editing this repo:**

- A public-only clone configures **no git `user.name` / `user.email`** — that
  is expected, not a bug. Same for `~/.extra` and `~/.claude/settings.json`.
- Nothing in the public source may depend on any overlay existing. Templates,
  tests, and scripts must all work without them (`ephemeral` boxes never get
  them).
- The `gh()` wrapper and `bin/git-credential-gh-user` deliberately contain no
  account or org names: both read the `credential.<url>.username` pins from
  git config at runtime, which the overlays provide. **Adding a work org is a
  one-line change in the work overlay and needs no edit here.**
- Don't "helpfully" reintroduce a name, email, org, or private repo name into
  this repo's files, tests, or commit messages. The personal overlay's
  `tests/no-public-leak.bats` enforces this over the tree, commit messages,
  and commit author/committer identities.

### Claude Code profiles

Claude Code keeps each account in its own config directory — separate login,
settings, plugins, and session history — selected by `CLAUDE_CONFIG_DIR`.
Two profiles are deployed:

| Directory | Profile | Source |
| --- | --- | --- |
| `~/.claude` | work (the default config dir; keeps the existing login, plugins, and session history) | `dot_claude/` here + the work overlay's `settings.json` and `CLAUDE.work.md` |
| `~/.claude-hadees` | personal | `private_dot_claude-hadees/` here |
| `~/.claude-shared` | memory imported by both | `dot_claude-shared/` here |

Each profile's `CLAUDE.md` is a thin file that imports the shared memory plus
its own machine-local (and, for work, work-specific) notes. Settings are
**not** shared: only the work profile's `settings.json` references the private
plugin marketplace.

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

**Each profile must be logged in once** with `claude auth login`; credentials
live in the macOS Keychain and cannot be copied between profiles — verified,
copying `.claude.json` does not carry a session.

### Workspace launcher (iTerm2 tabs, on demand or at launch)

`bin/workspace` puts a set of terminal tabs back on screen: **one iTerm2 window
per group**, one tab per entry, each tab sitting in its directory with its
command already running. What those entries are is identity-bearing (real
paths, real group names), so — like every other router here — the machinery is
public and the list is machine-local git config from an overlay:

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
- The trigger is **iTerm2's own AutoLaunch**. `workspace install` compiles a
  one-line AppleScript to `~/Library/Application Support/iTerm2/Scripts/
  AutoLaunch.scpt`; iTerm2 runs it at every launch. This replaced a per-user
  launchd agent, and the reason is TCC: a LaunchAgent driving `osascript` is
  its own responsible process needing its own Automation grant, which can
  prompt at login with nobody there to answer it, and which macOS can drop
  when a signing identity changes. A script iTerm2 runs is iTerm2 automating
  itself — implicitly allowed and never recorded. **Measured, not assumed:**
  with the calling terminal's Automation grant revoked, an AutoLaunch-spawned
  shell still created a window (`rc=0`) and no grant row appeared. It also
  deletes the Dock-wait, the settle delay, and the retry loop, all of which
  existed only because `RunAtLoad` fires before the GUI is ready — AutoLaunch
  fires *because* iTerm2 started. Install refuses to clobber an
  `AutoLaunch.scpt` it did not write, and prints the line to add by hand.
  The call is backgrounded: iTerm2 runs AutoLaunch on its own AppleScript
  runner, and a synchronous `do shell script` that sends events back to iTerm2
  can sit behind the very runner it waits on.

An iTerm2 **Window Arrangement** remains the wrong tool: it restores a shell in
a directory, not a running command; it lives in `com.googlecode.iterm2.plist`,
which this repo deploys, so real project paths would leak on the next capture;
and it is edited by clicking, not provisioned by an overlay.

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
the title still rendered empty). So `start` exports `WORKSPACE_GROUP` into each
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
workspace neither created nor reuses; `OpenNoWindowsAtStartup` suppresses it,
and `install`/`workspace-doctor` print that line rather than writing a
preference into a tracked file behind you.

Commands mirror `tailnet`'s shape: `list`, `groups`, `plan` (the decision
table, tab-separated), `script` (the AppleScript `start` would run — a dry
run), `start [name|group…]`, `alfred`, `install`, `uninstall`, `status`,
`logs`, `dir`. A selector names either one entry or a whole group.
`list`/`groups`/`plan`/`script`/`alfred` are pure text and work anywhere; the
acting commands refuse off macOS, and `.chezmoiignore` does not deploy the
script there. Nothing configured is ever silently ignored — a name git accepts
but this does not (`[workspace "bad name"]`) is warned about rather than
dropped during parsing. `workspace-doctor` reports the script, iTerm2, the
trigger, and the configured entries with which are open; `doctor` includes it.
Once per machine: `workspace install`. Tests: `tests/workspace.bats` (stub
osascript/open/ps/uname/osacompile; fixture names only).

**Alfred front-end.** `alfred/workspace/` is an Alfred 5 workflow — keyword
`ws` — whose Script Filter runs `workspace alfred` (Script Filter JSON, one
item per group with its open/total count) and whose action runs `workspace
start <group>`. `workspace alfred-install` zips it and hands it to Alfred,
which shows its own import sheet; dropping the folder into Alfred's
preferences by hand is not a supported path. Three things shape it: Alfred
runs scripts with `/bin/zsh --no-rcs` and a fixed PATH that **excludes
`~/bin`**, so both scripts call `$HOME/bin/workspace` by absolute path; the
filter sets `alfredfiltersresults` so the script runs once and Alfred narrows
as you type, rather than re-running per keystroke; and it passes the selection
as **argv**, not `{query}`, so there is no query escaping to get wrong. The
workflow holds no logic and therefore no identity — the group names come from
the overlay at run time. It is **not** a chezmoi target: Alfred rewrites
`info.plist` whenever the workflow is edited in its GUI, which would show as
permanent drift, so the repo keeps the source and `alfred-install` copies it.

### Wrangler (Cloudflare) auth profiles

Wrangler (≥ 4.106) keeps one OAuth login per **auth profile**: named ones
created with `wrangler auth create <name>`, plus the unnamed `default` that
`wrangler login` manages. Wrangler resolves the profile for a command as
`CLOUDFLARE_API_TOKEN` (overrides everything) → `--profile <name>` → the
nearest ancestor directory bound with `wrangler auth activate <name> <dir>`
→ `default`. `auth`, `login`, `logout`, and `whoami` reject `--profile`.

The `wrangler()` function in `.functions` picks the profile the way
`claude()` picks its config dir — cwd origin → account (credential pins) →
`wrangler.profile.<account>` in machine-local git config, set by the
overlays — with one extra layer first: a **per-repo pin**
`wrangler.<owner>/<repo>.profile` (origin slug, lowercase) outranks the
account mapping, for a repo that deploys to a Cloudflare account other than
its GitHub owner's usual one (a side project with its own Cloudflare login,
hosted under the personal account). It then **keeps the repo root bound to
that profile** via
wrangler's own `auth activate`, re-binding only when the binding is missing
or points elsewhere. Driving the binding (instead of injecting a flag) is
what makes `whoami`, `npx wrangler`, and package.json scripts agree with the
wrapper. Consequences:

- A mapped profile that was never created makes the wrapper refuse to run
  the command (it never logs you in and never falls back to another
  account); create it once with `wrangler auth create <name>`.
- Mapping an account to `default` means wrangler's default login and manages
  no binding — prefer a named profile for every account, including the main
  one, so each repo gets an explicit binding and nothing depends on which
  login `wrangler login` last stored. `auth`/`login`/`logout` pass straight
  through, and a set `CLOUDFLARE_API_TOKEN` disables profile management
  entirely.
- Unpinned repos and non-repo directories are left to wrangler's own
  resolution.
- **Which wrangler runs** is resolved the way `npx wrangler` resolves it:
  the nearest `node_modules/.bin/wrangler` at or above the cwd (a project
  that vendors wrangler as a devDependency gets the version it pinned, on
  the node it was installed under), else whatever `wrangler` is on PATH —
  an asdf/nodenv shim, `npm -g`, etc. asdf answers "which wrangler", the
  wrapper answers "as whom"; profiles and bindings live in wrangler's
  per-user config dir, so every install sees the same logins. No wrangler
  anywhere is a clear error, not a fallback.
- Override for one run with `WRANGLER_PROFILE=<mapped name or existing
  profile> wrangler …` or `wrangler-as <name> [args...]` (strict: unknown
  names error out listing the mapped ones); both pass `--profile=`, so they
  cannot be combined with the commands that reject it.
- `wrangler-doctor` traces all of the above for the cwd (pin, mapping,
  profile existence, binding, what wrangler will use) without running
  wrangler; `gh-doctor` and `claude-doctor` do the same for their wrappers
  (`gh-doctor` also verifies the stored token really authenticates as the
  pinned account, since gh's keyring has handed back the wrong one before),
  and `git-doctor` covers git itself: the commit identity the include chain
  selected and which file supplied it, signing config and whether its
  key/signer exist, the origin's SSH alias resolution, https credential
  routing. Each wrapper's doctor also prints a `binary:` line — which
  executable will run, a version-manager shim followed to the install it
  selects for the cwd (or "not installed under the selected node"), and the
  version read off the install without executing it (npm `package.json`,
  cask/native path segment). `doctor` runs them all (git, gh, claude,
  wrangler, hermes, tailnet, workspace, onepassword, iterm2 — the last two
  are not per-repo, but 1Password is what signing and `~/.extra` rest on and
  iTerm2 is the terminal the rest run inside, so their failures arrive
  disguised as per-repo ones). Every doctor also opens with a `defined:` line — are
  the helpers its wrapper (and the doctor itself) call actually defined in
  this shell — printed before any line that depends on one, because a
  missing helper makes a doctor misreport confidently (`account: <no pin
  matched>`) rather than fail; Claude Code's shell snapshot has dropped
  functions silently before. The lists are checked against the function
  bodies by `tests/git-doctor.bats`, so they cannot go stale.
  `tailnet-doctor` adds `helpers:` — it runs the wrappers' real decision
  path on a loopback URL and a host no tailnet has and reports the first
  thing that goes wrong; the wrappers fail open, so a broken helper is
  silent there and this is where it shows. `doctor` itself opens with a
  `shell:` line — zsh version, `under Claude Code` when its Bash tool is
  the caller, and the calling shell's non-default pattern/glob options —
  read before any `emulate`, so a pasted transcript says which shell it
  came from.

### Hermes (per-repo agent profiles)

The Hermes harness (NousResearch/hermes-agent) keeps per-agent state in
profiles (`hermes profile create <name>` — each its own HERMES_HOME with its
own config, approval rules, memory, and .env keys). The `hermes()` wrapper
in `.functions` routes by machine-local per-repo pins: `git config
hermes.profile <name>` injects `-p <name>`; optional `git config
hermes.model <model>` appends `--model <model>` (hermes CLI args outrank
config — same profile/memory/keys, different LLM; full isolation is a
profile per purpose, whose own config/.env carry that provider). In a
pinned repo an explicit `-p`/`--profile` naming a *different* profile is a
loud error, never an override (same stance as claude-as/wrangler; it was
never a working override anyway — hermes honours the first `-p` and the
leftover flag dies as an argparse usage error); the pinned name itself is a
no-op, `command hermes` is the bypass, unpinned directories pass through
untouched. The retired `hermes.launcher` pin is refused with its migration
printed, never silently ignored.

Hermes never starts a model server — it only speaks HTTP to the profile's
`model.base_url` (auto-starting the server was `ollama launch`'s only real
job). So the wrapper reads the effective profile's `config.yaml` and, only
when `model.provider` is ollama-ish AND `base_url` is loopback, probes the
port and starts `ollama serve` disowned with a bounded readiness wait when
nothing answers; a cloud profile (Anthropic/OpenAI/OpenRouter) or a
LAN/WireGuard ollama never waits on or spawns anything, and every failure
warns and falls open — hermes prints the real connection error.
`hermes-doctor` traces all of it for the cwd (pins, effective profile and
its config via the same helpers the wrapper calls — the two cannot drift —
and, for a local-ollama profile, whether the server answers) without
starting anything; `doctor` includes it. Tests: `tests/hermes.bats` (stub
hermes/ollama/curl; fixture profile names only).

### Tailnets (two Tailscale networks at once)

Tailscale.app holds several accounts but is *on* one tailnet at a time
(`tailscale switch`). To reach every tailnet from the terminal without
switching, `bin/tailnet` runs **one always-on userspace `tailscaled` per
tailnet** ("tailnet profile" `<name>`): unprivileged
(`--tun=userspace-networking`, no root, no TUN), a per-user launchd agent
(`local.tailnet.<name>`; systemd `--user` unit on Linux; `tailnet run` in the
foreground where neither exists), state in `~/.local/state/tailnet/<name>/`,
and a local SOCKS5+HTTP proxy on `127.0.0.1:<port>` (recorded in that dir).
The Homebrew `tailscale` **formula** provides that tailscaled (the app bundle
has none) — never `brew services start tailscale`: without root it
crash-loops. The daemon for the tailnet the app is currently on just idles;
the others' proxies are what make their tailnets reachable. Facts that shape
this: the userspace proxy resolves MagicDNS itself and dials non-tailnet
destinations through the OS stack; SOCKS5 and HTTP may share one port; the
proxies are unauthenticated on loopback (fine on a single-user machine); each
daemon is its own node in its tailnet (`up --hostname=<host>-<name>`, else it
becomes `<host>-1`) with its own key expiry — `tailnet up <name>` re-auths.

The shell side mirrors `claude()`/`wrangler()`: `tailnet.profile.<account>`
in machine-local git config (overlay-supplied) maps the cwd's account to a
tailnet, `tailnet.<owner>/<repo>.profile` pins one repo, `TAILNET=<name>`
overrides. But the cwd only sets a **preference**: for a target host,
`ssh`/`scp`/`sftp`/`curl` wrappers in `.functions` ask each installed daemon
(cwd's tailnet first) whether the host is one of its nodes — matched against
`status --json` DNSNames/IPs, never a DNS lookup or `tailscale ip`, and a
daemon whose socket file is missing is skipped without a call (the CLI stalls
2 s on a missing socket) — and act only on a hit on a tailnet the app is
**not** on: ssh gets `-o ProxyCommand="~/bin/tailnet nc <name> %h %p"`
(absolute path — ssh runs it via `$SHELL -c` without `~/bin` on PATH; `%h`
is ssh's post-config HostName and stays unresolved, so MagicDNS resolves in
that daemon), curl gets `--proxy socks5h://localhost:<port>`. A node of the
app's own tailnet, or of no tailnet, runs untouched; so do hosts whose shape
can't be a node (public FQDNs, non-CGNAT IPs, localhost — zero calls),
anything with a ProxyJump/ProxyCommand already (config or `-J`/`-o`: a
command-line `-o ProxyCommand` would silently override a configured
ProxyJump), and curl with `-x`/`--noproxy`/proxy variables set. The
destination comes from `ssh -G` (ssh's own parsing) — scp/sftp extract the
`[user@]host:` operand first — and for curl the first URL / bare host
argument. `TAILNET` forces its tailnet with the node check skipped (subnet
routes the daemons can't vouch for); `tailnet-as <name> <cmd…>` does that and
exports `ALL_PROXY`/`HTTP(S)_PROXY`/`NO_PROXY` so any proxy-aware tool
follows. `tailnet-doctor [host]` traces all of it. Without the script or an
installed tailnet the wrappers are plain passthroughs. Order and failure
mode are deliberate: the wrappers decide by host **shape first** (a pure
string check, before the state dir or any daemon is looked at), and the
whole routing decision runs in a subshell (`tailnet_exec` →
`tailnet_for_cmd`), so a broken helper leaves the command running direct —
routing is an optimization, the command is the point. Every tailnet
function starts with `emulate -L zsh` because not every shell sourcing
`.functions` has the interactive options: Claude Code's Bash tool runs zsh
with `NO_BARE_GLOB_QUAL`, where a bare `(N)` qualifier is literal and the
glob in `tailnet_active` aborted every wrapped curl/ssh in the session,
localhost included, the day the first tailnet was installed.

Tailnet auth URLs — the `up` login link, Tailscale SSH's check-mode link —
are identical for every tailnet, so no URL rule can route them to the right
browser profile; the tooling that printed them knows, and opens them itself
via `bin/open-as <alias> <url>`: it appends an opaque token from
machine-local git config (`browser.tag.<alias>`, overlay-supplied; tailnet
names double as aliases) as a `#fragment` — never sent to the server, and
random so the page's scripts learn nothing — and the Finicky overlay
fragments map token → profile (`tagged(<token>)` in lib.ts,
host-independent: any tool with an account-ambiguous auth URL can use the
same trick). `tailnet up` and the wrapped ssh/scp/sftp watch their own
output for the URL (stderr streams byte-for-byte through `tee` into a copy
a disowned watcher greps, so prompts and progress meters survive) and fail
open: no open-as, no pin, or no tempdir and the URL simply stays a printed
line, the command untouched.

Remote directories mount on demand with `tailnet mount <name>` (`umount`,
`mounts`; the spec — tailnet, host, path, optional user/mountpoint/
rclone-args — is overlay-supplied machine-local git config,
`tailnet-mount.<name>.*`). rclone speaks sftp through the tailnet via an
external `ssh -o ProxyCommand=… tailnet nc …` — so ssh config, known_hosts,
and the 1Password agent all apply; with `--sftp-ssh` set rclone ignores its
internal host/user config, the destination lives in the ssh command — and
serves it to the kernel as **loopback NFS** on macOS (`rclone nfsmount`: no
kext, no root; the kernel only talks to localhost, so a tailnet blip is an
IO error + retry, never a wedged mount) or a FUSE mount on Linux
(`fusermount3`, package `fuse3`). The default mountpoint is inside the
chmod-700 state tree (`~/.local/state/tailnet/mnt/<name>`) on purpose; a
fixed absolute path (a tool's hardcoded `/dir`) is a one-time
`/etc/synthetic.conf` symlink, done by hand — see
`docs/private-overlays.md`. Unlike the fail-open wrappers these commands
fail loud with remediation: the mount is the point. `umount` needs only the
mountpoint (a de-configured mount still tears down), and detaching the
kernel mount is what makes the rclone daemon exit. `tailnet-doctor` adds
`rclone:`/`mounts:` lines only when a `tailnet-mount.*` key exists, so
machines without the overlay stay noise-free.

Once per machine: `tailnet install <name> && tailnet up <name>` per tailnet
(browser login as that account; approve the device in its admin console),
overlays supply the mappings. Tests: `tests/tailnet.bats` (stub
tailscale/launchctl/ssh/curl/rclone/mount; state in a short `/tmp` dir
because a unix socket path is capped at ~104 bytes on macOS).

### Link routing (Finicky → Chrome profiles)

macOS hands every external link to the default browser, and Chrome opens
it in whichever profile's window was active last — wrong half the time on
a machine with personal, work, and per-company profiles. **Finicky**
(`cask 'finicky'`, set as the default browser once from its own window) is
the router: it launches Chrome with `--profile-directory=` per link, picking
the profile by URL (or by which app the link was clicked in).

The config is split the same way as everything else here — machinery public,
identity in overlays:

| Target | Source | Role |
| --- | --- | --- |
| `~/.finicky.ts` | public `dot_finicky.ts` | composer: imports the two fragments, work rules first, options |
| `~/.config/finicky/lib.ts` | public | helpers: `chrome(profileName)`, `hosts(...)`, `githubOwners(...)`, `openedBy(bundleIds...)`, `any(...)`, `tagged(token)` (opaque `#token` from `bin/open-as` → profile; see the tailnet section) |
| `~/.config/finicky/personal.ts` | personal overlay (public deploys a `create_` stub) | personal/per-company rules **and the `defaultBrowser`** for unmatched links |
| `~/.config/finicky/work.ts` | work overlay (public deploys a `create_` stub) | work domains, work GitHub orgs, work Cloudflare account |

Fragments export `default` (handler array), optional `rewrite`, and personal
also `defaultBrowser`. Chrome profiles are addressed by **display name**
(Finicky resolves it via Chrome's `Local State`). Facts learned from the
source that shape this: the config must be `.ts` (Finicky bundles with
esbuild; a `.js` config is babel-copied elsewhere first and loses relative
imports); Finicky caches the bundle keyed on the entry file's mtime, so a
fragment edit needs `touch ~/.finicky.ts` — `dotfiles()` does that after
applying overlays. Debug with `~/Library/Logs/Finicky/` (`logRequests` is
on) or `Finicky --dry-run` + `open -a Finicky <url>`. macOS-only: ignored
elsewhere via `.chezmoiignore`.

Tests: `tests/finicky.bats` loads the real composer + lib under Node (≥ 22.6
runs `.ts` natively — keep `lib.ts` to type annotations only) with fixture
fragments and asserts routing (helper semantics, work-before-personal
order, default fallthrough, stubs-only config); `tests/chezmoi.bats` covers
deployment/ignore/`create_` semantics. CI installs Node 22 for this; the
test skips where Node is too old.

### Espanso (text expansion)

`cask 'espanso'` — a text expander whose entire configuration, snippets
included, is plain YAML in one directory. That property is the reason it was
chosen over Raycast/TextExpander/Keyboard Maestro: the others keep snippets in
an internal store that git can only ever hold a *dump* of (Raycast's snippet
import is additive and duplicate-skipping, so a repo can never be
authoritative; Keyboard Maestro's macro archive is a plist that diffs badly).
With espanso the tracked files *are* the files it reads.

So the config directory is **its own private repo**, cloned to `~/code/espanso`
and symlinked into place:

    ln -s ~/code/espanso "$HOME/Library/Application Support/espanso"

It is deliberately not a chezmoi target and not part of any overlay. Espanso
writes into its own config dir (it puts installed packages in
`$CONFIG/match/packages`), which fights chezmoi's ownership model and would
show up as permanent drift; and snippets accumulate project and client names
over time, which this public repo must never carry. Nothing here depends on
that repo existing — a machine without it just has no snippets.

Facts that shape the setup:

- **The symlink must exist before espanso's first launch.** Otherwise espanso
  creates its own config directory and you have to delete it before linking.
- **`backend: Clipboard` is load-bearing**, not a preference. The default
  keystroke backend delivers a newline as a literal Return keypress; in a
  browser chat UI Return *submits the form*, so a multi-line prompt snippet
  fires off as several half-written messages. The same keystroke path is
  behind espanso's long-standing auto-indent mangling in Vim/Neovim (issues
  #760, #962). Pasting hands the whole body over in one shot.
- **macOS config lives under `~/Library/Application Support/espanso`**, not
  `~/.config/espanso`. `espanso path` prints all three directories (config,
  packages, runtime) and is the fastest way to confirm what it is actually
  reading.
- **Two bracket syntaxes, easily confused.** `[[field]]` works *only* inside a
  form; variables substituted into a `replace:` string use `{{var}}`. A form's
  fields are addressable afterwards as `{{form1.<field>}}` — which is what
  `espanso match list` shows, and that command parses the config without the
  daemon running, so it doubles as a syntax check.
- **Per-app scoping** uses `filter_exec` on macOS. `filter_title` matches the
  app *identifier* there rather than the window title, and `filter_class` is
  effectively Windows/Linux-only.
- **Upgrades can silently break triggers.** Espanso's code-signing certificate
  changed maintainers while the bundle id stayed `com.federicoterzi.espanso`,
  which confuses macOS into keeping a stale TCC entry: the daemon runs, the
  search bar works, and no trigger fires. Fix is
  `sudo tccutil reset Accessibility com.federicoterzi.espanso` (sometimes
  Input Monitoring too), then re-grant. Fresh installs of 2.3+ are unaffected.

Not in Ubuntu's repos; on Linux it is a `.deb` from the project's GitHub
releases, so `packages-apt.txt` only carries a note.

### iTerm2, and the skill that records what it can do

iTerm2 updates itself through Sparkle without asking, so anything written
about it decays on its own and the only symptom is confident, wrong advice.
The `.claude/skills/iterm2/` skill exists to make that decay visible instead:
it is a **version-stamped, machine-checkable record** of one release —
AppleScript dictionary, Python API and its cookie/socket auth model, Dynamic
Profiles, shell integration and the `it2*` utilities, triggers, badges, status
bar, hotkey windows, `tmux -CC`, Automatic Profile Switching, Smart Selection
and Semantic History, the Toolbelt, SSH Integration and `ssh://` URLs,
preferences and startup behaviour, the AI plugin and its permission model, and
how the project ships releases. Every claim was read off the installed bundle
rather than recalled, and the mechanically checkable part of it — sdef
commands, Dynamic Profile / APS / Smart Selection / preference key names, the
bundled utilities, updater `Info.plist` keys — is one fact per line in
`scripts/manifest.txt`. `scripts/verify.sh` re-reads all of it from the bundle
and exits non-zero on any drift.

One entry in that manifest is a different shape from the rest and is the most
useful: `tipcount`. iTerm2 ships `Contents/Resources/utilities/it2tip`, a
Python script holding the app's own feature tour — 123 entries in 3.6.11, each
with a menu path, documented nowhere on iterm2.com. Every other check asks
whether a name still *exists*, so they are all blind to a feature being
**added**; counting that list is the one tripwire that is not. When it trips,
run `it2tip` and read what is new.

Three consequences shape the code here:

- **The version is read off the bundle, never from Homebrew.** `auto_updates
  true` on the cask means brew installs once and Sparkle takes over; on this
  machine the Caskroom says 3.6.3 while the app says 3.6.11. The house rule
  (`defaults read /Applications/iTerm.app/Contents/Info
  CFBundleShortVersionString` — read the version, never execute the thing) is
  not a stylistic preference here, it is the only correct answer.
- **The stamp is duplicated on purpose.** It lives in `manifest.txt`, in
  `SKILL.md`, and as a `local stamp=` in `iterm2-doctor` — because the doctor
  is deployed to machines with no copy of the skill and has to carry its own.
  `tests/iterm2-doctor.bats` extracts all three from the source and fails if
  they disagree, so a half-done refresh cannot land.
- **`iterm2-doctor` is in the `doctor` aggregator** even though it is not
  per-repo routing like the others: it is the terminal all of them run inside,
  and a stale skill is exactly the silent change `doctor` exists to surface.
  It reports the bundle and version, the stamp comparison, the Caskroom
  channel, the plugin bundles, the prefs/API/startup keys, and **counts, never
  names**, of dynamic profiles and AutoLaunch scripts — those are usually
  named after a host or a client.

Two facts from that research matter to this repo directly. `PrefsCustomFolder`
points at this clone, so `com.googlecode.iterm2.plist` is tracked here — safe
only because the AI provider key goes to the **Keychain**, not the plist (the
binary says so, and `verify.sh` checks that sentence is still there), and
because keys prefixed `NoSync*` are excluded from the custom folder (verified:
26 in the live domain, 0 in the tracked copy). And none of
`LoadPrefsFromCustomFolder`, `PrefsCustomFolder`, `NoSync*` or
`EnableAPIServer` is documented anywhere on iterm2.com — they are real keys,
reverse-engineered, and free to change in a point release. Where the docs and
the binary disagree the skill records both and trusts the binary; that
disagreement is half of what makes it worth keeping.

Tests: `tests/iterm2-doctor.bats` (fake `iTerm.app` bundles and a stub
`defaults`; nothing ever touches the real iTerm2 or opens a dialog).

### Machine-local secrets (~/.extra)

`~/.extra` is rendered by chezmoi from `private_dot_extra.tmpl` (mode 0600)
**in the private overlay**, using chezmoi's built-in 1Password template
functions — secret *values* come from the 1Password CLI at apply time, only
references live in that repo:

    export SOME_SERVICE_TOKEN={{ onepasswordRead "op://Private/Some Service/token" | quote }}

Never export a token that one of the per-repo wrappers routes
(`GH_TOKEN`/`GITHUB_TOKEN`, `CLOUDFLARE_API_TOKEN`, `ANTHROPIC_API_KEY`,
`CLAUDE_CONFIG_DIR`, …) from `~/.extra`: it is sourced by every shell, so
such a token overrides the account routing everywhere. Project tokens belong
in that project's `op run --env-file`. The overlay's `tests/extra-tmpl.bats`
enforces this too, and `onepassword-doctor`'s `extra:` line reports a routed
name found in the deployed file (name only — never a value).

Get a reference path from the 1Password app: right-click a field →
"Copy Secret Reference", or `op item get <item> --format json` and read the
`reference` key off the field.

CAUTION: chezmoi parses that template as a Go template, comments included —
a stray `{{` anywhere breaks rendering. That's why these instructions live
here and not in the template itself. The overlay's `tests/extra-tmpl.bats`
enforces the invariant. The same collision is why a chezmoi-managed file can
never use `op inject` syntax: `op inject`'s placeholder is a bare secret
reference wrapped in `{{ }}`, which chezmoi reads as a template action.
`onepasswordRead` is the chezmoi-side equivalent — don't convert between
them. (Spelling that placeholder out here would itself trip the rendered-home
leak guard in `tests/chezmoi.bats`, since this file deploys to `~/CLAUDE.md`;
the skill has the literal form.)
