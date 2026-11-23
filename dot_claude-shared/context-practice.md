# Context practice

Stamp: checked against Claude Code 2.1.330 on 2026-11-23.

What the context review seat reads. Imported by nothing and not a topic, so no
session loads it. A practice is `adopted` only with a `Here:` result from this
machine's sessions; every other is a `candidate`, a note and never a finding.
Rank: 1 Anthropic and Claude Code documentation; 2 other vendors' guidance; 3
research papers; 4 practitioner write-ups. Rank orders what is read first, it
does not exclude. Paper quotes carry their PDF page; where an entry lists two
sources the rank is the lower number. `quote pending` means the claim is not
yet grounded in a verbatim quote.

## Budgets

| Layer | Budget | Hard limit, and where it comes from |
| --- | --- | --- |
| Shared memory, always loaded | 16,200 characters | the test ceiling in `tests/claude-agents.bats`; lower it when the text shrinks, never raise it |
| A repository's CLAUDE.md | 200 lines | Anthropic's target; this repository's test allows 25,000 characters |
| Start bundle | Lead 7,600; peer 4,000; other 3,300 (proposed per-role bounds) | 9,000 (`INJECT_MAX` in `bin/executable_shared-memory`), under Claude Code's 10,000 per hook output |
| One tool-added topic | 4,000 (proposed) | 9,000 (`INJECT_MAX`) |
| One path-scoped rule file | 20,000 for a new file; a larger existing file may not grow | 40,000 at a 200K window (`RULE_MAX` in `tests/claude-memory.bats`): past it a session receives only the start of the file |
| An agent description | 600 | this repository's lint, `tests/claude-agents.bats` |
| A skill's description with `when_to_use` | 1,536 | Claude Code cuts the listing there |
| Auto memory's `MEMORY.md` | 200 lines or 25KB | Claude Code loads no more at start |

## Practices

### P1. Keep each CLAUDE.md under 200 lines.
- Source: https://code.claude.com/docs/en/memory: "target under 200 lines per CLAUDE.md file. Longer files consume more context and reduce adherence."; rank 1
- Evidence: documented
- Checked: 2026-11-23
- Here: untested
- Status: candidate

### P2. Do not count an import as a saving: an imported file loads with the file that imports it, to a depth of four hops.
- Source: https://code.claude.com/docs/en/memory: "Imports help you organize a long file but don't reduce its context cost, because imported files load together with the CLAUDE.md that imports them." and "a maximum depth of four hops."; rank 1
- Evidence: documented
- Checked: 2026-11-23
- Here: untested
- Status: candidate

### P3. Put instructions that matter for part of the codebase in a rule with `paths:`, and keep each rule file under the start-only limit.
- Source: https://code.claude.com/docs/en/memory: path-scoped rules "load only when Claude works with matching files"; a rule file over the per-file limit (40,000 characters at a 200K window) gives Claude only its start, "Before v2.1.309, Claude Code didn't apply this limit to files that load on demand."; rank 1
- Evidence: documented
- Checked: 2026-11-23
- Here: untested
- Status: candidate

### P4. Leave maintainer notes in a CLAUDE.md as block-level HTML comments: they are stripped before injection and cost no context.
- Source: https://code.claude.com/docs/en/memory: "Block-level HTML comments (`<!-- maintainer notes -->`) in CLAUDE.md files are stripped before the content is injected into Claude's context."; rank 1
- Evidence: documented
- Checked: 2026-11-23
- Here: untested (the page says CLAUDE.md files; topics a hook adds are sent as raw file text, so a comment there is likely not stripped)
- Status: candidate

### P5. Put what must survive compaction in the project-root CLAUDE.md; a path-scoped rule returns only when a matching file is read again, and an instruction given only in conversation is lost.
- Source: https://code.claude.com/docs/en/memory: "Project-root CLAUDE.md survives compaction: after `/compact`, Claude re-reads it from disk and re-injects it into the session." and "If an instruction disappeared after compaction, it was given only in conversation, lives in a nested CLAUDE.md that hasn't reloaded yet, or is a path-scoped rule that hasn't matched a file since."; rank 1
- Evidence: documented
- Checked: 2026-11-23
- Here: untested
- Status: candidate

