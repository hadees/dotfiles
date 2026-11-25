## Where worktrees go

- Create every worktree inside the main checkout of the repo it belongs to,
  in a hidden, git-ignored worktree directory:
  `<repo>/.claude/worktrees/<name>`. Never as a sibling of the repo.
- Before creating the first one, make sure git ignores that directory. If
  nothing does yet, add `**/.claude/worktrees/` to the repo's
  `.git/info/exclude` (machine-local, no commit needed).
- The consequence for `~/code`: it holds one clone per repo and nothing else.
  Do not create any directory or file directly in it (worktrees, scratch
  clones, copies) unless I have told you to create or clone a new repo.
  Throwaway files go in the session scratchpad.
