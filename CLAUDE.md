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
- **`.chezmoiignore`** — target paths chezmoi must not manage (repo-level files everywhere, `CLAUDE.md` and `com.googlecode.iterm2.plist` among them; macOS GUI config off-mac; identity/secrets on `ephemeral`)
- **`bootstrap.sh`** — deprecated wrapper around `chezmoi init --source . --apply`
- **`docs/watchlist.md`** — tools evaluated and parked as "not yet", each with what would make it worth another look; check it before re-evaluating something, and add to it when an evaluation ends in "not yet"
- **`.macos`** — macOS `defaults write` settings; reads `$COMPUTER_NAME` env var for machine-specific naming; also enables Touch ID for sudo (via `/etc/pam.d/sudo_local`, Apple's update-proof hook) and a global sudo timestamp (`/etc/sudoers.d/timestamp`, `visudo`-checked before install, mode 0440), because a per-process cache plus Touch ID means one prompt per step for anything that runs sudo from fresh processes; the 60-minute timeout is a preference, overridable with `$SUDO_TIMESTAMP_TIMEOUT`
- **`Brewfile`** — Homebrew formulae, casks, and Mac App Store apps (macOS only; `.chezmoiscripts/darwin/` runs `brew bundle` when it changes)
- **`packages-apt.txt`** — Debian/Ubuntu/WSL package list (`.chezmoiscripts/linux/` installs it when it changes; skips gracefully without apt or sudo)
- **`packages-apt-wsl.txt`** — WSL-only additions, installed on top of the shared list when the machine class is `wsl`
- **`bin/`** — personal scripts added to `$PATH`
- **Claude Code statusline** — lives in a private skills marketplace repo (skill `claude-statusline`), not here. Install once per machine with `/claude-statusline`; the plugin's session-start hook keeps the installed copies in `~/.claude` current after that. `~/.claude/settings.json` comes from the work overlay, so on a machine without that overlay there is no statusLine command to be dead.
- **`init/`** — one-time setup scripts
- **`theme/`** — Base16 Eighties color themes (darkened bg `#1a1a1a`) for iTerm2, Terminal.app, and Alfred; VSCode uses the `bsides.Theme-Base16-Eighties` extension installed by `.macos`. Terminal apps (bat, delta, fzf, k9s, vim) use `base16-256`/`base16-eighties` and inherit the iTerm palette.

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

### Claude Code profiles

Each account has its own config directory, selected by `CLAUDE_CONFIG_DIR`.
This repo deploys the default profile (`dot_claude/`), the personal one
(`private_dot_claude-*/`) and the memory and agent definitions both import
(`dot_claude-shared/`). No profile's `settings.json` lives here; each
comes from its overlay. `claude()` picks the directory: `CLAUDE_PROFILE`,
then `claude.<owner>/<repo>.profile`, then `claude.profile.<account>`,
then `claude.profile.default`, then bare `claude`.

**Three facts survive `bin/attend`**, the tab-triage script removed in favour
of iTerm2 3.7's own per-tab Claude Code status (it painted tabs red/amber from
Claude Code hooks and dimmed them once looked at; the dim-once-seen
distinction — "new" vs "you know about this one" — is the one thing the native
panel does not reproduce). They were measured, and they cost hours to find:

- **A hook does not inherit the tab's controlling terminal.** Claude Code
  starts hook commands detached (`ps -o tty= -p $$` answers `??`), so
  `printf … > /dev/tty` from a hook reaches nothing. The `claude` process has
  the tty and is the hook's ancestor, so walking *up* the parent chain to the
  first process with one costs 2ms, where `lsof -a -p <pid> -d 0` costs ~50ms.
- **Such a walk must report the process it stopped at, not the hook's
  parent.** Keying per-tab state on `$PPID` breaks the moment anything splices
  a shell in between: that state is keyed by pid and reaped when the pid dies,
  so it would attach a tab to a shell that exits a millisecond later and take
  the tab's state with it.
- **Reading which tab has focus needs no Automation grant — but only if you
  talk to nothing but iTerm2**, which answers `frontmost` itself (Standard
  Suite, absent from the sdef but real). The obvious `tell application
  "System Events"` is a *separate* automation target with its own per-client
  grant: it prompts on a machine that never granted it and fails forever once
  denied. Asking one app both questions is 40ms against 140ms.

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
  wrangler, hermes, tailnet, worktabs, postbox, remote-mcp, workset, onepassword,
  iterm2 — the last two
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