### P6. Write instructions specific and concise, and remove any that contradict another file loaded with it.
- Source: https://code.claude.com/docs/en/memory: "The more specific and concise your instructions, the more consistently Claude follows them." and "if two instructions contradict each other, Claude may pick one arbitrarily."; rank 1
- Evidence: documented
- Checked: 2026-11-23
- Here: untested
- Status: candidate

### P7. Treat a CLAUDE.md as context, not enforcement: a rule that must hold whatever the model decides belongs in a hook.
- Source: https://code.claude.com/docs/en/memory: "Claude treats CLAUDE.md files and auto memory as context. They aren't enforced configuration. To block an action regardless of what Claude decides, use a PreToolUse hook instead."; rank 1
- Evidence: documented
- Checked: 2026-11-23
- Here: untested
- Status: candidate

### P8. Keep a skill's detail in its body, not its description: the description is carried on every turn and cut at 1,536 characters; keep `SKILL.md` under 500 lines.
- Source: https://code.claude.com/docs/en/skills: "In a regular session, skill descriptions are loaded into context so Claude knows what's available, but full skill content only loads when invoked." and "the combined `description` and `when_to_use` text is truncated at 1,536 characters in the skill listing" and "Keep `SKILL.md` under 500 lines."; rank 1
- Evidence: documented
- Checked: 2026-11-23
- Here: untested
- Status: candidate

### P9. After compaction an invoked skill keeps only its first 5,000 tokens, within 25,000 shared by all, newest first: put what a skill must not lose at the top.
- Source: https://code.claude.com/docs/en/skills: "keeping the first 5,000 tokens of each. Re-attached skills share a combined budget of 25,000 tokens."; rank 1
- Evidence: documented
- Checked: 2026-11-23
- Here: untested
- Status: candidate

### P10. Keep hook-added text under 10,000 characters per string: past it Claude Code saves it to a file and passes a 2,000-character preview, and does not ask Claude to read the file.
- Source: https://code.claude.com/docs/en/hooks: "A hook's `additionalContext`, `systemMessage`, and `initialUserMessage` strings, and its plain stdout, are capped at 10,000 characters" and "Claude Code doesn't ask Claude to read the file, so keep anything Claude must always see within the cap."; rank 1
- Evidence: documented
- Checked: 2026-11-23
- Here: untested
- Status: candidate

### P11. Put consent that must hold in CLAUDE.md content or `autoMode`, never in a tool result or another agent's message: the auto-mode classifier does not read those.
- Source: https://code.claude.com/docs/en/permission-modes: "In the classifier requests sent by Claude Code itself, the classifier sees user messages, tool calls other than read-only lookups such as file reads and searches, and your CLAUDE.md content. Tool results are stripped from those requests"; the page does not say what the server-side review sees; rank 1
- Evidence: documented
- Checked: 2026-11-23
- Here: untested
- Status: candidate

### P12. Send to a subagent only a side task whose output would flood the main conversation, and ask for a summary back.
- Source: https://code.claude.com/docs/en/sub-agents: "Use one when a side task would flood your main conversation with search results, logs, or file contents you won't reference again: the subagent does that work in its own context and returns only the summary." and "Running many subagents that each return detailed results can consume significant context, and each subagent spends tokens of its own while it runs."; rank 1
- Evidence: documented
- Checked: 2026-11-23
- Here: untested
- Status: candidate

### P13. For sequential work, same-file edits or many dependencies, use one session or subagents, not a team of sessions; give each teammate its own files; check in on a running team.
- Source: https://code.claude.com/docs/en/agent-teams: "Agent teams add coordination overhead and use significantly more tokens than a single session." and "For sequential tasks, same-file edits, or work with many dependencies, a single session or subagents are more effective." and "Two teammates editing the same file leads to overwrites." and "Letting a team run unattended for too long increases the risk of wasted effort."; rank 1
- Evidence: documented
- Checked: 2026-11-23
- Here: untested
- Status: candidate

