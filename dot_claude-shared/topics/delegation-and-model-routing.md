## Delegation and model routing

- **The main conversation is the orchestrator and, for a dependent chain, the
  implementer.** A feature whose steps depend on each other stays here, at the
  pinned model and effort, unless it has gone to `plan-fable` (three bullets
  down). Delegate two things only: work whose *tool output* would be long, and
  genuinely independent, fully specified pieces of a fan-out. Freeze the
  interface first, check the pieces for overlap, then fan out the *consumers*
  of that interface; the producer, and any file two pieces both touch, stays
  sequential.
- **Five shared definitions**, deployed to every profile from
  `.chezmoitemplates/claude-agents/`, referred to by these exact names (a
  misspelled agent type fails against the session's fixed list): `scout-haiku`
  — read-only sweeps, Haiku, loads no CLAUDE.md; `work-sonnet` — one fully
  specified piece: of a fan-out, or a step of a `plan-fable` plan;
  `unstick-fable` — the escalation seat, and it owns the task it is given
  (capped at 50 turns); `plan-fable` — a big idea once the chat has shaped it
  (next bullet), or whenever the operator asks for it by name; `review-fable`
  — only when the operator asks for it by name. Use `scout-haiku` and
  `plan-fable` in place of the built-in Explore and Plan.
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
  Ask for that go once, with the plan's Sign-off rows numbered: the go covers
  every row they do not strike, to the end of the build, merge and deploy
  alike, and no step asks again for what a row names. A plan with no Sign-off
  section gets the same rows from you first.
- **A big plan is a pipeline, not one long run of one seat.** `plan-fable`
  starts its own cheap research helpers (`scout-haiku` for code sweeps, a
  Sonnet or Haiku general agent for the web and any reference sources), one question
  each, each writing a findings file under the reports directory; it plans
  from those files and the refined brief, never from raw transcripts, and its
  report gives their token totals. Before I see the plan, a critic pass by a
  seat separate from the planner, run from here, checks it against the other
  live plans and my signed decisions. Then my sign-off, then `work-sonnet`
  steps as in the next bullet. A small or medium ask skips all of this.
- **Once `plan-fable` has it, the plan is that seat's and `work-sonnet` builds
  it:** read the plan here, then one plan step per brief — the plan's path and
  step number plus what earlier steps produced, never the plan pasted in —
  dispatched in plan order, one at a time, each verified here before the next
  spawns. The main conversation orchestrates and verifies; it builds no step
  itself and redesigns nothing. A step that cannot land as written (a worker
  hands it back, a gate stays red, an Unverified item proves false) goes back
  to `plan-fable` for a revised plan, never quietly into the code; a failure
  nobody can explain is still `unstick-fable`'s, below. Only live hands-on
  steps with the operator — a login, an approval, their terminal — stay here.
- **Escalation is a rule, not a mood.** Any one of these means stop and spawn
  `unstick-fable` with the failure verbatim and every attempt so far: the same
  failure has survived two attempts with different hypotheses; a worker has
  handed the task back twice; or the honest state is "I don't know why this
  fails" rather than "I know what to do next". Not before. Fable then finishes
  the task: one change at a time, no "while I'm here", and after three fixes
  that did not hold it stops and names the design problem.
- **Every seat reports the same way**: the full account goes to a file under
  `${XDG_STATE_HOME:-$HOME/.local/state}/claude-reports/<repo>/`, and the reply to the orchestrator
  is under 15 lines, first line one of `DONE` / `DONE_WITH_CONCERNS` /
  `BLOCKED` / `NEEDS_CONTEXT`. Read the file only when the status warrants it;
  never paste a report into the conversation. A seat may start as many cheap
  helpers (Haiku or Sonnet) as the work needs, one level deep, and reports
  their tokens and what they found. No seat starts a Fable seat, another
  planner, or a reviewer: a tree of Fable seats once ate the credits, and a
  worker-spawned reviewer is a duplicate seat at full cost.
- **Do not change what is being researched.** While an audit or research pass
  on X is in flight, X is frozen; deltas queue and land once, after the last
  report.
- **I am never a step.** Only a login, a secret, a payment or a macOS
  security setting needs my hands. Do the rest yourself, or hand it to the
  session that can; where a rule of ours is all that stops you, say which,
  ask me for one go, then do it. Never hand me steps to run or type.
