# Private overlays: keeping identity out of a public dotfiles repo

This repo is public and **identity-free**: it holds every mechanism —
wrappers, templates, tests — and none of the facts about who uses it. Every
name, email, account, org, side-company, private repo, hostname, and secret
lives in a **private overlay**: a second (third, …) chezmoi source, in a
private repo, applied on top of the public one. This document is the manual
for those overlays — how one is built, how a machine loads it, and where each
kind of private thing goes — so the public repo can explain the system
without containing any of it.

The rule of thumb: **if a string would tell a stranger something about you,
it belongs in an overlay.** The public repo may only ever contain
placeholders (`<personal-account>`, `<work-org>`, `<side-company>`) and
fixture names in tests (`octo-personal`, `personal-profile`, …).

## How overlays work

chezmoi allows one source directory per *config file*. An overlay is simply
another config file in `~/.config/chezmoi/`, pointing at its own source clone,
with its own state database:

```
~/.config/chezmoi/chezmoi.toml   → ~/code/dotfiles           (public, this repo)
~/.config/chezmoi/private.toml   → ~/code/dotfiles-private   (personal overlay)
~/.config/chezmoi/<work>.toml    → ~/code/dotfiles-<work>    (work overlay, if this machine does work)
```

The `dotfiles` function in `.functions` applies the public source, then
**every** overlay config whose source clone exists, in name order, then
touches `~/.finicky.ts` so Finicky picks up changed rule fragments:

```sh
chezmoi apply                                          # public
chezmoi --config ~/.config/chezmoi/private.toml apply  # each overlay, in turn
```

Which overlays a machine carries *defines* what it is: personal box →
personal overlay; work box → personal + work; `ephemeral` box → none (it is
shell config only, no identity, no 1Password). Consequently **nothing in the
public source may depend on an overlay existing** — every template, test,
and script must work with none present. A public-only clone having no git
`user.email`, no `~/.extra`, no Claude settings is correct, not broken.

Ownership follows content: the personal overlay is owned by the personal
GitHub account and names only personal things; a work overlay is owned by the
work account and names only work things. Neither names the other's accounts,
so a machine used for one never learns about the other.

## Building an overlay

An overlay repo is a normal chezmoi source. Minimum layout:

```
.chezmoi.toml.tmpl      # writes the overlay's config file (below)
.chezmoiignore          # README, tests, anything repo-level
README.md               # what lives here and the one-time init (below)
tests/                  # bats; see "Guarding against leaks"
dot_gitconfig.local.tmpl            # or dot_gitconfig.work.tmpl for a work overlay
private_dot_extra.tmpl              # personal overlay only: secrets → ~/.extra (0600)
dot_config/finicky/personal.ts      # or work.ts: link-routing rules
…
```

`.chezmoi.toml.tmpl` — the two settings that matter are `sourceDir` and an
**explicit `persistentState`**: all configs share `~/.config/chezmoi/`, and
without their own state file they would share one database and corrupt each
other's `run_onchange_` hashes. Keep the prompt named `machineClass` so it
can be answered non-interactively the same way as the public repo's:

```
{{- $machineClass := promptStringOnce . "machineClass" "machineClass" -}}
sourceDir = "~/code/dotfiles-<name>"
persistentState = "~/.config/chezmoi/<name>-state.boltdb"

[data]
    machineClass = {{ $machineClass | quote }}
```

`.chezmoiignore` in the overlay should mirror the public one for repo-level
files (`README.md`, `tests`), and skip identity files on `ephemeral`.

## Loading an overlay on a new machine

After the public repo is initialised (`chezmoi init --apply <account>` or
`chezmoi init --source ~/code/dotfiles --apply`):

```sh
git clone <ssh-alias>:<owner>/dotfiles-<name>.git ~/code/dotfiles-<name>

# One-time: write ~/.config/chezmoi/<name>.toml, reusing the public answer
chezmoi init --config ~/.config/chezmoi/<name>.toml \
             --source ~/code/dotfiles-<name> \
             --promptString machineClass="$(chezmoi execute-template '{{ .machineClass }}')"

dotfiles      # public, then every overlay present
doctor        # git / gh / claude / wrangler: what each resolves to right here
```