### P14. Start a team at 3 to 5 sessions, not more.
- Source: https://code.claude.com/docs/en/agent-teams: "Start with 3-5 teammates for most workflows." and "Three focused teammates often outperform five scattered ones."; rank 1
- Evidence: documented
- Checked: 2026-11-23
- Here: untested
- Status: candidate

### P15. Start with one well-equipped agent, and split work only when its context can be isolated.
- Source: https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them (2026-01-23): "A well-designed single agent with appropriate tools can accomplish far more than many developers expect." and "Work should only be split when context can be truly isolated." and "Start with the simplest approach that works, and add complexity only when evidence supports it."; rank 1
- Evidence: documented
- Checked: 2026-11-23
- Here: untested
- Status: candidate

### P16. Expect several times the tokens when work is split across agents, and spend them where the benefit is thoroughness, not speed.
- Source: https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them (2026-01-23): "multi-agent implementations typically use 3-10x more tokens than single-agent approaches for equivalent tasks" and "The primary benefit of parallelization is thoroughness, not speed." and "the subagents spent more tokens on coordination than on actual work."; rank 1
- Evidence: documented
- Checked: 2026-11-23
- Here: untested
- Status: candidate

### P17. Do not expect parallel agents to pay on coding work that is mostly sequential.
- Source: https://www.anthropic.com/engineering/multi-agent-research-system (2025-06-13): "most coding tasks involve fewer truly parallelizable tasks than research" and "multi-agent systems use about 15× more tokens than chats" (self-reported, internal eval); rank 1
- Evidence: documented
- Checked: 2026-11-23
- Here: untested
- Status: candidate

### P18. Brief a delegate with an objective, an output format, guidance on tools and sources, and clear boundaries; hand work back as a reference to a stored artifact.
- Source: https://www.anthropic.com/engineering/multi-agent-research-system (2025-06-13): "Each subagent needs an objective, an output format, guidance on the tools and sources to use, and clear task boundaries." and "Subagents call tools to store their work in external systems, then pass lightweight references back to the coordinator."; rank 1
- Evidence: documented
- Checked: 2026-11-23
- Here: untested
- Status: candidate

### P19. Put the rules that must not be lost at the start or the end of a loaded text, not the middle.
- Source: Liu et al. 2023, "Lost in the Middle", arXiv 2307.03172, p. 1: "performance is often highest when relevant information occurs at the beginning or end of the input context, and significantly degrades when models must access relevant information in the middle of long contexts, even for explicitly long-context models." + Hsieh et al. 2024, "Found in the Middle", arXiv 2406.16008, p. 1: "LLMs exhibit an U-shaped attention bias where the tokens at the beginning and at the end of its input receive higher attention, regardless of their relevance."; rank 3
- Evidence: measured
- Checked: 2026-11-21
- Here: untested (measured on retrieval tasks with 2023-era models, not on rule adherence in a coding session)
- Status: candidate

### P20. Do not trust an advertised window: test a long-context claim at the length you use.
- Source: Hsieh et al. 2024, "RULER", arXiv 2404.06654, p. 1: "While these models all claim context sizes of 32K tokens or greater, only half of them can maintain satisfactory performance at the length of 32K."; rank 3
- Evidence: measured
- Checked: 2026-11-21
- Here: untested
- Status: candidate

### P21. Prefer the shorter context even when retrieval is perfect.
- Source: Du et al. 2025, "Context Length Alone Hurts LLM Performance Despite Perfect Retrieval", arXiv 2510.05381, p. 2: "even when a model can perfectly retrieve all the evidence—in the strictest possible sense, reciting all tokens with 100% exact match—its performance still degrades substantially as input length increases"; rank 3
- Evidence: measured
- Checked: 2026-11-21
- Here: untested
- Status: candidate

