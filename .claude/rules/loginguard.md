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
| `mismatch` | logged in, `orgId` differs, or any `authMethod` other than `claude.ai` outside a Desktop session (detail `auth-method:<method>`) | 3 |
| `desktop` | a Claude Desktop Code-tab session whose credentials name no organization (detail `desktop:no-org`) | 0 |
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
prompt. `settings` prints both hook entries for an overlay to paste into a
profile's `settings.json`: `UserPromptSubmit`, whose `exit 2` branch is what
blocks prompts when `~/bin/loginguard` is missing, and `Notification`,
matcher `auth_success`.

`launch` is for the `claude()` wrapper to call; the wrapper does not call it
yet (a later step), so today only the hooks act.

## The removal

`after-login` takes the verdict. Only a `mismatch` with no `auth-method:`
detail acts, that is `authMethod` `claude.ai` and a different `orgId`: it runs
`<claude> auth logout` under the same environment rule as the status call,
asks again, and when the profile is now `logged-out` logs `removed-login`
and prints `claude: REMOVED the login just made:` lines (exit 3); when it is
not, logs `remove-failed` and says the wrong login is still stored and
`claude auth logout` must be run by hand (exit 3). `unverifiable` removes
nothing (exit 4): a status the CLI could not produce must never log a
profile out. `ok`, `logged-out` and `unpinned` are silent exit 0.
`CLAUDE_LOGIN_CHECK=0` removes nothing (logged as `bypassed`).

`hook auth` is the same action with all output discarded and exit 0: a
`Notification` hook's stderr and exit status are ignored by Claude Code.
The session that saw "Login successful" learns why it is logged out from
`hook prompt`: when the verdict is `logged-out` and the events log holds a
`removed-login` for this directory under 600 seconds old, it exits 2 with a
sentence saying the login was to another organization and was removed.

Logging out resets Claude Code's first-launch setup for that directory
(documented). A `mismatch` by `authMethod` (for example an `oauth_token`
environment credential, whatever its `orgId`, outside a Desktop session) still blocks prompts and
launches, but `after-login` never logs out for it: an environment token says
nothing about the login that is stored, which may be the right one. It
prints `nothing removed` and exits 3.

An uncaught exception in the script (an old Python, say) is caught at the
end: it logs `internal-error`, prints `internal error` on stderr, and exits
2 for `hook prompt`, 4 otherwise (`hook auth` stays 0 and silent). It never
logs out from there.

## Claude Desktop's Code tab

Desktop starts the CLI for a Code-tab session with
`CLAUDE_CODE_ENTRYPOINT=claude-desktop` and `CLAUDE_CODE_OAUTH_TOKEN` set to
the app's own token. The stored login is not what that session uses, and the
status then reports `authMethod` `oauth_token` and no `orgId`. Hooks from the
profile's `settings.json` do run there.

A session is recognised as Desktop only when **both** hold: the entrypoint is
exactly `claude-desktop`, and the status says `oauth_token`. The entrypoint
alone changes nothing (a terminal that inherited it still has its stored
login compared); `oauth_token` alone is refused as above (`mismatch`,
`auth-method:oauth_token`, or `unverifiable`). `claude-desktop-3p` and
Cowork's `local-agent` are not recognised. The `logged-out`, `pin-not-a-uuid`
and status-failure verdicts are decided first, as always.

The organization of a Desktop session is the first of: the status's `orgId`
(reason `desktop:status-org`), then `CLAUDE_CODE_ORGANIZATION_UUID`, which
Desktop exports for its own sign-in (reason `desktop:env-org`), each only
when UUID-shaped. With one, it is compared with the pin: equal is `ok` and
silent, different is `mismatch`, blocked, and the message gives the Desktop
advice (sign that window in to the pinned organization, or open the folder in
the right instance), never `claude auth login`, which cannot change a Desktop
session. With none the verdict is `desktop` (reason `desktop:no-org`): not
checked. The Desktop instance's own sign-in is the boundary there.

`desktop` warns on every prompt and does not block. `hook prompt` prints one
JSON line `{"systemMessage": ...}` on stdout and exits 0, logs `warned-prompt`.
That is the only shape that neither blocks nor lands in the model's context:
plain stdout from a `UserPromptSubmit` hook is added to Claude's context, and
under `onFailure: "block"` any exit code but 0 or 2 (and unparseable JSON)
counts as a failure and blocks. `launch` writes one `claude: WARNING:` line,
logs `warned-launch`, exits 0. `explain` begins `DESKTOP (not checked):`.

Nothing is ever logged out in a Desktop session (`after-login` and
`hook auth` remove nothing, a Desktop mismatch prints `nothing removed`):
the stored login is not what the session uses, and may be the right one.
`CLAUDE_CODE_ACCOUNT_UUID`, `CLAUDE_CODE_USER_EMAIL` and the token are never
read or logged.

What it cannot tell: which of several Desktop instances this is (the
directory, `CLAUDE_CONFIG_DIR`, is the instance's identity, and the pin is
read under it); and anything at all if the hook's environment has had the
token removed (`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`), in which case the status
reports the stored login and that is what gets compared. A Code-tab prompt
wrongly blocked has two causes, both named in the message: the status call
cannot run from Desktop's hook environment, or Desktop exports a different
UUID than the CLI reports for the same organization. The way through is
`CLAUDE_LOGIN_CHECK=0` in that one instance's environment, never a shell
profile.

Evidence, read not run live: Desktop 5.1231.2's bundle sets the entrypoint,
the token and the two UUID variables; Claude Code 2.1.321 (Desktop's copy) and
2.1.322 print no `orgId` for `oauth_token`. Whether the Code tab displays a
`systemMessage`, and whether the hook sees the token, are unverified.

## Why it fails closed

Same reason as denyguard: the refusal is the point. A CLI update that
renamed `orgId` would otherwise switch the guard off without a sound.
Failing closed turns that into a visible refusal with a named reason and a
one-variable way through.

## What it cannot see

A login is checked when something asks. A session mid-turn can send one
request under a swapped login before the next prompt is blocked. A one-word
prompt such as `claude fix` will not be checked at launch once the wrapper
calls `launch` (it will only check subcommand-shaped arguments out of the
way). A hook that times out does not block.

## Bypass and log

`CLAUDE_LOGIN_CHECK=0` bypasses `launch` and `hook prompt` for that launch
(logged as `bypassed`). `LOGINGUARD_LOG` overrides the events log, default
`${XDG_STATE_HOME:-~/.local/state}/loginguard/events.log`. One line per
event, six TAB fields: UTC time, event (`refused-launch`, `blocked-prompt`,
`bypassed`, `removed-login`, `remove-failed`, `warned-prompt`, `warned-launch`, `internal-error`), directory in tilde form, pin, stored `orgId` or `-`, reason or
`-`. Organization names and email addresses are never written. A failed
write never changes a verdict or an exit status.

Tests use two fixture UUIDs and a stub `claude` that prints a fixture; the
real CLI is never asked.
