---
name: run-dotfiles
description: Render, run, and drive these chezmoi dotfiles. Use when asked to run or apply the dotfiles, try a machine class, launch or screenshot the resulting zsh (prompt, wrappers, doctors), run the bats tests, or check what a real apply would change.
---

This is a chezmoi source, not an app: "running" it means rendering it into a
`$HOME` for a machine class and using the shell that results. Drive it via
`.claude/skills/run-dotfiles/driver.sh` — it renders into a **sandbox home**
(never the real one), runs one-shot commands in an interactive zsh there, or
starts that zsh under tmux so you can type at the prompt and capture the
pane. All paths are relative to the repo root.

## Prerequisites

Present on this Mac via Homebrew; on Ubuntu the CI equivalent is:

```bash
sudo apt-get install -y bats zsh git tmux
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
```

## Run (agent path)

Render a machine class into the sandbox (`/tmp/dotfiles-sandbox`; scripts —
package installers — are excluded, so this never runs `brew bundle`):

```bash
.claude/skills/run-dotfiles/driver.sh sandbox mac      # or linux | wsl | ephemeral
```

One-shot commands in an interactive zsh inside it (`.zshrc` and everything
it sources load; the wrappers and doctors are the interesting surface):

```bash
.claude/skills/run-dotfiles/driver.sh shell 'whence -w gh claude wrangler dotfiles doctor; doctor'
```

The public source alone has no identity, so every doctor reports
"no credential pin matched" — correct. To see routing work, stack overlays
(any chezmoi sources) on top and stand in a repo whose origin they pin:

```bash
OVERLAYS="$HOME/code/dotfiles-private" .claude/skills/run-dotfiles/driver.sh sandbox mac
.claude/skills/run-dotfiles/driver.sh shell 'cd ~ && git init -q demo && cd demo && git remote add origin github-<alias>:<owner>/demo.git && doctor'
```

Interactive (the "GUI" is the two-line prompt with git indicators):

```bash
.claude/skills/run-dotfiles/driver.sh tui
.claude/skills/run-dotfiles/driver.sh send 'cd ~ && git init -q demo && cd demo && touch a && git add a && echo x > b'
.claude/skills/run-dotfiles/driver.sh send 'wrangler-doctor | head -3'
.claude/skills/run-dotfiles/driver.sh pane      # → "… in ~/demo on main [+?]" then the doctor lines
.claude/skills/run-dotfiles/driver.sh stop
```

| command | what it does |
|---|---|
| `sandbox [class]` | fresh render into `$SANDBOX` (default `/tmp/dotfiles-sandbox`); `OVERLAYS="src …"` stacks more sources |
| `shell <cmd>` | run `<cmd>` in `zsh -i` with `HOME=$SANDBOX` (env otherwise empty, cwd = sandbox) |
| `tui` / `send` / `pane` / `stop` | tmux session `$TMUX_SESSION` (default `dotfiles`) running that zsh; `pane` is the screenshot |
| `live` | read-only view of the **real** machine: `chezmoi diff` for the public source and every overlay config, then `doctor` for the cwd |
| `test [args]` | `bats tests` |
| `clean` | remove sandbox + tmux session |

## Run (human path)

On a managed machine the daily loop is `chezmoi diff` then the `dotfiles`
shell function (applies the public source, then every overlay whose clone
exists, then touches `~/.finicky.ts`). `driver.sh live` shows what that
would change without doing it; the driver never applies to the real home.

## Test

```bash
.claude/skills/run-dotfiles/driver.sh test        # = bats tests; ~135 tests, a few minutes
```

CI runs the same on ubuntu, macOS, Rocky 9, and WSL. Some tests use
`git grep` and so only see **tracked** files — a new test file passes
locally until it is `git add`ed.

## Gotchas

- **The sandbox inherits PATH but not HOME**, so version-manager shims
  (asdf, nodenv) on PATH have no data dir: `asdf which` answers with the
  shim itself and node tools may fail to launch. The doctors' `binary:`
  line copes (prints the bare shim); anything that actually needs node in
  the sandbox should set `ASDF_DATA_DIR` or use a plain binary.
- **`gh auth token` / Keychain-backed logins are per real HOME.** In the
  sandbox `gh-doctor` reports no token and `claude-doctor` not logged in
  even when the real machine is — expected.
- **`--exclude scripts` is load-bearing.** A `mac`-class render without it
  runs the darwin `run_onchange_` scripts, i.e. `brew bundle`.
- **The prompt's ready marker is `$` at line start** (the second line of
  the two-line prompt), not `%`/`→`; the driver polls for that.
- **Standing in the sandbox matters.** The doctors resolve identity from
  the cwd's origin; running `shell` from a real repo would show that repo's
  routing, so the driver `cd`s into the sandbox first.

## Troubleshooting

- **`prompt never appeared`** from `tui`: the pane shows what did render;
  usually a sourced file errored — run `driver.sh shell true` to see the
  zsh error text.
- **`no sandbox at /tmp/dotfiles-sandbox`**: run `sandbox` first (also
  after `clean`).
