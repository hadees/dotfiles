---
paths:
  - "**/bin/executable_loginguard"
  - "**/tests/loginguard.bats"
---

# loginguard

A profile directory may only hold a login to its own organization. A
`/login` once stored the wrong account because the authorize URL names no
organization and Claude Code compared the result with nothing.
`bin/executable_loginguard` is that comparison. Its form is denyguard's: an
sh prelude, then `exec python3 -I - "$@"`.

## The pin

Supplied by the overlay that owns the profile, machine-local, keyed like
`claude.<dir>.browser`:

- `claude.<dir>.org`: one organization UUID. `<dir>` is spelled
  `~/.claude-<name>`; the expanded path is also accepted. Tilde form is
  looked up first, then expanded, after trailing slashes are stripped.
- `claude.<dir>.org-label`: optional text for messages.

This repo names no organization. A directory with no pin is never touched
(no python, no claude is started for it): a public-only clone has no
opinion, like the commit gate.

## The witness

`claude auth status --json`, field `orgId`, run in the profile's
environment (`CLAUDE_CODE_EXECPATH`, else `claude`; 8 second timeout; the
JSON is read whatever the exit status, since the CLI exits 1 when logged
out). Not the `oauthAccount` cache in `.claude.json`: the default
directory's copy lives in `~/.claude.json`, not in the directory, and the
cache has been seen disagreeing with the token. With `--profile DIR` the
call follows postbox's rule: `CLAUDE_CONFIG_DIR` unset for `$HOME/.claude`,
set to DIR otherwise. Without `--profile` the environment is passed
untouched and the directory is `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`.

## Verdicts

| Verdict | Condition | `verdict` exit |
| --- | --- | --- |
| `unpinned` | no `claude.<dir>.org` | 0 |
| `ok` | logged in via `claude.ai`, `orgId` equals the pin (case-insensitive) | 0 |
| `logged-out` | `loggedIn` false | 0 |
| `mismatch` | logged in, `orgId` differs, or any `authMethod` other than `claude.ai` (detail `auth-method:<method>`) | 3 |
| `unverifiable` | pinned, and none of the above can be established | 4 |

`unverifiable` reasons: `pin-not-a-uuid`, `no-python3`, `no-claude`,
`status-failed`, `status-not-json`, `no-org-in-status`,
`auth-method:<method>` (logged in by something other than `claude.ai`, with
no `orgId` to compare).

`verdict` prints one TAB line: verdict, pin, `orgId`, `loginExpiresAt`,
detail (the reason, or `other=<~dir>` when another directory's pin equals
the stored `orgId`). `explain` prints one sentence for `claude-doctor`.
`launch` prints `claude: REFUSED:` lines and exits 3 or 4; with
`--attended` it also says when the profile is logged out, or the login
expires within three days or has expired. `hook prompt` exits 2 to block a
prompt. `settings` prints the `UserPromptSubmit` entry for an overlay to
paste into a profile's `settings.json`, with its `exit 2` branch intact:
that branch is what blocks prompts when `~/bin/loginguard` is missing.

## Why it fails closed

Same reason as denyguard: the refusal is the point. A CLI update that
renamed `orgId` would otherwise switch the guard off without a sound.
Failing closed turns that into a visible refusal with a named reason and a
one-variable way through.

## What it cannot see

A login is checked when something asks. A session mid-turn can send one
request under a swapped login before the next prompt is blocked. A one-word
prompt such as `claude fix` is not checked at launch (the wrapper only
checks subcommand-shaped arguments out of the way). A hook that times out
does not block.

## Bypass and log

`CLAUDE_LOGIN_CHECK=0` bypasses `launch` and `hook prompt` for that launch
(logged as `bypassed`). `LOGINGUARD_LOG` overrides the events log, default
`${XDG_STATE_HOME:-~/.local/state}/loginguard/events.log`. One line per
event, six TAB fields: UTC time, event (`refused-launch`, `blocked-prompt`,
`bypassed`), directory in tilde form, pin, stored `orgId` or `-`, reason or
`-`. Organization names and email addresses are never written. A failed
write never changes a verdict or an exit status.

Tests use two fixture UUIDs and a stub `claude` that prints a fixture; the
real CLI is never asked.
