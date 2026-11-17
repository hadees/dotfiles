# Claude delegation notes

Measurements and provenance behind the rules in
`dot_claude-shared/topics/delegation-and-model-routing.md` ("Delegation and
model routing", always loaded) and `dot_claude-shared/topics/delegation-reference.md`
(read on demand). Every rule stays in one of those two files; this page holds
only what a session does not need in order to act, and loads only when read.

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

Moved from the lever-order rule (it sat in front of "`/fast` buys speed, not
savings"):

> Effort: measured `medium` matched default quality on knowledge work at
> 70–85% of the cost;

## Spans moved out of the delegation topics

Each section below is named after the rule it was cut from. The quoted spans
were taken out of the topic file word for word, so a rule reads shorter there
and nothing is reworded; a leading dash, colon or semicolon is the span's own
punctuation. The one edit that is not a move: in the first rule "So a feature"
became "A feature", because the sentence before it is below.

### The main conversation is the orchestrator

> Anthropic measured the orchestrator-plus-cheap-workers split: it pays only
> when there is bulk to fan out — many independent pieces — and on one
> dependent chain "the coordinator's model alone at lower effort came out
> ahead in every measured case".
>
> (a subagent's output stays in its own context; only its short reply comes
> back, and the orchestrator's context is re-sent on every later turn)

### Five shared definitions

> Planning with Fable and implementing with Sonnet is the advisor pairing
> Anthropic measured as "within noise of the frontier model alone at medium
> effort, at about the same cost", and the review seat duplicates the Codex
> and Gemini seats that already run.
>
> : those inherit the main conversation's model, and the wrapper's
> `CLAUDE_CODE_SUBAGENT_MODEL` does not move them (documented)

### Once `plan-fable` has it

> Learned 2026-09-24: with the rule above alone, a session planned with
> `plan-fable`, then built the feature itself and changed the plan on the
> way; a skill cannot carry the fix, since it loads only when it triggers
> and this always-loaded rule wins.

### Escalation is a rule, not a mood

> — a third try at the same seat is the expensive path, and so is a Fable
> pass on something not yet tried twice
>
> Handing a half-done fix back to a cheaper seat costs a fresh context that
> shares no cache — the split measured as a loss.

### Every seat reports the same way

> — what lands here is re-sent on every later turn
>
> ; a worker-spawned reviewer is a duplicate seat at full cost

### Do not change what is being researched

> Interim fixes restart CI, invalidate what the researchers read, and get
> redone (learned 2026-09-17, three pushes into two running audits).

### Effort is fixed in the agent file

> (verified 2026-09-17)
>
> (tested by superpowers; Anthropic's authoring reference says the same)

### The wrapper exports four defaults

> (subagents default to a five-minute cache, and a session on usage credits
> drops the main conversation to five minutes too)

### Cache discipline

> (rewind truncates to a prefix that is already cached)
>
> (~7× a normal session)

### Lever order

> per-file detail in path-scoped rules (`.claude/rules/`) rather than skills,
> whose descriptions are dropped from the listing without warning
