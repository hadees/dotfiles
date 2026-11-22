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
  and `prompts` from the two logs, counted only for sessions of a project the
  scan allowed (see the hooks below). The patterns are frozen so weeks compare:
  changing one starts a new baseline.
- **A denied project is never read.** There is no deny parser here: every
  test is `denyguard check --profile <running profile>` (see the `denyguard`
  rule), found on `PATH`. It is asked about the target's `projects` directory
  (a match exits 1 before any transcript is opened), then, for each project,
  about the project directory and the `cwd` its records name (the first
  record that has one is the only part read first). A project that fails is
  skipped in `count` and `list` alike, and only a total is reported, on
  stderr: `N projects skipped (denied)`; its name, path and cwd are never
  printed. Fail closed: only exit 0 allows, so exit 1, exit 2 (a rule
  denyguard cannot evaluate), a hang, a missing denyguard and a project whose
  records name no `cwd` all deny. On the `projects` check alone, exit 2 also
  prints denyguard's lines naming the rule it cannot evaluate (a `./` rule,
  say), never a path; the per-project checks stay silent. This is the reason `--dir` is safe to offer:
  a profile may not count sessions held in a repo it may not read, whichever
  profile's directory they sit in.
- `hook denied` (PermissionDenied) and `hook prompt` (PermissionRequest) append
  to `${XDG_STATE_HOME:-$HOME/.local/state}/operator-asks/denials.tsv` and
  `prompts.tsv`: UTC time, profile label (the base name of
  `CLAUDE_CONFIG_DIR`), then the leading `[Label]` of the reason (or `other`)
  and the tool name, or the tool name alone, then the session id (`-` when
  the payload has none). Never tool input or a path: the directory is readable
  by every profile, and the session id is an opaque uuid. `count` tallies a row
  only when its session id is that of a transcript in an allowed project, so
  the two log metrics honour the same per-project check; a row with no session
  id (written before the id was logged, or `-`) is not counted, and their
  number alone is printed on stderr: `N hook log rows without a session id not
  counted`. They print nothing and
  always exit 0, because a PermissionDenied hook's output can tell the model
  to retry. `settings` prints the two entries to paste; each profile's
  `settings.json` belongs to its overlay, so nothing here wires them.
- The record shapes (`toolUseResult.answers`, `permission-mode`, `customTitle`)
  are those of Claude Code 2.1.325. A shape that changes shows as a metric
  falling to zero, not as an error.
