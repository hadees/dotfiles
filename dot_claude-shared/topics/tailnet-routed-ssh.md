## Tailnet-routed ssh, scp, sftp, and curl

- `ssh`, `scp`, `sftp`, and `curl` are wrapper functions from `.functions`,
  defined inside Claude Code's Bash tool too. A destination that is a node
  of a tailnet the Tailscale app is *not* currently on is routed through
  that tailnet's always-on userspace daemon (ssh gets a `ProxyCommand`,
  curl a SOCKS proxy). A node of the app's own tailnet, a public host,
  localhost, or anything already carrying a ProxyJump/ProxyCommand or an
  explicit curl proxy runs untouched.
- The wrappers fail open: a broken helper leaves the command running
  direct, so a routing problem looks like an ordinary connection failure.
  `tailnet-doctor [host]` traces the decision for a host; `TAILNET=<name>`
  forces one tailnet, `tailnet-as <name> <cmd…>` does that and exports the
  proxy variables for any proxy-aware tool, and `command ssh` bypasses the
  wrapper entirely.
