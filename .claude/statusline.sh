#!/usr/bin/env bash

# Claude Code status line:
#   (venv) (direnv:dir) org/repo[/subdir] on branch [+!?$] ↑N↓N pr N as @ghuser via Model ctx N% +N/-N <spinner>
# Git status flags: + staged, ! unstaged, ? untracked, $ stashed.
#
# Design rule: every segment is optional and self-hiding. Each probe carries
# its own guard, so a machine missing git, a GitHub identity, lsof — even jq —
# renders whatever segments it can and never prints an error or exits non-zero.
# Colors come from the 16-color ANSI palette, so they track whatever color
# scheme the terminal uses.

# jq is the one parsing dependency: without it we can't read the JSON Claude
# Code pipes in, so render an empty status line rather than an error. The
# install step is where a missing jq should be reported — a human is watching
# then; nobody is watching a statusline subprocess fail every second.
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
cwd=$(jq -r '.workspace.current_dir // .cwd // empty' <<<"$input")
model=$(jq -r '.model.display_name // empty' <<<"$input")
session_id=$(jq -r '.session_id // empty' <<<"$input")
project_dir=$(jq -r '.workspace.project_dir // .cwd // empty' <<<"$input")
added=$(jq -r '.cost.total_lines_added // 0' <<<"$input")
removed=$(jq -r '.cost.total_lines_removed // 0' <<<"$input")
ctx_pct=$(jq -r '.context_window.used_percentage // empty' <<<"$input")

# ANSI palette colors — the terminal's own scheme decides the actual hues
grey=$'\033[90m'  red=$'\033[31m'    green=$'\033[32m'
blue=$'\033[34m'  magenta=$'\033[35m' cyan=$'\033[36m'
yellow=$'\033[33m' reset=$'\033[0m'

# Spinner frames and glyph accents, selected by the argument the statusLine
# command in settings.json passes ("braille", "nerd"; anything else means
# plain ASCII). The style lives in settings, never in edits to this file, so
# every installed copy stays byte-identical to the shipped asset. The glyphs
# are literal UTF-8, not $'\u' escapes — macOS ships bash 3.2, which lacks
# them. nerd needs a patched font: spinner U+EE06–U+EE0B, branch U+E0A0,
# GitHub U+F09B, model U+F06A9, ctx gauge U+F04C5, venv python U+E73C,
# direnv leaf U+F06C, pull request U+F407. Icons stand in for words, so
# nerd drops the grey "via"/"ctx"/"pr" labels rather than decorating them,
# and the venv/direnv segments drop their () text wrappers. braille renders
# in nearly any modern terminal.
case ${1-} in
braille)
	frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
	branch_icon='' user_icon='@' model_icon='' ctx_icon='' venv_icon='' direnv_icon='' pr_icon='' ;;
nerd)
	frames=('' '' '' '' '' '')
	branch_icon=' ' user_icon=' ' model_icon='󰚩 ' ctx_icon='󰓅 ' venv_icon=' ' direnv_icon=' ' pr_icon=' ' ;;
