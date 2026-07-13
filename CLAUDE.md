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

- **`bootstrap.sh`** — uses `rsync` to copy repo files to `$HOME`; excludes `bootstrap.sh`, `README.md`, `Brewfile`, `LICENSE-MIT.txt`
- **`.macos`** — macOS `defaults write` settings; reads `$COMPUTER_NAME` env var for machine-specific naming
- **`Brewfile`** — Homebrew formulae, casks, and Mac App Store apps
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

### Machine-local customization

Add `~/.extra` (not committed) for per-machine overrides. Add `~/.path` for per-machine PATH entries. The `.macos` script skips the computer name block if `$COMPUTER_NAME` is unset.

### Machine-local secrets (~/.extra)

`~/.extra` is rendered from the tracked `.extra.tmpl` by 1Password's
`op inject`. bootstrap.sh runs it automatically when `~/.extra` is missing;
re-render manually with `op inject -i .extra.tmpl -o ~/.extra -f`. The
template stores only secret *references*, never values:

    export GITHUB_TOKEN="{{ op://Private/GitHub PAT/token }}"

Get a reference path from the 1Password app: right-click a field →
"Copy Secret Reference".

CAUTION: `op inject` parses the whole template, comments included, and
errors on any curly-brace pair or bare `op://` text that isn't a real
brace-wrapped reference. That's why these instructions live here and not in
the template itself. `tests/extra-tmpl.bats` enforces the invariant.
