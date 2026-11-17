## Delegation and model routing: reference

- **Effort is fixed in the agent file, never chosen per spawn**; the Agent
  tool takes only `model`. **Definitions load at session start**; a new or
  edited one needs a fresh session. A definition's `description` is trigger
  conditions only — when, and when not — never a summary of what it produces:
  a description that restates the workflow gets followed instead of the body.
  `tests/claude-agents.bats` enforces the checkable part.
- **Each profile's `settings.json` is owned by that profile's private
  overlay** (`chezmoi apply` of the overlay rewrites it), so a setting changed
  by hand or by `/model`, `/effort`, `/config` lasts only until the next apply
  — make the change in the overlay source and apply it. Cross-profile defaults
  go in the wrapper instead, because an overlay can only speak for one profile.
- **The wrapper exports four defaults** (and one gated export, below), each
  overridable per launch: `CLAUDE_CODE_SUBAGENT_MODEL=sonnet`;
  `CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL=1h` and
  `CLAUDE_CODE_PROMPT_CACHE_TTL=1h`;
  `PONYTAIL_SUBAGENT_MATCHER='^(work-|unstick-)'`, which scopes the ponytail
  plugin's ruleset to the seats that write code. Ponytail's benchmark is the
  vendor's own: treat it as a reason to try it, never as a number to quote. It
  injects itself into matching subagents, so its rules are never pasted into a
  definition. A fifth, `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`, is not a
  default: it is exported only where `claude.terminal-title false` is set;
  there, set it to `''`, `0`, `false`, `no` or `off` for one launch to get
  Claude's own tab titles back.
- **Cache discipline.** Documented invalidators: switching model, changing
  effort (except Fable 5.1 on a subscription or API key, where effort changes
  keep the cache), fast mode, MCP connect or disconnect, plugin enable or
  disable, denying an entire tool, compaction, many images, a CLI upgrade. So:
  no mid-session model switching, `/effort` changes only at a natural break,
  `/rewind` over letting a wrong path run to `/compact`, `/clear` between
  unrelated tasks, and never `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`.
- **Metering on Max**: Fable draws the same weekly pool, capped at half of
  it, then pay-as-you-go credits behind a consent prompt — not a separate
  tank. Pin the main model rather than `best`.
  **`/usage` is the instrument**: it attributes consumption per model, skill,
  subagent and MCP server. Read it before any change and a week after; nothing
  above is a saving until that number moves. On a token-billed plan the dollar
  analysis governs instead, and the same routing still applies.
- **Lever order, Anthropic's, model last**: caching → input hygiene → loop
  hygiene → effort → model. Input hygiene means a CLAUDE.md near 200 lines
  with per-file detail in path-scoped rules (`.claude/rules/`) rather than
  skills. Loop hygiene is `omitClaudeMd` on seats that take everything from
  the brief, `PreToolUse` hooks that rewrite a noisy command before it runs,
  and subagents for bulk. `/fast` buys speed, not savings.
- Measurements behind these rules: `docs/claude-delegation-notes.md` in the
  dotfiles clone.
