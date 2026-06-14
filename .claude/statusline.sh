#!/usr/bin/env bash

# Claude Code status line, styled after ~/.zsh_prompt (Gruvbox Dark ANSI):
#   org/repo[/subdir] on branch [+!?$] ↑N↓N as  ghuser 󰚩 Model 󰓅 N% +N/-N <spinner>
# Status flags match the zsh prompt: + staged, ! unstaged, ? untracked, $ stashed.
# Nerd Font glyphs (branch, github, model, ctx gauge) are shown only when
# ~/bin/has-glyphs confirms the terminal font renders them (over ssh: when
# the client is iTerm); other terminals degrade to plain text.

input=$(cat)
cwd=$(jq -r '.workspace.current_dir // .cwd // empty' <<<"$input")
model=$(jq -r '.model.display_name // empty' <<<"$input")
session_id=$(jq -r '.session_id // empty' <<<"$input")
project_dir=$(jq -r '.workspace.project_dir // .cwd // empty' <<<"$input")
added=$(jq -r '.cost.total_lines_added // 0' <<<"$input")
removed=$(jq -r '.cost.total_lines_removed // 0' <<<"$input")
ctx_pct=$(jq -r '.context_window.used_percentage // empty' <<<"$input")

# ANSI palette (terminal maps these to Gruvbox Dark, same as the prompt)
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

# Running work indicator. Each Bash tool call (foreground or background) and
# each subagent writes to <tasks_dir>/<id>.output and holds it open until it
# finishes, so counting open .output files = tasks running right now. Needs
# statusLine.refreshInterval in settings.json: without it the statusline only
# re-renders on conversation events, so the count would go stale while the
# session sits waiting on background work — exactly when it matters.
if [[ -n $session_id && -n $project_dir ]]; then
	tasks_dir="/tmp/claude-$(id -u)/$(sed 's/[^A-Za-z0-9]/-/g' <<<"$project_dir")/${session_id}/tasks"
	outputs=("$tasks_dir"/*.output)
	if [[ -e ${outputs[0]} || -L ${outputs[0]} ]]; then
		running=$(lsof -F n -- "${outputs[@]}" 2>/dev/null | sed -n 's/^n//p' | sort -u | grep -c .)
		if (( running > 0 )); then
			# Throbber. The script is stateless, so key the frame to the
			# clock — each 1s refresh advances one frame. Three tiers:
			# Fira Code's spinner glyphs (nf extra-progress_spinner_1..6,
			# gated separately from nf_on so a font with the core glyphs
			# but not these still degrades), then braille dots (regular
			# Unicode, so has-glyphs checks the OS fallback cascade rather
			# than the terminal font itself), then ASCII.
			frames=('-' '\' '|' '/')
			if [[ -n $nf_on ]] && "$HOME/bin/has-glyphs" ee06 ee07 ee08 ee09 ee0a ee0b 2>/dev/null; then
				frames=($'\xee\xb8\x86' $'\xee\xb8\x87' $'\xee\xb8\x88' \
					$'\xee\xb8\x89' $'\xee\xb8\x8a' $'\xee\xb8\x8b')
			elif "$HOME/bin/has-glyphs" 280b 2819 2839 2838 283c 2834 2826 2827 2807 280f 2>/dev/null; then
				frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
			fi
			out+=" ${yellow}${frames[$(( $(date +%s) % ${#frames[@]} ))]}${reset}"
		fi
	fi
fi

printf '%s' "$out"