### Hermes (agent profiles)

The Hermes harness (NousResearch/hermes-agent) keeps per-agent state in
profiles (`hermes profile create <name>` — each its own HERMES_HOME with its
own config, approval rules, memory, and .env keys). The `hermes()` wrapper
in `.functions` picks the profile the way `claude()` and `wrangler()` pick
theirs, by machine-local git config the overlays supply: an explicit
`-p`/`--profile` first; else the per-repo pin `git config hermes.profile
<name>` (set in that repo's `.git/config` — a hardened profile for one
checkout); else the cwd's account — origin owner through the credential
pins — mapped by `hermes.profile.<account>`, so every repo of an account
runs that account's profile with no per-repo change; else passthrough to
hermes' own resolution. Whatever wins is injected as `-p <name>`. The two
keys are a section key and a `[hermes "profile"]` subsection entry and
never shadow each other. Optional `git config hermes.model <model>` appends
`--model <model>` (hermes CLI args outrank config — same
profile/memory/keys, different LLM; full isolation is a profile per
purpose, whose own config/.env carry that provider).

A pin and a mapping differ in what they refuse. In a pinned repo an
explicit `-p`/`--profile` naming a *different* profile is a loud error,
never an override (same stance as claude-as/wrangler; it was never a
working override anyway — hermes honours the first `-p` and the leftover
flag dies as an argparse usage error); the pinned name itself is a no-op.
Under a mapping an explicit `-p` is simply honoured — the mapping is a
default, the pin a statement — but a mapped profile nobody has created on
this machine is refused with the `hermes profile create` line, as
`wrangler()` refuses an uncreated mapped login: hermes' sticky default would
otherwise run with another identity's keys and memory. `command hermes` is
the bypass for both. The retired `hermes.launcher` pin is refused with its
migration printed, never silently ignored. `routes` marks a pin that
outranks a mapping with `*`, like its other columns.

