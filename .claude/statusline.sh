#!/usr/bin/env bash

# Claude Code status line, styled after ~/.zsh_prompt (Base16 Eighties ANSI):
#   org/repo[/subdir] on  branch [+!?$] as @ghuser via Model +N/-N
# Status flags match the zsh prompt: + staged, ! unstaged, ? untracked, $ stashed.
# Branch glyph () requires a Nerd Font (SauceCodePro NFM, same as the prompt).

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
# Powerline branch glyph (U+E0A0), same as .zsh_prompt. Fonts aren't
# detectable from a script, so terminal identity is the proxy: iTerm is
# configured with the Nerd Font; in any other terminal, skip the glyph.
# LC_TERMINAL covers ssh sessions launched from iTerm.
glyph=''
if [[ $TERM_PROGRAM == iTerm.app || $LC_TERMINAL == iTerm2 ]]; then
	glyph=$(printf '\xee\x82\xa0')  # renders wide; no space needed after
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
	out+=" ${grey}on${reset} ${blue}${glyph}${branch}${reset}"
	[[ -n $flags ]] && out+=" ${red}[${flags}]${reset}"

	gh_user=$(git -C "$cwd" config github.user 2>/dev/null)
	[[ -n $gh_user ]] && out+=" ${grey}as${reset} ${magenta}@${gh_user}${reset}"
else
	out+="${green}${cwd/#$HOME/~}${reset}"
fi

[[ -n $model ]] && out+=" ${grey}via${reset} ${cyan}${model}${reset}"

# context usage: green until 60%, yellow until 85%, red after (near auto-compact)
if [[ -n $ctx_pct ]]; then
	pct=${ctx_pct%.*}
	if (( pct >= 85 )); then ctx_color=$red
	elif (( pct >= 60 )); then ctx_color=$yellow
	else ctx_color=$green
	fi
	out+=" ${grey}ctx${reset} ${ctx_color}${pct}%${reset}"
fi

if (( added > 0 || removed > 0 )); then
	out+=" ${green}+${added}${reset}${grey}/${reset}${red}-${removed}${reset}"
fi

printf '%s' "$out"
