---
paths:
  - "**/bin/executable_operator-asks"
  - "**/tests/operator-asks.bats"
---

# The operator-asks count (`~/bin/operator-asks`)

Counts how often a session made the operator a step: a question put to them,
a line telling them to type or run something, a permission prompt, a
permission the classifier refused. It exists so "is the operator needed less"
has a number that weeks can be compared on. Nothing here changes what a
session does.

- `count [--since DAYS] [--dir PROFILE_DIR]` prints `metric<TAB>count`,
  sorted. `list` prints the step lines themselves (time, session name, kind,
  text cut to 200) for a person to classify; it prints transcript text, so it
  goes to the caller's terminal only. Both read
  `<PROFILE_DIR>/projects/*/*.jsonl`, main conversation only, and write
  nothing. `PROFILE_DIR` is `$CLAUDE_CONFIG_DIR`, else `~/.claude`; `DAYS` is 7.
- Metrics: `questions` (answered `AskUserQuestion` calls) and `first-option`
  (answered with the first listed option on every question); `steps` (assistant
  text lines matching one of four patterns in the script, once per session,
  calendar day and line with digits folded to `N`) and `elsewhere` (the subset
  matching pattern 1, "type it in that pane"); `read:<file>` (Read calls on
  the approvals ledger and each shared topic); `peer-mode:<mode>` (the first
  `permission-mode` record of each worktree-project session); `denied:<reason>`
  and `prompts` from the two logs. The patterns are frozen so weeks compare:
  changing one starts a new baseline.
- **A denied profile is never read.** The running profile's
  `permissions.deny` (its `settings.json`, `Read(~/...)` and `Read(//...)`
  entries) is checked against the target's `projects` directory, and a match
  exits 1 before any transcript is opened. This is the reason `--dir` is safe
  to offer: a profile that may not read another's transcripts cannot count
  them either. A settings file it cannot read denies nothing, as for any tool.
- `hook denied` (PermissionDenied) and `hook prompt` (PermissionRequest) append
  to `${XDG_STATE_HOME:-$HOME/.local/state}/operator-asks/denials.tsv` and
  `prompts.tsv`: UTC time, profile label (the base name of
  `CLAUDE_CONFIG_DIR`), then the leading `[Label]` of the reason (or `other`)
  and the tool name, or the tool name alone. Never tool input, a session id or
  a path: the directory is readable by every profile. They print nothing and
  always exit 0, because a PermissionDenied hook's output can tell the model
  to retry. `settings` prints the two entries to paste; each profile's
  `settings.json` belongs to its overlay, so nothing here wires them.
- The record shapes (`toolUseResult.answers`, `permission-mode`, `customTitle`)
  are those of Claude Code 2.1.325. A shape that changes shows as a metric
  falling to zero, not as an error.