**`hermes.worktree = true` keeps the agent out of every live checkout.**
With it set (machine-local; a repo's own `.git/config` can say `false`),
the wrapper adds hermes' own `--worktree` flag to every invocation made
inside a git work tree, so each chat runs in a throwaway worktree,
`<repo>/.worktrees/hermes-<id>` on branch `hermes/hermes-<id>`, removed at
exit unless it holds unpushed commits (hermes prunes leftovers older than a
day). That is hermes' hardcoded layout, not this repo's
`.claude/worktrees/` convention — there is no setting for the path — and
hermes appends `.worktrees/` to the repo's `.gitignore` the first time, so
this repo carries that line already. Measured on 0.19: the flag is an
error outside a work tree, so the wrapper adds it only inside one, and
non-chat subcommands (`mcp`, `profile`, …) accept and ignore it, so the
wrapper does not have to know which subcommand it is looking at. An
explicit `-w`/`--worktree` is never doubled. `hermes-doctor` has a
`worktree:` line.

Hermes never starts a model server — it only speaks HTTP to the profile's
`model.base_url` (auto-starting the server was `ollama launch`'s only real
job). So the wrapper reads the effective profile's `config.yaml` and, only
when `model.provider` is ollama-ish AND `base_url` is loopback, probes the
port and starts `ollama serve` disowned with a bounded readiness wait when
nothing answers; a cloud profile (Anthropic/OpenAI/OpenRouter) or a
LAN/WireGuard ollama never waits on or spawns anything, and every failure
warns and falls open — hermes prints the real connection error.
`hermes-doctor` traces all of it for the cwd (pin, account, mapping, the
effective profile and its source, and its config, via the same
`hermes_profile`/`hermes_cfg_path` helpers the wrapper and `routes` call — the three cannot drift —
and, for a local-ollama profile, whether the server answers) without
starting anything; `doctor` includes it. Tests: `tests/hermes.bats` (stub
hermes/ollama/curl; fixture profile names only).

**`hermes_peer` is what the Claude Peers Hermes session runs.** It calls
`hermes` only where `hermes_profile` routes the directory (a pin or an
account mapping); anywhere else it prints one line and the pane stays a plain
shell. The gate cannot be left to the wrapper, which passes an unrouted
directory through to Hermes' own resolution — the sticky `active_profile`
would then run one account's profile in another account's repo. Isolation
follows `hermes.worktree` and is not forced, and a refusal (profile mapped but
not created, retired launcher pin) is the wrapper's own. `hermes-doctor` has a
`peer:` line saying which of the two the cwd gets.

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

### Which project routes where (`routes`)

The doctors answer "as whom, right *here*". `routes` answers it for every
project at once: **one row per repo, one column per wrapper** — account,
Claude profile, wrangler profile, tailnet, hermes profile, worktabs group,
postbox agent name, and with `-l` the commit identity and the gate's verdict
on it.

```
PROJECT           ACCOUNT   CLAUDE            WRANGLER    TAILNET      HERMES
some-project      acct-a    .claude           acct-a-cf   net-a        -
side-project      acct-a    .claude           other-cf*   net-a        -
another           acct-b    .claude-other     acct-b-cf   net-b!       some-agent

12 projects under ~/code — acct-a 7, acct-b 4, unpinned 1
* per-repo pin, outranking the account mapping   ! mapped but not created on this machine
```

Every cell is produced by calling the wrapper's **own** resolver
(`gh_account_for_cwd`, `claude_profile_dir`, `wrangler_profile`,
`tailnet_for_cwd`, `identity_expected`) in a subshell cd'd into the repo, so
a row cannot claim something the wrapper would not do — the same anti-drift
rule the doctors follow, applied across the fleet. The `tabs` column is not
re-derived either: it reads `worktabs plan`, which already decides group,
directory and usability.

Decisions worth keeping:

- **The project list is machine-local, like every other list here.** Roots
  come from arguments, else `routes.root` in git config (repeatable,
  overlay-supplied), else `~/code`. Real project paths are identity-bearing
  and never land in this repo. The walk is two deep and **stops at the first
  repo**, so a flat `~/code/<repo>` and a nested `~/code/<owner>/<repo>` both
  work while a worktree or vendored checkout inside a project is never
  listed beside it.
- **The override variables are unset in the probe.** `CLAUDE_PROFILE`,
  `WRANGLER_PROFILE` and `TAILNET` override one invocation; leaving one set
  would stamp itself down a whole column and describe none of the repos. When
  one is set the footer says so rather than silently ignoring it.
- **Two suffixes carry what only a fleet view can show.** `*` is a per-repo
  pin outranking the account mapping; `!` is *mapped but never created on
  this machine* — a Claude profile directory, wrangler profile, tailnet or
  hermes profile that a repo routes to and that does not exist here. That is
  the failure the per-repo doctors can only find one repo at a time, and the
  one that greets you as "wrong account" months later.
- **A column no project uses is dropped** and named in the footer, so a
  machine with no hermes or wrangler pins gets a narrow table instead of a
  field of dashes — the same stance as `tailnet-doctor`'s mount lines.
  `--tsv` is the exception: it keeps all eleven fields in a fixed order
  whatever is empty, so a script can index them (`worktabs plan` is the same
  idea).
- **Rows sort by account, unpinned last, and the rank is a digit** — not a
  punctuation character. `${(o)}` collates by locale, and `~` sorts *before*
  letters in en_US, which put every unpinned repo on top of the first draft.
- The gate verdict shares `identity_expected` with `git-doctor` rather than
  re-deriving the per-repo-pin-beats-account precedence, so the two cannot
  disagree about which email a repo is allowed to commit under.

`routes` is deliberately **not** in the `doctor` aggregator: `doctor` is the
per-cwd diagnosis you run inside one repo, this is the survey across all of
them. Tests: `tests/routes.bats` (sandboxed HOME, fixture repos and pins,
stub worktabs; no real account names, no installation touched).

### Working sets (`workset`) — one session over several repos

A **working set** is a named group of repos one Claude Code session works as
a single codebase: N git worktrees on one branch, opened together and torn
down together, with the session launched in the primary member's worktree
and every other member added via `--add-dir`. Like `workspace.*` (worktabs)
and `routes.root`, membership is machine-local git config the overlays
supply — the public repo names no set and no member:

```gitconfig
[workset "<name>"]                 # <name>: letters, digits, - and _
	member   = ~/code/<repo>         # repeatable, ordered; the first entry
	                                 # that survives real-path dedupe is the
	                                 # PRIMARY (its worktree is where the
	                                 # session launches; every other member's
	                                 # worktree is added with --add-dir)
	profile  = <account|alias|dir>   # optional; what CLAUDE_PROFILE accepts.
	                                 # Absent: every member must resolve to
	                                 # the same Claude profile directory
	note     = <one line>            # repeatable; printed in the session's
	                                 # opening brief — landing order, which
	                                 # artifact must stay green, that kind of
	                                 # choreography
	disabled = true                  # optional; keep the entry, skip it
```

`bin/executable_workset` owns config, worktrees and two hooks (`list`,
`members`, `plan`, `checkout`, `status`, `close`, `hook start`, `guard`,
`settings`); `workset()`, `workset_profile()` and `workset-doctor()` in
`.functions` decide which profile a set runs under and open it. `workset
open <name> <type>/<slug>` resolves the profile, creates or reuses the
worktrees, then launches `claude` — the wrapper, so `CLAUDE_CONFIG_DIR`, the
browser pin, the cache TTLs and the subagent-model default all still
apply — cd'd into the primary's worktree with
`CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` and `--add-dir` for the
rest, so every member's own `CLAUDE.md` loads too (confirmed present in the
installed CLI: seven references to that variable name in the 2.1.274
binary; documented in the memory page's "Load from additional directories"
and the permissions page's directories table — `additionalDirectories` in a
tracked `.claude/settings.json`, by contrast, loads neither `CLAUDE.md` nor
skills, and would put sibling members' real paths into whichever repo held
the file, which for a set spanning the public clone is the one thing that
file must never do). `workset profile <name>` prints the resolver's answer
alone; every other subcommand passes straight through to the script.

