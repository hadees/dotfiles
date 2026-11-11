---
paths:
  - "**/bin/executable_remote-mcp"
  - "**/tests/remote-mcp.bats"
---

# Remote MCP servers (`remote-mcp`)

`claude mcp add` covers a public server with a static header. **`bin/remote-mcp`**
covers the one you run yourself: a streamable-HTTP server behind a bearer
token that must not sit in a config file, possibly reachable only on a
tailnet the Tailscale app is not on. Machinery here, every name in overlay
git config — the public repo names no server:

```gitconfig
[remote-mcp "<server>"]            # the name sessions use it by: it becomes
                                   # the tool prefix, mcp__<server>__*
	url     = https://host/mcp       # required
	token   = <profile-dir> <1Password secret reference>
	                                 # repeatable, one per profile; a profile
	                                 # with no pin is not connected
	tailnet = <name>                 # optional: relay through this tailnet
	port    = <n>                    # optional: the forwarder's loopback port
	health  = <path>                 # optional: a path `check` relays verbatim
```

Name the server for its **role**, not the project behind it: the prefix is
written literally in agent `tools:` lists and in shared memory, both public,
and a role name survives replacing what answers to it. Two overlays may each
add `token` lines to one section, so each pins only its own profiles.

Three measurements on Claude Code 2.1.296 shape it:

- **`claude mcp add-json` keeps `headersHelper`; `claude mcp add` has no flag
  for it.** The entry names `~/bin/remote-mcp headers`, and `connect` reads
  the written entry back rather than trusting the exit status.
- **The helper is told who is asking**: `CLAUDE_CODE_MCP_SERVER_NAME` and
  `CLAUDE_CONFIG_DIR` (unset for the default directory) are in its
  environment, so one helper serves every server and profile. It reads that
  profile's token from 1Password at connect time and prints one header; the
  token never lands on disk. **It gets about ten seconds.** Past that the
  request goes out with no `Authorization` header at all and the server
  answers 401 — so an unanswered 1Password approval looks like a bad token.
- **The MCP client honours `HTTPS_PROXY`, but only process-wide**: the API
  connection went through it too, and every command the session runs would
  inherit it. So a server with `tailnet` set gets a forwarder of its own — a
  python3-stdlib plain-HTTP listener on loopback that relays each request
  over TLS through that tailnet's userspace daemon (`tailnet port`), so the
  certificate and the `Host` the far side sees are the real name's. The
  profile is registered against the loopback URL.

The forwarder holds no secret, answers only loopback `Host` names, and
refuses anything carrying an `Origin` header (a web page can reach loopback).
That loopback hop is plain HTTP and the forwarder is recognised by a line
anyone could answer, so it assumes what the tailnet daemons' unauthenticated
loopback proxies already assume — a single-user machine. Do not pin a
`tailnet` server on a host other people log in to as it stands.
Nothing installs or supervises it: `headers` starts it detached when the port
is not answering, with a bounded wait, the way the hermes wrapper starts
`ollama serve`. It answers `/.remote-mcp` with the server, upstream and proxy
it was started for, which is how a forwarder left over from an older config
is told from the right one and replaced. Its port has no public default:
`connect` takes the first free one from a base and records it under
`~/.local/state/remote-mcp/<server>/`, because the registered URL has to stay
put.

Unconfigured it is inert, on every machine class: `status` is one line,
`headers` fails without calling `op`, nothing runs at apply. `connect` is a
manual, once-per-machine step like `postbox connect`. `status` and
`remote-mcp-doctor` (in `doctor`) read config and loopback only; `remote-mcp
check <server> [profile-dir]` is the one that reads a token and asks the
server, and it relays the `health` body verbatim rather than interpreting a
vocabulary that is the server's own. Commands: `connect|disconnect
[server...]`, `status`, `check`, `headers`, `forward <server>`, `dir`. Tests:
`tests/remote-mcp.bats` (stub op/claude/tailnet/curl, sandboxed HOME and git
config; the forwarder runs for real against a dead far side).