### P22. Remove stale notes and near-duplicate rules: what hurts is look-alike competing statements, not neutral length.
- Source: Liu 2026, "Length Is Cheap, Competition Is Not", arXiv 2611.04169, p. 1 (small open models, 0.5B-3B only): "neutral filler costs nothing: accuracy stays at 0.97 to 1.00, up to 32K tokens on Qwen2.5-1.5B. Statements in the format of the evidence, placed at the same positions, drop it to 0.11 to 0.21."; rank 3
- Evidence: measured
- Checked: 2026-11-21
- Here: untested (disputes P21 on mechanism; both agree a shorter, less competing context is safer)
- Status: candidate

### P23. Put the rules you cannot afford to lose first in a long instruction list, and keep the list short: adherence falls as the count grows, with earlier instructions favoured.
- Source: Jaroslawicz et al. 2025, "How Many Instructions Can LLMs Follow at Once?", arXiv 2507.11538, p. 1 and p. 6: "even the best frontier models only achieve 68% accuracy at the max density of 500 instructions" and "Primacy effects refer to the tendency of models to better satisfy instructions appearing earlier versus later in the instruction list"; rank 3
- Evidence: measured
- Checked: 2026-11-21
- Here: untested (keyword-inclusion task at 500 instructions, far denser than a CLAUDE.md; the shape of the curve is the useful part)
- Status: candidate

### P24. Put only non-obvious conventions in a context file, and leave out what the agent can read from the repository.
- Source: Gloaguen et al. 2026, "Evaluating AGENTS.md", arXiv 2602.11988, p. 1: "while instructions in the context files are well followed by coding agents, repository overviews, although popular and recommended by model providers, are not helpful."; rank 3
- Evidence: measured
- Checked: 2026-11-21
- Here: untested
- Status: candidate

### P25. Test a context file on and off over real tasks before trusting that it helps: the measured effect is small either way.
- Source: Khatri 2026, "Do Context Files Help Coding Agents?", arXiv 2607.27250, p. 1 (Claude Code and Codex, 17 tasks, 3 repositories): "agents fail on implementation skill—feature design, pattern selection, exact wiring—not missing repository knowledge that a context file could supply"; effect bounded to 10-15 percentage points either way; rank 3
- Evidence: measured
- Checked: 2026-11-21
- Here: untested
- Status: candidate

### P26. Audit instruction files for conflicting instructions, procedures that belong in skills, and bloat: they occur together.
- Source: Santos et al. 2026, "Configuration Smells in AGENTS.md Files", arXiv 2606.15828, p. 8 (100 repositories, descriptive not causal): "the probability of Conflicting Instructions, Skill Leakage, and Context Bloat co-occurring in the same file is 1.81 times higher than if they were independent"; rank 3
- Evidence: measured
- Checked: 2026-11-21
- Here: untested
- Status: candidate

### P27. Do not rely on a layer or a position to settle a conflict between instructions; remove the conflict.
- Source: Wallace et al. 2024, "The Instruction Hierarchy", arXiv 2404.13208, p. 1: "LLMs often consider system prompts (e.g., text from an application developer) to be the same priority as text from untrusted users and third parties."; rank 3
- Evidence: documented
- Checked: 2026-11-21
- Here: untested (a problem statement; the fix was measured on one model)
- Status: candidate

### P28. When a long session has taken a wrong turn, restart from a consolidated brief instead of pushing on.
- Source: Laban et al. 2025, "LLMs Get Lost In Multi-Turn Conversation", arXiv 2505.06120, p. 1: "when LLMs take a wrong turn in a conversation, they get lost and do not recover."; rank 3
- Evidence: measured
- Checked: 2026-11-21
- Here: untested
- Status: candidate

### P29. Load detail on demand, behind a pointer, with the full text as the fallback.
- Source: Li et al. 2024, "RAG or Long-Context LLMs?", arXiv 2407.16833, p. 1: "Our approach, SELF-ROUTE, combining RAG and LC, achieves comparable performance to LC at a much lower cost."; rank 3
- Evidence: measured
- Checked: 2026-11-21
- Here: untested
- Status: candidate