**The profile rule is read-only, never a pin.** A set runs under exactly one
Claude profile: either every member resolves to the same
`claude_profile_dir`, or `workset.<name>.profile` names one explicitly (same
vocabulary `CLAUDE_PROFILE` and a per-repo `claude.<owner>/<repo>.profile`
pin accept). Either way, before anything opens, every member's real path is
checked against that profile's `permissions.deny` rules via `denyguard
check` — one definition of that boundary, the same one Bash is fenced by,
never a second scanner. A member a rule covers, a heterogeneous set with no
explicit `profile`, or a rule `denyguard` cannot evaluate, all refuse (exit
3 or 4) rather than opening anything, and the remedy is always **drop the
member, or run a smaller set** — never a per-repo profile pin. The tier a
repo sits in is a sensitivity boundary the tool reads; adjusting it to make
a set homogeneous would be the tool writing the very thing it exists to
check. `workset-doctor` and the `routes` `SET` column report this same
verdict for every configured set (a set name with a trailing `!` there means
`workset_profile` refused it on this machine), so none of the three can ever
disagree.

**Isolation is a hook plus instruction, not a sandbox.** Claude Code's own
worktree-isolation checks (blocking `git -C` into the launch repo,
unparsable commands refused) apply only to a `--worktree`/`EnterWorktree`
session, and only for the repo it was launched from — a working set opens a
plain session in an ordinary `git worktree add` directory, so none of that
applies to any of its N members. What stands in for it: a `PreToolUse` hook
on `Edit|Write|NotebookEdit` (`workset guard`) refuses a write to a member's
**live checkout** while `$WORKSET` is set, naming the worktree to use
instead; a `SessionStart` hook (`workset hook start`) prints the set's
brief — every member's worktree and the live path it stands for, the
set's `note` lines, and a fixed reminder to land in member order and revert
forward, never rewrite, if a later member is rejected after an earlier one
merged. Both hooks fail open (`[ -x ~/bin/workset ] && … || true`) — they
are conveniences, not the sensitivity boundary; Bash is not parsed by either
of them, and is fenced separately by `denyguard`, wired fail-closed.

**Distinct from a `workspace.*` group.** Worktabs groups repos into windows
by however the operator sorts tabs, which is not the same axis a working
set groups by — the same trio of repos can be split across two worktabs
windows (say, one per Claude profile) while still being one working set
for a single session, and a worktabs entry can simply run `workset open
<name> <branch>` as its `command` with no code of its own. Postbox identity
is unchanged too: a set session is still just the agent named by whichever
directory it is standing in (its primary's worktree), since `postbox`
resolves a name per directory and never lists worktrees separately.

**What this does not do.** There is no cross-repo transaction — a set can
land k of its members before k+1 is rejected, and `workset status` (every
worktree's dirty/ahead/behind/remote state) is what makes that visible, not
something that prevents it. `workset close` never `--force`s a worktree
away: it refuses a dirty one, refuses one whose commits are not on the
remote, and only deletes the local branch once merged. A worktree left
behind by an `open` with no matching `close` is loud (`status`,
`workset-doctor`), never silently reclaimed. Tests: `tests/workset.bats`
(sandboxed HOME, fixture repos, the real `denyguard` — never a stub of it —
so the profile and deny checks are exercised for real; no real path, repo,
profile or account name).

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
and Semantic History, the Toolbelt, the 3.7 Session Status / Claude Code
integration / Workgroups layer, SSH Integration and `ssh://` URLs,
preferences and startup behaviour, the AI plugin and its permission model, and
how the project ships releases. Every claim was read off the installed bundle
rather than recalled, and the mechanically checkable part of it — sdef
commands, Dynamic Profile / APS / Smart Selection / preference key names, the
bundled utilities, updater `Info.plist` keys — is one fact per line in
`scripts/manifest.txt`. `scripts/verify.sh` re-reads all of it from the bundle
and exits non-zero on any drift.

