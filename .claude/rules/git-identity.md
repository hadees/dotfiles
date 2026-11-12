---
paths:
  - "**/bin/executable_git-ssh-pinned"
  - "**/bin/executable_git-credential-gh-user"
  - "**/dot_gitconfig"
  - "**/tests/git-ssh-pinned.bats"
  - "**/tests/git-credential-gh-user.bats"
  - "**/tests/gh-wrapper.bats"
---

# Commit signing

Commits are signed with **SSH-format signatures via 1Password**, not GPG.
Signing is entirely machine-local: the tracked `.gitconfig` does NOT enable
it, so a fresh machine defaults to unsigned commits instead of failing on a
missing signer. Each machine opts in via untracked files:

- `~/.gitconfig.local` (from the private overlay) and any per-identity include
  it pulls in set `commit.gpgsign = true`, `gpg.format = ssh`,
  `gpg.ssh.program = .../op-ssh-sign`, and
  `user.signingkey = ~/.ssh/*.pub`.
- `~/.ssh/config` points `IdentityAgent` at the 1Password agent socket; the
  private keys live in 1Password and never touch disk. The `.pub` files are
  just selectors.

**Which key authenticates a `git@github.com:` remote** is the same question
for ssh that the credential helper answers for https (which it does for
`github.com` and `gist.github.com` only, and declines silently for any other
host or for plain http), and it has the same answer: `bin/git-ssh-pinned`, installed as `core.sshCommand` by the
overlays. With several GitHub keys in one agent, ssh offers them in the
agent's order and GitHub takes the first that authenticates — so a plain
`git@github.com:` URL lands on whichever account owns *that* key, and every
other account's private repos are "Repository not found". The old fix was a
per-account `Host github-<account>` alias in every remote URL. The helper
reads the owner out of the remote command git hands it (`git-upload-pack
'<owner>/<repo>.git'`), resolves it through the credential pins to an
account, and runs `ssh -o IdentitiesOnly=yes -i <identity.<account>.sshkey>`
— a `.pub` selector; the private half stays in 1Password. It touches nothing
else: an alias host, an unpinned owner, an account with no key declared, a
non-GitHub host, or git's `-G` variant probe all pass through untouched, and
`GIT_SSH_COMMAND=ssh` outranks it for one command. `identity.<owner>/<repo>
.sshkey` pins one repo (a deploy key, a side project) above its owner's
account, mirroring the gate's per-repo email pin. `git-doctor`'s `ssh:` line
traces the same lookup for the cwd. Tests: `tests/git-ssh-pinned.bats`
(stub ssh, sandboxed git config; the last test drives it through real git).
The WSL class keeps its `core.sshCommand = ssh.exe` — that ssh reads the
Windows-side config, where these key paths mean nothing.

On a machine without 1Password (e.g. a remote Linux box), nothing needs
disabling — signing is simply never enabled there. To sign on a remote you
keep around, forward your local 1Password SSH agent over the connection and
set `user.signingkey` to the literal public key (not `op-ssh-sign`, which
only exists locally). There is **no GPG keypair** in this setup despite the
`gpgsign` name.

When signing breaks, read `onepassword.md` before touching any config — the
usual failure is transient and not a misconfiguration at all.
