---
paths:
  - "**/bin/executable_tailnet"
  - "**/tests/tailnet.bats"
---

# Tailnets (two Tailscale networks at once)

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
