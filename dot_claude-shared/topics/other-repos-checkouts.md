## Working in other repos' checkouts

- If a task takes you into a repo other than the one the session was
  started in, NEVER work on that repo's live checkout: check out your own
  worktree of it (EnterWorktree, or `git worktree add` under
  `<repo>/.claude/worktrees/`) and do the work there. Another session,
  agent, or tool may be using that checkout right now, and a branch switch
  or edit changes the tree under it mid-run
  (learned 2026-08-22: a branch switch in a shared checkout swapped the
  content under another session's live production deploy). Apply this even
  when the checkout looks idle — you cannot see other sessions' intent.
- The rule is about the working tree. Machine-local `git config` in that
  repo, and read-only commands (`git log`, `grep`, reading files on the
  current branch), are fine directly.
- The repo the session was started in is exempt — that checkout is yours
  (subject to whatever the user is doing in it; stash-and-restore or a
  worktree is still the polite default when its tree is dirty).
