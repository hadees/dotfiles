## Commit signing failures (1Password)

- Commits are signed with SSH-format signatures through 1Password's
  `op-ssh-sign`; there is no GPG keypair despite the `gpgsign` name. Three
  connections fail independently: the `op` CLI to the app, `ssh` to the
  agent socket named in `~/.ssh/config`, and `op-ssh-sign`'s own link to
  the app. `op-ssh-sign` never reads `SSH_AUTH_SOCK`, and `ssh-add -l`
  speaks only to that variable — so an agent listing keys is not evidence a
  commit will sign, and "The agent has no identities" is not evidence
  anything is broken.
- `git commit` dying with `error: 1Password: failed to fill whole buffer` /
  `fatal: failed to write commit object` means the app's reply came up
  short: locked, an approval prompt unanswered, or the app restarting. Tell
  me to unlock or approve, then retry the same commit. It clears with **no
  config change**, which is the proof nothing is misconfigured.
- Never work around it: no `--no-gpg-sign`, no `commit.gpgsign = false`, no
  repo-local `user.signingkey` or `user.email`. Identity and signing come
  from the include chain keyed on the remote URL.
- `git-doctor` shows the selected identity, signing config, and whether the
  key and signer exist; `onepassword-doctor` reports the three channels
  separately; `doctor` runs every doctor.
