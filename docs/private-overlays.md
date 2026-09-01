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
| tailnet mount | nothing of its own — ssh keys stay in 1Password's agent; optional one-time `/etc/synthetic.conf` entry for a fixed absolute path | overlay supplies `tailnet-mount.<name>.*`; rclone comes from the package lists |
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
	email  = <address the account commits as>   # repeatable
	sshkey = ~/.ssh/<that account's key>.pub     # what git-ssh-pinned hands ssh
```

Declare one block per pinned account in the overlay that owns it (personal
commits: the GitHub noreply address only). `sshkey` is the public half of
the key GitHub knows for that account (the private half stays in the
agent): `~/bin/git-ssh-pinned` — installed as git's ssh by the block below —
runs `ssh -o IdentitiesOnly=yes -i <sshkey>` for any plain `git@github.com:`
remote whose owner is pinned to the account, so the key no longer has to be
chosen by a host alias in the URL. A repo that commits as an identity other
than its owner's — a side company hosted under the personal account — is
pinned by slug, which outranks the account's emails and key (the same shape
as wrangler's per-repo pin); `sshkey` here is also how a deploy key is used:

```gitconfig
[identity "<owner>/<repo>"]
	email  = <that project's own address>
	sshkey = ~/.ssh/<that project's own key>.pub   # optional
```

```gitconfig
[core]
	sshCommand = $HOME/bin/git-ssh-pinned   # macOS/Linux; WSL keeps ssh.exe
[ssh]
	variant = ssh                          # skip git's -G probe of the helper
```

Both overlays may carry that `core`/`ssh` block, the way both carry the
credential helper block: the values are identical, so whichever file git
reads last changes nothing. An account with no `sshkey`, an unpinned owner,
an alias host, or a non-GitHub host leaves ssh's arguments untouched.

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
`gh()`, `claude()`, `wrangler()`, `bin/git-credential-gh-user` (https), and
`bin/git-ssh-pinned` (ssh) all read them at run time, which is how those
public files name no accounts. Personal
owners go in the personal overlay, work orgs in the work overlay.

### Claude Code profile per account

```gitconfig
[claude "profile"]
	<account> = ~/.claude-<name>     # or ~/.claude for the default dir
	<alias>   = ~/.claude-<name>     # friendly name for claude-as / CLAUDE_PROFILE
	default   = ~/.claude-<name>     # optional: used when no pin matches the cwd
```

### Workspace: terminal tabs to reopen (macOS)

`~/bin/worktabs` opens one iTerm2 window per group with a tab per entry, each
in its directory running its command. Paths and group names are private, so the
whole list lives here:

```gitconfig
[workspace "<name>"]               # <name>: letters, digits, - and _
	dir      = ~/code/<project>      # required; the tab's working directory
	command  = <command line>        # optional; run after cd. Omit for a shell
	window   = <group>               # optional; default: <name>, its own window
	title    = <tab title>           # optional (default: <name>); iTerm2
	                                 # relabels tabs itself, so it is a hint
	disabled = true                  # optional; keep the entry, skip it
```

A worked example — two projects sharing a window, one side project in its own,
and one tab that is not running an agent at all:

```gitconfig
[workspace "atlas"]
	dir = ~/code/atlas
	command = claude
	window = day-job
[workspace "beacon"]
	dir = ~/code/beacon
	command = claude --continue
	window = day-job                 # same window as atlas
[workspace "sideline"]
	dir = ~/code/sideline
	command = claude
	window = sideline-co             # a window of its own
[workspace "logs"]
	dir = /var/log
	command = tail -f system.log
	window = sideline-co             # shares sideline's window
[workspace "notes"]
	dir = ~/notes                    # no command: just a shell in a directory
```

`window` is the whole grouping story — there is no derivation and nothing is
inferred from a repo's remote. Group by whatever you actually think in
(employer, client, side project, "things I am debugging today"); entries with
no `window` get a window to themselves. Because the command is typed into a
**login shell**, `claude` there is the wrapper from `~/.functions`, so it still
picks the right `CLAUDE_CONFIG_DIR` for that directory — which matters, since
session history is partitioned per config dir and the wrong one silently
resumes nothing.

Once per machine, after `dotfiles`:

```sh
worktabs install          # the iTerm2 dynamic profile
worktabs status           # profile, entries, which tabs are open
worktabs start day-job    # open one group, any time
```

Nothing opens at iTerm2 launch: a set is opened when you ask for it, with
`worktabs start` or the Alfred workflow. (An older version installed an
AutoLaunch script that reopened everything at every launch; `worktabs
install` removes one it finds.) `worktabs plan` shows the whole decision
table without touching iTerm2, and `worktabs-doctor` (also run by `doctor`)
reports it next to the profile's state.

For a launcher you can reach from the keyboard, `worktabs alfred-install`
hands the Alfred workflow in `alfred/worktabs/` to Alfred; its keyword `ws`
lists the groups with their open/total counts and opens the one you pick. The
workflow contains no names — it calls `worktabs`, which reads this config.

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

### Tailnet mounts — a remote directory as a local path

```gitconfig
[tailnet-mount "<name>"]
	tailnet     = <tailnet-name>       # a tailnet installed with `tailnet install`
	host        = <node-hostname>      # the serving node (short MagicDNS name)
	path        = /remote/dir          # absolute path on that node
	user        = <ssh-user>           # optional; omitted -> ssh config decides
	mountpoint  = /some/where          # optional; default ~/.local/state/tailnet/mnt/<name>
	rclone-args = --vfs-cache-max-size 5G   # optional, space-separated, appended
