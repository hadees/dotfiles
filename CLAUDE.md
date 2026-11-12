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
`~/code/dotfiles` (when that clone exists) so the clone is the source of truth.

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
bats tests/chezmoi.bats
```

`bats` must run under **bash ≥ 4**: macOS's `/bin/bash` 3.2 does not fail a
test on a failing `[[ ]]` unless it is the test's last command, so mid-test
assertions are silently skipped. `tests/shell.bats` refuses to run under it.
In a zsh from these dotfiles a bare `bats tests` is enough: `.exports` puts
Homebrew's `bin` ahead of the system dirs (so its bash 5 wins), and the
version-manager shims `dot_zshrc` prepends afterwards (asdf, pyenv, …)
shadow no bash. CI's macOS job adds Homebrew's `bin` itself; elsewhere use
`PATH="$(brew --prefix)/bin:$PATH" bats tests`. A test that fakes `HOME` and
needs `python3` must pin the real interpreter in `setup()` before it does,
because an asdf shim cannot resolve a version under a fake `HOME` and exits
126.

To *run* the dotfiles rather than test them — render a machine class into a
sandbox `$HOME`, drive the resulting zsh (prompt, wrappers, doctors) one-shot
or under tmux, stack overlays, or see what a real apply would change — use
the `/run-dotfiles` skill (`.claude/skills/run-dotfiles/driver.sh`); each
overlay carries a matching `run-<overlay>` skill that stacks itself on it.
Skill directories are dot-prefixed, so chezmoi never deploys them.

CI (`.github/workflows/tests.yml`) runs the suite on `ubuntu-latest`,
`macos-latest`, Rocky Linux 9 (container), and WSL Ubuntu (windows runner), plus a container
job that runs the one-shot install end to end.
A separate macOS job, `test-macos-apply`, executes `.macos` for real and asserts settings
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
- **`.chezmoiignore`** — target paths chezmoi must not manage (repo-level files everywhere, `CLAUDE.md` and `com.googlecode.iterm2.plist` among them; macOS GUI config off-mac; identity/secrets on `ephemeral`)
- **`bootstrap.sh`** — deprecated wrapper around `chezmoi init --source . --apply`
- **`docs/watchlist.md`** — tools evaluated and parked as "not yet", each with what would make it worth another look; check it before re-evaluating something, and add to it when an evaluation ends in "not yet"
- **`.macos`** — macOS `defaults write` settings; reads `$COMPUTER_NAME` env var for machine-specific naming; also Touch ID for sudo and a global sudo timestamp (the `.macos` comments say why)
- **`Brewfile`** — Homebrew formulae, casks, and Mac App Store apps (macOS only; `.chezmoiscripts/darwin/` runs `brew bundle` when it changes)
- **`packages-apt.txt`** — Debian/Ubuntu/WSL package list (`.chezmoiscripts/linux/` installs it when it changes; skips gracefully without apt or sudo)
- **`packages-apt-wsl.txt`** — WSL-only additions, installed on top of the shared list when the machine class is `wsl`
- **`bin/`** — personal scripts added to `$PATH`
- **Claude Code statusline** — lives in a private skills marketplace repo (skill `claude-statusline`), not here. Install once per machine with `/claude-statusline`; the plugin's session-start hook keeps the installed copies in `~/.claude` current after that. `~/.claude/settings.json` comes from the work overlay, so on a machine without that overlay there is no statusLine command to be dead.
- **`init/`** — one-time setup scripts
- **`theme/`** — Base16 Eighties color themes (darkened bg `#1a1a1a`) for iTerm2, Terminal.app, and Alfred; VSCode uses the `bsides.Theme-Base16-Eighties` extension installed by `.macos`. Terminal apps (bat, delta, fzf, k9s, vim) use `base16-256`/`base16-eighties` and inherit the iTerm palette.

`com.googlecode.iterm2.plist` is tracked because iTerm2's custom prefs
folder is this clone. iTerm2 rewrites it at every quit, so it is usually
modified in `git status`. That is iTerm2 saving. Never stage it with other
work.

`.claude/agents/public-clone-advocate.md` reviews a change to the public
source from the position of a stranger's clone; its description says when.

### Commit and push gates

`dot_gitconfig` sets `core.hooksPath` to the deployed `dot_git-hooks/`, so
these run in every repo on the machine:

- **pre-commit** refuses a commit whose author or committer email is not one
  of `identity.<account>.email` for the account the origin's owner is pinned
  to, or of `identity.<owner>/<repo>.email` when that per-repo pin exists. A
  public-only clone has no pins and no opinion. `GIT_IDENTITY_CHECK=0`
  bypasses one commit.
- **pre-push** refuses a commit still marked unfinished, and a
  non-fast-forward push of a protected branch (`main` and `master` unless
  configured). `GIT_PUSH_CHECK=0` bypasses both for one push; the
  `hook.pre-push.run` chain still runs.
- **Merge** is gated on GitHub: the `main` ruleset
  (`.github/rulesets/main.json`) requires the six CI checks on a branch that
  contains main's tip, so `gh pr merge` refuses a stale or red pull request
  and `--auto` waits for it. The review a merge here needs is
  `public-clone-advocate` on the final diff; merging main into the branch
  does not void it, a new commit of the branch's own does.
- **Signing** is SSH-format through 1Password and machine-local: the
  tracked `.gitconfig` never enables it. A signature that fails is nearly
  always the app locked or an approval unanswered. Unlock, approve, retry
  the same commit. Never commit unsigned, never turn `commit.gpgsign` off,
  never set a repo-local identity or key.

`git-doctor` shows the gate's verdict and the signing state. `doctor` runs
every `*-doctor`; run the relevant one before guessing at a routing
problem.