Then the **per-machine logins** the overlays' mappings refer to. Overlays
carry *names*; credentials are minted once per machine and live outside any
repo (Keychain / the tool's own config dir):

| Tool | Once per account, per machine | Where the credential lives |
| --- | --- | --- |
| gh | `gh auth login` (as each account) | gh's keyring |
| Claude Code | `claude auth login` under each profile dir (`claude-as <name> auth login`) | macOS Keychain, keyed on the config dir — cannot be copied between profiles |
| wrangler | `wrangler auth create <profile>` (browser OAuth as that Cloudflare account) | `~/Library/Preferences/.wrangler/config/<profile>.toml` (macOS) / `~/.config/.wrangler/config/` |
| tailnet | `tailnet install <name> && tailnet up <name>` (browser login as that Tailscale account) | `~/.local/state/tailnet/<name>/` — the daemon's node key and its proxy port |
| git signing | nothing — 1Password's SSH agent holds the key | 1Password |
| `~/.extra` secrets | `op signin` once; chezmoi reads them at apply | 1Password; the file is regenerated (0600) |

## What goes where

Each private fact has exactly one home — and almost all of them are **git
config keys**. That is deliberate: git is on every machine and in every repo
already; its config is layered (the public `.gitconfig` `include`s the
overlay files, `includeIf` narrows by remote), machine-local, and readable
from anything with `git config --get`. The wrappers key off the one fact
every project already carries — its origin remote — so nothing needs a
second config format, a per-project dotfile, or a daemon. Public files read
these keys at run time, so adding an org/account/repo is an overlay edit and
never a public one.

### Git identity — `~/.gitconfig.local` (personal) / `~/.gitconfig.work` (work)

`user.name`, `user.email`, and `includeIf` routing by SSH remote alias, plus
signing (`commit.gpgsign`, `gpg.format = ssh`, `gpg.ssh.program`,
`user.signingkey`) — see CLAUDE.md "Commit signing". The public `.gitconfig`
ends by including both files; git silently skips whichever is absent.

Routing alone is advice: a repo cloned with a URL shape the `includeIf`
misses commits under whatever identity is the default. The **pre-commit
identity gate** (`~/.git-hooks/pre-commit`, selected by `core.hooksPath` in
the public `.gitconfig`) makes it a rule: it resolves the origin's owner to
an account through the credential pins below and refuses the commit unless
author *and* committer email are among the account's declared emails:

```gitconfig
[identity "<account>"]
	email = <address the account commits as>   # repeatable
```

Declare one block per pinned account in the overlay that owns it (personal
commits: the GitHub noreply address only). A repo that commits as an
identity other than its owner's — a side company hosted under the personal
account — is pinned by slug, which outranks the account's emails (the same
shape as wrangler's per-repo pin):

```gitconfig
[identity "<owner>/<repo>"]
	email = <that project's own address>
```

Unpinned owner, no origin, or no declared email → no opinion (a warning
for the last case). Bypass one
commit with `GIT_IDENTITY_CHECK=0`. `git-doctor` prints the gate's verdict
for the cwd. Every hook name in `~/.git-hooks` chains to the repo's own
`.git/hooks/<name>`, so repo-local hooks keep working; a repo that sets its
own `core.hooksPath` (husky) is untouched. Each hook also runs any
`hook.<name>.run` commands from git config first (repeatable, usually
per-repo `.git/config`) — the way to attach a machine-local check to a repo
without tracking it, see below.

### GitHub account per owner — the credential pins (load-bearing)

```gitconfig
[credential "https://github.com/<owner>"]
	username = <account>
```

One block per GitHub owner (your account, each org, each side-company
owner). These pins are the **single source of truth for owner → account**:
`gh()`, `claude()`, `wrangler()`, and `bin/git-credential-gh-user` all read
them at run time, which is how those public files name no accounts. Personal
owners go in the personal overlay, work orgs in the work overlay.

### Claude Code profile per account

```gitconfig
[claude "profile"]
	<account> = ~/.claude-<name>     # or ~/.claude for the default dir
	<alias>   = ~/.claude-<name>     # friendly name for claude-as / CLAUDE_PROFILE
	default   = ~/.claude-<name>     # optional: used when no pin matches the cwd
```

### Claude Code sessions to reopen after a restart (macOS)

`~/bin/claude-session` opens one iTerm2 window per Claude Code profile with a
tab per project. Project paths are private, so the whole list lives here:

```gitconfig
[claude-session "<name>"]          # <name>: letters, digits, - and _
	dir      = ~/code/<project>      # required; the tab's working directory
	window   = <label>               # optional; see below
	profile  = <claude profile>      # optional; forces `claude-as <profile>`
	args     = --continue            # optional; appended to the claude call
	title    = <tab title>           # optional (default: <name>); iTerm2
	                                 # relabels tabs itself, so it is a hint
	disabled = true                  # optional; keep the entry, skip it
[claude-session]
	delay    = 3                     # optional; seconds to settle after login
```

A worked example — two work projects, one personal, one side project that
lives under a personal GitHub owner but wants a named profile of its own:

```gitconfig
[claude-session "atlas"]
	dir = ~/code/atlas               # origin belongs to the work org
[claude-session "beacon"]
	dir = ~/code/beacon              # same org -> same window as atlas
	args = --continue
[claude-session "dotfiles"]
	dir = ~/code/dotfiles            # personal owner -> the other window
[claude-session "notes"]
	dir = ~/notes                    # not a repo: nothing to resolve
	window = personal-stuff          # so say which window by hand
	profile = <personal alias>       # and which profile to launch as
```

`window` is only needed for the last shape. Leave it out and the session joins
the window of the profile its **directory** resolves to — the same
`credential.https://github.com/<owner>.username` → `claude.profile.<account>`
chain `claude()` walks — which is what keeps the two accounts in two windows
with neither account named in the launcher. `profile` takes a name mapped in
`claude.profile.*` (an alias is fine) and is what `claude-as` would take.

Once per machine, after `dotfiles`:

```sh
claude-session install     # the launchd agent (Aqua session only)
claude-session start       # once by hand: macOS asks about controlling iTerm2
claude-session status      # agent, sessions, which tabs are open
```

Expect a second Automation prompt at the first login after that — the agent is
a different client to macOS than your terminal. `claude-session plan` shows
the whole decision table without touching iTerm2, and `claude-session-doctor`
(also run by `doctor`) reports it next to the agent's state.

### Wrangler (Cloudflare) profile per account — and per repo

```gitconfig
[wrangler "profile"]
	<account> = <profile>            # e.g. the personal account → a profile named after it
	<alias>   = <profile>            # friendly name for wrangler-as / WRANGLER_PROFILE

[wrangler "<owner>/<repo>"]        # a repo that deploys somewhere other than
	profile = <other-profile>        # its owner's usual account (a side company)
```

Naming advice: **make every account a named profile**, including the one you
log in to most — map nothing to `default`. `default` is whatever
`wrangler login` last stored, so mapping to it means "no binding, hope the
global login is right"; a named profile gets a per-repo binding that
`npx wrangler` and package.json scripts honour too. Profile names are
labels: pick short ones (an account handle, a company nickname); they never
appear in the public repo, only in the overlay's gitconfig and in wrangler's
local config dir.

### Tailnet (Tailscale network) per account — and per repo

```gitconfig
[tailnet "profile"]
	<account> = <name>               # a tailnet installed with `tailnet install <name>`
	<alias>   = <name>               # friendly name for tailnet-as / TAILNET

[tailnet "<owner>/<repo>"]         # a repo whose hosts live on another tailnet
	profile = <other-name>           # than its owner's usual one
```

Names are labels for `~/bin/tailnet`'s per-tailnet daemons ("personal",
"work", a company nickname); the port and node key are machine-local state,
not overlay content. The mapping is only a *preference* — the wrappers still
try every installed tailnet for a host — so an unmapped account merely loses
the tie-break when two tailnets share a node name.

