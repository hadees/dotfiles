# SSH Integration, and `ssh://` URLs

Two separate things that both say "ssh". Keep them apart:

- **Shell integration** (`references/shell-integration.md`) is scripts *you*
  install on a host, in that host's rc file.
- **SSH Integration** is iTerm2 pushing an equivalent to a host **without
  installing anything there**, over the ssh connection it started.

## What SSH Integration is

The binary's own one-line description:

> Export environment variables and copy files to remote hosts seamlessly with
> SSH integration. Either configure a profile to use ssh or use `it2ssh` in
> place of `ssh`.

Two entry points:

1. **A profile whose Command is set to SSH** (Settings > Profiles > General >
   Command; the hostname and other ssh arguments go in the adjacent field).
   A per-profile **Configure** button opens a sheet that can turn SSH
   Integration *off* — falling back to the system `ssh` — and holds the list
   of environment variables to copy over and the files to upload on connect.
   This is also one of the two Command settings for which *Load shell
   integration automatically* is offered.
2. **`it2ssh <the same arguments as ssh>`** from an existing session. iTerm2
   puts it on `$PATH` for you; a dotfile that rebuilds `PATH` from scratch is
   why it sometimes is not found.

What the docs say about maturity, verbatim, and it is worth repeating before
recommending it:

> Consider SSH integration to be a beta quality feature. To take full
> advantage of it the remote host must have **Python 3** installed. It is not
> recommended for SSHing to non-Unix hosts.

### The two levels

The session variable `sshIntegrationLevel` reports which you have:

```
0  no ssh integration
1  basic ssh integration
2  full ssh integration with all features available
```

That maps exactly onto the mechanism below: **level 1 is the `sh` bootstrap**
(environment variables plus connection-time file copy), **level 2 is the
Python 3 "conductor"** — a framing protocol that carries metadata such as the
running job list and Composer filename completions alongside your interactive
session. No Python 3 on the remote means you stop at level 1.

### What it buys over plain ssh

- Shell integration on the remote **without installing anything there**.
- Status-bar components showing the *remote* host's CPU, jobs, and directory.
- **File transfer over the framing protocol instead of scp** — "generally more
  reliable because it doesn't require opening a new connection." This covers
  cmd-clicking a filename, `it2ul` and `it2dl`.
- `Shell > ssh > Download Files` — browse and download from the connected
  host without a second connection. Remote files also appear in open/save
  dialogs.
- `Shell > ssh > Disconnect`.
- `Session > Duplicate` reconnects to the same host.
- Auto Composer filename and command completion works over the connection.
- AI `View Manpages` can read the *remote* host's man pages, and the remote
  OS configuration is exposed so generated commands suit it.

The documented drawbacks: connecting takes longer, many features need Python
3 remotely, there is added typing latency that is noticeable on a slow link,
and the remote-side script uses CPU (mostly polling the job list).

## How `it2ssh` actually works

Read straight out of `/Applications/iTerm.app/Contents/Resources/utilities/it2ssh`
(189 lines of bash, worth reading when something misbehaves):

1. It fetches a **token from a unix socket** — the first that answers of
   `~/.config/iterm2/sockets/secrets`, `~/.iterm2/sockets/secrets`,
   `~/.iterm2-1/sockets/secrets`. Off macOS the token is the literal `none`.
2. It base64-encodes your full local environment and the ssh arguments, and
   emits three escape sequences:
   `OSC 1337 ; Env=report=all:<base64 env>`,
   `OSC 1337 ; it2ssh=<token> <uniqueid> <encoded> <ssh args>`, and
   `OSC 1337 ; SendConductor=v=3`.
3. It runs `/usr/bin/ssh <your args> -- <host> exec sh -c '<bootstrap>'`. The
   bootstrap does `stty -echo -isig`, echoes those escape sequences back up
   the pipe, then reads lines until `-- BEGIN CONDUCTOR --`, collects
   base64 until an ESC, decodes it and `eval`s it.
4. So **iTerm2 sends the "conductor" script down the connection and the
   remote `sh` evaluates it.** Nothing is installed on the host. On exit it
   emits `OSC 1337 ; EndSSH=<uniqueid>` and restores the tty.

Facts that follow from that, and that matter in practice:

- **`it2ssh` invokes `/usr/bin/ssh` directly**, via `SSH=${SSH:-/usr/bin/ssh}`.
  A shell *function* named `ssh` — like this repo's tailnet wrapper — is
  therefore bypassed entirely. What still applies is everything
  `/usr/bin/ssh` reads for itself: `~/.ssh/config`, so a configured
  `ProxyJump`/`ProxyCommand` works, and the 1Password agent via
  `IdentityAgent`. What does *not* apply is anything a wrapper injects on the
  command line. Override with `SSH=/path/to/wrapper it2ssh …` if you need to.
