# User memory

Machine-local notes (terminal, OS) live in the first import below; chezmoi
generates it per machine and it is never committed. The second import carries
work-specific notes (accounts, orgs) and is deployed only by the private
overlay repo — this file is public, so it must not name them. Both imports are
simply unresolved on a machine that lacks them.

@~/.claude/CLAUDE.local.md
@~/.claude/CLAUDE.work.md

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

## Output formatting

- Write URLs as bare plain-text URLs (https://...) on their own line, with no
  trailing punctuation. Never use markdown [text](url) link syntax — bare URLs
  are auto-detected and clickable in my terminal; markdown links hide the URL.
- Write file paths as plain absolute paths on their own line, for the same
  reason.
