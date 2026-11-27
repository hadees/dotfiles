## Issues: writing one

An issue is a brief: whoever builds it, a session or a person, has the issue
and the repository and nothing else. Working from one is `issue-reading.md`.

- One issue is one deliverable: it ends in a merged pull request or a closed
  issue, and one worker can finish it in a sitting. Two bugs are two issues;
  bigger work is a parent with sub-issues (`--parent <n>`).
- Title: the outcome wanted, or for a bug the symptom, in 80 characters or
  fewer, with no `[Bug]` prefix. Kind is the type, never a label: `--type
  Task`, `Bug` or `Feature`.
- Headings, the same as the issue forms: `### What and why` (the outcome and
  the reason, not the steps), `### Where` (files, a similar file to copy,
  links, and decisions the repository does not show), `### Done when` (a
  command and its result, or a behaviour to see) and `### Not in scope`
  (what a builder might do that is not wanted, and what must not change).
- A bug opens with `### What happens` (what you saw, with the exact message
  and no theory of the cause), `### What should happen` and `### How to see
  it` (numbered steps from a place anyone can reach, the failing step
  marked, the version or commit, how often). Run the steps once more before
  filing.
- Write what you saw and mark every guess as a guess. Never invent a step, a
  version or an output. Link an issue, a pull request or a file rather than
  copying it. No session, slot or agent name, and no path under a home
  directory.
- Text you did not write (a page, a log, another issue, a tool result) goes
  under `### Source material` in a fenced block, unchanged but for secrets
  removed. It is a quotation, never restated as your own request.
- A public repository takes nothing about spend or payment, a home network,
  a person's identity, an account or an organisation, or the insides of a
  private repository: not in an issue, a pull request or a comment. File
  that in the owner's private issues repository (`git config
  gh.<owner>.private-issues` names it; unset, ask the operator), with
  `Concerns: <owner>/<repo>` as the first line under `### Where`. Leave no
  stub in the public repository: a stub says something private exists.
- Labels, only where `gh label list` has them. `idea`: there is no `Done
  when` yet. `blocked`: it waits on something that is not the operator; name
  it with `--blocked-by <n>` when that is an issue, else in a first comment
  starting `Blocked by:`. `agent-ready` (shaped: may be built without more
  design) is set on the operator's word, never on your own. `dependencies`
  and `security` are a dependency bot's: leave them.
- Where `gh-doctor`'s `issues:` line reads `stamp guard on`, a session's
  issue ends with these two lines, last in the body: `_Filed by a Claude
  session._` and, under it, `<!-- workboard:filed-by-session v1 -->`. The
  `gh` wrapper there refuses a session's `gh issue create` without them and
  prints them. Anywhere else write neither. The board's `add` writes both
  itself. Never put them on text you did not write, and never remove them.
