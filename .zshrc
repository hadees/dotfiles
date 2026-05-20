#!/usr/bin/env zsh

# Ensure ~/bin is on the PATH, keeping entries unique.
typeset -U path PATH
path=("$HOME/bin" $path)

# Load modular configuration files when present.
for file in ~/.{path,zsh_prompt,exports,aliases,functions,extra}; do
	if [[ -r "$file" && -f "$file" ]]; then
		source "$file"
	fi
done
unset file

# History configuration geared for interactive shells.
HISTFILE="${HOME}/.zsh_history"
HISTSIZE=32768
SAVEHIST=$HISTSIZE

setopt APPEND_HISTORY
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_VERIFY

# Shell quality-of-life options comparable to the prior Bash setup.
setopt AUTO_CD
setopt EXTENDED_GLOB
setopt GLOBSTARSHORT
setopt NO_CASE_GLOB
setopt PROMPT_SUBST

# Completion system setup, including Homebrew-provided definitions.
typeset -gU fpath
if (( $+commands[brew] )); then
	brew_prefix="$(brew --prefix 2>/dev/null)"
	if [[ -d "${brew_prefix}/share/zsh/site-functions" ]]; then
		fpath=("${brew_prefix}/share/zsh/site-functions" $fpath)
	fi
	if [[ -d "${brew_prefix}/share/zsh-completions" ]]; then
		fpath=("${brew_prefix}/share/zsh-completions" $fpath)
	fi
	unset brew_prefix
fi

autoload -Uz compinit
if [[ -n "${ZDOTDIR:-$HOME}/.zcompdump"(#qN.mh+24) ]]; then
	compinit
else
	compinit -C
fi

if (( $+functions[_git] )); then
	compdef _git g
fi

_defaults_completion() {
	compadd NSGlobalDomain
}
compdef _defaults_completion defaults

_killall_completion() {
	compadd Contacts Calendar Dock Finder Mail Safari SystemUIServer Terminal
}
compdef _killall_completion killall

# Runtime environment managers.
# asdf is the preferred multi-language manager; the per-language managers below
# are no-ops when not installed, so both setups coexist safely.
if (( $+commands[brew] )) && [[ -f "$(brew --prefix asdf 2>/dev/null)/libexec/asdf.sh" ]]; then
	source "$(brew --prefix asdf)/libexec/asdf.sh"
fi

if (( $+commands[rbenv] )); then
	eval "$(rbenv init - zsh)"
fi

if (( $+commands[nodenv] )); then
	eval "$(nodenv init - zsh)"
fi

if (( $+commands[pipenv] )); then
	eval "$(_PIPENV_COMPLETE=zsh_source pipenv)"
fi

if (( $+commands[pyenv] )); then
	eval "$(pyenv init -)"
fi

# fzf key bindings and completion.
if (( $+commands[brew] )) && [[ -f "$(brew --prefix fzf 2>/dev/null)/shell/key-bindings.zsh" ]]; then
	source "$(brew --prefix fzf)/shell/key-bindings.zsh"
fi
if (( $+commands[brew] )) && [[ -f "$(brew --prefix fzf 2>/dev/null)/shell/completion.zsh" ]]; then
	source "$(brew --prefix fzf)/shell/completion.zsh"
fi

# direnv: load/unload .envrc files per directory.
if (( $+commands[direnv] )); then
	eval "$(direnv hook zsh)"
fi

# zoxide: frecency-based directory jumping (replaces cd with z).
if (( $+commands[zoxide] )); then
	eval "$(zoxide init zsh)"
fi

# zsh plugins (installed via Homebrew).
# zsh-syntax-highlighting must be sourced last.
if (( $+commands[brew] )); then
	_brew_prefix="$(brew --prefix 2>/dev/null)"
	[[ -f "${_brew_prefix}/share/zsh-autosuggestions/zsh-autosuggestions.zsh" ]] &&
		source "${_brew_prefix}/share/zsh-autosuggestions/zsh-autosuggestions.zsh"
	[[ -f "${_brew_prefix}/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]] &&
		source "${_brew_prefix}/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
	unset _brew_prefix
fi

# Ensure gpg-agent is running so commit signing works.
# GPG Suite on macOS manages its own agent; gpgconf is a no-op if it's already up.
command -v gpgconf > /dev/null 2>&1 && gpgconf --launch gpg-agent

# Increase how many files can be opened at once.
ulimit -n 10480 2>/dev/null
