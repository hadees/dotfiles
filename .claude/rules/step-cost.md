---
paths:
  - "**/bin/executable_step-cost"
  - "**/tests/step-cost.bats"
---

# What a session or a task cost (`step-cost`)

`bin/executable_step-cost` (`~/bin/step-cost` once deployed) reads the
transcripts a profile already keeps and prints numbers. It writes nothing,
and it prints numbers, timestamps and session names only, never a prompt or a
reply, so one profile's output can go into a report written from another.

```
step-cost sessions [--since DAYS] [--dir PROFILE_DIR]
step-cost file TRANSCRIPT...
```

`PROFILE_DIR` is `--dir`, else `$CLAUDE_CONFIG_DIR`, else `~/.claude`; `DAYS`
is 7. Claude Code deletes transcripts after `cleanupPeriodDays` (30 unless a
profile says otherwise), so a baseline has to be taken before that.

## Where the numbers come from

Shapes observed at Claude Code 2.1.325; a later release that moves them
makes a column print zeros, not fail.

- A main transcript is `<profile>/projects/<project>/<session>.jsonl`; its
  subagents are `<session>/subagents/*.jsonl`.
- `sessions` counts only records stamped inside the window, so a long-lived
  session shows what it did in the window. A transcript with no record in it
  has no row.
- The name is the last `agent-name` record, else the last `custom-title`,
  else `-`. `role`: `lead` and `secretary` by the name's suffix, `slot` when
  the project directory name holds `-claude-worktrees-`, else `other`.
- A request is written once per content block with its usage repeated, so
  usage is kept once per `requestId` (the last record). `<synthetic>` records
  are not requests. `ctx_median` and `ctx_p90` are over requests, as
  `input + cache_read + cache_creation` tokens: the median takes the lower
  middle value, the 90th is nearest-rank.
- `human` counts user records on the main chain whose content is text that
  does not begin with `<` (task notifications, command echoes) and that are
  not tool results, `isMeta`, `isCompactSummary` or sidechain.
  `human_busy` is those inside the first-to-last span of any one of the
  session's subagent transcripts. `agent_tokens` is input, cache write, cache
  read and output summed over those transcripts. `compactions` counts
  `compact_boundary` system records; `sendmessage` counts `SendMessage` tool
  calls on the main chain.
- `file` has no window and works on a subagent's transcript too (its `human`
  is 0: every record in it is a sidechain). The first column is the path as
  given.

`tests/step-cost.bats` builds a profile of invented transcripts and checks
each column, the human and busy rules, the window, and that no prompt text
reaches the output (fixture prompts start with `FX-`).
