# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Personal dotfiles for macOS/zsh, including shell configuration, macOS system defaults, and a Homebrew bundle. The primary shell is **zsh** (`.bash_profile` auto-upgrades any bash session to zsh).

## Installation

```bash
# Clone and apply dotfiles to $HOME
source bootstrap.sh

# Apply macOS system preferences (requires sudo)
# Optionally set a machine name first:
COMPUTER_NAME="My-Mac" ./.macos

# Install Homebrew packages
brew bundle
```

## Running tests

Tests use [bats-core](https://github.com/bats-core/bats-core). Install it first (`brew install bats-core`), then:

```bash
# Run all tests
bats tests

# Run a single test file
bats tests/macos.bats
bats tests/bootstrap.bats
```

CI runs tests on both `ubuntu-latest` and `macos-latest` via `.github/workflows/tests.yml`.

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

- **`bootstrap.sh`** — uses `rsync` to copy repo files to `$HOME`; excludes `bootstrap.sh`, `README.md`, `Brewfile`, `LICENSE-MIT.txt`
- **`.macos`** — macOS `defaults write` settings; reads `$COMPUTER_NAME` env var for machine-specific naming
- **`Brewfile`** — Homebrew formulae, casks, and Mac App Store apps
- **`bin/`** — personal scripts added to `$PATH`
- **`init/`** — one-time setup scripts
- **`theme/`** — Base16 Eighties color themes (darkened bg `#1a1a1a`) for iTerm2, Terminal.app, and Alfred; VSCode uses the `bsides.Theme-Base16-Eighties` extension installed by `.macos`. Terminal apps (bat, delta, fzf, k9s, vim) use `base16-256`/`base16-eighties` and inherit the iTerm palette.

### Commit signing

Commits are signed with **SSH-format signatures via 1Password**, not GPG. The
repo sets `commit.gpgsign = true` (format-agnostic); the actual mechanism lives
in untracked machine-local files:

- `~/.gitconfig.local` / `~/.gitconfig-ica` set `gpg.format = ssh`,
  `gpg.ssh.program = .../op-ssh-sign`, and `user.signingkey = ~/.ssh/*.pub`.
- `~/.ssh/config` points `IdentityAgent` at the 1Password agent socket; the
  private keys live in 1Password and never touch disk. The `.pub` files are
  just selectors.

On a machine without 1Password (e.g. a remote Linux box), `op-ssh-sign` doesn't
exist and the agent socket is absent. Either forward your local 1Password SSH
agent over the connection, or disable signing there with
`git config commit.gpgsign false`. There is **no GPG keypair** in this setup
despite the `gpgsign` name.

### Machine-local customization

Add `~/.extra` (not committed) for per-machine overrides. Add `~/.path` for per-machine PATH entries. The `.macos` script skips the computer name block if `$COMPUTER_NAME` is unset.
