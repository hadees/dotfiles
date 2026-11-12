---
paths:
  - "**/private_dot_ssh/**"
  - "**/bin/executable_git-allowed-signers"
  - "**/tests/ssh-config.bats"
  - "**/tests/allowed-signers.bats"
---

# Composed files: one target, several owners

`~/.ssh/config` and `~/.config/git/allowed_signers` are the two targets that
**mix identities inside a single file** — a personal alias next to a work
one, a personal signer next to a work signer. chezmoi allows one source per
target, so neither file can live whole in any repo here: the work overlay
must not name the personal identity, the personal overlay must not name the
work one, and the public repo must name neither. Each is therefore assembled
from per-overlay fragments, and a machine composes exactly what its overlays
give it — a work-only box (the shared workstations) gets a correct file with
no personal lines and no conditional anywhere.

The two use different mechanisms, because only one of them can:

- **`~/.ssh/config`** is a skeleton in this repo (`private_dot_ssh/`) whose
  first line is `Include ~/.ssh/config.d/*.conf`; each overlay drops a
  fragment there. No generator — ssh includes natively, and an unmatched glob
  is not an error (`ssh -G` exits 0 on the bare skeleton).
- **`~/.config/git/allowed_signers`** has no include: `gpg.ssh.allowedSignersFile`
  names exactly one path. So `bin/git-allowed-signers` concatenates
  `~/.config/git/allowed_signers.d/*` into it. `dotfiles()` runs it **after**
  every overlay has applied — the same placement, and for the same reason, as
  the `touch ~/.finicky.ts` beside it: a `run_after_` script in any one source
  would compose before the other sources had deployed their fragments and be
  one apply stale. The path itself is machinery and lives in the public
  `.gitconfig`, so a repo matching no `includeIf` still verifies rather than
  erroring.

**The ordering rule is inverted between the two config languages, and this is
the thing to get right.** ssh_config: *"for each parameter, the first obtained
value will be used"* — so an earlier fragment wins, and the `Include` must sit
above `Host *` or the catch-all shadows everything. git: the *last* include
wins, which is why `.gitconfig` lists `~/.gitconfig.local` before
`~/.gitconfig.work` and work overrides personal. The fragments are numbered
`10-personal`, `20-work` so the ssh precedence is written down rather than
inherited from glob luck; under first-wins that means **personal outranks work
on any host both describe** — the opposite of what the same visual order means
in `.gitconfig`. Nothing overlaps today. `tests/ssh-config.bats` pins it by
renaming a fixture fragment and asserting the answer flips.

Signing keys are never copied to a machine to make this work: the shared
workstations sign and authenticate through an ssh agent **forwarded** from the
mac (`ForwardAgent yes`, scoped to those hosts in the work fragment), so the
private half stays in 1Password. See `git-identity.md`.

A third target is composed the same way and for the same reason, iTerm2's
preferences, but by merge rather than by include or concatenation, because
iTerm2 rewrites the file itself: see `iterm2-prefs.md`. There the later
fragment wins, as in `.gitconfig`.
