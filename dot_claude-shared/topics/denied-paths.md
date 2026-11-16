## A denied path is denied by every route

- A profile's `permissions.deny` does **not reliably reach Bash**. It binds
  Read and Edit, and catches the handful of commands Claude Code recognises as
  reading a path directly (`cat`, `head`, `tail`, `sed`, `tee`, redirection
  targets) — but not `grep -r`, not a script that opens files itself, and not
  any command it does not recognise. Treat the coverage as incidental: a
  denied path is off limits by *every* route — Bash, a script you write to do
  it for you, or a subagent.
- When a read is refused, say so and stop. Do not reconstruct the answer from
  a neighbouring file, an index, a commit message, or from counts and matches
  that characterise the content without quoting it. The block exists because
  the content is too sensitive for this profile, and a summary of it leaks the
  same thing more quietly.
- A subagent reporting that it was refused has behaved correctly. Never
  re-issue its task by another route, and never brief the next one in a way
  that routes around the block.
- Where a profile is itself the sensitivity boundary — the repo's
  `claude.<owner>/<repo>.profile` pin deciding which login may see it — that
  pin may be read and obeyed, never adjusted. Re-pinning a repo to a lighter
  profile to make a grouping work is the same leak with extra steps.
- **A denied directory may still be known to exist, and routed.** The
  routers (`routes`, `worktabs`, `workset`, `claude-tab`, `postbox names`)
  exist to wire every repo on the machine, including ones the current
  profile may not open, so a denied repo's path, name, the fact that a
  session runs there, and the git *metadata* routing needs (origin remote,
  current branch, worktree list) are all fair to read and print. What stays
  off limits is content: working-tree files, history, diffs, anything that
  characterises what the repo holds. Do not "fix" a router by hiding denied
  repos from it, and do not add a bypass flag either way (operator,
  2026-11-05: "it needs to know they exist … but I also need to know which
  claude profile they use").
