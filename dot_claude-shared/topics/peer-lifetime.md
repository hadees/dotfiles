## How long a peer lives (start, stop, keep)

- A peer is for one task. Once the task is done the session is a cost, not a
  store: its prompt cache is gone within the hour, so its next turn re-reads
  the whole conversation at full price, and Claude Code may compact a long
  idle conversation by itself. What a peer knows is kept in files.
- **A peer, before it logs `done`**: write the report file with these
  headings. `Asked`: the task and who gave it. `State`: branch, last commit,
  pull request, anything uncommitted or unpushed. `Decided`: each decision
  and why, my words quoted. `Learned`: what was tried and failed, what
  surprised you. `Open`: what is unfinished, the next step, questions waiting
  on me or on Lead. `Session`: `$CLAUDE_CODE_SESSION_ID` and the worktree.
  Then `claude-peer log done "<STATUS>: <one line>; <commit or PR>; <report
  path>"`. A decision I give you mid-task is a `claude-peer log note` at
  once: a pane can end without warning.
- **Lead, when a `done` reaches it**: read the report, check `State` against
  the worktree and the branch, take over what `Open` lists, then
  `claude-peer stop <slot>` in the same turn. The pane waits and costs
  nothing. The next task for that slot is a fresh `start --handoff` whose
  brief names the reports it needs; a different task is never a message to a
  finished peer.
- **Keep** a peer running only while its own task still moves: checks or a
  review it must answer, or a follow-up Lead sends now. Lead says so,
  `claude-peer log note "keeping <Label>: <why>"`, and stops it when that
  ends.
- **`claude-peer stop` is the whole guard, for every peer of the repo**, one
  I started at its pane included. It stops a session that is at its prompt,
  one with a background shell only after its `done`, one whose worktree is
  gone, and a pane-started one only once it has sat idle
  (`claude-peer.pane-idle-minutes`). What it refuses (exit 5) stays running:
  message that peer or leave it. Never `--force` unasked, never `kill` a
  pid, and never me: I close no pane and type no `/exit`.
- **No report, no stop**, for a slot Lead handed over: one with no `done`
  naming a report since it started gets one message asking for it. One that
  was stopped without it is asked afterwards: `claude-peer start <slot>
  --continue --handoff -- "write the report you owe"`. A pane-started peer
  owes none: look at its branch and `claude-peer log show`, and tell me in
  one line what it was on when you stop it.
- Never remove a slot's worktree while `claude-peer slots` shows it running.
- Before Lead tells me it is idle or blocked, and before my overnight list,
  it runs `claude-peer slots`: every running slot is working or kept with a
  note.
- `claude-peer context list` shows the ready-made starts for this repo, each
  with its file. When I ask you to start a peer on something one of them
  covers, use `claude-peer start <slot> --context <name> <value>` rather than
  writing the prompt out. To add or fix one for this repo, write
  `90-<name>.ctx` in the directory `claude-peer context dir --repo` prints (it
  works at once) and tell me, so it gets moved into the overlay that owns the
  repo, where there is one. When you rename a skill, agent or script, grep that directory for the
  old name.