- **It refuses `-N`, `-n`, `-f` and `-G`** — "meant for interactive use via
  SSH only". (The message says "it2sh", a typo in the shipped script.)
- **It creates `~/.ssh/controlmasters/` on every run.** `CONTROL_PATH` is
  assigned right after and then never used anywhere in the script — a dead
  variable that still leaves a directory behind. Verified: exactly one
  occurrence in the 3.6.11 copy.
- `TERM=screen*` gets a tmux passthrough wrapper (`\033Ptmux;`) around every
  escape sequence, so it works inside tmux.
- Version skew is loud, not silent: "Out-of-date version of it2ssh detected.
  Please upgrade it2ssh." and "Future version of it2ssh detected. Please
  upgrade iTerm2."

## `ssh://` URLs

The bundle **declares** the scheme, so macOS can offer iTerm2 as a handler.
The full `CFBundleURLTypes` scheme list in 3.6.11, read off `Info.plist`:

```
ftp  gemini  gopher  http  https  mailto  news  nntp
ssh  telnet  titan  wais  whois  x-man-page
```

(Including `gemini` and `titan` — the Gemini protocol — and `x-man-page`,
which is how a man-page link opens in a terminal.)

Declaring a scheme is not the same as claiming it: macOS still picks one
handler per scheme, and iTerm2 does nothing with an `ssh://` URL until you
configure it. Three separate mechanisms, easily confused:

1. **Settings > Profiles > General > URL Schemes** — "You can configure a
   profile to handle a URL scheme, such as ssh. When a hyperlink is clicked
   on with that scheme, a new tab is opened with the selected profile. It is
   recommended that you set the command to `$$`, in which case an ssh command
   line will be auto-generated." The Command field also takes `$$URL$$`,
   `$$HOST$$`, `$$USER$$`, `$$PASSWORD$$`, `$$PORT$$`, `$$PATH$$`, and
   `$$RES$$` (everything after the scheme).
2. **Settings > General > Experimental > "Use SSH integration for ssh: URLs"**
   — "If enabled, use SSH integration when opening an SSH URL." Note the pane:
   *Experimental*, not AI and not Profiles. The internal flag is
   `_sshIntegrationForURLs`.
3. **Smart Selection** already recognises `ssh` among its default URI schemes
   (`references/workflow.md`), which is what makes an `ssh://` string in the
   terminal clickable in the first place.

There is also an advanced setting, verbatim from the binary — "Terminal:
Command to run when handling an `ssh://` URL." (key `sshURLsSupportPath`),
under Settings > Advanced.

Practical consequence on this machine: link routing sends everything to
Finicky, but Finicky routes to browsers. An `ssh://` link is handled by
whichever app macOS has registered for the scheme, and iTerm2 declares it.
If such a link does something surprising, that is where to look — and note
that mechanism 1 is per-profile, so the profile you pointed at the scheme
determines what actually runs.

## Which to use

| Want | Use |
| --- | --- |
| Marks, command status, directory tracking on a host you control | Install shell integration there |
| The same on a host you cannot or should not modify | SSH Integration (`it2ssh`, or a profile with Command = SSH) |
| Just a terminal on a remote host | Plain `ssh` — and on this machine that is the wrapped `ssh`, which does the tailnet routing `it2ssh` skips |

## Docs vs. the binary (3.6.11)

| Claim | Reality |
| --- | --- |
| `it2ssh` is documented | Not on iterm2.com at all — one of six bundled utilities the Utilities page omits. Its only prose description is the off-site GitLab wiki (`gitlab.com/gnachman/iterm2/-/wikis/SSH-Integration`, whose `.md` raw endpoint loads when the rendered page does not). The script itself is the real reference. |
| SSH Integration has a documentation page | It does not. `documentation-ssh.html` is a 404; the feature is a paragraph inside the Profiles > General > Command reference. |
| The one-page build is a complete grep target | It silently omits the Scripting Variables page body, so `sshIntegrationLevel` and every other variable are missing from it. |
| SCP config path `~/Library/Application Support/iTerm/ssh_config` | Applies to libssh2 transfers, not to `it2ssh`, which shells out to `/usr/bin/ssh` and uses `~/.ssh/config`. |
| `it2ssh` honours your `ssh` | It honours `/usr/bin/ssh` unless `$SSH` says otherwise. A shell function is invisible to it. |