### P30. Do not shorten a rule by dropping tokens or abbreviating until it has been tested on rule lists: compression was tested on redundant prose.
- Source: Pan et al. 2024, "LLMLingua-2", arXiv 2403.12968, p. 1: "compression ratios of 2x-5x" + Jiang et al. 2023, "LLMLingua", arXiv 2310.05736, p. 1: "allows for up to 20x compression with little performance loss" (reasoning demonstrations and documents); rank 3
- Evidence: measured
- Checked: 2026-11-21
- Here: untested (no source tests abbreviating instructions)
- Status: candidate

### P31. Give every multi-agent job a verification step: two of three failure categories are misalignment between agents and task verification.
- Source: Cemri et al. 2025, "Why Do Multi-Agent LLM Systems Fail?", arXiv 2503.13657, p. 1: "This process identifies 14 unique modes, clustered into 3 categories: (i) system design issues, (ii) inter-agent misalignment, and (iii) task verification."; rank 3
- Evidence: measured
- Checked: 2026-11-21
- Here: untested
- Status: candidate

### P32. Use parallel agents for exploration and search, not for sequential work.
- Source: Kim et al. 2025, "Towards a Science of Scaling Agent Systems", arXiv 2512.08296, p. 4: "decentralized coordination benefits tasks requiring parallel exploration of high-entropy search spaces (dynamic web navigation: +9.2%), while all multi-agent variants universally degrade performance on tasks requiring sequential constraint satisfaction (planning: −39% to −70%)"; rank 3
- Evidence: measured
- Checked: 2026-11-21
- Here: untested
- Status: candidate

### P33. Check adherence with a program, not a model judge, as IFEval does for verifiable instructions.
- Source: Zhou et al. 2023, "Instruction-Following Evaluation for Large Language Models" (IFEval), arXiv 2311.07911, p. 2; quote pending; rank 3
- Evidence: documented
- Checked: 2026-11-21
- Here: untested
- Status: candidate

### P34. State a measured difference as a paired difference with its standard error: at small n most improvements cannot be told from noise.
- Source: Miller, "Adding Error Bars to Evals", arXiv 2411.00640, p. 8: "Pairwise standard errors may be computed either directly on the differences"; rank 3
- Evidence: documented
- Checked: 2026-11-21
- Here: untested
- Status: candidate

### P35. Split the start text by the role of the session that receives it.
- Source: none; a choice made here; rank 4
- Evidence: anecdotal
- Checked: 2026-11-23
- Here: untested
- Status: candidate

### P36. Add a topic with a tool-event trigger and a pointer line, so a session reads it at the moment it applies.
- Source: none; a choice made here; rank 4
- Evidence: anecdotal
- Checked: 2026-11-23
- Here: untested
- Status: candidate

## Backlog

Experiments that would move an entry to `adopted` or `demoted`:

- Rule-adherence curve: a fixed coding task with the shared rule file at 5, 20 and 50 rules, rules placed first against last, programmatic pass/fail checks, at least 20 runs per cell, paired differences with standard errors (P19, P23, P33, P34).
- Context file on and off: the repository's CLAUDE.md and rule files removed against present, over 15 to 20 real tasks (P24, P25).
- Session count: one session against a lead with peers on the same batch of tasks, measuring tokens, wall time, merge conflicts and operator interventions (P13, P14, P16, P17, P32).
- Start text by role: sizes before and after the split, and the effect on rule-following (P35).
- Tool-event pointer: the `injected` counts from `shared-memory log` (P36).
- Whether a block-level HTML comment in a hook-added topic is stripped (P4).

## Changes

- 2026-11-23: added P1 to P36: first entries, seeded from a reading list of papers and vendor pages. Web quotes were re-fetched on 2026-11-23; paper quotes carry the page and date of the earlier check against the documents (2026-11-21), with PDF line-break hyphens removed. All `candidate`: no entry has a result from this machine's sessions yet.
