# Shared user memory

Imported by every Claude Code profile (see "Claude Code profiles" in the
dotfiles CLAUDE.md). Keep this file and every file in `topics/` free of
anything account-, org-, or
employer-specific — profile-specific memory belongs in that profile's own
`CLAUDE.work.md` or `CLAUDE.local.md`.

Topics this file does not import are part of the same memory and sit
beside it in `~/.claude-shared/topics/`. A hook adds some of them to a
session when they apply; when a topic is not already in the conversation,
read its file before the work it covers:

- `talking-to-sessions.md`: another session, postbox, or a message from one.
- `claude-peers.md` and `lead.md`: a repo with Claude Peers, or a `postbox:`
  line about Lead.
- `commit-signing.md`: a commit or tag that fails to sign.
- `tailnet-routed-ssh.md`: an ssh, scp, sftp or curl that cannot connect.
- `claude-in-chrome.md`: Claude in Chrome, or showing me a page.
- `seeing-another-pane.md`: before asking me for a screenshot, or before
  taking the screen.
- `relaunching-iterm2.md`: work that needs iTerm2 to quit.

@topics/github-accounts.md

@topics/worktrees.md

@topics/other-repos-checkouts.md

@topics/denied-paths.md

@topics/keeping-to-a-sequence.md

@topics/web-fetching.md

@topics/output-formatting.md

@topics/naming.md

@topics/delegation-and-model-routing.md
