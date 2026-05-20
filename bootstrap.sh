#!/usr/bin/env bash

cd "$(dirname "${BASH_SOURCE}")";

git pull origin master;

function doIt() {
	rsync --exclude ".git/" \
		--exclude ".DS_Store" \
		--exclude ".osx" \
		--exclude "bootstrap.sh" \
		--exclude "README.md" \
		--exclude "LICENSE-MIT.txt" \
		--exclude "Brewfile" \
		-avh --no-perms . ~;
	source ~/.zshrc;
	echo "";
	echo "Next steps on a new machine:";
	echo "  brew bundle          — install Brewfile packages";
	echo "  gpg --full-generate-key  — generate GPG key for commit signing";
	echo "  bash init/mackup.sh  — restore app settings from ~/.config/Mackup/";
}

if [ "$1" = "--force" -o "$1" = "-f" ]; then
	doIt;
else
	printf "This may overwrite existing files in your home directory. Are you sure? (y/n) ";
	read REPLY;
	echo "";
	if [[ $REPLY =~ ^[Yy]$ ]]; then
		doIt;
	fi;
fi;
unset doIt;
