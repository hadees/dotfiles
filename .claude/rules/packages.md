---
paths:
  - "**/Brewfile"
  - "**/packages-apt.txt"
  - "**/packages-apt-wsl.txt"
  - "**/.chezmoiscripts/**"
  - "**/tests/packages.bats"
  - "**/tests/update.bats"
---

# Package lists

CLI tools are declared per-OS — `Brewfile` (macOS), `packages-apt.txt`
(Debian/Ubuntu/WSL), plus `packages-apt-wsl.txt` for what only makes sense
inside WSL (today: `wslu`, whose `wslview` gives `xdg-open` a Windows browser
to hand URLs to). The `wsl` class installs the shared list and then the WSL
one; every other Linux class installs only the shared one, and only the
lists it actually installs are hashed into the script, so editing the WSL
list does not re-run installs on a plain Linux box. **When adding or removing a tool, update every list
where it's available**, using each distro's native package name (e.g.
Ubuntu's `bat` package installs the binary as `batcat`; the shell config's
`command -v` guards tolerate the difference). If a tool exists on one
platform only, note it in the list file. Where the shell config reads a
tool's files it searches both layouts: `fd-find`'s `fdfind` binary, and
Ubuntu's `fzf` package keeping its zsh bindings under
`/usr/share/doc/fzf/examples` rather than Homebrew's `opt/fzf/shell`. Homebrew is deliberately not used
on Linux. The install scripts re-run automatically on `chezmoi apply`
whenever their list's hash changes; the `ephemeral` machine class never
runs them.

**Two paths install from the `Brewfile`, and both pass `--no-upgrade`.** The
`run_onchange_` script converges a machine when the list changes; `update()`
installs whatever the list declares and the machine lacks, so editing the
Brewfile is enough to get the tool. Neither upgrades, because `brew upgrade`
in `update()` already does that and `brew bundle`'s own upgrade pass is worse
at it: it re-downloads casks that update themselves (an `auto_updates` cask's
Caskroom record only looks stale) and dies on a `mas` app or a `.pkg` whose
installer wants a password — which the script, running with no terminal,
cannot answer. That failure used to abort the whole apply partway. Neither
path ever runs `brew bundle cleanup`: that uninstalls anything absent from the
list, which is not what converging a machine should mean.

`update()` still upgrades everything in place, `claude-code@latest` included.
`iterm2-relaunch brew:<cask>` (`iterm2-relaunch.md`) is only for an upgrade that
wants the terminal and its Claude sessions down: a session finds what is
outdated, upgrades whatever needs no quit, and relaunches for the rest. It
refuses a cask that updates itself (iTerm2's, whose Caskroom record only looks
stale) and one with a `pkg` or `installer` artifact, for the reason above: the
runner has no terminal to answer a password. When `update()` got there first the
row reads `is current` and nothing is quit.

`update()` itself always runs from `$HOME` and puts the shell back where it
started, whatever directory it was typed in — a removed cwd (a deleted
worktree, the usual way) is inherited by every child and each dies on its own
`getcwd`/`[[ -d $PWD ]]` check, and asdf shims resolve node/ruby/uv from the
nearest `.tool-versions` above the cwd, so a run typed inside a project would
update that project's toolchain instead of the global one pinned in
`~/.tool-versions`. `tests/update.bats` pins this.

**`update()` runs machine-local checks after the upgrades.** Every
`update.check` command in git config (repeatable, overlay-supplied — the
public repo names none) runs right after the no-sudo upgrades, while an
upgrade is still the obvious suspect for whatever it breaks: a service whose
networking a formula update changed, a cask a daemon reads secrets through.
A failing check never stops the update; each failure is repeated in a red
banner at the very end, past the softwareupdate and gem output that would
otherwise bury it. A value containing `;` must be quoted in the config file
(git reads a bare `;` as a comment) — `git config --add` does that for you.

**A half-installed cask is invisible to all of this.** A `.pkg` cask whose
installer never ran still leaves a Caskroom entry, so `brew bundle` counts it
as satisfied and never retries while the app is missing from `/Applications`.
`brew reinstall --cask <name>` from a terminal is the only way out.

**A skipped run is recorded as a successful one.** chezmoi keys a
`run_onchange_` script on its content hash and stores that hash in the
`entryState` bucket — *not* `scriptState`, and `chezmoi apply --force` does
not re-run it either. Both install scripts deliberately exit 0 when they
decline to do anything (no `apt-get`; no root and no passwordless sudo), so
that skip is written down as done and no later `chezmoi apply` will retry it,
however much the machine has changed underneath. Granting sudo afterwards
therefore installs nothing, silently, while `chezmoi status` stays clean. To
re-trigger: `chezmoi state delete-bucket --bucket=entryState` (re-applying
files is idempotent), or edit the list, which changes the hash. First hit on
a WSL box whose package install had skipped for want of sudo.

**`gh` is the one entry whose version matters.** The `gh()` wrapper and
`bin/git-credential-gh-user` resolve every account through it, so a box
without `gh` cannot route at all — and Ubuntu's build trails upstream badly
(24.04 ships 2.45.0). Add GitHub's own apt repo once per machine and the
`gh` line in `packages-apt.txt` then installs the current release from it
instead, upgrading with ordinary `apt upgrade`:

```sh
sudo mkdir -p -m 755 /etc/apt/keyrings
out=$(mktemp) && wget -nv -O"$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  && sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg < "$out" > /dev/null \
  && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update && sudo apt install gh
```

Do **not** use the snap — the GitHub CLI project actively discourages it
(sandbox breakage). Homebrew-on-Linux would also work and is deliberately
not used here.