Every check asks whether a name still *exists*, so the manifest is blind to a
feature being **added**. The `tipcount` entry was meant to cover that —
iTerm2 ships `Contents/Resources/utilities/it2tip`, a Python script holding
the app's own feature tour, 123 entries with menu paths — but it does not:
3.7 added Session Status, Workgroups, floating panes and a Companion app, and
the tour kept the same 123 titles. What notices an addition is **diffing the
bundle against the stamped release's** (download the old zip, never run it,
`comm` the two executables' `strings`, `diff` the `.sdef`s); `SKILL.md`'s
refresh procedure spells it out, and `verify.sh --app <old bundle>` should
then fail on exactly the facts recorded as new. The 3.6.11 → 3.7.6 refresh
also showed the release notes are silent on the AppleScript dictionary and
preference keys, both of which changed.

Three consequences shape the code here:

- **The version is read off the bundle, never from Homebrew.** `auto_updates
  true` on the cask means brew installs once and Sparkle takes over; on this
  machine the Caskroom said 3.6.3 while the app said 3.6.11, and says 3.7.3
  while the app says 3.7.6. The house rule
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
points at this clone, so `com.googlecode.iterm2.plist` is tracked here — and,
because the clone is where iTerm2 both reads and writes it, the plist is a
**repo-level file in `.chezmoiignore`, never deployed to `$HOME`**. A copy
there would be read by nothing: iTerm2 looks in the custom folder or in its
Preferences domain, and neither is `$HOME`. Worse, iTerm2 writes into that
folder — chezmoi's own source — so every prefs change would ask chezmoi to
re-deploy ~99KB that nothing opens. It is also why a modified
`com.googlecode.iterm2.plist` in `git status` is normal: that is iTerm2
saving, not you. Tracking it at all is safe only because the AI provider key
goes to the **Keychain**, not the plist (the binary says so, and
`verify.sh` checks that sentence is still there), and
because keys prefixed `NoSync*` are excluded from the custom folder (verified:
26 in the live domain, 0 in the tracked copy). And none of
`LoadPrefsFromCustomFolder`, `PrefsCustomFolder`, `NoSync*` or
`EnableAPIServer` is documented anywhere on iterm2.com — they are real keys,
reverse-engineered, and free to change in a point release. Where the docs and
the binary disagree the skill records both and trusts the binary; that
disagreement is half of what makes it worth keeping.

Tests: `tests/iterm2-doctor.bats` (fake `iTerm.app` bundles and a stub
`defaults`; nothing ever touches the real iTerm2 or opens a dialog).

**Session Status rows come from Claude Code hooks, through a shim.** iTerm2
3.7 ships `cc-status`, a binary its onboarding symlinks at
`~/.config/iterm2/cc-status` and wires into every hook event of a profile's
`settings.json`; it turns each event into a row (name, status word,
optional detail of up to three lines, dot and text colours). On Stop it
reads the payload's `background_tasks` — the session's whole task registry,
which Claude Code never ages out — and keeps the row at "working" while
that array is non-empty. Measured: a backgrounded shell blocked on stdin
kept a tab "working" for 41 hours (a foreground command that outlives its
timeout moves to the background still holding its stdin pipe, and a local
session has no time limit on background commands); a subagent that never
reported back did the same with no process behind it. No hook can kill
such a task — the payload carries no pid — so the shim only stops the row
believing it.

