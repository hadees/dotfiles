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
- **Run `gh` plain — never prefix it with `GH_TOKEN=`.** The wrapper already
  pinned the token, and it is defined inside Claude Code's Bash tool too
  (`gh-doctor` prints `wrapper: gh: function` and the `account:` it resolved
  for the cwd). Where a pin matches, the wrapper replaces any `GH_TOKEN`
  you set, so the prefix does nothing; a pinned account with no stored token
  warns and runs as plain gh would.
- If org-scoped gh output looks thin or wrong, run `gh-doctor` and read its
  `account:` line before anything else. A working per-repo call does NOT
  confirm the right account — per-repo access and org-wide visibility
  differ. The pre-wrapper remedy still works and is the fallback when the
  wrapper genuinely is not there (`gh-doctor` says `wrapper: gh` is not a
  function, or the command runs through `sh`/`bash -c`, a script file, or a
  hook, none of which source `.functions`) or when it is broken:
  `GH_TOKEN=$(gh auth token --user <acct>) command gh …`. Keep it for
  that, not while the wrapper is fine.
