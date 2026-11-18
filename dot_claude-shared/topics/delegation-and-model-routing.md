## Delegation and model routing

- **The main conversation is the orchestrator and, for a dependent chain, the
  implementer.** Anthropic measured the orchestrator-plus-cheap-workers split:
  it pays only when there is bulk to fan out — many independent pieces — and on
  one dependent chain "the coordinator's model alone at lower effort came out
  ahead in every measured case". So a feature whose steps depend on each other
  stays here, at the pinned model and effort, unless it has gone to
  `plan-fable` (three bullets down). Delegate two things only: work
  whose *tool output* would be long (a subagent's output stays in its own
  context; only its short reply comes back, and the orchestrator's context is
  re-sent on every later turn), and genuinely independent, fully specified
  pieces of a fan-out. Freeze the interface first, check the pieces for
  overlap, then fan out the *consumers* of that interface; the producer, and
  any file two pieces both touch, stays sequential.
- **Five shared definitions**, deployed to every profile from
  `.chezmoitemplates/claude-agents/`, referred to by these exact names (a
  misspelled agent type fails against the session's fixed list):
  `scout-haiku` — read-only sweeps, Haiku, loads no CLAUDE.md;
  `work-sonnet` — one fully specified piece: of a fan-out, or a step of a
  `plan-fable` plan;
  `unstick-fable` — the escalation seat, and it owns the task it is given
  (capped at 50 turns);
  `plan-fable` — a big idea once the chat has shaped it (next bullet), or
  whenever the operator asks for it by name; `review-fable` — only when the
  operator asks for it by name. Planning with Fable and implementing with
  Sonnet is the advisor pairing Anthropic measured as "within noise of the
  frontier model alone at medium effort, at about the same cost", and the
  review seat duplicates the Codex and Gemini seats that already run.
  Use `scout-haiku` and `plan-fable` in place of the built-in Explore and Plan:
  those inherit the main conversation's model, and the wrapper's
  `CLAUDE_CODE_SUBAGENT_MODEL` does not move them (documented).
- **A big idea is chit-chat first, and then `plan-fable`'s.** When the
  operator floats a new tool, skill, feature or integration, do not spawn
  the planner at once and do not design it all here: it gets
  fleshed out in chat. Help with what the repo and memory already hold,
  keep a running list of decided vs open, and do not ask "shall I plan it?"
  every turn. The hand-off is theirs — they drop out of the idea, say to
  plan it, or move on — and the brief is a refined, coherent restatement
  (goal, what they said matters, constraints, decisions, open questions,
  their key phrases quoted), never raw fragments: "I'm expecting you to
  refine my words because my ideas can sometimes be disjoined." Then say in
  a few lines what the planner will cover, and move on. A small ask (a
  lookup, a one-line fix) is not a big idea: just do it. Building waits for
  their go.
- **Once `plan-fable` has it, the plan is that seat's and `work-sonnet`
  builds it:** read the plan here, then one plan step per brief — the
  plan's path and step number plus what earlier steps produced, never the
  plan pasted in — dispatched in plan order, one at a time, each verified
  here before the next spawns. The main conversation orchestrates and
  verifies; it builds no step itself and redesigns nothing. A step that
  cannot land as written (a worker hands it back, a gate stays red, an
  Unverified item proves false) goes back to `plan-fable` for a revised
  plan, never quietly into the code; a failure nobody can explain is still
  `unstick-fable`'s, below. Only live hands-on steps with the operator — a
  login, an approval, their terminal — stay here. Learned 2026-09-24: with
  the rule above alone, a session planned with `plan-fable`, then built the
  feature itself and changed the plan on the way; a skill cannot carry the
  fix, since it loads only when it triggers and this always-loaded rule
  wins.
- **Escalation is a rule, not a mood.** Any one of these means stop and spawn
  `unstick-fable` with the failure verbatim and every attempt so far: the same
  failure has survived two attempts with different hypotheses; a worker has
  handed the task back twice; or the honest state is "I don't know why this
  fails" rather than "I know what to do next". Not before — a third try at the
  same seat is the expensive path, and so is a Fable pass on something not yet
  tried twice. Fable then finishes the task: one change at a time, no "while
  I'm here", and after three fixes that did not hold it stops and names the
  design problem. Handing a half-done fix back to a cheaper seat costs a fresh
  context that shares no cache — the split measured as a loss.
- **Every seat reports the same way**: the full account goes to a file under
  `${XDG_STATE_HOME:-$HOME/.local/state}/claude-reports/<repo>/`, and the reply to the orchestrator
  is under 15 lines, first line one of `DONE` / `DONE_WITH_CONCERNS` /
  `BLOCKED` / `NEEDS_CONTEXT`. Read the file only when the status warrants it;
  never paste a report into the conversation — what lands here is re-sent on
  every later turn. No seat dispatches subagents of its own; a worker-spawned
  reviewer is a duplicate seat at full cost.
- **Do not change what is being researched.** While an audit or research pass
  on X is in flight, X is frozen; deltas queue and land once, after the last
  report. Interim fixes restart CI, invalidate what the researchers read, and
  get redone (learned 2026-09-17, three pushes into two running audits).
- **Effort is fixed in the agent file, never chosen per spawn**; the Agent tool
  takes only `model`. **Definitions load at session start**; a new or edited one
  needs a fresh session (verified 2026-09-17). A definition's `description` is
  trigger conditions only — when, and when not — never a summary of what it
  produces: a description that restates the workflow gets followed instead of
  the body (tested by superpowers; Anthropic's authoring reference says the
  same). `tests/claude-agents.bats` enforces the checkable part.
- **Each profile's `settings.json` is owned by that profile's private
  overlay** (`chezmoi apply` of the overlay rewrites it), so a setting changed
  by hand or by `/model`, `/effort`, `/config` lasts only until the next apply
  — make the change in the overlay source and apply it. Cross-profile defaults
  go in the wrapper instead, because an overlay can only speak for one profile.
- **The wrapper exports four defaults** (and one gated export, below), each overridable per launch:
  `CLAUDE_CODE_SUBAGENT_MODEL=sonnet`; `CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL=1h`
  and `CLAUDE_CODE_PROMPT_CACHE_TTL=1h` (subagents default to a five-minute
  cache, and a session on usage credits drops the main conversation to five
  minutes too); `PONYTAIL_SUBAGENT_MATCHER='^(work-|unstick-)'`, which scopes
  the ponytail plugin's ruleset to the seats that write code. Ponytail's
  benchmark is the vendor's own: treat it as a reason to try it, never as a
  number to quote. It injects itself into matching subagents, so its rules
  are never pasted into a definition.
  A fifth, `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`, is not a default: it is
  exported only where `claude.terminal-title false` is set; there, set it to
  `''`, `0`, `false`, `no` or `off` for one launch to get Claude's own tab
  titles back.
- **Cache discipline.** Documented invalidators: switching model, changing
  effort (except Fable 5.1 on a subscription or API key, where effort changes
  keep the cache), fast mode, MCP connect or disconnect, plugin enable or
  disable, denying an entire tool, compaction, many images, a CLI upgrade. So:
  no mid-session model switching, `/effort` changes only at a natural break,
  `/rewind` over letting a wrong path run to `/compact` (rewind truncates to a
  prefix that is already cached), `/clear` between unrelated tasks, and never
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` (~7× a normal session).
- **Metering on Max**: Fable draws the same weekly pool, capped at half of
  it, then pay-as-you-go credits behind a consent prompt — not a separate
  tank. Pin the main model rather than `best`.
  **`/usage` is the instrument**: it attributes consumption per model, skill,
  subagent and MCP server. Read it before any change and a week after; nothing
  above is a saving until that number moves. On a token-billed plan the dollar
  analysis governs instead, and the same routing still applies.
- **Lever order, Anthropic's, model last**: caching → input hygiene → loop
  hygiene → effort → model. Input hygiene means a CLAUDE.md near 200 lines with
  per-file detail in path-scoped rules (`.claude/rules/`) rather than skills,
  whose descriptions are dropped from the listing without warning. Loop
  hygiene is `omitClaudeMd` on seats that take everything from the brief,
  `PreToolUse` hooks that rewrite a noisy command before it runs, and
  subagents for bulk. Effort: measured `medium` matched default quality on
  knowledge work at 70–85% of the cost; `/fast` buys speed, not savings.
- Measurements behind these rules: `docs/claude-delegation-notes.md` in the
  dotfiles clone.
