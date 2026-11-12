---
paths:
  - "**/dot_functions"
  - "**/tests/git-doctor.bats"
---

# The doctors

`wrangler-doctor` traces the wrangler routing for the cwd (pin, mapping,
profile existence, binding, what wrangler will use) without running
wrangler; `gh-doctor` and `claude-doctor` do the same for their wrappers
(`gh-doctor` also verifies the stored token really authenticates as the
pinned account, since gh's keyring has handed back the wrong one before;
its `pins:` line flags a pin recorded with a capital: the wrappers and hooks
lowercase the owner before looking it up, so they need the lowercase pin,
while git's own credential match is case-sensitive, so a remote spelled with
capitals still needs that spelling as well),
and `git-doctor` covers git itself: the commit identity the include chain
selected and which file supplied it, signing config and whether its
key/signer exist, the origin's SSH alias resolution, https credential
routing. Each wrapper's doctor also prints a `binary:` line — which
executable will run, a version-manager shim followed to the install it
selects for the cwd (or "not installed under the selected node"), and the
version read off the install without executing it (npm `package.json`,
cask/native path segment). `doctor` runs them all (git, gh, claude,
wrangler, hermes, tailnet, worktabs, postbox, remote-mcp, workset, onepassword,
iterm2 — the last two
are not per-repo, but 1Password is what signing and `~/.extra` rest on and
iTerm2 is the terminal the rest run inside, so their failures arrive
disguised as per-repo ones). Every doctor also opens with a `defined:` line — are
the helpers its wrapper (and the doctor itself) call actually defined in
this shell — printed before any line that depends on one, because a
missing helper makes a doctor misreport confidently (`account: <no pin
matched>`) rather than fail; Claude Code's shell snapshot has dropped
functions silently before. The lists are checked against the function
bodies by `tests/git-doctor.bats`, so they cannot go stale.
`tailnet-doctor` adds `helpers:` — it runs the wrappers' real decision
path on a loopback URL and a host no tailnet has and reports the first
thing that goes wrong; the wrappers fail open, so a broken helper is
silent there and this is where it shows. `doctor` itself opens with a
`shell:` line — zsh version, `under Claude Code` when its Bash tool is
the caller, and the calling shell's non-default pattern/glob options —
read before any `emulate`, so a pasted transcript says which shell it
came from.

`iterm2-cookie` is the verb `iterm2-doctor` will point at, not a doctor: it
mints the API cookie the hooks read, and `iterm2_cookie_state` names whether
that cookie is fresh, stale, rejected or absent (see `cc-status-shim.md`).

`iterm2-doctor` prints two lines after `cc-status:`. `cookie:` is the static
state (`fresh`, `stale`, `rejected`, `absent`, each with the fix); whether
iTerm2 accepts the cookie is `iterm2-cookie status`'s question. `osascript:`
is the size of `~/.local/state/iterm2/uncookied` (hook events that ran without a
cookie), that file's birth time, and the number of processes whose command
line contains `request cookie and key for app named`, from one `ps`; `0 … since
never` when the file does not exist. `iterm2_cookie_state` is in its `defined:`
list.

`iterm2-doctor` then prints `hooks:` and `shim:`. `hooks:` is one line per
profile directory that has a `settings.json` (from `claude_profile_dirs`:
`~/.claude`, `$CLAUDE_CONFIG_DIR`, every `claude.profile.*` value): iTerm2
3.7.7's health check `passes (10/10 owned)` or `FAILS (K/10 owned)`, how many
events run the handler first and how many carry a raw iTerm2 entry beside the
shim, and a marker on the directory iTerm2's launch alert reads
(`NoSyncClaudeCodeConfigDirPath`). The judgement is the 3.7.7 rule, so read it
with the `skill:` line. `shim:` is `can paint`, `cannot paint: <reason>` or
`MISSING`, decided from the shim's `explain after` (which calls nothing; the
doctor still runs nothing of iTerm2's). `tabstatus_wiring` and
`claude_profile_dirs` are in its `defined:` list.
