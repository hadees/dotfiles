# User memory

Machine-local notes (terminal, OS) live in the import below; bootstrap.sh
generates it per machine. Like ~/.extra, it is never committed.

@~/.claude/CLAUDE.local.md

## GitHub accounts (gh CLI)

- Two gh accounts are logged in: work `icaevan` (icanalytica/icarichie orgs)
  and personal `hadees`. hadees is NOT an icanalytica member — it sees only
  public repos there, so org-scoped results as hadees are silently incomplete.
- A `gh()` wrapper in ~/.functions pins the token per invocation: an explicit
  icanalytica/icarichie/hadees owner in the arguments wins, else the repo's
  origin host alias (`github-icaevan:` / `github-hadees:`), else the active
  account. It never runs `gh auth switch`.
- If org-scoped gh output looks thin or wrong, don't trust the active account:
  pin it explicitly with `GH_TOKEN=$(gh auth token --user icaevan) gh …`.
  A working per-repo call does NOT confirm the right account — per-repo access
  and org-wide visibility differ.

## Output formatting

- Write URLs as bare plain-text URLs (https://...) on their own line, with no
  trailing punctuation. Never use markdown [text](url) link syntax — bare URLs
  are auto-detected and clickable in my terminal; markdown links hide the URL.
- Write file paths as plain absolute paths on their own line, for the same
  reason.
