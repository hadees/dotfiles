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
can't be a node (public FQDNs, public IPs, localhost — zero calls), and
anything with a ProxyJump/ProxyCommand already (config or `-J`/`-o`: a
command-line `-o ProxyCommand` would silently override a configured
ProxyJump), and curl with `-x`/`--noproxy`/proxy variables set. The
destination comes from `ssh -G` (ssh's own parsing) — scp/sftp extract the
`[user@]host:` operand first — and for curl the first URL / bare host
argument, skipping the value of an option that takes one (a header or a form
field can hold a URL). A private (RFC 1918) IPv4 is asked about too: `peer_in` counts it when it
falls inside a subnet route a peer advertises (`PrimaryRoutes`, read from the
peers only; the daemons run `--accept-routes`), so a LAN behind a subnet
router is reachable away from it. The most specific route holding the address
decides (longest prefix; an exit node's `/0` never does), and what happens
next depends on whether this machine is *on* that route, meaning one of its
own interface addresses (`ifconfig`, else `ip -4 addr`) is inside it. Per
daemon, cwd's tailnet first:

| Case | Test | Verdict |
| --- | --- | --- |
| away | no interface address is in the route | this tailnet; direct if the app is on it, else the daemon's proxy |
| known LAN | an interface address is in the route, and a default gateway inside the route has a MAC listed in `tailnet-lan.<label>.gateway` | direct, whichever tailnet the app is on; later daemons are not asked; `tailnet route` exits 3 and prints nothing; `tailnet peer` exits 3 |
| overlap, not known | an interface address is in the route, no listed gateway | this tailnet's daemon proxy, **even when the app is on this tailnet**; tallied; `tailnet peer` still exits 0 |

The LAN's identity is its default gateway's MAC, read for nothing (`netstat
-rn -f inet` and `arp -an` on macOS, `ip -4 route show default` and `ip neigh
show` elsewhere; chosen by `os()`, not by fall-through) and compared after
normalising (macOS prints octets without leading zeros). It is checked only
when an interface address overlaps a route that holds the target, so a host
away from the route costs nothing extra. The SSID is not usable (macOS
redacts it without a signed app holding a Location Services grant, and
Ethernet has none), and a DHCP domain is whatever the network's owner chose.
The config holds only gateway MACs — `[tailnet-lan "<label>"] gateway = <mac>`,
repeatable, machine-local and overlay-supplied (`docs/private-overlays.md`) —
never an address range or a tailnet name: the prefix comes from what the
daemons advertise at run time, so a second copy cannot drift. A MAC is a
convenience, not a security boundary: anyone on a network can spoof the
gateway's, and the worst case is that a stranger's network is treated as the
known LAN and its addresses run direct. A value that is not six hex octets is skipped (`tailnet lan`
shows it as INVALID).

The default for an unlisted overlapping network is the tailnet because the
two errors are not symmetric: wrong at a known LAN nobody listed yet is a
hairpin through the subnet router (and needs `command ssh` when the router is
down), wrong the other way is a stranger's device at that address answering
`ssh`. A userspace daemon's proxy reaches the routed address whatever this
machine's interfaces are, so it works there, and for the tailnet the app is
on too (that daemon idles but is logged in). That is also why the
same-tailnet shortcut (direct when the system daemon is on the very tailnet
that vouches) is skipped on an overlap: macOS scopes the app's route to its
own interface when a local route has the same prefix, so "direct" there
means the local network. Linux does the opposite (a root tailscaled's table
52 outranks the main table), which predates this and is not addressed. On a
known LAN direct is the kernel's route and is right. Limits that remain: a
Docker or VM bridge overlapping a route has no gateway to list, so its
addresses go through the tailnet (`command ssh` for direct); WSL2's NAT mode
hides the real LAN, so it reads as away; a route narrower than the LAN that
leaves the gateway outside it is never known. Until a LAN's gateway is listed,
and after its router is replaced (a new MAC), that LAN is reached through its
subnet router.

`tailnet lan` prints the default gateway, its MAC and whether it is a known
LAN (with the line to add when it is not), the configured gateways, and a
`tally:` line. `tailnet route --explain <host>` keeps `route`'s exit status
and prints zero or one reason line, never the tailnet name, and tallies
nothing; the line exists only when a subnet route was involved. Every
unforced route that ends in the overlap case appends one byte to
`lan-unrecognised.count` and replaces `lan-unrecognised.last` (UTC time,
tailnet, route, host, tab-separated) in the state dir, like the lsof guard's
tally; a failed write changes nothing. Neither is a tailnet directory, so
`names` and `tailnet_active` do not see them. `tailnet-doctor` shows a `lan:`
block (the output of `tailnet lan`) only when a `tailnet-lan.*` key exists or
the tally is non-empty, and for a host a `subnet:` line under `route:` saying
which route and which case; its verdicts are `via <name>`, `direct (on a
known LAN)`, `direct (a subnet route of the tailnet the app is on)`. The curl
wrapper skips the value of `--interface`, `--dns-interface`, `--dns-ipv4-addr`,
`--dns-servers`, `--haproxy-clientip`, `--connect-to` and `--resolve`: since a
private IPv4 is node-shaped, an address given to one would otherwise send the
whole request through whichever tailnet routes it. `TAILNET=<name>` forces
that tailnet with the node check skipped (subnet routes the daemons can't
vouch for), and on an address inside a route this machine is on it forces the
daemon's proxy, never the kernel route; `command ssh` is the direct override.
`tailnet-as <name> <cmd…>` does that and
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
