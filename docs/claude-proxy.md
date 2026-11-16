# Routing Claude Code through claude-codex

`claude-codex` is a local proxy on `127.0.0.1:18765`. Pointed at it, Claude
Code sends requests for Claude models on to Anthropic unchanged and requests
for `gpt-*` models to Codex. This file is the **parity contract**: what a
routed session must do exactly as a direct one does before routing becomes
the default, and the tools that check it. Pinned release: `claude-codex`
**0.8.0**, built from source commit
`ead919ff0d8993696a496cce19ef31becf90260b`.

This file holds the contract, its harness, the installation steps, the
service definition and how `claude()` routes (below).

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

## Routing

`claude()` decides the endpoint for every launch, inside the subshell that
already picks the profile, so the profile, its credentials, the arguments and
the exit status are unchanged. It sets nothing in the calling shell. The
decision (`claude_proxy_decide`) is made afresh each time, in this order:

1. A caller's own route stays: a nonlocal `ANTHROPIC_BASE_URL`, an
   `ANTHROPIC_UNIX_SOCKET`, or `CLAUDE_CODE_USE_BEDROCK`, `_VERTEX`,
   `_FOUNDRY` or `_ANTHROPIC_AWS` set to `1`, `true`, `yes` or `on`. Mode
   **external**. It outranks the opt-out: switching this proxy off must not
   dismantle an independent provider. `http://127.0.0.1:18765`, with at most
   one trailing slash, counts as ours only when the inherited
   `CLAUDE_CODEX_ROUTE=routed` marker comes with it (a parent session of ours
   launched this one); without the marker it is somebody's own proxy and is
   left alone.
2. `CLAUDE_CODEX_PROXY=0` goes direct (**opt-out**) and drops an inherited
   loopback URL.
3. `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` set: direct, reason
   `credential-override`, credentials untouched. The wrapper never sets
   either; they would break the subscription route.
4. Any `CLAUDE_CODEX_PROXY` value other than unset, empty, `0` or `1` goes
   direct (`invalid-mode`).
5. Otherwise it routes when `~/.cargo/bin/claude-codex` is executable and
   `GET http://127.0.0.1:18765/healthz` answers `200` with `{"ok":true}`.
   The probe is `command curl -q --noproxy '*'` with one-second connect and
   total limits, no redirects and no credentials. No executable is
   `not-installed`; no curl `missing-curl`; no answer `unreachable`; any other
   answer `unexpected-health`. A missing helper is `helper-error`.

A **routed** launch sets `ANTHROPIC_BASE_URL=http://127.0.0.1:18765` and, only
where the caller has not set them, `CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING=1`,
`ENABLE_TOOL_SEARCH=true` and `CLAUDE_CODE_GATEWAY_HINT_HEADERS=1`, which
Claude Code switches off behind a custom base URL. A **direct** launch has no
`ANTHROPIC_BASE_URL`. Every launch exports `CLAUDE_CODEX_ROUTE`
(`routed`, `direct`, `external`) and `CLAUDE_CODEX_REASON`, so a session can
say how it started. `--help`, `-h`, `--version` and `-v` anywhere in the
arguments skip all of it: no probe, no markers, no line.

Failing open is the point: a missing, stopped or confused proxy only ever
costs the GPT agents, and an attended launch says so in one line on stderr
(stdout is never touched):

```text
claude: direct by opt-out for Remote Control; GPT agents unavailable in this session.
claude: direct because proxy is unreachable; GPT agents unavailable in this session.
claude: external base URL preserved; GPT routing is unverified in this session.
```

(`missing-curl`, `unexpected-health`, `credential-override`, `invalid-mode`
and `helper-error` have their own wording; an external provider says
`external provider preserved`.) A routed launch prints nothing. Neither does a
clone that never opted in: a line is printed only when
`~/.cargo/bin/claude-codex` exists or `CLAUDE_CODEX_PROXY` is set (the opt-out
always counts), never for `not-installed`, and only on an attended launch (a
terminal, no `-p`, no subcommand), the gate of the wrapper's other notes.
`git config claude.proxy-check false` silences it. A launch is
the only moment the route changes: a daemon that dies later leaves the
session routed with its health unavailable, and one that recovers does not
turn a direct session into a routed one.

**Remote Control** needs a direct launch, the one accepted difference: start
it with `CLAUDE_CODEX_PROXY=0 claude`. The line above says why GPT agents are
absent from that session.

Helpers (all in `dot_functions`, all print nothing unless noted, all start
with `emulate -L zsh`):

| Helper | Does |
| --- | --- |
| `claude_proxy_probe` | Sets `REPLY` to `ok`, `missing-curl`, `unreachable` or `unexpected-health`; returns 0 only for `ok`. |
| `claude_proxy_decide` | Sets `reply=(route reason endpoint)` for a new launch; returns 2 when a helper it needs is gone. |
| `claude_proxy_session` | Reads the markers and the actual environment of the running session into the same array, never probing and never deciding. No markers is `unmarked-session` (route empty, returns 0); markers the environment contradicts are `state-mismatch` (route empty, returns 2). |
| `claude_gpt_ready MODEL` | Preflight for a `gpt-*` agent, from `claude_proxy_session` plus a probe. Prints `GPT_ROUTE_READY model=<id> auth=untested`, `GPT_ROUTE_UNAVAILABLE reason=<reason>` or `GPT_ROUTE_ERROR reason=invalid-model|helper-error`; returns 0, 1 or 2. Ready means routed and answering, not logged in or within quota. |
| `claude_proxy_external`, `claude_proxy_notice` | The external test shared by the two decisions, and the stderr line above. |

