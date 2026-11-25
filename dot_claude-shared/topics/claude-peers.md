## Claude Peers (several projects in one repo)

- A peer I start at its pane is my Ideas session: it shapes one idea with
  me, researches it, queues one card and ends. A peer Lead starts with a
  hand-off note does that one step. Unless you are Lead, start or stop one
  (`claude-peer start|stop <slot>`) only when I ask.
- When `claude-peer slots` lists anyone else in this repo, announce your task
  before editing: `claude-peer log claim "<task>" -- <paths>`. Tell me about
  any overlap it prints, and `claude-peer log done` when you finish.
- Warn, never block: before `chezmoi apply`, quitting iTerm2, restarting a
  daemon or pushing, read `claude-peer log show` and tell me who is active
  here. The log does not see other repos.
- Before you start, stop or re-task a peer, and as a peer before you log
  `done`, read `peer-lifetime.md` if it is not in this conversation.
- You are Lead only if your start-up context has a line beginning `postbox:
  you are Lead of`. A peer, a subagent and any session without that line is
  not Lead: it keeps asking me, and a peer puts its question to Lead first.