```

`tailnet mount <name>` mounts that directory on demand (`umount` / `mounts`
are its siblings): rclone speaks sftp to the node through the tailnet — an
external `ssh -o ProxyCommand=tailnet nc …`, so the machine's ssh config,
known_hosts, and 1Password SSH agent all apply and no credential of its own
exists — and serves the result to the kernel as loopback NFS on macOS (no
kext, no root) or a FUSE mount on Linux. The default mountpoint sits inside
the chmod-700 state tree deliberately: the mount is not exposed outside the
tailnet dirs.

For a tool that hardcodes an absolute path (say `/data`), keep the default
mountpoint and add a one-time synthetic symlink — the only sudo in this
whole scheme, and it is run by hand, never by the repo:

```
printf 'data\tUsers/<user>/.local/state/tailnet/mnt/<name>\n' | sudo tee -a /etc/synthetic.conf
```

Caveats: the separator must be a literal TAB; the target is relative to `/`
(no leading slash); the entry name may not contain `/`. It takes effect at
the next boot (`sudo /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -t`
sometimes works without one, varying by macOS release). The symlink dangles
harmlessly while nothing is mounted.

### Composed files — `~/.ssh/config` and `~/.config/git/allowed_signers`

Both mix identities *inside one file*, so neither can live whole anywhere:
chezmoi allows one source per target, and no repo here may name both
identities. Each overlay contributes a fragment instead.

```
~/.ssh/config                             public   Include ~/.ssh/config.d/*.conf
~/.ssh/config.d/10-personal.conf          personal  mac only
~/.ssh/config.d/20-work.conf              work      mac only

~/.config/git/allowed_signers             GENERATED by ~/bin/git-allowed-signers
~/.config/git/allowed_signers.d/10-personal   personal  every class
~/.config/git/allowed_signers.d/20-work       work      every class
```

To add a signer or an ssh route, add a **line to your overlay's fragment** —
never to the composed file, which is overwritten. Then `dotfiles`, which
composes after every overlay has applied.

ssh needs no generator: `Include` is native, and an unmatched glob is not an
error, so a missing overlay is silently a missing fragment. Git has no
include for `allowedSignersFile` — it names exactly one path — so that one is
concatenated by `bin/git-allowed-signers` (`--print` to inspect, `--check` to
fail when stale).

**Ordering is inverted between the two languages.** `ssh_config(5)`: *"for
each parameter, the first obtained value will be used"* — earlier wins, and
the `Include` must precede `Host *`. Git: the last include wins, which is why
`.gitconfig` reads `~/.gitconfig.local` then `~/.gitconfig.work`. The `10-` /
`20-` prefixes make the ssh precedence explicit: **personal outranks work**
on any host both describe, which is the reverse of what the same order means
in `.gitconfig`. Nothing overlaps today, and the public repo's
`tests/ssh-config.bats` renames a fixture fragment to prove the prefix — not
luck — is what decides.

The ssh fragments are macOS-only (each overlay's `.chezmoiignore`): every
block in them describes how *the laptop* reaches a host. A Linux box resolves
its key through `git-ssh-pinned` and the credential pins instead, against an
agent forwarded from the laptop — so it needs no alias, and "forward my agent
to hex" means nothing when you are already on hex. The signers fragments
deploy everywhere, because verifying a signature is not machine-shaped.

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
   `identity.<account>.email` and `identity.<account>.sshkey`;
   `claude.profile.<account>`;
   `wrangler.profile.<account>` (or a `wrangler.<owner>/<repo>.profile` pin
   for a one-off repo); `tailnet.profile.<account>` if that account has a
   tailnet; `tailnet-mount.<name>.*` if that tailnet serves a directory
   worth mounting; a `workspace.<name>.dir` for each of that account's
   projects you want reopened after a restart; Finicky rules.
   Personal overlay only:
   `claude.profile.default` names the profile stray, unpinned directories
   get (unset, they get bare `claude` = the default config dir).
   Any overlay may add `routes.root` (repeatable) if this machine keeps
   projects somewhere other than `~/code`; it is only the list of directories
   `routes` scans, so the paths — not the accounts — are what make it private.
3. `dotfiles` to apply; `doctor` in a repo of that owner to confirm every
   wrapper resolves it, then `routes` to see the new account's projects take
   their column values and nothing else move.
4. Once per machine: `gh auth login`, `claude auth login` in its profile,
   `wrangler auth create <profile>`.
5. Nothing in the public repo changes.
