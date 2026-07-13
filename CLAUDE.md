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
chezmoi diff && chezmoi apply    # `dotfiles` is aliased to `chezmoi apply`

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
- **`~/.extra`** — machine-local overrides and secrets like git credentials (not in repo)
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
- **Claude Code statusline** — lives in `work-org/private-skills` (skill `claude-statusline`), not here. Install once per machine with `/claude-statusline`; the plugin's session-start hook keeps the installed copies in `~/.claude` current after that. On a fresh machine, `.claude/settings.json`'s statusLine command is harmlessly dead until that one-time install.
- **`init/`** — one-time setup scripts
- **`theme/`** — Base16 Eighties color themes (darkened bg `#1a1a1a`) for iTerm2, Terminal.app, and Alfred; VSCode uses the `bsides.Theme-Base16-Eighties` extension installed by `.macos`. Terminal apps (bat, delta, fzf, k9s, vim) use `base16-256`/`base16-eighties` and inherit the iTerm palette.

### Commit signing

Commits are signed with **SSH-format signatures via 1Password**, not GPG.
Signing is entirely machine-local: the tracked `.gitconfig` does NOT enable
it, so a fresh machine defaults to unsigned commits instead of failing on a
missing signer. Each machine opts in via untracked files:

- `~/.gitconfig.local` / `~/.gitconfig-work` set `commit.gpgsign = true`,
  `gpg.format = ssh`, `gpg.ssh.program = .../op-ssh-sign`, and
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

Add `~/.extra` (not committed) for per-machine overrides. Add `~/.path` for per-machine PATH entries. The `.macos` script skips the computer name block if `$COMPUTER_NAME` is unset.

### Machine-local secrets (~/.extra)

`~/.extra` is rendered by chezmoi from `private_dot_extra.tmpl` (mode 0600)
on every `chezmoi apply`, using chezmoi's built-in 1Password template
functions — secret *values* come from the 1Password CLI at apply time, only
references live in the repo:

    export GITHUB_TOKEN={{ onepasswordRead "op://Private/GitHub PAT/token" | quote }}

Get a reference path from the 1Password app: right-click a field →
"Copy Secret Reference". The `ephemeral` machine class never deploys this
file (see `.chezmoiignore`).

CAUTION: chezmoi parses the template as a Go template, comments included —
a stray `{{` anywhere breaks rendering. That's why these instructions live
here and not in the template itself. `tests/extra-tmpl.bats` enforces the
invariant.
