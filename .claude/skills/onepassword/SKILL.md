---
name: onepassword
description: How 1Password is wired into this machine — the op CLI, secret references, the SSH agent, op-ssh-sign commit signing, and chezmoi's onepasswordRead in the private overlay. Use whenever a commit fails to sign, ssh or git rejects a key, `op read`/`op run` misbehaves, `chezmoi apply` cannot render ~/.extra, a secret needs to reach a shell or a config file, or anyone asks where a token should live. Reach for it on the error strings too — "failed to fill whole buffer", "No SSH private key found for the specified public key", "account is not signed in", "error: Load key ... invalid format" — and before hand-editing anything under ~/.ssh, gpg.ssh.program, or the overlay's private_dot_extra.tmpl.
---

1Password is load-bearing here in three unrelated places: it holds the SSH
keys, it signs every commit, and it is where `~/.extra`'s secrets come from at
`chezmoi apply` time. Those three run over **three separate connections that
fail independently**, and almost every wasted hour with this setup comes from
reading one channel's health as evidence about another.

Start by running `onepassword-doctor` (in `~/.functions`; `doctor` runs it
last, after the six per-repo ones). It reports all three channels separately
and finishes with a `skill:` line saying whether these notes were written
against the software actually installed. If that line reports drift, treat
what follows as dated — see [Keeping this current](#keeping-this-current).

## The three channels

| # | Who talks | Over what | Gated by | Proof it works |
|---|---|---|---|---|
| 1 | `op` CLI | `~/.config/op/op-daemon.sock` → desktop app | `op signin`, biometric, a session that lapses | `op whoami` exits 0 |
| 2 | `ssh`, `git` over ssh | the agent socket in `IdentityAgent` | app unlocked, "Use the SSH agent" on | `ssh -T` to the forge succeeds |
| 3 | `op-ssh-sign` | its **own** connection to the app | app unlocked + per-signature approval | a commit actually signs |

The trap is channel 3. Verified on this machine: `op-ssh-sign` produces a
signature with `SSH_AUTH_SOCK` unset, set to the launchd default, and pointed
at a path that does not exist. **It never reads `SSH_AUTH_SOCK`.** It is not
the agent your shell is talking to, and nothing you learn from `ssh-add`
constrains it.

`ssh-add` compounds this from the other side: it speaks only to
`$SSH_AUTH_SOCK` and **never reads `~/.ssh/config`**, so it cannot see the
`IdentityAgent` that ssh and git will use. Under Claude Code's Bash tool
`$SSH_AUTH_SOCK` is the launchd agent, so `ssh-add -l` there says "The agent
has no identities" on a machine where all three channels are perfectly
healthy. To ask the 1Password agent directly, point the variable at it for
one command:

```bash
SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" ssh-add -l
```

`onepassword-doctor` prints the `IdentityAgent` ssh resolves (from `ssh -G`,
ssh's own parsing) and `$SSH_AUTH_SOCK` on separate lines precisely because
they are different questions.

## `git commit` fails: "failed to fill whole buffer"

This is the hard-won one, and it looks exactly like a misconfiguration:

```
error: 1Password: failed to fill whole buffer
fatal: failed to write commit object
```

while `ssh-add -l` cheerfully lists every key and the app is running with a
healthy pile of processes. Both of those observations are worthless here —
they are channel 2, and this is channel 3.

The string comes out of `op-ssh-sign` itself (it is in the binary; it is Rust's
`read_exact` error). It means the helper's read of the app's reply came up
short: **the connection went away mid-protocol.** In practice that is the app
locked, the approval prompt never answered or dismissed, or the app restarting
underneath. It is transient — it clears on unlock/approve and retry, with no
config change — which is itself the strongest evidence that nothing is
misconfigured.

**Distinguish it from a real misconfiguration** by the shape of the error, not
by retrying blindly:

| Symptom | Channel | Cause | Fix |
|---|---|---|---|
| `failed to fill whole buffer` | 3 | app locked / approval not granted / app restarted | Unlock 1Password, approve the prompt, re-run the commit. No config change. |
| `No SSH private key found for the specified public key` | 3 | `user.signingkey` names a `.pub` whose private half is not in the vault | Point `user.signingkey` at a `.pub` that matches a key item, or add the key to 1Password |
| `signer: … NOT FOUND` from `git-doctor` | 3 | `gpg.ssh.program` path wrong, or no app (remote box) | Fix the path, or on a remote unset `commit.gpgsign` |
| `error: Load key … invalid format` | 3 | `user.signingkey` points at a private key or a non-key file | It must be the `.pub` |
| `Permission denied (publickey)` on push | 2 | agent socket wrong/missing, or key not authorised on the forge | Check `agent:` in the doctor; unlock the app |
| `account is not signed in` | 1 | CLI session lapsed | `op signin` |

Reproduce channel 3 in isolation without making a commit — this is the check
that actually answers "will a commit sign right now":

```bash
printf 'probe' | /Applications/1Password.app/Contents/MacOS/op-ssh-sign \
    -Y sign -n git -f ~/.ssh/<selector>.pub
```

A `-----BEGIN SSH SIGNATURE-----` block means channel 3 is up. The same error
git printed means it is down, and now you know it is not git's fault. Note
`op-ssh-sign` takes the payload on **stdin**; its positional `[payload]`
argument is a file path, and passing `-` there just gets you
`No such file or directory (os error 2)`.

**Never respond to this by committing unsigned or turning `commit.gpgsign`
off.** It is a transient unlock problem; disabling signing to get past it
leaves the setting off and the next hundred commits unsigned.

## How signing is configured here

Signing is **entirely machine-local** — the tracked `.gitconfig` does not
enable it, so a fresh clone defaults to unsigned rather than failing on a
missing signer. The private overlay supplies `~/.gitconfig.local`, which sets:

```
commit.gpgsign  = true
gpg.format      = ssh
gpg.ssh.program = /Applications/1Password.app/Contents/MacOS/op-ssh-sign
user.signingkey = ~/.ssh/<selector>.pub
```

The private halves live in 1Password and never touch disk; the `.pub` files
are only selectors. There is **no GPG keypair** despite the `gpgsign` name.
`git-doctor` reports which of these are set and whether the signer and key
file exist — run it alongside `onepassword-doctor` when signing breaks.

On a machine with no 1Password (a remote Linux box), nothing needs disabling:
signing is simply never enabled there. To sign on a remote you keep, forward
the local agent and set `user.signingkey` to the **literal public key string**,
not `op-ssh-sign`, which exists only locally.

## Secrets into the shell and into files

Full command surface, syntax grammar, and service-account/SDK detail:
[`references/cli.md`](references/cli.md).

The short version, and the rule that matters most here:

- `op read op://<vault>/<item>/<field>` — one secret to stdout.
- `op run --env-file=.env -- <cmd>` — the project pattern. The `.env` holds
  *references*, not values, and is safe to commit.
- `op inject -i tpl -o out` — a config file templated with `{{ op://… }}`.

**`~/.extra` must never export a token that a per-repo wrapper routes** —
`GH_TOKEN`, `GITHUB_TOKEN`, `CLOUDFLARE_API_TOKEN`, `ANTHROPIC_API_KEY`,
`CLAUDE_CONFIG_DIR`. `~/.extra` is sourced by *every* shell, so such a token
silently outranks the cwd-based account routing that `gh()`, `claude()`, and
`wrangler()` implement — everywhere, in every repo, including ones that
belong to the other account. Project tokens belong in that project's
`op run --env-file`. `onepassword-doctor`'s `extra:` line checks for exactly
these names (names only — it never prints a value), and the overlay's
`tests/extra-tmpl.bats` enforces it too.

## chezmoi: rendering `~/.extra`

`~/.extra` (mode 0600) is rendered by chezmoi from `private_dot_extra.tmpl`
**in the private overlay**, using chezmoi's built-in 1Password template
functions. Only references live in that repo; values are fetched from the CLI
at apply time, so `op signin` must have succeeded first (channel 1).

```
export SOME_SERVICE_TOKEN={{ onepasswordRead "op://Private/Some Service/token" | quote }}
```

Verified present in chezmoi v2.72.0: `onepassword`, `onepasswordRead`,
`onepasswordDetailsFields`, `onepasswordItemFields`, `onepasswordDocument`.

Two traps, and they are the same trap seen from two sides:

1. **A stray `{{` anywhere in that template breaks rendering** — chezmoi
   parses the whole file as a Go template, comments included. This is why the
   guidance lives in `CLAUDE.md` and not in the template.
2. **`op inject` syntax and chezmoi templating collide.** `op inject`'s
   placeholder is literally `{{ op://… }}`, which is also a Go template
   action. A chezmoi-managed file therefore cannot use `op inject` syntax; it
   uses `onepasswordRead` instead. Do not "helpfully" convert one to the
   other.

Debug a render without writing anything:

```bash
chezmoi execute-template < private_dot_extra.tmpl   # in the overlay source
```

## Keeping this current

`VERSIONS` in this directory stamps the `op` CLI and desktop-app versions
these notes were written and verified against. `onepassword-doctor` reads it,
compares it to what is installed — both read off the install rather than by
executing anything — and prints one of:

```
skill:   written against op 2.39.0 / app 8.12.33 — matches what is installed
skill:   written against op 2.39.0 / app 8.12.33 — installed is op 2.41.0 / app 8.13.4; refresh it (…)
```

When it reports drift: re-verify the claims here against the installed
binaries and the current docs (`references/upstream.md` says where the release
notes live and how versions are numbered), then bump `VERSIONS`. **Bump the
stamp only together with the re-verification** — a bumped stamp over stale
prose is worse than an honest mismatch, because the doctor then says nothing
at all.

## Reference files

- [`references/cli.md`](references/cli.md) — `op` command surface, secret
  reference grammar and query parameters, `op run`/`read`/`inject` details and
  precedence, app integration vs service accounts vs Connect, shell plugins,
  the SDKs.
- [`references/signing.md`](references/signing.md) — the SSH agent in depth:
  socket paths per platform, `agent.toml`, key selection and ordering,
  `IdentityAgent`, WSL forwarding, and the full signing setup.
- [`references/upstream.md`](references/upstream.md) — 1Password's dev
  operations: the developer portal, release cadence and channels for the app
  and the CLI, version numbering, where changelogs live, beta programs, and
  how breaking changes get announced. Read this before bumping `VERSIONS`.
