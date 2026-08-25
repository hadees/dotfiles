# Shared user memory

Imported by every Claude Code profile (see "Claude Code profiles" in the
dotfiles CLAUDE.md). Keep this file free of anything account-, org-, or
employer-specific — profile-specific memory belongs in that profile's own
`CLAUDE.work.md` or `CLAUDE.local.md`.

## GitHub accounts (gh CLI)

- More than one gh account may be logged in. A `gh()` wrapper in ~/.functions
  pins the token per invocation instead of ever running `gh auth switch`, so
  it never mutates the global active account.
- It reads the owner → account mapping at runtime from the
  `credential.https://github.com/<owner>.username` pins in git config, so no
  account or org names live in this repo. Adding an org is a one-line
  gitconfig change. With no pins present, `gh` behaves normally.
- Precedence: an explicit owner in the arguments wins, else the owner parsed
  from the repo's origin remote, else the active account. Arguments outrank
  the cwd because org-scoped commands name their target and the repo you are
  standing in says nothing about it.
- If org-scoped gh output looks thin or wrong, don't trust the active account:
  pin it explicitly with `GH_TOKEN=$(gh auth token --user <acct>) gh …`.
  A working per-repo call does NOT confirm the right account — per-repo access
  and org-wide visibility differ.

## Working in other repos' checkouts

- If a task takes you into a repo other than the one the session was
  started in, NEVER work on that repo's live checkout: check out your own
  worktree of it (EnterWorktree, or `git worktree add`) and do the work
  there. Another session, agent, or tool may be using that checkout right
  now, and a branch switch or edit changes the tree under it mid-run
  (learned 2026-08-22: a branch switch in a shared checkout swapped the
  content under another session's live production deploy). Apply this even
  when the checkout looks idle — you cannot see other sessions' intent.
- The rule is about the working tree. Machine-local `git config` in that
  repo, and read-only commands (`git log`, `grep`, reading files on the
  current branch), are fine directly.
- The repo the session was started in is exempt — that checkout is yours
  (subject to whatever the user is doing in it; stash-and-restore or a
  worktree is still the polite default when its tree is dirty).

## Web fetching

- If WebFetch fails on a resource you need (blocked page, JS-rendered
  content, an error response), retry it through the fetcher MCP tools
  (`mcp__fetcher__fetch_url` / `fetch_urls` — they drive a real browser)
  before giving up. Pass the same fallback instruction to any research
  subagent you brief. If a resource still won't load, say so explicitly in
  the result instead of silently omitting it.

## Output formatting

- Write URLs as bare plain-text URLs (https://...) on their own line, with no
  trailing punctuation. Never use markdown [text](url) link syntax — bare URLs
  are auto-detected and clickable in my terminal; markdown links hide the URL.
- Write file paths as plain absolute paths on their own line, for the same
  reason.

## Naming

- Names for code (modules, classes, tools, dirs, fields) come from the repo you
  are working in and what the thing actually is — never from an example or
  reference repo you are only pointing to for technique. Port the mechanism, then
  re-derive every identifier from the target repo's domain and the artifact's real
  purpose. This holds even when I start the session in one repo and ask for work
  in another: the repo being changed names its own things.
- Don't carry a name across just because a source repo used it. Look at each
  borrowed name critically; if one slips in, flag it and rename it (learned
  2026-08-25: a per-paper summary layer got called "cards" only because it reused
  scraping technique from a reference repo whose own name contained "cards" — the
  name had nothing to do with what the artifact was; renamed to "synopsis").
