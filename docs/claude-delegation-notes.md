# Claude delegation notes

Measurements and provenance behind the rules in `dot_claude-shared/CLAUDE.md`
("Delegation and model routing"). Every rule stays there, in the always-loaded
file; this page holds only what a session does not need in order to act, and
loads only when read.

## Ponytail

Ponytail is installed per profile (marketplace `DietrichGebert/ponytail`,
plugin `ponytail@ponytail`) — the one style skill that ships a benchmark at
all, and it is the vendor's own, not an independent one: real headless Claude
Code sessions editing a seeded codebase, 12 one-line tickets scored on diff
size plus 7 tasks scored on whether the code survives adversarial input,
Haiku 4.5, n=4. It is not this machine, this model, or this work, and nothing
here is a saving until `/usage` moves.

## Terminal title

`CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` is exported only where
`claude.terminal-title false` is set (machine-local, overlay-supplied, under a
`mac` machine-class guard where the shim is wired), so Claude's own tab titles
do not displace the repo name. The mechanism is in
`.claude/rules/cc-status-shim.md`.

## Metering on Max

Verified 2026-09-17: one weekly envelope; separate sub-limits for Opus and for
"all other models"; Fable draws the same pool, capped at half of it, then
pay-as-you-go credits behind a consent prompt. `[1m]` is a credits-gated
entitlement (the API has no long-context premium, the plan does).

## Lever order

Behind "input hygiene": this repository's CLAUDE.md was 20,659 words before it
was split into path-scoped rules and is 2,359 now. A CLAUDE.md is paid on every
session start, `/clear`, compaction and non-`omitClaudeMd` spawn, which made it
the biggest number on the table. Skills are the wrong home for per-file detail
because every skill's description is injected each turn against a listing
budget, and the least-used descriptions are dropped without a warning.

Behind "loop hygiene": an example of a `PreToolUse` rewrite for a noisy command
is appending `| grep -E 'FAIL|ERROR' | head -100` before it runs.
