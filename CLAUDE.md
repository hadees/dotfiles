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
  cask/native path segment). `doctor` runs all four.

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
| `~/.config/finicky/lib.ts` | public | helpers: `chrome(profileName)`, `hosts(...)`, `githubOwners(...)`, `openedBy(bundleIds...)`, `any(...)` |
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
