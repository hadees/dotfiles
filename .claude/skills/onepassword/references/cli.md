# The `op` CLI

Command surface, secret-reference grammar, and the three ways to authenticate.
Verified against the `op` version in `../VERSIONS`, both from `op --help` on
this machine and from `https://www.1password.dev/cli/reference`.

## Contents

- [Command surface](#command-surface)
- [Secret reference syntax](#secret-reference-syntax)
- [`op read`](#op-read)
- [`op run`](#op-run)
- [`op inject`](#op-inject)
- [Authentication: three models](#authentication-three-models)
- [Service account limits](#service-account-limits)
- [Environment variables](#environment-variables)
- [Shell plugins](#shell-plugins)
- [Config directory](#config-directory)

## Command surface

Management commands: `account`, `connect`, `document`, `events-api`, `group`,
`item`, `plugin`, `service-account`, `user`, `vault`.

Commands: `completion`, `inject`, `read`, `run`, `signin`, `signout`,
`update`, `whoami`.

Global flags worth knowing: `--account` (or `OP_ACCOUNT`), `--cache`
(default on, **not available on Windows**), `--config <dir>`, `--debug`,
`--format human-readable|json`, `--iso-timestamps`, `--no-color`, `--session`.

Two facts that save round-trips and rate limit:

- Every name in a reference may instead be a **26-character unique ID**.
- Passing IDs rather than names cuts most commands to a single request.

Get a field's canonical reference programmatically rather than assembling one
by hand:

```bash
op item get <item> --format json | jq -r '.fields[].reference'
```

In the desktop app the same thing is right-click a field →
**Copy Secret Reference**.

## Secret reference syntax

Canonical docs: `https://www.1password.dev/cli/secret-reference-syntax`

```
op://<vault>/<item>/<field>
op://<vault>/<item>/<section>/<field>
op://<vault>/<item>/<file>                        # a file attachment
op://<vault>/<item>[/<section>]/<field>?attribute=<value>
op://<vault>/<item>[/<section>]/<field>?ssh-format=openssh
```

The section is optional and **positional**: three segments mean
`vault/item/field`, four mean `vault/item/section/field`.

**There is no percent-encoding scheme.** This is the trap, because URI-shaped
syntax invites the assumption that there is one. Instead:

- References are **case-insensitive**.
- Legal characters are `a-z A-Z 0-9`, plus `-`, `_`, `.`, and **space**.
  Spaces are fine — just quote the whole reference in the shell.
- **Any segment containing anything else — a `/` above all — must be replaced
  by that object's unique ID.** There is no escape sequence to reach for. A
  field literally named `test/` is only addressable by ID.

Query parameters (`attribute`, alias `attr`):

| On a field | On a file attachment |
|---|---|
| `type`, `value`, `id`, `purpose` (`username`/`password`/`notes`), `otp` | `type`, `content`, `size`, `id`, `name` |

Plus `ssh-format=openssh` on an SSH key's private-key field, to get OpenSSH
PEM rather than the default format.

Shell variables interpolate inside a reference, which is how one `.env` serves
several environments:

```bash
DB_PASSWORD=op://$APP_ENV/db/password
```

## `op read`

One secret to stdout.

```bash
op read op://<vault>/<item>/<field>
op read "op://<vault>/<item>/one-time password?attribute=otp"
op read --out-file ./key.pem op://<vault>/<item>/key.pem
```

Flags: `-o/--out-file`, `--file-mode` (**default 0600**), `-n/--no-newline`
(matters when piping a secret into something that would choke on the
newline), `-f/--force`.

## `op run`

The project pattern: load secrets as environment variables for the lifetime of
one subprocess, from a file that contains only references and is therefore
safe to commit.

```bash
echo 'DB_PASSWORD=op://<vault>/<item>/password' > .env
op run --env-file=./.env -- <command>
```

Details that bite:

- **Secrets printed to stdout/stderr are masked by default.** `--no-masking`
  turns that off. If a value "isn't being set", check masking before
  suspecting the reference.
- **Precedence, highest first: `--env-file` files, then shell environment
  variables.** Among multiple `--env-file`s, the **last** wins.
- A variable expanded by the *calling* shell expands before `op run` gets to
  substitute it. Run the expanding command in a subshell:

  ```bash
  MY_VAR=op://<vault>/<item>/field op run --no-masking -- sh -c 'echo "$MY_VAR"'
  ```

## `op inject`

A config file templated with references, resolved to a real file.

```bash
op inject -i config.yml.tpl -o config.yml
```

The template placeholder is `{{ op://... }}`.

**This collides head-on with Go templating**, which matters here: chezmoi
parses `private_dot_extra.tmpl` as a Go template, where `{{` is an action
delimiter. A chezmoi-managed file cannot use `op inject` syntax — it uses
`onepasswordRead` instead (see `../SKILL.md`). Do not convert between them.

`--file-mode` defaults to 0600 here too. Delete the resolved file when done;
unlike `op run`, this one writes plaintext to disk.

## Authentication: three models

|  | Desktop app integration | Service account | Connect server |
|---|---|---|---|
| Docs | `/cli/app-integration` | `/service-accounts` | `/connect` |
| Auth | biometric / system unlock via the local app | `OP_SERVICE_ACCOUNT_TOKEN` | `OP_CONNECT_HOST` + `OP_CONNECT_TOKEN` |
| Self-hosted | — | no | yes |
| REST API | no | no | yes |
| Rate limited | — | **yes** | no |
| Latency | — | higher | low (caches locally) |

**Precedence: the Connect variables outrank `OP_SERVICE_ACCOUNT_TOKEN`.**

This machine uses the **desktop app integration** — turned on in the app under
Settings → Security (biometric unlock) and Settings → Developer → "Integrate
with 1Password CLI". `op signin` is idempotent and only prompts when the
session has actually lapsed. Which account it uses resolves as `--account`,
then `OP_ACCOUNT`, then the most recent `op signin` in any terminal.

Without app integration, `op signin --raw` emits a session token instead, to be
carried in `OP_SESSION_<id>` or `--session`.

Service account tokens are prefixed **`ops_`** — deliberately, so secret
scanners can spot them. Note that a service account **cannot reach the
built-in Personal / Private / Employee vault at all**, which surprises people
migrating a working desktop-integration script to CI.

## Service account limits

Only relevant if a service account is ever introduced here, but the shape is
worth knowing before designing around one.

- Max 100 service accounts per 1Password account.
- Hourly per token: 10,000 reads / 1,000 writes on Business; 1,000 / 100 on
  the other plans. Daily per account: 50,000 (Business), 5,000 (Teams), 1,000
  (individual/Families). Over the limit is `429`.
- Check usage with `op service-account ratelimit`.
- Commands cost more than one request each: `op read` and `op item get` are 3
  reads apiece; `op item edit` and `op item delete` are 5 reads + 1 write.
  Using IDs instead of names collapses most of these to one.
- **Unsupported entirely**: `op connect`, `op group`, `op events-api`,
  `op vault edit`, and the `op user` provisioning verbs (`provision`,
  `confirm`, `suspend`, `delete`, `recovery`).
- Verify you are one with `op user get --me` → `Type: SERVICE_ACCOUNT`.

## Environment variables

`OP_ACCOUNT`, `OP_BIOMETRIC_UNLOCK_ENABLED`, `OP_CACHE`, `OP_CONFIG_DIR`,
`OP_CONNECT_HOST`, `OP_CONNECT_TOKEN`, `OP_DEBUG`, `OP_FORMAT`,
`OP_INCLUDE_ARCHIVE`, `OP_ISO_TIMESTAMPS`, `OP_RUN_NO_MASKING`, `OP_SESSION`,
`OP_SERVICE_ACCOUNT_TOKEN`.

None of these belong in `~/.extra` — see the routed-token rule in
`../SKILL.md`. `OP_SERVICE_ACCOUNT_TOKEN` in particular would silently take
over every `op` call in every shell, including ones meant to run as you.

## Shell plugins

`op plugin` authenticates *other* CLIs from 1Password instead of from
plaintext dotfiles: `op plugin init <tool>`, then that tool's credentials come
from the vault behind a biometric prompt. Roughly 80 tools are supported;
docs at `https://www.1password.dev/cli/shell-plugins`.

Worth a deliberate note: **this overlaps with the per-repo wrappers in
`~/.functions`** (`gh`, `wrangler`, `claude`, `hermes`), which route by *which
account the cwd belongs to*. A shell plugin for one of those tools would
inject a single credential regardless of cwd — the same failure mode as
exporting a routed token from `~/.extra`. If a plugin is ever introduced for a
tool this repo already wraps, that interaction needs deciding first.

## Config directory

`~/.config/op/` on this machine, holding `config` and `op-daemon.sock`. `op`
also accepts `~/.op/config` and `~/.config/.op/config`, and `--config` /
`OP_CONFIG_DIR` override.

With app integration on, the `accounts` key in that config is empty — accounts
come from the desktop app, not from the CLI's own config. So an empty-looking
`config` is not evidence of a problem, and `op account list` answering while
`op whoami` says "account is not signed in" is the normal signed-out state.
