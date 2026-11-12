---
paths:
  - "**/dot_functions"
---

# dot_functions

Deployed as `.functions` and sourced by every zsh, including the one
Claude Code's Bash tool runs. That shell lacks the interactive options
(`NO_BARE_GLOB_QUAL` among them), so a function that globs or relies on an
option starts with `emulate -L zsh`.

The rules for `claude()`, `wrangler()`, `hermes()`, `routes` and the
doctors loaded with this file. Parts of other tools live here too; read
the rule before changing them:

- the `ssh`/`scp`/`sftp`/`curl` wrappers and `tailnet-doctor`: `tailnet.md`
- `workset()`, `workset_profile()`, `workset-doctor`: `workset.md`
- `update()`: `packages.md`
- `tabstatus`, `tabstatus_wiring`, `iterm2-cookie` and `iterm2_cookie_state`, and the terminal-title export in `claude()`: `cc-status-shim.md`
- the `BROWSER` pair in `claude()`, `claude_browser_alias`: `browser-routing.md`
- `onepassword-doctor`: `onepassword.md`
- `iterm2-doctor` and its `stamp`: `iterm2-skill.md`
- `dotfiles()` composing `allowed_signers`: `composed-identity-files.md`
