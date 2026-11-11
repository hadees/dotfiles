---
paths:
  - "**/dot_functions"
  - "**/tests/routes.bats"
---

# Which project routes where (`routes`)

The doctors answer "as whom, right *here*". `routes` answers it for every
project at once: **one row per repo, one column per wrapper** — account,
Claude profile, wrangler profile, tailnet, hermes profile, worktabs group,
postbox agent name, and with `-l` the commit identity and the gate's verdict
on it.

```
PROJECT           ACCOUNT   CLAUDE            WRANGLER    TAILNET      HERMES
some-project      acct-a    .claude           acct-a-cf   net-a        -
side-project      acct-a    .claude           other-cf*   net-a        -
another           acct-b    .claude-other     acct-b-cf   net-b!       some-agent

12 projects under ~/code — acct-a 7, acct-b 4, unpinned 1
* per-repo pin, outranking the account mapping   ! mapped but not created on this machine
```

Every cell is produced by calling the wrapper's **own** resolver
(`gh_account_for_cwd`, `claude_profile_dir`, `wrangler_profile`,
`tailnet_for_cwd`, `identity_expected`) in a subshell cd'd into the repo, so
a row cannot claim something the wrapper would not do — the same anti-drift
rule the doctors follow, applied across the fleet. The `tabs` column is not
re-derived either: it reads `worktabs plan`, which already decides group,
directory and usability.

Decisions worth keeping:

- **The project list is machine-local, like every other list here.** Roots
  come from arguments, else `routes.root` in git config (repeatable,
  overlay-supplied), else `~/code`. Real project paths are identity-bearing
  and never land in this repo. The walk is two deep and **stops at the first
  repo**, so a flat `~/code/<repo>` and a nested `~/code/<owner>/<repo>` both
  work while a worktree or vendored checkout inside a project is never
  listed beside it.
- **The override variables are unset in the probe.** `CLAUDE_PROFILE`,
  `WRANGLER_PROFILE` and `TAILNET` override one invocation; leaving one set
  would stamp itself down a whole column and describe none of the repos. When
  one is set the footer says so rather than silently ignoring it.
- **Two suffixes carry what only a fleet view can show.** `*` is a per-repo
  pin outranking the account mapping; `!` is *mapped but never created on
  this machine* — a Claude profile directory, wrangler profile, tailnet or
  hermes profile that a repo routes to and that does not exist here. That is
  the failure the per-repo doctors can only find one repo at a time, and the
  one that greets you as "wrong account" months later.
- **A column no project uses is dropped** and named in the footer, so a
  machine with no hermes or wrangler pins gets a narrow table instead of a
  field of dashes — the same stance as `tailnet-doctor`'s mount lines.
  `--tsv` is the exception: it keeps all eleven fields in a fixed order
  whatever is empty, so a script can index them (`worktabs plan` is the same
  idea).
- **Rows sort by account, unpinned last, and the rank is a digit** — not a
  punctuation character. `${(o)}` collates by locale, and `~` sorts *before*
  letters in en_US, which put every unpinned repo on top of the first draft.
- The gate verdict shares `identity_expected` with `git-doctor` rather than
  re-deriving the per-repo-pin-beats-account precedence, so the two cannot
  disagree about which email a repo is allowed to commit under.

`routes` is deliberately **not** in the `doctor` aggregator: `doctor` is the
per-cwd diagnosis you run inside one repo, this is the survey across all of
them. Tests: `tests/routes.bats` (sandboxed HOME, fixture repos and pins,
stub worktabs; no real account names, no installation touched).
