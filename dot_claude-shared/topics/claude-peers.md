## Claude Peers (several projects in one repo)

- A peer is its own project: its own branch and PRs, planned and delegated
  like any session. Unless you are Lead, start or stop one (`claude-peer
  start|stop <slot>`) only when I ask.
- When `claude-peer slots` lists anyone else in this repo, announce your task
  before editing: `claude-peer log claim "<task>" -- <paths>`. Tell me about
  any overlap it prints, and `claude-peer log done` when you finish.
- Warn, never block: before `chezmoi apply`, quitting iTerm2, restarting a
  daemon or pushing, read `claude-peer log show` and tell me who is active
  here. The log does not see other repos.
- `claude-peer context list` shows the ready-made starts for this repo, each
  with its file. When I ask you to start a peer on something one of them
  covers, use `claude-peer start <slot> --context <name> <value>` rather than
  writing the prompt out. To add or fix one for this repo, write
  `90-<name>.ctx` in the directory `claude-peer context dir --repo` prints (it
  works at once) and tell me, so it gets moved into the overlay that owns the
  repo, where there is one. When you rename a skill, agent or script, grep that directory for the
  old name.
- When you are a peer (your directory is a slot worktree), keep Lead told; you
  never need its session name. Your `claude-peer log claim`, `note` and `done`
  lines reach Lead by themselves, so write them, and tell Lead in one line
  when you open a pull request, are blocked, need me, or hear a decision from
  me. A handed-over step ends with `claude-peer log done
  "<DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT>: <commit or PR>, <report
  path>"`: a report left only in your own pane reaches nobody. `postbox lead`
  prints Lead's session name for a conversation.
- A peer message that begins `postbox: Claude Peers:` is a peer's log line,
  turn end or exit, relayed. Take it as news: check the tree yourself (the
  commit, the tests) before the next step, tell me what matters, and do not
  reply to the relay.
- Hand a step to a peer with `claude-peer start <slot> --handoff …`, never a
  bare `start`: its finish, a turn that ends without one, and its exit then
  reach you, and reach me when nobody picks them up.
