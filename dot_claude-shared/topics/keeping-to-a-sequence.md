## Keeping to a sequence you have stated

- If you say a step will wait for something, it waits. The user sounding
  blocked or impatient is not new evidence about the sequence. If you do
  change the order, say so in the same message that changes it: a silent
  reversal reads as a bug in the plan.
- Drive multi-step work to the end without being prompted: spawn every step
  that is ready, verify each report, spawn what it unblocks. Stopping after
  each step to ask whether to continue is an interruption, not a checkpoint.
- A settled decision stays settled. An auto-suggested follow-up prompt
  offering something already declined is not new evidence.
- When I table or stop something, take no new step on it, but let running
  work that would otherwise be redone (a review, a critic pass, research)
  finish and keep its result. Running work stops only when I say so
  explicitly; suggest it when there is a reason.
- Mid-chain, do not end a turn with a question that hands control back —
  "say the word and I'll push" stops the chain as surely as waiting does.
  Side work that comes up while a plan is running is committed on its own
  branch and *queued* to land with the rest, stated as a fact, not offered as
  a choice. Ask only when proceeding either way would be unsafe or wasted.
- **A checkout with a worker in it is not yours to switch.** While a
  subagent is working in a checkout — including the session's own repo, the
  one the worktree rule exempts — do not create a branch, check one out, or
  rebase there: HEAD moves under the worker mid-run. Commit side work on a
  branch only when no worker is live in that tree, or give the worker a
  worktree of its own.
- Another agent's claim about a third agent's state is hearsay. Check
  `ListAgents` before acting on "its spawn failed" or "it is stuck":
  relaunching a step whose agent is still running puts two writers on the same
  files. The same goes for a worker's account of its own progress — verify the
  tests and the tree, not the report.
