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

### Claude Code session launcher (iTerm2, after a restart)

`bin/claude-session` puts the day's sessions back on screen after a reboot:
**one iTerm2 window per Claude Code profile**, one tab per project, each tab
sitting in the project with `claude` already running. Which projects those are
is identity-bearing, so — like every other router here — the machinery is
public and the list is machine-local git config from an overlay:

```gitconfig
[claude-session "<name>"]          # <name>: letters, digits, - and _
	dir      = ~/code/<project>      # required
	window   = <label>               # optional: which window it shares
	profile  = <claude profile>      # optional: forces `claude-as <profile>`
	args     = --continue            # optional: appended to the claude call
	title    = <tab title>           # optional (default: <name>); a hint —
	                                 # iTerm2 relabels tabs itself
	disabled = true                  # optional: keep the entry, skip it
[claude-session]
	delay    = 3                     # optional: seconds `at-login` settles
```

A session with no `window` key lands in the window of the profile its
*directory* resolves to, asked of `claude_profile_dir` in `.functions` — the
very helper `claude()` obeys — so personal projects share one window and work
projects another **without either repo stating an account**. A directory
nothing resolves (no origin, no pin, no `~/.functions`) gets a window of its
own: an extra window beats two accounts in one. Tabs open in config order.

Three decisions carry the design:

- The tab runs the **login shell and is typed at** (iTerm2's `write text`),
  not handed a command to exec. `create tab … command "…"` does not run an
  interactive shell, so `.functions` is never sourced, `claude` is the bare
  binary, and the account routing silently disappears — every tab would come
  up as whoever owns `~/.claude`. Typing `cd <dir> && claude` is what makes
  the wrapper (and `CLAUDE_CONFIG_DIR`) apply. `profile` is the escape hatch
  for a directory whose origin resolves to nothing.
- The trigger is a **per-user launchd agent** (`local.claude-session`,
  `RunAtLoad`) with `LimitLoadToSessionType = Aqua` **and nothing else** — the
  job opens windows in a GUI login session, and in an ssh or LoginWindow
  context it could only fail (with a TCC prompt nobody is there to answer).
  `RunAtLoad` fires while the session is still assembling, so `at-login` waits
  for the Dock, settles for `claude-session.delay`, launches iTerm2, and
  retries the AppleScript — early is not the same as ready. macOS asks once
  per client binary whether it may control iTerm2; run `claude-session start`
  by hand after installing so that prompt arrives while you are looking at it,
  and expect a second one at the first login (the agent is a different
  client). Denied, it shows up as `-1743` and the launcher says where to
  grant it.
- An iTerm2 **Window Arrangement** was the obvious alternative and is the
  wrong tool: it restores a shell in a directory, not a running `claude`; it
  lives in `com.googlecode.iterm2.plist`, which this repo deploys *publicly*,
  so real project paths would leak on the next capture; and it is edited by
  clicking, not by an overlay on a fresh machine. (For pure layout with no
  `claude` in it, the arrangement is still less work — nothing here stops you
  using both.)

Re-running is safe: each tab is tagged with an iTerm2 user variable
(`user.claudeSession`), and `start` skips a session already on screen, adding
what is missing to that group's existing window. Reading the tag needs care —
an unset iTerm2 variable answers `missing value`, and coercing *that* to text
yields the string "missing value", which would make every untagged session
look tagged.

Commands mirror `tailnet`'s shape: `list`, `plan` (the decision table,
tab-separated), `script` (the AppleScript `start` would run — a dry run),
`start [name…]`, `at-login`, `install`, `uninstall`, `status`, `logs`, `dir`.
`list`/`plan`/`script` are pure text and work anywhere; the acting commands
refuse off macOS, and `.chezmoiignore` does not deploy the script there.
`claude-session-doctor` reports the launcher, the agent, the configured
sessions with which are open, and which window *this* repo would join;
`doctor` includes it. Once per machine: `claude-session install &&
claude-session start`. Tests: `tests/claude-session.bats` (stub
osascript/open/launchctl/ps; fixture project and window names only).

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
  cask/native path segment). `doctor` runs all seven (git, gh, claude,
  claude-session, wrangler, hermes, tailnet). Every doctor also opens with a `defined:` line — are
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

Once per machine: `tailnet install <name> && tailnet up <name>` per tailnet
(browser login as that account; approve the device in its admin console),
overlays supply the mappings. Tests: `tests/tailnet.bats` (stub
tailscale/launchctl/ssh/curl; state in a short `/tmp` dir because a unix
socket path is capped at ~104 bytes on macOS).

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
enforces this too.

Get a reference path from the 1Password app: right-click a field →
"Copy Secret Reference".

CAUTION: chezmoi parses that template as a Go template, comments included —
a stray `{{` anywhere breaks rendering. That's why these instructions live
here and not in the template itself. The overlay's `tests/extra-tmpl.bats`
enforces the invariant.
