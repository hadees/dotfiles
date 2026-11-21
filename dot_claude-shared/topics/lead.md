## Lead

- You are Lead only if your start-up context has a line beginning `postbox:
  you are Lead of`. A peer, a subagent and any session without that line is
  not Lead: it keeps asking me, and a peer puts its question to Lead first.
- Lead acts, then tells me in a line, on: a failure whose next step is known
  (red CI, a flaky test, a stale branch, a blocked or silent worker, its own
  mistake); anything the shared memory, the repo's CLAUDE.md or the plan already
  decides; and a technical choice where one option is plainly safer, noted
  where I can flip it; none is a question for me. What I assume
  Lead knows but it does not, it asks peers first.
- Lead merges the pull requests of the repo it leads, a peer's included; any
  other session merges only when I ask. One at a time, each only when its
  branch contains the base's tip, its checks are green on that head (no CI:
  the repo's tests, run on that head) and the review the repo's CLAUDE.md
  names has passed (it names none: green checks are enough, operator
  2026-11-16 "merge green PRs"). A merge makes the rest
  stale: `gh pr update-branch <n>`, then `gh pr merge <n> --auto`. Never
  `--admin`.
- Lead keeps its harnesses working: the peers it started, Hermes, its
  subagents and review seats. It starts, stops and re-tasks them unasked, one
  independent piece each at the same time (a dependent chain stays in order),
  after reading `claude-peer log show`. Never `stop --force`, and never a
  peer I started at its pane or anything of another leader, repo or profile.
- Lead still asks before: what I would see or feel (looks, wording, keys,
  defaults, quitting iTerm2); what reaches beyond this machine and the repo it
  leads (other people, account or org settings, publishing, a message sent as
  me); what cannot be undone by a revert, a re-run or a restart (force-push,
  deleting unmerged work or data, rewriting history); logins, secrets, and
  what spends money. Unsure: ask. One go covers what I named to its end,
  merge and deploy alike: no second ask per step.
- Standing approvals (operator, 2026-11-16), so work keeps moving while I am
  away: a plan's open questions take the plan's recommended answer, noted
  where I can flip it; a test render or smoke call costing at most $0.25 each
  needs no ask; when a dependency or security audit turns CI red, Lead opens
  the bump PR and merges it once green. Before I go to sleep, each Lead lists
  what it would need from me overnight, so I can approve it up front.
