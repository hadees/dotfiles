# Routing Claude Code through claude-codex

`claude-codex` is a local proxy on `127.0.0.1:18765`. Pointed at it, Claude
Code sends requests for Claude models on to Anthropic unchanged and requests
for `gpt-*` models to Codex. This file is the **parity contract**: what a
routed session must do exactly as a direct one does before routing becomes
the default, and the tools that check it. Pinned release: `claude-codex`
**0.8.0**, built from source commit
`ead919ff0d8993696a496cce19ef31becf90260b`.

Only this contract, its harness, the installation steps and the service
definition exist so far. The `claude()` routing arrives in a later change,
which extends this file.

## Installation

The proxy is a Rust program installed by hand, at the pinned version, and
upgraded deliberately. Nothing installs or upgrades it automatically:
`update()` runs no Cargo or proxy command, and no chezmoi script does either.

The toolchain comes from the package lists: `rustup` in the `Brewfile` and in
`packages-apt.txt`, never on the `ephemeral` class. Homebrew's formula is
keg-only, so `dot_exports` puts `$HOMEBREW_PREFIX/opt/rustup/bin` and
`~/.cargo/bin` on `PATH` behind Homebrew's own `bin` and `sbin`, each only
when the directory exists. A distro without a `rustup` package skips it
(`packages-apt.txt` says which releases carry it) and gets the toolchain by
hand from https://rustup.rs.

```sh
rustup default stable
cargo install claude-codex --version 0.8.0 --locked --root "$HOME/.cargo"
"$HOME/.cargo/bin/claude-codex" --version
```

`--version 0.8.0` pins the release; `--locked` only makes the build use the
crate's own lockfile. `--root "$HOME/.cargo"` fixes the executable at
`~/.cargo/bin/claude-codex`, the path the service definition names. Moving
to a newer release means changing the pinned version here and in the parity
contract, then repeating acceptance.

## The service

On the `mac` class, on macOS, chezmoi deploys a user LaunchAgent,
`~/Library/LaunchAgents/local.claude-codex.plist`, that runs
`~/.cargo/bin/claude-codex serve --port 18765 --no-monitor` under
`KeepAlive`, 30 seconds between restarts. It binds `127.0.0.1` only, forwards
Claude requests to `https://api.anthropic.com`, and reads its configuration
from `~/.config/claude-codex`, whose managed `config.json` is `{}`: no model
aliases, effort overrides, review routing, endpoints or credentials. Provider
logins are another matter: when one is missing there, the proxy falls back to
its own default directory, so a login made with a standalone install is still
used. No other class gets the plist, a Mac without `claude-codex` installed
gets none either (it lands on the first apply after the install), and there
is no systemd unit.

It ships **inactive**: the plist has `Disabled` set, so a public-only apply,
or one before the proxy is installed, starts nothing. No chezmoi script and no
wrapper loads or starts it. The operator does that, after acceptance:

```sh
launchctl enable "gui/$(id -u)/local.claude-codex"
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/local.claude-codex.plist
launchctl bootout "gui/$(id -u)/local.claude-codex"    # stop it again
```

The proxy writes its request log, as JSON lines, to
`~/.local/state/claude-code-proxy/proxy.log`. A failure before logging begins
(a missing binary, a bad path) shows in
`launchctl print "gui/$(id -u)/local.claude-codex"` (last exit status) and
`launchctl list local.claude-codex`. Traffic capture stays off.

Where there is no launchd (Linux, WSL), run the same service by hand:

```sh
env CCP_BIND_ADDRESS=127.0.0.1 CCP_ALIAS_PROVIDER=anthropic \
    CCP_ANTHROPIC_BASE_URL=https://api.anthropic.com \
    CCP_CONFIG_DIR="$HOME/.config/claude-codex" \
    "$HOME/.cargo/bin/claude-codex" serve --port 18765 --no-monitor
```

`~/.config/claude-codex/config.json` deploys on every class except
`ephemeral`.

## Why transport alone is not parity

The proxy relays request bytes and headers, and streams the response back.
That is what the transport checks prove. It is not enough, because with a
custom base URL Claude Code changes its own behaviour: some client defaults
switch off unless set (fine-grained tool streaming, tool search, gateway
hint headers), token counting falls back when `count_tokens` is missing or
rejected, and what the client sends differs between releases. A proxy that
passes every byte-level check can still lose caching, token counts, tool
search or effort in a real session. Acceptance therefore also runs the real
client, in print mode and attended, against direct and routed launches, and
the result is only valid for the Claude Code, Codex and proxy versions it
recorded.

## The one accepted difference

Remote Control does not work through a custom base URL, so it is unavailable
in a routed session. That is the **only** accepted difference. Remote Control
must work through an explicitly announced direct launch
(`CLAUDE_CODEX_PROXY=0 claude`). Lost caching, token counting, tool search,
effort, usage reporting or any other direct workflow still fails acceptance.

## Commands