`claude-doctor` prints a `proxy:` line and a `proxybin:` line. In a session the
launch marked, `proxy:` reports that session (`scope=session`); in a Claude
Code session with no markers it says `unverified`; anywhere else it labels a
prediction `scope=next-launch`. Modes: `routed` (with `health=`), `direct` (with
its reason; the opt-out line names Remote Control), `external`, or `unknown`.
`proxybin:` gives the fixed path, the pinned version and the installed version
read from `~/.cargo/.crates.toml` (`unknown` when unreadable), without running the
executable; it proves neither that the executable works nor that the service
runs.

## GPT agents

A definition whose `model:` starts `gpt-` (today `plan-gpt`, `gpt-6-astra`, the
same planner as `plan-fable`) works only in a routed session. The orchestrator
runs `claude_gpt_ready MODEL` before dispatching one, never overrides the
definition's model in the Agent call, and does not dispatch on an unavailable
or error result (an absent helper, or output that disagrees with the exit
status, is `GPT_ROUTE_ERROR reason=helper-error`). Ready proves routing and
liveness, not login, entitlement or quota; a GPT agent cannot check for itself
before its first request. A step of a `plan-gpt` plan goes to `work-sonnet`
like any other, and the planner that owns the accepted report owns its
revisions.

The protocol lives in the shared memory's pointer-only topic
`dot_claude-shared/topics/gpt-seats.md` (the index lists it with its trigger;
the delegation topic is unchanged). Static checks in `tests/claude-agents.bats`
and `tests/claude-shared-memory.bats` pin its structure, not whether Claude
follows it.

**Handover.** `plan-gpt` is used when asked for by name, or once after a
terminal `plan-fable` whose returned error is a confirmed Fable allowance
failure: the rejected allowance `status="rejected"` with
`rateLimitType="seven_day_overage_included"`, the observed text `You've hit your
Fable limit` (2026-11-15; a `· resets <time>` suffix is not parsed), or
`Fable limit reached`. Matching is on the error, never on text quoted in the
brief or a report. `model_requires_usage_credits` or `consent_unanswered` alone,
a generic 429, overload, timeout, authentication or context failure, an
unexplained incomplete report and a successful substituted-model result do not
qualify, and nothing is classified while `plan-fable` still runs or consent
awaits the operator. The unchanged brief goes to one fresh `plan-gpt` after the
readiness check; the Claude fallback and usage-credit consent are untouched.
Every `plan-fable` that ends in failure, incomplete output or on a substituted
model ends with one line,
`GPT_HANDOVER attempted= dispatched= unavailable= reason=` (`fable-limit`,
`route-unavailable`, `not-fable-limit` or `unclassified`), and every `plan-gpt`
with `GPT_PLAN outcome=<complete|incomplete|failed> reason=<none|chatgpt-limit|auth|api-error|unclassified>`.
If ChatGPT is exhausted too, that is one GPT attempt and a stated failure: no
other `gpt-*` model, no bounce to Fable, no escalation.

**Claude-behaviour advice.** The planner body carries, for `plan-gpt` only, an
instruction block between `<!-- gpt-assumptions:start -->` and
`<!-- gpt-assumptions:end -->`: when the plan relies on how Claude reads, loads
or follows instructions, files, memory, tools or agent definitions, the report
has one `## Claude-behaviour assumptions` table (`ID`, `Assumption`, `Affected
steps`, `Basis / check`; IDs `CB1`, `CB2`, ...) before `## Unverified`, and
otherwise no such section. The orchestrator hands a nonempty section, verbatim
plus a fixed read-only instruction, to a fresh built-in `claude-code-guide`
invoked with `model: opus`, and nothing else from the plan. The reply is one
JSON object with an `agree`, `disagree` or `unknown` verdict per ID. A
`disagree` goes back to `plan-gpt` to revise; `unknown` is acceptable only when
the report already lists the dependency under `Unverified` and no step relies
on it first; an unavailable or malformed advisor leaves the gate unresolved and
nothing substitutes for it. Each assessed revision ends with
`GPT_ADVISOR dispatched= assumptions= agree= disagree= unknown= outcome=`
(`empty`, `agree`, `revise`, `unknown`, `unavailable` or `protocol-error`). It is
advice on Claude's behaviour, not a verdict on how Claude will behave in every
session.

Whether the account really delivers the allowance signals, and whether the
orchestrator follows the protocol, are live acceptance checks. The scenarios,
each an input to the existing `cli.fable-handover`, `cli.provider-routing` and
`cli.gpt-tool-roundtrip` evidence:

| Scenario | Required observation |
| --- | --- |
| The observed Fable-limit error, before output | One unchanged-brief GPT handover. |
| The same error after partial output | Wait for the terminal incomplete result, then one handover. |
| Generic throttle, auth error, quota wording only quoted in the brief, successful substitution | No handover. |
| Consent still pending | No handover and no automatic answer. |
| Helper absent or route unavailable | Counted decline; no GPT Agent call. |
| Fable and ChatGPT both exhausted | One GPT attempt, an explicit terminal failure, no alternate GPT model or planner bounce. |
| GPT plan with no Claude-behaviour dependency | No assumptions section and no Opus call. |
| Nonempty assumptions section | Fresh guide invocation on Opus; payload is the section plus the fixed instruction. |
| Advisor disagrees | Revision goes to GPT; no worker starts on the disputed plan. |
| Advisor returns unknown | The dependency stays visible and is verified first or removed by the planner. |
| Advisor absent, quota-limited or malformed | Counted unresolved gate, no automatic substitution. |
| Revised report | One new assessment; none for an unchanged report. |

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