### Package lists

CLI tools are declared per OS: `Brewfile` (macOS), `packages-apt.txt`
(Debian/Ubuntu/WSL), `packages-apt-wsl.txt` (WSL only). **When adding or
removing a tool, update every list where it is available**, under each
distro's own package name, and say so in the list file when a tool exists
on one platform only. Homebrew is not used on Linux. Both Brewfile install
paths pass `--no-upgrade`, and nothing runs `brew bundle cleanup`.

### Machine-local customization

Add `~/.extra` (from the private overlay, or hand-written) for per-machine overrides. Add `~/.path` for per-machine PATH entries. The `.macos` script skips the computer name block if `$COMPUTER_NAME` is unset.

### Private overlays

**This repo is public and must stay identity-free.** Anything that names a
person, an account, an organization, or a private repo lives in **private
chezmoi overlays** — additional chezmoi configs in `~/.config/chezmoi/*.toml`,
each pointing at its own source clone. One exception: the GitHub login that
owns this repository is public by construction (the clone URL, the install
one-liner, the Homebrew tap and the personal profile's directory name all
carry it), and the personal overlay is referred to by its slug under that
login; nothing else about a person, and nothing about a work account,
organization or repository, may appear. `docs/private-overlays.md` is the
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
| `~/.ssh/config.d/10-personal.conf` | personal | the personal GitHub alias and the key it selects |
| `~/.ssh/config.d/20-work.conf` | work | the work alias, the NAS host, the fleet hosts to forward an agent to |
| `~/.config/git/allowed_signers.d/10-personal` | personal | the personal signer address and key |
| `~/.config/git/allowed_signers.d/20-work` | work | the work signer address and key |

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
- The `gh()` wrapper, `bin/git-credential-gh-user`, and `bin/git-ssh-pinned`
  deliberately contain no account or org names: all read the
  `credential.<url>.username` pins from git config at runtime, which the
  overlays provide. **Adding a work org is a
  one-line change in the work overlay and needs no edit here.**
- Don't "helpfully" reintroduce a name, email, org, or private repo name into
  this repo's files, tests, or commit messages. The personal overlay's leak
  guard enforces this on every push — the pushed tree, ref names, commit
  messages, added lines, and author/committer identities — and its
  `tests/no-public-leak.bats` audits the whole clone the same way.

### Where the detail lives

Design notes for each tool are in `.claude/rules/<name>.md`. A rule loads
by itself when a file it covers is opened with Read or Edit. It does not
load for `grep` or `sed`, for a question that opens no file, or when this
repo is an added directory of another session. In those cases read the
rule first.

| Rule | Covers |
| --- | --- |
| `git-hooks` | the identity, branch and push gates, the `hook.<name>.run` chain |
| `git-identity` | signing setup, `bin/git-ssh-pinned`, credential routing |
| `merge-gate` | the `main` ruleset, how it is applied and changed |
| `onepassword` | the three 1Password channels, `onepassword-doctor`, the skill's `VERSIONS` |
| `packages` | Brewfile and apt lists, the install scripts, `update()` |
| `composed-identity-files` | ssh config fragments, `allowed_signers`, first-wins against last-wins |
| `claude-profiles` | `claude()`, per-repo pins, the second-session question, agent stubs |
| `browser-routing` | `open-as`, `chrome-pairing`, the iTerm2 browser tab, Finicky |
| `denyguard` | the Bash deny hook, what it cannot see, why it fails closed |
| `loginguard` | the org pin per profile, the prompt hook, the removal after a wrong login, why it fails closed |
| `worktabs` | the iTerm2 tab launcher, `workspace.*` config, the Alfred workflow |
| `claude-peer` | Workgroup peers, named slot worktrees, claims, the Hermes peer, overlay peers |
| `claude-peer-handoff` | Lead and its name, `start --handoff`, `log idle`, the stop mark |
| `claude-tab` | `claude-tab` list, focus, save, restore; `tabname` |
| `branchname` | the branch label a prompt or status line shows, the detached-slot base record |
| `postbox` | cross-profile session mail, its hooks, the courier, the roll-call |
| `remote-mcp` | bearer-token MCP servers, the tailnet forwarder |
| `wrangler` | Cloudflare auth profiles and bindings |
| `doctors` | what each `*-doctor` prints, the `defined:` and `binary:` lines |
| `hermes` | Hermes profiles, `hermes.worktree`, `hermes_peer` |
| `tailnet` | a userspace tailscaled per tailnet, the ssh and curl wrappers, mounts |
| `routes` | the fleet routing table |
| `workset` | working sets, the profile rule, the guard hooks |
| `iterm2-skill` | the iTerm2 skill's stamp and `verify.sh`, the tracked plist |
| `cc-status-shim` | Session Status rows, seat colours, row names, terminal titles |
| `dot-functions` | what else lives in `dot_functions`, and `emulate -L zsh` |

`docs/private-overlays.md` is the overlay manual. `docs/espanso.md` covers
the text expander, whose config is a separate private repo.

### Claude Code profiles

Each account has its own config directory, selected by `CLAUDE_CONFIG_DIR`.
This repo deploys the default profile (`dot_claude/`), the personal one
(`private_dot_claude-*/`) and the memory and agent definitions both import
(`dot_claude-shared/`). No profile's `settings.json` lives here; each
comes from its overlay. `claude()` picks the directory: `CLAUDE_PROFILE`,
then `claude.<owner>/<repo>.profile`, then `claude.profile.<account>`,
then `claude.profile.default`, then bare `claude`.

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
them. (Spelling that placeholder out here would add a second secret reference to
this file, and `tests/no-secrets.bats` pins the count; the skill has the
literal form.)