The shim, deployed as `~/.local/libexec/cc-status-shim/cc-status`
(`dot_local/libexec/cc-status-shim/`), takes cc-status's place in each
profile's hook command. On Stop, StopFailure and SubagentStop it tells
**quiet** tasks from **active** ones by the task's output file,
`tasks/<task_id>.output` beside the payload's `scratchpad_dir` (a symlink
to the transcript for an agent): written within `tabstatus.quiet-minutes`
(git config, default 15 — above the ten-minute foreground ceiling) is
active, older is quiet, and no file to judge by counts as active, because
wrongly active only delays the idle and wrongly idle lies. Hiding every
task would be the opposite lie — a Stop over a running background agent is
what iTerm2 3.7.2 made cc-status cover — so cc-status is fed only the
active ones. When nothing is active, one `it2 set-status` paints the row
idle in amber (`tabstatus.color.quiet`, default `#af8700`; cc-status's blue
is its "waiting" colour, and a quiet row must not look like a permission
prompt) with the quiet tasks in the detail. The count stored back is **0**
on purpose: cc-status's `Notification(idle_prompt)` handler, a minute after
Stop, reads the stored count with `get-background-tasks` and repaints
"working · N background tasks running", so storing the quiet N would revive
the lie. `it2 set-status` keeps every field it is not given — a reset
sending only the status word leaves the old dot colour — so every paint
sends the full field set, and `tabstatus idle|working|waiting` sends
cc-status's colour pair (plus a zero count for idle) unless given a colour,
which makes it the manual reset for a stuck row. The shim also adds the
`id` and `status` keys cc-status reads and 2.1.289 no longer sends, and
drops the stopping agent from its own SubagentStop.

A subagent **seat** gets its own dot and text colour while it runs
(`plan-fable #d787ff`, `unstick-fable #ff5faf`, `review-fable #af87ff`,
`work-sonnet #00afaf`, `scout-haiku #87af5f`; `git config
tabstatus.color.<agent_type> '#rrggbb'` overrides one or adds a seat). The
status stays one of the three words: the Session Status tool sorts by them,
and an unknown word's place is unspecified. Hooks fired inside a subagent
carry `agent_type`; the shim paints an in-seat PreToolUse/PostToolUse itself
(cc-status would paint plain orange) and passes PermissionRequest and
Notification through, since waiting outranks a colour. Running seats are
tracked in `${XDG_STATE_HOME:-~/.local/state}/tabstatus/<session_id>.seats`
— written on SubagentStart, pruned on SubagentStop, deleted on
SessionStart/SessionEnd, ignored past a day — so a Stop over a still-running
background seat repaints its colour, not orange. The detail carries
only the status: the row name carries the repo (next paragraph).

