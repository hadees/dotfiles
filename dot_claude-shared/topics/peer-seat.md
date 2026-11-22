## When you are a peer

- When you are a peer (your directory is a slot worktree), keep Lead told; you
  never need its session name. Your `claude-peer log claim`, `note` and `done`
  lines reach Lead by themselves, so write them, and tell Lead in one line
  when you open a pull request, are blocked, need me, or hear a decision from
  me. A handed-over step ends with `claude-peer log done
  "<DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT>: <commit or PR>, <report
  path>"`: a report left only in your own pane reaches nobody. `postbox lead`
  prints Lead's session name for a conversation.
