---
paths:
  - "**/bin/executable_claude-peer"
  - "**/dot_config/claude-peer/**"
  - "**/tests/claude-peer.bats"
  - "**/tests/claude-peer-screen.bats"
---

# Claude peers: the jobs record, the queue and the secretary pane

The part of `bin/claude-peer` that keeps what Lead dispatched, queues what the
operator thought up, and runs the one pane to think in. The rest of the script is
in `claude-peer.md`.

## The jobs record

Workers are subagents: no pane, no claim, no registry record, so nothing of them
survives Lead's compaction or restart. Claude Code's own events are written to
`<git common dir>/claude-peer.jobs`, beside the coordination log, by `claude-peer
job hook`, one line per event, append-only, tab-separated, tabs and newlines in
text written as spaces:
`<UTC time><TAB><who><TAB><event><TAB><agent id><TAB><agent type><TAB><text><TAB><worktree>`.

- `event` is `start` (SubagentStart), `stop` (SubagentStop; text is the
  `description` of `agent_transcript_path` with `.jsonl` replaced by `.meta.json`, empty
  when that file does not parse) or `report` (PostToolUse of `SubagentHandback`; text is
  the first line of `tool_input.message` cut to 200 characters, then a space and the
  first path in the message that holds `/claude-reports/`).
- `who` is the label of the basename of `CLAUDE_PEER_WORKTREE` when the hook's
  environment has it (a peer's own session), else `Lead`. `log_who` is not used: it
  answers `Lead` only while a peer holds a claim. `worktree` is the payload's `cwd`
  when its toplevel is not the repository's main checkout, else `-`.
- The hook reads one payload on stdin (python3, as `peer_py` needs it) and **prints
  nothing and exits 0 whatever happens**: no repository, bad JSON, no python3, an
  unwritable file. A SubagentStop hook that prints or exits 2 keeps the subagent
  running. A start or stop with an empty `agent_type` (Claude Code's own internal
  agents) and any event with no `agent_id` write nothing; a start of an internal agent
  would otherwise never get its stop and read as running.
- `job settings` prints the three `settings.json` entries (`SubagentStart` and
  `SubagentStop` with no matcher, `PostToolUse` matched on `SubagentHandback`, each
  `[ -x ~/bin/claude-peer ] && exec ~/bin/claude-peer job hook || true`, timeout 5).
  It edits nothing: each profile's file is its overlay's.
- `claude-peer jobs [--all | --since HOURS] [<dir>]` prints one row per agent id first
  seen in the window (default 24 hours), newest first:
  `state<TAB>agent id<TAB>who<TAB>type<TAB>started<TAB>ended<TAB>worktree<TAB>description<TAB>report`,
  `-` for a missing field. `state` is `running` (no `stop`), `ended` (a `stop`) or
  `reported` (a `stop` and a `report`). `jobs_running <who>` is the same rows asked
  one question: exit 0 when `<who>` has a `running` row in the last 24 hours.
- The `.meta.json` and its `description` are observed at Claude Code 2.1.325, not an
  interface: a change leaves the description `-`, never a missing row.

Tests: `tests/claude-peer.bats` ("job hook: ...", "jobs: ...", "jobs_running: ...",
"job settings: ..."). `jobs_running` is a shell function, so its test extracts it
from the script with `sed`.
