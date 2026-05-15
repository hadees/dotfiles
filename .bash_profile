# This repository now targets zsh; upgrade Bash sessions to zsh automatically.
if command -v zsh >/dev/null 2>&1; then
	exec zsh -l
else
	echo "zsh is not available; continuing in bash with limited configuration." >&2
fi