### Link routing (Finicky) — `~/.config/finicky/personal.ts` / `work.ts`

Per-account/per-company rules and Chrome profile display names — the personal
fragment also sets `defaultBrowser`. The public composer imports whichever
fragments exist (it deploys empty `create_` stubs). Chrome profile display
names count as private (they name accounts and companies).

### Claude Code work settings — work overlay only

`~/.claude/settings.json` (names the private plugin marketplace) and
`~/.claude/CLAUDE.work.md` (work account/org notes; imported by the public
`~/.claude/CLAUDE.md`, unresolved and harmless where absent).

### Secrets — `~/.extra` from `private_dot_extra.tmpl` (personal overlay)

Never a value, only a 1Password reference; chezmoi resolves it at apply time
with `onepasswordRead` (see CLAUDE.md "Machine-local secrets" for the exact
syntax and the Go-template caveat). Per-vendor account names and vault paths
go in `~/.config/<vendor>/env` files from the same overlay. **Do not** put
per-project tokens (e.g. `CLOUDFLARE_API_TOKEN`) in `~/.extra` — it is
sourced by every shell, so a project token there overrides account routing
everywhere; project tokens belong in that project's `op run --env-file`
setup.

## Guarding against leaks

The public repo can't test for the strings it must not contain — the test
would leak them. So **each overlay ships the leak test** (`tests/no-public-leak.bats`),
pointed at the public clone, with a `DENY` regex of every private identifier
that overlay owns: real name, emails, GitHub accounts, orgs, side-company
names and domains, private repo names, hostnames, Chrome profile names,
wrangler profile names if they are telling. It checks the public **working
tree**, **commit messages** (`git log --format='%s%n%b'`), **history**
(`git log -S<string>` — anything ever added or removed), and **author /
committer emails** (public commits use the GitHub noreply address). Run it
before pushing anything public:

