# Hadees’ dotfiles

Managed with [chezmoi](https://www.chezmoi.io/). One repo targets macOS,
Linux, WSL, and disposable remote boxes; a **machine class** chosen at init
time (`mac` / `linux` / `wsl` / `ephemeral`) controls what gets deployed.

## Installation

**Warning:** If you want to give these dotfiles a try, you should first fork this repository, review the code, and remove things you don’t want or need. Don’t blindly use my settings unless you know what that entails. Use at your own risk!

### Fresh machine (one-liner, no root needed)

```bash
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply hadees
```

Installs chezmoi to `~/.local/bin`, clones this repo, prompts once for the
machine class, and applies.

### Disposable box (leave no trace)

```bash
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --one-shot hadees
```

Applies the dotfiles, then removes chezmoi, its source clone, and its config
from the machine. Answer `ephemeral` to the machine-class prompt: that class
deploys shell config only — no git identity and no secrets ever touch disk.
For commit signing on a box you keep around, forward your local 1Password
SSH agent (per-host `ForwardAgent yes`) instead of putting keys there.

### Development clone (macOS)

```bash
brew install chezmoi
git clone git@github.com:hadees/dotfiles.git ~/code/dotfiles
chezmoi init --source ~/code/dotfiles --apply
```

The `mac` machine class pins chezmoi’s `sourceDir` to the clone, so the
day-to-day loop is: edit files in `~/code/dotfiles`, review with
`chezmoi diff`, deploy with `chezmoi apply` (aliased to `dotfiles`).

### Specify the `$PATH`

If `~/.path` exists, it will be sourced along with the other files, before any feature testing (such as [detecting which version of `ls` is being used](https://github.com/mathiasbynens/dotfiles/blob/aff769fd75225d8f2e481185a71d5e05b76002dc/.aliases#L21-26)) takes place.

Here’s an example `~/.path` file that adds `/usr/local/bin` to the `$PATH`:

```bash
export PATH="/usr/local/bin:$PATH"
```

### Add custom commands without creating a new fork

If `~/.extra` exists, it will be sourced along with the other files. On
managed machines it is rendered by chezmoi from `private_dot_extra.tmpl`,
which pulls secret values out of 1Password at apply time — see CLAUDE.md
“Machine-local secrets” for the syntax. On the `ephemeral` machine class it
is never deployed at all.

You could also use `~/.extra` to override settings, functions and aliases from my dotfiles repository. It’s probably better to [fork this repository](https://github.com/hadees/dotfiles/fork) instead, though.

### Sensible macOS defaults

When setting up a new Mac, you may want to set some sensible macOS defaults:

```bash
./.macos
```

To keep separate machine names, export `COMPUTER_NAME` before running the script, e.g. `COMPUTER_NAME="Work-Mac" ./.macos`. If the variable is not set, the existing system name is left unchanged so each Mac can keep its own identity.

### Install Homebrew formulae

When setting up a new Mac, you may want to install some common [Homebrew](https://brew.sh/) formulae (after installing Homebrew, of course):

```bash
brew bundle
```

## Feedback

Suggestions/improvements [welcome](https://github.com/hadees/dotfiles/issues)!

## Thanks to…

* [Mathias Bynens](https://github.com/mathiasbynens/dotfiles/)
* @ptb and [his _macOS Setup_ repository](https://github.com/ptb/mac-setup)
* [Ben Alman](http://benalman.com/) and his [dotfiles repository](https://github.com/cowboy/dotfiles)
* [Cătălin Mariș](https://github.com/alrra) and his [dotfiles repository](https://github.com/alrra/dotfiles)
* [Gianni Chiappetta](https://butt.zone/) for sharing his [amazing collection of dotfiles](https://github.com/gf3/dotfiles)
* [Jan Moesen](http://jan.moesen.nu/) and his [ancient `.bash_profile`](https://gist.github.com/1156154) + [shiny _tilde_ repository](https://github.com/janmoesen/tilde)
* [Lauri ‘Lri’ Ranta](http://lri.me/) for sharing [loads of hidden preferences](http://osxnotes.net/defaults.html)
* [Matijs Brinkhuis](https://matijs.brinkhu.is/) and his [dotfiles repository](https://github.com/matijs/dotfiles)
* [Nicolas Gallagher](http://nicolasgallagher.com/) and his [dotfiles repository](https://github.com/necolas/dotfiles)
* [Sindre Sorhus](https://sindresorhus.com/)
* [Tom Ryder](https://sanctum.geek.nz/) and his [dotfiles repository](https://sanctum.geek.nz/cgit/dotfiles.git/about)
* [Kevin Suttle](http://kevinsuttle.com/) and his [dotfiles repository](https://github.com/kevinSuttle/dotfiles) and [macOS-Defaults project](https://github.com/kevinSuttle/macOS-Defaults), which aims to provide better documentation for [`~/.macos`](https://mths.be/macos)
* [Haralan Dobrev](https://hkdobrev.com/)
* Anyone who [contributed a patch](https://github.com/mathiasbynens/dotfiles/contributors) or [made a helpful suggestion](https://github.com/mathiasbynens/dotfiles/issues)
