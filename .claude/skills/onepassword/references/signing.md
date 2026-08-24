# The SSH agent and commit signing

The two channels that are not the CLI. Verified against the versions in
`../VERSIONS`, empirically on this machine and against
`https://www.1password.dev/ssh/`.

## Contents

- [Socket paths](#socket-paths)
- [`IdentityAgent` and why `ssh-add` disagrees](#identityagent-and-why-ssh-add-disagrees)
- [`agent.toml`](#agenttoml)
- [The six-key limit](#the-six-key-limit)
- [Commit signing](#commit-signing)
- [Probing `op-ssh-sign` directly](#probing-op-ssh-sign-directly)
- [Remote machines and WSL](#remote-machines-and-wsl)

## Socket paths

| Platform | Agent socket |
|---|---|
| macOS | `~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock` |
| Linux | `~/.1password/agent.sock` |
| Windows | the named pipe `\\.\pipe\openssh-ssh-agent` |

**`~/.1password/agent.sock` is the Linux path, not a macOS one.** On macOS it
exists only if you create it yourself — 1Password documents an optional
symlink for tools that cannot cope with a path containing spaces:

```bash
mkdir -p ~/.1password && \
  ln -s ~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock \
        ~/.1password/agent.sock
```

This machine does **not** have that symlink; `~/.ssh/config` names the group
container path directly. Do not "fix" a config that points at the real path.

On Windows the pipe is fixed and shared, so per-host key selection is
impossible there — the agent authenticates for every host.

## `IdentityAgent` and why `ssh-add` disagrees

Either form works:

```
# ~/.ssh/config
Host *
  IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
```

```bash
export SSH_AUTH_SOCK=~/.1password/agent.sock   # Linux
```

This repo uses the first. `IdentityAgent none` opts one host back out.

The consequence, and it is the single most misleading thing in this whole
area: **`ssh-add` does not read `~/.ssh/config`.** It speaks only to
`$SSH_AUTH_SOCK`. So on a machine configured via `IdentityAgent`, `ssh-add -l`
reports whatever the *ambient* agent holds — under Claude Code's Bash tool
that is macOS's launchd agent, which answers "The agent has no identities"
while ssh, git, and signing all work perfectly.

To ask the 1Password agent, name it for the one command:

```bash
SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" ssh-add -l
```

`onepassword-doctor` prints the `IdentityAgent` that `ssh -G` resolves and
`$SSH_AUTH_SOCK` on separate lines for exactly this reason. `ssh -G` is used
rather than grepping the config because it is ssh's own parsing — `Match`
blocks, includes and all — the same technique `git-doctor` uses for origin
aliases.

## `agent.toml`

| Platform | Path |
|---|---|
| macOS / Linux | `~/.config/1Password/ssh/agent.toml` (`$XDG_CONFIG_HOME` honoured first) |
| Windows | `%LOCALAPPDATA%/1Password/config/ssh/agent.toml` |

Not present on this machine, which means the **default** applies: every SSH
key item in the built-in Personal/Private/Employee vaults is offered.

Format (TOML 1.0) — repeated `[[ssh-keys]]` tables, each narrowing a query:

```toml
[[ssh-keys]]
item = "<item>"
vault = "<vault>"

[[ssh-keys]]
vault = "<other vault>"
```

Semantics worth knowing before writing one:

- Keys within a table are `AND`ed — more keys, narrower match. `item` alone
  selects that key; `vault` alone selects every key in it; `account` alone
  every key in the account.
- Header and key names are **lowercase only**; values must be quoted, and
  values are case-insensitive. `item`/`vault` take names or UUIDs; `account`
  takes a name, a sign-in address, or an ID.
- **Table order is the order keys are offered to servers.** This is the lever
  for the six-key limit below. Within one table matching several keys, they go
  oldest-created first.
- **Creating the file at all — even empty — replaces the default entirely.**
  An empty `agent.toml` offers *no* keys. Delete or move the file to get the
  default back.
- Edits take effect immediately; no agent restart. (Creating it for the first
  time may need one app lock/unlock.)
- Archived or deleted key items are ignored even when named by ID, and
  non-matching entries are silently ignored rather than erroring — so a typo
  looks like a missing key, not like a config error.
- **A syntax error stops the agent.** The app surfaces it under Developer
  settings; the symptom in the terminal is simply that nothing authenticates.
- The file is local-only and never synced by 1Password. If it is ever
  introduced here it belongs in the private overlay, since it names vaults.

## The six-key limit

OpenSSH servers default to `MaxAuthTries 6`. The agent offers keys in order
until one is accepted, so **from the seventh key on you get
`Too many authentication failures`** before your real key is ever tried —
and it looks exactly like a rejected key.

Three fixes, in increasing order of precision:

1. Order the likely keys first with `agent.toml`.
2. Pin per host in `~/.ssh/config`:

   ```
   Host <alias>
     IdentityFile ~/.ssh/<selector>.pub
     IdentitiesOnly yes
   ```

   1Password supports pointing `IdentityFile` at the **public** key — not
   every client does.
3. SSH Bookmarks (beta).

This machine currently offers 3 keys, so the limit is not live — but it is the
thing that breaks when a fourth, fifth, and sixth get added, and the error
will not mention it.

## Commit signing

Requires git ≥ 2.34. The configuration lives in `~/.gitconfig.local` from the
private overlay, never in the tracked `.gitconfig`:

```
gpg.format      = ssh
user.signingkey = ~/.ssh/<selector>.pub
commit.gpgsign  = true
gpg.ssh.program = /Applications/1Password.app/Contents/MacOS/op-ssh-sign
```

The app can write these for you: item ⋮ → Configure Commit Signing → Edit
Automatically, or Copy Snippet for a per-repo `.git/config`. Multiple
identities are handled with `includeIf`, which is what this setup does.

Two points that are easy to get wrong:

- **`user.signingkey` must be the `.pub`**, not a private key and not a random
  file. A private key there produces `error: Load key ...: invalid format`.
- **`gpg.ssh.program` exists so that signing does not depend on
  `SSH_AUTH_SOCK`.** That is not a convenience note — it is why `op-ssh-sign`
  is an independent channel, and why agent health tells you nothing about
  signing health.

Local *verification* of signatures additionally needs
`gpg.ssh.allowedSignersFile`; without it, `git log --show-signature` cannot
confirm signatures it can otherwise see.

There is **no GPG keypair** anywhere in this setup, despite `commit.gpgsign`.

## Probing `op-ssh-sign` directly

The check that actually answers "will a commit sign right now", without making
a commit:

```bash
printf 'probe' | /Applications/1Password.app/Contents/MacOS/op-ssh-sign \
    -Y sign -n git -f ~/.ssh/<selector>.pub
```

`-----BEGIN SSH SIGNATURE-----` means the channel is up.

Mechanics found by inspecting the binary and running it:

- It takes the payload on **stdin**. The positional `[payload]` argument is a
  *file path*; passing `-` there yields
  `1Password: No such file or directory (os error 2)`, which reads like a
  1Password failure and is not one.
- `-Y` accepts `sign`, `verify`, `find-principals`, `check-novalidate`,
  `match-principals`. It has no `--version`.
- **It ignores `SSH_AUTH_SOCK`.** Verified three ways: unset, at the launchd
  default, and pointed at a nonexistent path — it signed in all three.
- `failed to fill whole buffer` is a string inside the binary. It is Rust's
  `read_exact` error: the reply from 1Password came up short, i.e. the
  connection dropped mid-protocol. Unlock/approve and retry; see the triage
  table in `../SKILL.md`.

## Remote machines and WSL

On a box with no 1Password, nothing needs disabling — the tracked `.gitconfig`
never enables signing, so it is simply off.

To sign on a remote you keep: forward the local agent, and set
`user.signingkey` to the **literal public key string** rather than a path, and
do **not** set `gpg.ssh.program` — `op-ssh-sign` exists only where the app is
installed.

WSL uses 1Password's `ssh.exe` forwarding pattern (the `wsl` machine class in
this repo sets it up); docs at
`https://www.1password.dev/ssh/integrations/wsl`.