```sh
python3 tests/helpers/claude-proxy-parity.py transport --proxy-bin PATH
python3 tests/helpers/claude-proxy-parity.py assess --report PATH
```

Both print one JSON object. Exit `0` passed, `1` an observed failure, `2`
missing prerequisites, malformed or incomplete evidence, or a required check
that is blocked or skipped.

`transport` starts a loopback fixture upstream and the proxy on unused
ports, with an empty home, sanitized environment, dummy credentials, and
`CCP_ANTHROPIC_BASE_URL` pointing at the fixture. It never contacts a real
provider. A missing or non-executable binary yields all eight transport
checks `blocked` and exit `2`, never a green skip. The report always has
`eligible=false`: transport passing never makes anything eligible.

`assess` takes a complete **acceptance** report, recomputes the counts and
eligibility, and validates the whole check inventory. It adds a `problems`
array to the output naming each reason. It rejects: a non-acceptance scope, a
null or `unknown` version, a proxy version or source commit other than the
pinned pair, an empty feature inventory, duplicate, unknown or missing check
IDs, a `pass` without evidence, `accepted_difference` anywhere but
`interactive.remote-control`, counts that do not match the checks, and
`eligible=true` on a report that has not earned it.

## Report schema (version 2)

```text
schema_version: 2
scope: "transport" | "acceptance"
source_commit: string
claude_version: string | null
proxy_version: string
codex_version: string | null
feature_inventory: string[]
checks: [ { id, layer, status, reason, evidence: string[] } ]
counts: { pass, fail, blocked, skipped, accepted_difference }
eligible: boolean
```

- `layer` is `transport`, `cli`, `interactive` or `service`, and matches the
  first segment of `id`.
- `status` is `pass`, `fail`, `blocked`, `skipped` or `accepted_difference`.
- `evidence` lists paths or identifiers of artifacts kept outside the
  repository. A `pass` needs at least one entry. Credentials, transcripts,
  headers and captures never enter this repository.
- Acceptance reports need non-null `claude_version` and `codex_version`.
- `eligible` is true only when every required check passes, except that
  `interactive.remote-control` may be `accepted_difference`. That status
  needs evidence entries prefixed `direct:` (Remote Control works direct),
  `routed-refused:` (it is unavailable routed) and `opt-out:` (it works
  through the documented opt-out). If a release supports routed Remote
  Control, the check simply passes.
- `feature_inventory` is a list of slugs (`[a-z0-9-]`), one per direct
  workflow checked routed; each has a check `interactive.feature.<slug>`,
  and no feature check may exist outside the inventory.

## Required checks

Transport, run by `transport`:

| ID | Required behaviour |
| --- | --- |
| `transport.messages` | `/v1/messages?beta=true` reaches the upstream with path and query preserved. |
| `transport.count-tokens` | `/v1/messages/count_tokens?beta=true` works without generation-only fields such as `max_tokens`. |
| `transport.body` | Exact bytes survive: normal history, signed thinking, system ordering, unknown fields, tool schemas, one-hour cache fields, root effort and per-message effort. |
| `transport.request-headers` | Authorization, version, beta values, future `anthropic-*` headers and duplicate application-header values survive. |
| `transport.response-headers` | Status, error body, retry hints and every supplied unified-rate-limit header survive, on success and failure. |
| `transport.streaming` | Ordered events, pings and the final events arrive without being held until completion. |
| `transport.quota-429` | A quota rejection keeps its distinguishing body and headers. |
| `transport.throttle-429` | A transient throttle keeps its different body and headers. |

Transport framing (host, content length and encoding, hop-by-hop headers)
is excluded from header equality. Only valid Claude histories are tested:
the proxy repairs unsigned thinking left by an earlier Codex turn, which is
documented behaviour, not a regression.

Acceptance, filled in by later work against real sessions:

```text
cli.cache-read            cli.cache-ttl             cli.token-count
cli.tool-search           cli.effort                cli.provider-routing
cli.gpt-tool-roundtrip    cli.fable-handover        cli.route-modes
interactive.usage         interactive.context       interactive.fast
interactive.remote-control
interactive.direct-feature-inventory
service.lifecycle
```

An acceptance report holds all eight transport checks as well, plus one
`interactive.feature.<slug>` per inventory entry.

## Running the tests

`tests/claude-proxy-parity.bats` tests the assessor with synthetic reports
and the transport checks against an in-process reference proxy that is
faithful, or tampers in one named way (re-serialised body, dropped query,
dropped header, buffered stream, rewritten 429). It runs the real proxy
against the fixture only when `claude-codex` is installed, and skips cleanly
without it or without `python3`. Run it under bash 4 or newer, as the rest of
the suite:

```sh
PATH="$(brew --prefix)/bin:$PATH" bats tests/claude-proxy-parity.bats
python3 tests/helpers/claude-proxy-parity.py transport --proxy-bin "$(command -v claude-codex)"
```

The second command is the acceptance evidence for the transport layer.
