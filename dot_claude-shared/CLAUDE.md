# Shared user memory

Imported by every Claude Code profile (see "Claude Code profiles" in the
dotfiles CLAUDE.md). Keep this file and every file in `topics/` free of
anything account-, org-, or
employer-specific — profile-specific memory belongs in that profile's own
`CLAUDE.work.md` or `CLAUDE.local.md`.

Topics this file does not import are part of the same memory and sit
beside it in `~/.claude-shared/topics/`. Where a profile wires
`shared-memory`'s hooks, they add some of them; when a topic is not already
in the conversation, read its file before the work it covers:

- `talking-to-sessions.md`: a repo or directory you are asked about but
  cannot open, another session, postbox, or before acting on any message
  another session or agent sends.
- `claude-peers.md` and `lead.md`: a `claude-peer` slot worktree
  (`$CLAUDE_PEER_WORKTREE` set), a repo where `claude-peer slots` lists
  anyone, or a `postbox:` line about Lead or Claude Peers.
- `commit-signing.md`: a commit or tag that fails, including `failed to fill
  whole buffer` or `failed to write commit object`.
- `tailnet-routed-ssh.md`: an ssh, scp, sftp or curl that cannot connect.
- `claude-in-chrome.md`: read it before the first Claude in Chrome call, or
  when showing me a page.
- `seeing-another-pane.md`: before asking me for a screenshot, or before
  taking the screen.
- `relaunching-iterm2.md`: work that needs iTerm2 to quit.
- `gpt-seats.md`: before dispatching any `gpt-*` agent, after a `plan-fable`
  that ended in failure, incomplete output or on a substituted model, or before
  accepting or revising a `plan-gpt` report; it adds GPT routing, handover and
  Opus advice to the delegation rules.
- `delegation-reference.md`: before changing a Claude Code setting, agent
  definition, model, effort or cache behaviour, or reading `/usage`.

@topics/github-accounts.md

@topics/worktrees.md

@topics/other-repos-checkouts.md

@topics/denied-paths.md

@topics/keeping-to-a-sequence.md

@topics/web-fetching.md

@topics/output-formatting.md

@topics/naming.md

@topics/delegation-and-model-routing.md