**The row's name is the session's name, and the shim sets it.** The Session
Status tool labels a row with `session.name` (iTerm2's `ToolStatus.swift`),
which the tab shows too. On iTerm2 3.7.5+ the Claude Code integration's
onboarding leaves a `builtin.claudeCode` workgroup (root session displayName
"Chat", peer "Diff") and, on every profile, an Enter Workgroup trigger that
fires when a job named `claude` starts. Entering renames the leader session to
the root's displayName through a `KEY_NAME` override — that is why every row
read `Chat (claude)`. The `(claude)` is the Job component of iTerm2's job-only
default title (these profiles set no `Title Components`) and is not touched
here. The workgroup's exit trigger restores the shell's own title when
`claude` quits.

So the shim renames the session back: `it2 session set-name` with `[<group>] `
(`WORKTABS_GROUP`, when set) and then `$WORKSET` (a working set is N repos, so
the set names the row) else `tabname` of the payload's `cwd`, on a session's
first UserPromptSubmit (marked by an empty `<session_id>.named` beside the seats
file, written whether or not a rename happened, deleted on
SessionStart/SessionEnd) and on every Stop and StopFailure, so
a later rename by iTerm2 heals at the end of the turn. It runs after the
cc-status call and before the paints, which keeps a paint the last `it2` call of
a turn end. Never on SessionStart: that fires before the job-start trigger may
have, and a rename landing first would be captured as the "original" title the
workgroup restores on exit. The title has control characters dropped and is cut
at 80 characters. `$WORKSET` needs no `tabname`; without it, no `tabname`, no `cwd`,
or a directory outside a repo means no rename, never an empty one (iTerm2 would
show its profile name). `set-name` is
a session-specific in-memory override: **no pref in
`com.googlecode.iterm2.plist` is part of this mechanism** — iTerm2's Claude
Code onboarding writes its workgroup (a `Workgroups` entry, `builtin.claudeCode`)
and the Enter/Exit Workgroup triggers into that plist itself, as it does every
other preference; that is iTerm2 saving, not part of this mechanism, and
clearing the root's displayName in Settings was rejected because it would be a
preference edit in the tracked plist. `cc-status explain` prints `name=` and
`rename=yes|no (<reason>)` and `marker=present|none`. A tab already stuck on `Chat (-zsh)` is fixed once
by hand: `it2 session set-name "$(tabname)"` in it, or Session > Edit Session.
Workgroup peers (`claude-peer`) are never renamed by iTerm2, so their rows are
the shim's name alone.
`bin/claude-tab` reads the other side of the same join: `list` prints one
row per live Claude Code session across every profile (from each profile's
`sessions/<pid>.json` registry, the files `claude_sessions_here` reads),
labelled by `tabname`, with the iTerm2 window and title its tty belongs to;
`focus <pid>` brings that tab forward. `list` works anywhere; `tabs` and
`focus` need macOS. Tests: `tests/claude-tab.bats`, `tests/tabname.bats`.
`save` and `restore` bring the sessions back after an iTerm2 quit (see "Claude
peers"). The tab bar reads `<repo> (claude)` during a session; the conversation topic no
longer appears there.

`bin/tabname [dir]` (`~/bin/tabname`) is the label: the git toplevel's name, or
for a linked worktree the repo, an `@`, then the worktree name, so the worktrees
under `.claude/worktrees/` stay told apart. Outside a work tree it prints
nothing and exits 1 — never 0 with empty output. It is a script so the shim and
any other tab labeller (an Alfred switcher) share one answer. The worktree
format is `git config tabname.worktree-format '{repo} <glyph>{worktree}'`; the
default is ASCII because the toolbelt renders rows in iTerm2's UI font
(`NSFont.it_toolbelt()`), where a Nerd Font private-use glyph is a tofu box
unless proven otherwise. Set a glyph only after checking it in both the Session
Status tool and the tab bar. Tests: `tests/tabname.bats`.

The `claude()` wrapper writes no title. Where `git config claude.terminal-title
false` is set (machine-local, overlay-supplied under a `mac` machine-class
guard wherever the shim is wired; default unset, so a public-only clone or a
Linux box is untouched)
it exports `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` (`''`, `0`, `false`, `no` and
`off` are normalised to unset under the gate, since Claude Code reads the
variable as a raw string and would treat `0` as disabling; outside the gate a
caller's value passes through untouched), so Claude Code's own OSC 0 titles —
its `/rename`-or-`-n` title, an AI title, a small-model title, and an empty one
on exit — never displace the repo between a title change and the next Stop. It
is gated rather than a default because it costs every machine and pays only
where the shim, iTerm2 3.7.5+ and the integration are all present. Two
documented costs: the docs say the variable also skips the request that
generates an AI session title, so `/resume` rows may show a summary or first
prompt instead (the binary gates that skip behind a feature flag, so it may not
happen), and it turns off Claude Code's OSC 7501 status reports, which the hooks
make redundant. Open `/resume` after a week and drop the config line if it
hurts; the Stop rename converges every turn either way. `claude-doctor`'s
`titles:` line shows the key and the variable. A session not launched through
the wrapper (bare `command claude`, Claude Desktop, an editor terminal) is
still renamed by the shim, but Claude's own titles may displace the name until
the next Stop.

A turn that **ends by asking the operator a question** paints `waiting` in
yellow (`tabstatus.color.question`, default `#ffd75f`) with the question as
the detail: on Stop or StopFailure with nothing active, a
`last_assistant_message` whose last non-empty line (bullets and quotes
stripped) ends in `?` or `？`. cc-status alone cannot show it — it reserves
"waiting" for PermissionRequest and AskUserQuestion, paints a plain Stop
idle, and its detail is only the message's opening ~180 characters, where a
closing question is cut off. The paint follows cc-status's and outranks the
quiet-task one; a Stop with something active stays working, and
SubagentStop never fires it.

A quiet **shell** task is **stalled** when nothing holds its output file open
any more, or when it was first seen quiet `tabstatus.stall-minutes` (git
config, default 15) ago and its holders' whole process tree has used under a
second of CPU since, the file untouched — a wedged download, not a silent
compile. It is measured without root: `lsof -t` names the holders, one `ps
-axo pid,ppid,time` (visible for every user) sums the tree's CPU, and
`<session_id>.tasks` beside the seats file keeps each task's last mtime, CPU
and first-seen-quiet time between Stops. With nothing active a stalled task
paints `waiting` in red (`tabstatus.color.stalled`, default `#ff5f5f`),
outranking the question and quiet paints; agent tasks are never probed, and a
missing `lsof` means unknown, never stalled.

Wiring is the load-bearing part. The shim is **named** `cc-status`, in a
directory off `PATH`, and its hook command is the bare absolute path with
the home directory expanded: iTerm2 3.7.3's health check accepts a hook
only if the command ends in `/cc-status` and `isExecutableFile` passes on
the literal string (verified in the app's onboarding source at that tag), so
`~`, `$HOME`, a wrapper line or another name makes the app report its
integration broken, and a Reinstall then appends a raw cc-status beside it,
which repaints "working". Master's hook lexer (`CCStatusHookCommand.swift`,
2026-10-03) will relax this, but 3.7.3 and 3.7.4 do not. The shim sits in
cc-status's own slot, never beside it — hooks for one event run in
parallel, so a second hook would race the thing it fixes — on eleven
events: the ten iTerm2 wires plus `SubagentStart`, which cc-status ignores
and the seat file relies on. Reinstall rewrites the entry back to the raw
binary and Uninstall strips it; re-applying the overlays restores it. The
overlays write the line (`cc-status settings` prints the block;
`docs/private-overlays.md`). iTerm2's own symlink at
`~/.config/iterm2/cc-status` is left alone — `ensureCCStatusSymlink`
removes anything else put there — and is where the shim finds the real
binary, with `it2` from beside it; `PATH` only carries `it2` while an
experimental iTerm2 setting is on. The shim deploys on every machine class
and exits 0 at once without the binary, which beats a hook entry that
errors on every event.

Pass-through events cost one `sh`, a `cat`, two `case` matches and a pipe
into cc-status; every Stop and StopFailure, and a session's first
UserPromptSubmit, adds one `python3` (~30 ms), a `tabname` and an `it2` start
for the rename (after the turn), a `stat` per task, one `git config
--get-regexp`, and a paint `it2` call only when nothing is active; an in-seat
tool call makes one `it2` call instead of cc-status's. It fails open to stock behaviour everywhere (no binary, `it2`,
python3 or session id, bad JSON, `it2` past five seconds) and never exits
non-zero: the row is cosmetic and must never cost a turn. It cannot see task
types that keep no output file (`monitor`, `in_process_teammate`,
`local_workflow`, `remote_agent` are unverified; a missing file reads as
active), nor a dead process behind a recently written file. The upstream
reports — the moved command keeping its stdin pipe, the hooks reference's
stale `background_tasks[].status`, cc-status reading `id`/`status` where
2.1.289 sends `task_id` — are drafts, not yet filed. `cc-status explain`
(payload on stdin) prints each task's verdict, the seat and the action,
calling nothing; `unknown` means the output file is not where it looks,
`passthrough` that the gate missed the payload. The facts the shim rests on
are `utilstr`/`binstr` lines in the skill's `manifest.txt`, so `verify.sh`
says when a point release moves them. `claude-doctor`'s `tabstatus:` line
counts the eleven events in a profile's `settings.json` that run the shim,
still run iTerm2's raw cc-status, or run neither, plus the seats live;
`iterm2-doctor`'s `cc-status:` line reads the app's symlink and where `it2`
is, never executing either. Tests: `tests/cc-status-shim.bats` (stub
cc-status and it2, side by side like the bundle ships them).

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
