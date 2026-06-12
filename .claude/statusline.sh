#!/usr/bin/env bash

# Claude Code status line, styled after ~/.zsh_prompt (Base16 Eighties ANSI):
#   org/repo[/subdir] on branch [+!?$] ↑N↓N as  ghuser 󰚩 Model 󰓅 N% +N/-N
# Status flags match the zsh prompt: + staged, ! unstaged, ? untracked, $ stashed.
# Nerd Font glyphs (branch, github, model, ctx gauge) are shown only when
# ~/bin/has-glyphs confirms the terminal font renders them (over ssh: when
# the client is iTerm); other terminals degrade to plain text.

input=$(cat)
cwd=$(jq -r '.workspace.current_dir // .cwd // empty' <<<"$input")
model=$(jq -r '.model.display_name // empty' <<<"$input")
added=$(jq -r '.cost.total_lines_added // 0' <<<"$input")
removed=$(jq -r '.cost.total_lines_removed // 0' <<<"$input")
ctx_pct=$(jq -r '.context_window.used_percentage // empty' <<<"$input")

# ANSI palette (terminal maps these to Base16 Eighties, same as the prompt)
grey=$'\033[90m'  red=$'\033[31m'    green=$'\033[32m'
blue=$'\033[34m'  magenta=$'\033[35m' cyan=$'\033[36m'
yellow=$'\033[33m' reset=$'\033[0m'
# Nerd Font glyphs, same font as .zsh_prompt. Locally, has-glyphs asks
# CoreText whether the terminal's configured font can actually render them
# (cached). Over ssh the remote host can't inspect the local machine's fonts,
# so iTerm identity (LC_TERMINAL, forwarded by iTerm) stays as the proxy.
# Either way the fallback is plain text. printf -v keeps the trailing spaces
# that $(...) would strip.
# nf_github replaces the plain-text "@" rather than adding to it (icons
# stand in for words), matching ~/.zsh_prompt.
nf_branch='' nf_github='@' nf_model='' nf_ctx='' nf_on=''
if [[ -n ${SSH_TTY:-}${SSH_CONNECTION:-} ]]; then
	[[ ${LC_TERMINAL:-} == iTerm2 ]] && nf_on=1
elif [[ -x $HOME/bin/has-glyphs ]]; then
	"$HOME/bin/has-glyphs" e0a0 f09b f06a9 f04c5 2>/dev/null && nf_on=1
fi
if [[ -n $nf_on ]]; then
	printf -v nf_branch '\xee\x82\xa0 '     # U+E0A0 branch; glyph + space, as in .zsh_prompt
	printf -v nf_github '\xef\x82\x9b '     # U+F09B nf-fa-github
	printf -v nf_model '\xf3\xb0\x9a\xa9 '  # U+F06A9 nf-md-robot
	printf -v nf_ctx '\xf3\xb0\x93\x85 '    # U+F04C5 nf-md-speedometer
fi

out=''

toplevel=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
if [[ -n $toplevel ]]; then
	# org/repo from the origin URL (works for ssh and https), else dir name
	remote=$(git -C "$cwd" config --get remote.origin.url 2>/dev/null)
	repo=${remote%.git}
	repo=$(sed -E 's#^.*[:/]([^/]+/[^/]+)$#\1#' <<<"$repo")
	[[ -z $repo ]] && repo=$(basename "$toplevel")

	# path inside the repo, if we're below the root
	rel=${cwd#"$toplevel"}

	branch=$(git -C "$cwd" symbolic-ref --quiet --short HEAD 2>/dev/null ||
		git -C "$cwd" rev-parse --short HEAD 2>/dev/null)

	# +!?$ flags via one porcelain call (cheaper than the prompt's diff trio)
	porcelain=$(git -C "$cwd" status --porcelain 2>/dev/null)
	flags=''
	cut -c1 <<<"$porcelain" | grep -q '[MADRCT]' && flags+='+'
	cut -c2 <<<"$porcelain" | grep -q '[MADRCT]' && flags+='!'
	grep -q '^??' <<<"$porcelain" && flags+='?'
	git -C "$cwd" rev-parse --verify --quiet refs/stash >/dev/null && flags+='$'

	out+="${green}${repo}${rel}${reset}"
	out+=" ${grey}on${reset} ${blue}${nf_branch}${branch}${reset}"
	[[ -n $flags ]] && out+=" ${red}[${flags}]${reset}"

	# commits ahead/behind upstream; plain ↑/↓ render fine without a Nerd Font
	counts=$(git -C "$cwd" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)
	if [[ -n $counts ]]; then
		behind=${counts%%[!0-9]*} ahead=${counts##*[!0-9]}
		arrows=''
		(( ahead )) && arrows+="↑${ahead}"
		(( behind )) && arrows+="↓${behind}"
		[[ -n $arrows ]] && out+=" ${yellow}${arrows}${reset}"
	fi

	gh_user=$(git -C "$cwd" config github.user 2>/dev/null)
	[[ -n $gh_user ]] && out+=" ${grey}as${reset} ${magenta}${nf_github}${gh_user}${reset}"
else
	out+="${green}${cwd/#$HOME/~}${reset}"
fi

if [[ -n $model ]]; then
	if [[ -n $nf_model ]]; then
		out+=" ${cyan}${nf_model}${model}${reset}"
	else
		out+=" ${grey}via${reset} ${cyan}${model}${reset}"
	fi
fi

# context usage: green until 60%, yellow until 85%, red after (near auto-compact)
if [[ -n $ctx_pct ]]; then
	pct=${ctx_pct%.*}
	if (( pct >= 85 )); then ctx_color=$red
	elif (( pct >= 60 )); then ctx_color=$yellow
	else ctx_color=$green
	fi
	if [[ -n $nf_ctx ]]; then
		out+=" ${grey}${nf_ctx}${reset}${ctx_color}${pct}%${reset}"
	else
		out+=" ${grey}ctx${reset} ${ctx_color}${pct}%${reset}"
	fi
fi

if (( added > 0 || removed > 0 )); then
	out+=" ${green}+${added}${reset}${grey}/${reset}${red}-${removed}${reset}"
fi

printf '%s' "$out"
