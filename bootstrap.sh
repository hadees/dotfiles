#!/usr/bin/env bash

# DEPRECATED: these dotfiles are now managed by chezmoi. This wrapper
# survives one release for muscle memory, then goes away.
#
#   Fresh machine:  sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply hadees
#   This clone:     chezmoi init --source . && chezmoi apply

cd "$(dirname "${BASH_SOURCE}")" || { return 1 2>/dev/null || exit 1; };

if ! command -v chezmoi > /dev/null 2>&1; then
	echo "chezmoi is not installed. Install it first:";
	echo "  brew install chezmoi                                       # macOS";
	echo "  sh -c \"\$(curl -fsLS get.chezmoi.io)\" -- -b ~/.local/bin   # anywhere";
	return 1 2>/dev/null || exit 1;
fi;

echo "bootstrap.sh is deprecated — applying via chezmoi instead.";
chezmoi init --source "$PWD" --apply;