*)
	frames=('-' '\' '|' '/')
	branch_icon='' user_icon='@' model_icon='' ctx_icon='' venv_icon='' direnv_icon='' pr_icon='' ;;
esac

out=''

# venv segment — ACTIVATION-based: show only when $VIRTUAL_ENV is set and its
# dir still exists. A dormant .venv merely sitting in the project tree is not
# an active venv, so presence alone must not light it up; the -d guard hides a
# venv whose dir was deleted after activation. The statusline's env is frozen
# at Claude launch, so this reflects what was activated, not what's on disk.
if [[ -n ${VIRTUAL_ENV:-} && -d $VIRTUAL_ENV ]]; then
	# .venv/venv/.env/env is uninformative; name the segment for the project dir
	vname=${VIRTUAL_ENV##*/}
	case $vname in .venv|venv|.env|env) vp=${VIRTUAL_ENV%/*}; vname=${vp##*/} ;; esac
	if [[ -n $venv_icon ]]; then
		out+="${magenta}${venv_icon}${vname}${reset} "
	else
		out+="${magenta}(${vname})${reset} "
	fi
fi

# direnv segment — PRESENCE-based, unlike venv: walk up from $cwd to the
# nearest .envrc. Presence is the right signal here (an .envrc means the tree
# uses direnv) and re-reading the tree every render self-heals when the file
# is deleted — the frozen $DIRENV_DIR env var would just go stale.
d=$cwd
while [[ -n $d && $d != / ]]; do
	if [[ -e $d/.envrc ]]; then
		if [[ -n $direnv_icon ]]; then
			out+="${cyan}${direnv_icon}${d##*/}${reset} "
		else
			out+="${cyan}(direnv:${d##*/})${reset} "
		fi
		break
	fi
	d=${d%/*}
done

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

	# +!?$ flags via one porcelain call (one subprocess, not three diffs).
	# Each flag gets its own color — staged green, unstaged yellow, untracked
	# blue, stashed magenta — so the state reads at a glance by hue, without
	# parsing which punctuation made it into the brackets.
	porcelain=$(git -C "$cwd" status --porcelain 2>/dev/null)
	flags=''
	cut -c1 <<<"$porcelain" | grep -q '[MADRCT]' && flags+="${green}+${reset}"
	cut -c2 <<<"$porcelain" | grep -q '[MADRCT]' && flags+="${yellow}!${reset}"
	grep -q '^??' <<<"$porcelain" && flags+="${blue}?${reset}"
	git -C "$cwd" rev-parse --verify --quiet refs/stash >/dev/null && flags+="${magenta}\$${reset}"

	out+="${green}${repo}${rel}${reset}"
	out+=" ${grey}on${reset} ${blue}${branch_icon}${branch}${reset}"
	[[ -n $flags ]] && out+=" ${grey}[${reset}${flags}${grey}]${reset}"

	# The ↑↓ arrows below compare against origin's last-*fetched* state — the
	# remote-tracking ref only moves on fetch, so on a machine that never
	# fetches, "behind" reads 0 forever and nobody learns they should pull.
	# Keep it fresh: at most once per 5 minutes, fetch origin in the
	# background. The stamp file is touched *before* the attempt (and gates
	# the attempt) so an offline machine retries on the same 5-minute cadence
	# instead of every render. Prompts are disabled (GIT_TERMINAL_PROMPT=0,
	# ssh BatchMode): when auth would need a human, the fetch fails silently
	# and the counts just go stale. Opt out per repo or globally with
	# `git config statusline.fetch false`.
	git_dir=$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)
	if [[ -n $remote && -n $git_dir ]] &&
		[[ $(git -C "$cwd" config --get statusline.fetch 2>/dev/null) != false ]] &&
		[[ -z $(find "$git_dir" -maxdepth 1 -name statusline-fetch -mmin -5 2>/dev/null) ]] &&
		touch "$git_dir/statusline-fetch" 2>/dev/null; then
		(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -oBatchMode=yes' \
			git -C "$cwd" fetch --quiet origin >/dev/null 2>&1 </dev/null &)
	fi

	# commits ahead/behind origin; ↑/↓ are plain Unicode, no special font.
	# ↑ = local commits origin doesn't have, ↓ = origin commits you don't
	# have (time to pull); both at once means the branch has diverged.
	# @{upstream} is the configured counterpart; fall back to origin/<branch>
	# for branches that were never pushed with tracking set up.
	counts=$(git -C "$cwd" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null ||
		git -C "$cwd" rev-list --left-right --count "origin/${branch}...HEAD" 2>/dev/null)
	if [[ -n $counts ]]; then
		behind=${counts%%[!0-9]*} ahead=${counts##*[!0-9]}
		arrows=''
		(( ahead )) && arrows+="↑${ahead}"
		(( behind )) && arrows+="↓${behind}"
		[[ -n $arrows ]] && out+=" ${yellow}${arrows}${reset}"
	fi

	# Open-PR count for the repo, from the GitHub search API via gh. The
	# script renders every second, so the count is read from a cache file in
	# the git dir and refreshed in the background at most once per 5 minutes
	# — the same stamp-first throttle as the fetch above: touching the cache
	# gates the attempt, so a failing gh (offline, rate-limited, repo not
	# visible to the active account) retries on the cadence instead of every
	# render, and the segment just goes stale or stays hidden. The count is
	# whatever gh's active account can see. Hidden at zero: the segment
	# answers "are there open PRs?", so silence means no. Opt out per repo or
	# globally with `git config statusline.prcount false`.
	pr_file="$git_dir/statusline-prcount"
	if [[ -n $git_dir && $remote == *github* && $repo == */* ]] &&
		command -v gh >/dev/null 2>&1 &&
		[[ $(git -C "$cwd" config --get statusline.prcount 2>/dev/null) != false ]] &&
		[[ -z $(find "$git_dir" -maxdepth 1 -name statusline-prcount -mmin -5 2>/dev/null) ]] &&
		touch "$pr_file" 2>/dev/null; then
		(gh api "search/issues?q=repo:${repo}+type:pr+state:open" \
			--jq .total_count >"$pr_file.tmp" 2>/dev/null &&
			mv -f "$pr_file.tmp" "$pr_file" &)
	fi
	prcount=$(cat "$pr_file" 2>/dev/null)
	if [[ $prcount =~ ^[0-9]+$ ]] && (( prcount > 0 )); then
		if [[ -n $pr_icon ]]; then
			out+=" ${grey}${pr_icon}${reset}${blue}${prcount}${reset}"
		else
			out+=" ${grey}pr${reset} ${blue}${prcount}${reset}"
		fi
	fi

	# GitHub identity, two tiers. `git config github.user` is per-repo truth
	# (it follows includeIf-based work/personal identity schemes), so it wins.
	# Fallback: the gh CLI's active account, read straight from hosts.yml —
	# this script re-runs every second, so spawning `gh auth status` (slow) or
	# `gh api user` (network) is off the table. The awk matches the host
	# block's `user:` key exactly — hosts.yml also has a `users:` map of all
	# logged-in accounts, which must not false-match. The two tiers can
	# legitimately disagree: gh's login is who you call the API as, git
	# config is who you push as — which is why git config wins.
	gh_user=$(git -C "$cwd" config github.user 2>/dev/null)
	if [[ -z $gh_user && -r $HOME/.config/gh/hosts.yml ]]; then
		gh_user=$(awk '
			/^github\.com:/ { in_host = 1; next }
			in_host && /^[^[:space:]]/ { in_host = 0 }
			in_host && $1 == "user:" { print $2; exit }
		' "$HOME/.config/gh/hosts.yml" 2>/dev/null)
	fi
	[[ -n $gh_user ]] && out+=" ${grey}as${reset} ${magenta}${user_icon}${gh_user}${reset}"
else
	out+="${green}${cwd/#$HOME/~}${reset}"
fi

if [[ -n $model ]]; then
	if [[ -n $model_icon ]]; then
		out+=" ${cyan}${model_icon}${model}${reset}"
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
	if [[ -n $ctx_icon ]]; then
		out+=" ${grey}${ctx_icon}${reset}${ctx_color}${pct}%${reset}"
	else
		out+=" ${grey}ctx${reset} ${ctx_color}${pct}%${reset}"
	fi
fi

if (( added > 0 || removed > 0 )); then
	out+=" ${green}+${added}${reset}${grey}/${reset}${red}-${removed}${reset}"
fi

# Running-task spinner. The statusline JSON has no "work in progress" field,
# but every Bash tool call (foreground or background) and every subagent
# holds open an output file under the session's tasks dir until it finishes,
# so counting files some process holds open (lsof, deduped on the n field)
# equals the number of tasks running right now. This is observed behavior,
# not a documented interface — if the spinner stops appearing after a Claude
# Code update, re-check this path first. Needs statusLine.refreshInterval in
# settings.json: without it the statusline only re-renders on conversation
# events, which go quiet exactly when background work runs.
if [[ -n $session_id && -n $project_dir ]] && command -v lsof >/dev/null 2>&1; then
	tasks_dir="/tmp/claude-$(id -u)/$(sed 's/[^A-Za-z0-9]/-/g' <<<"$project_dir")/${session_id}/tasks"
	outputs=("$tasks_dir"/*.output)
	if [[ -e ${outputs[0]} || -L ${outputs[0]} ]]; then
		running=$(lsof -F n -- "${outputs[@]}" 2>/dev/null | sed -n 's/^n//p' | sort -u | grep -c .)
		if (( running > 0 )); then
			# The script is stateless across invocations, so key the frame
			# to the clock — each 1s refresh advances one frame.
			out+=" ${yellow}${frames[$(( $(date +%s) % ${#frames[@]} ))]}${reset}"
		fi
	fi
fi

printf '%s' "$out"
