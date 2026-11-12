---
paths:
  - "**/.claude/skills/onepassword/**"
  - "**/tests/onepassword.bats"
---

# 1Password

1Password is load-bearing in three unrelated places — it holds the SSH keys,
it signs every commit, and it is where `~/.extra`'s secrets come from at
apply time — over **three connections that fail independently**:

1. the `op` CLI → the desktop app via `~/.config/op/op-daemon.sock`, gated by
   `op signin` and a session that lapses;
2. `ssh` and git-over-ssh → the agent socket named by `~/.ssh/config`'s
   `IdentityAgent` (macOS: inside the app's group container — `~/.1password/
   agent.sock` is the **Linux** path, and this repo deliberately names the
   real one);
3. `op-ssh-sign` → its own connection to the app.

Treating those as one channel is the source of nearly every wasted hour here.
Verified: **`op-ssh-sign` never reads `SSH_AUTH_SOCK`** (it signs with the
variable unset, at the launchd default, and pointed at a nonexistent path),
and **`ssh-add` never reads `~/.ssh/config`** (it speaks only to
`$SSH_AUTH_SOCK`, which under Claude Code's Bash tool is macOS's launchd
agent). So `ssh-add -l` listing keys is not evidence a commit will sign, and
"The agent has no identities" is not evidence anything is broken.

The concrete symptom that costs time: `git commit` dying with
`error: 1Password: failed to fill whole buffer` / `fatal: failed to write
commit object` while the agent lists keys and the app is running. That string
is inside `op-ssh-sign` (Rust's `read_exact` error) and means the app's reply
came up short — locked, approval unanswered, or restarting. It clears on
unlock/approve + retry with **no config change**, which is itself the proof
that nothing is misconfigured. Never respond by committing unsigned or
turning `commit.gpgsign` off.

`onepassword-doctor` reports all three channels separately (`ssh -G` for the
`IdentityAgent`, `$SSH_AUTH_SOCK` on its own line), whether `~/.extra`
mentions a routed token (**names only, never a value**), and a `skill:` line
comparing the notes' version stamp to what is installed. `doctor` runs it. Versions come off the install without executing anything
— the CLI is a **cask**, so `bin_trace` reads it out of the Caskroom path,
and the app's version comes from its `Info.plist`.

The long form lives in the **`onepassword` skill**
(`.claude/skills/onepassword/`, dot-prefixed so chezmoi never deploys it):
the triage table, the `op` command surface and secret-reference grammar, the
SSH agent in depth (`agent.toml`, the OpenSSH six-key limit), and 1Password's
own release cadence and changelog locations. `VERSIONS` in that directory is
the stamp the doctor compares against — **bump it only together with
re-verifying the claims**, since a bumped stamp over stale prose silences the
nudge without fixing anything. Tests: `tests/onepassword.bats` (stub
op/ssh/ssh-add, sandboxed HOME; no vault or network touched).
