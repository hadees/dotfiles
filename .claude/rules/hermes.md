---
paths:
  - "**/dot_functions"
  - "**/tests/hermes.bats"
---

# Hermes (agent profiles)

The Hermes harness (NousResearch/hermes-agent) keeps per-agent state in
profiles (`hermes profile create <name>` — each its own HERMES_HOME with its
own config, approval rules, memory, and .env keys). The `hermes()` wrapper
in `.functions` picks the profile the way `claude()` and `wrangler()` pick
theirs, by machine-local git config the overlays supply: an explicit
`-p`/`--profile` first; else the per-repo pin `git config hermes.profile
<name>` (set in that repo's `.git/config` — a hardened profile for one
checkout); else the cwd's account — origin owner through the credential
pins — mapped by `hermes.profile.<account>`, so every repo of an account
runs that account's profile with no per-repo change; else passthrough to
hermes' own resolution. Whatever wins is injected as `-p <name>`. The two
keys are a section key and a `[hermes "profile"]` subsection entry and
never shadow each other. Optional `git config hermes.model <model>` appends
`--model <model>` (hermes CLI args outrank config — same
profile/memory/keys, different LLM; full isolation is a profile per
purpose, whose own config/.env carry that provider).

A pin and a mapping differ in what they refuse. In a pinned repo an
explicit `-p`/`--profile` naming a *different* profile is a loud error,
never an override (same stance as claude-as/wrangler; it was never a
working override anyway — hermes honours the first `-p` and the leftover
flag dies as an argparse usage error); the pinned name itself is a no-op.
Under a mapping an explicit `-p` is simply honoured — the mapping is a
default, the pin a statement — but a mapped profile nobody has created on
this machine is refused with the `hermes profile create` line, as
`wrangler()` refuses an uncreated mapped login: hermes' sticky default would
otherwise run with another identity's keys and memory. `command hermes` is
the bypass for both. The retired `hermes.launcher` pin is refused with its
migration printed, never silently ignored. `routes` marks a pin that
outranks a mapping with `*`, like its other columns.

**`hermes.worktree = true` keeps the agent out of every live checkout.**
With it set (machine-local; a repo's own `.git/config` can say `false`),
the wrapper adds hermes' own `--worktree` flag to every invocation made
inside a git work tree, so each chat runs in a throwaway worktree,
`<repo>/.worktrees/hermes-<id>` on branch `hermes/hermes-<id>`, removed at
exit unless it holds unpushed commits (hermes prunes leftovers older than a
day). That is hermes' hardcoded layout, not this repo's
`.claude/worktrees/` convention — there is no setting for the path — and
hermes appends `.worktrees/` to the repo's `.gitignore` the first time, so
this repo carries that line already. Measured on 0.19: the flag is an
error outside a work tree, so the wrapper adds it only inside one, and
non-chat subcommands (`mcp`, `profile`, …) accept and ignore it, so the
wrapper does not have to know which subcommand it is looking at. An
explicit `-w`/`--worktree` is never doubled. `hermes-doctor` has a
`worktree:` line.

Hermes never starts a model server — it only speaks HTTP to the profile's
`model.base_url` (auto-starting the server was `ollama launch`'s only real
job). So for a launch that talks to the model (a bare `hermes`, `chat`, or
one that starts with an option) the wrapper reads the effective profile's
`config.yaml` and, only when `model.provider` is ollama-ish AND `base_url` is loopback, probes the
port and starts `ollama serve` disowned with a bounded readiness wait when
nothing answers; a cloud profile (Anthropic/OpenAI/OpenRouter) or a
LAN/WireGuard ollama never waits on or spawns anything, and every failure
warns and falls open — hermes prints the real connection error. A first
argument shaped like a subcommand other than `chat` (`profile list`, `mcp …`:
the shape, as `claude()` tests it, because a list would go stale) or a
`--version`, `--help` or `-h` anywhere skips all of it, so asking hermes its
version never starts a server or waits for one.
`hermes-doctor` traces all of it for the cwd (pin, account, mapping, the
effective profile and its source, and its config, via the same
`hermes_profile`/`hermes_cfg_path` helpers the wrapper and `routes` call — the three cannot drift —
and, for a local-ollama profile, whether the server answers) without
starting anything; `doctor` includes it. Tests: `tests/hermes.bats` (stub
hermes/ollama/curl; fixture profile names only).

**`hermes_peer` is what the Claude Peers Hermes session runs.** It calls
`hermes` only where `hermes_profile` routes the directory (a pin or an
account mapping); anywhere else it prints one line and the pane stays a plain
shell. The gate cannot be left to the wrapper, which passes an unrouted
directory through to Hermes' own resolution — the sticky `active_profile`
would then run one account's profile in another account's repo. Isolation
follows `hermes.worktree` and is not forced, and a refusal (profile mapped but
not created, retired launcher pin) is the wrapper's own. With
`CLAUDE_PEER_HERMES_WAIT=1` (exported by `claude-peer hermes --wait`) a routed
directory first waits: on a terminal under Hermes's caduceus (`claude-peer art
--hermes --wait`, `claude-peer.md` has it), else, or when that has no figure to
draw, it loops `Hermes (<profile>): Return starts hermes here, q leaves
a shell`: Return runs `hermes`, `q` returns, anything else asks again; an
unrouted directory prints its one line without asking, and a `hermes_peer`
older than this ignores the variable and starts at once. `hermes-doctor` has a
`peer:` line saying which of the two the cwd gets.