```sh
bats ~/code/dotfiles-<name>/tests
```

**Run it before every public push, automatically:** the overlay ships a
`run_onchange_` script that attaches the test to the public clone via the
global hooks' `hook.<name>.run` mechanism —

```sh
git -C ~/code/dotfiles config --replace-all hook.pre-push.run \
    "bats $HOME/code/dotfiles-<name>/tests/no-public-leak.bats"
```

— so `~/.git-hooks/pre-push` runs the leak test and blocks the push when it
fails, on every machine that has both clones, with nothing tracked in the
public repo.

Leaks run in every direction, so each private repo polices its own tree
the same way: the work overlay carries a `no-cross-leak.bats` (no personal
email, side-company names, or personal-only paths), and a side-company
repo carries a test that no work identifier appears in its tree, commit
messages, or author emails. A repo naming another identity's *public* repo
(this one) is fine; naming a private repo, account, or email is not.

When a new private thing enters the setup — an org, a side company, a
profile — the first edit is adding its identifiers to that DENY list; the
second is the overlay config that uses them. Public commit messages describe
mechanism, never the account it was for ("resolve repo-local wrangler like
npx", not "pin <side-company> to its profile").

## Checklist for adding a new account or org

1. Overlay: add the identifiers to `tests/no-public-leak.bats` `DENY` (and
   the other overlays' cross-leak tests).
2. Overlay gitconfig: `credential.https://github.com/<owner>.username` pin;
   `identity.<account>.email`; `claude.profile.<account>`;
   `wrangler.profile.<account>` (or a `wrangler.<owner>/<repo>.profile` pin
   for a one-off repo); `tailnet.profile.<account>` if that account has a
   tailnet; a `claude-session.<name>.dir` for each of that account's
   projects you want reopened after a restart; Finicky rules.
   Personal overlay only:
   `claude.profile.default` names the profile stray, unpinned directories
   get (unset, they get bare `claude` = the default config dir).
3. `dotfiles` to apply; `doctor` in a repo of that owner to confirm every
   wrapper resolves it.
4. Once per machine: `gh auth login`, `claude auth login` in its profile,
   `wrangler auth create <profile>`.
5. Nothing in the public repo changes.
