#!/usr/bin/env bash

# Start
echo "`basename $0` starting."

# Link Homebrew casks in `/Applications` rather than `~/Applications`
export HOMEBREW_CASK_OPTS="--appdir=/Applications"

# Ask for the administrator password upfront
sudo -v

# setup taps
brew tap caskroom/fonts

# install applications
brew install Caskroom/cask/1password
brew install Caskroom/cask/airserver
brew install Caskroom/cask/alfred
brew install Caskroom/cask/anki
brew install Caskroom/cask/bartender
brew install Caskroom/cask/caffeine
brew install Caskroom/cask/cocktail
brew install Caskroom/cask/colloquy
brew install Caskroom/cask/controlplane
brew install Caskroom/cask/crashplan
brew install Caskroom/cask/dropbox
brew install Caskroom/cask/fantastical
brew install Caskroom/cask/firefox
brew install Caskroom/cask/flux
brew install Caskroom/cask/github-desktop
brew install Caskroom/cask/google-chrome
brew install Caskroom/cask/google-drive
brew install Caskroom/cask/handbrake
brew install Caskroom/cask/horndis
brew install Caskroom/cask/istat-menus
brew install Caskroom/cask/iterm2
brew install Caskroom/cask/jdiskreport
brew install Caskroom/cask/kodi
brew install Caskroom/cask/libreoffice
brew install Caskroom/cask/little-snitch
brew install Caskroom/cask/mackup
brew install Caskroom/cask/macvim
brew install Caskroom/cask/moom
brew install Caskroom/cask/namechanger
brew install Caskroom/cask/ngrok
brew install Caskroom/cask/nzbvortex
brew install Caskroom/cask/opera
brew install Caskroom/cask/screenhero
brew install Caskroom/cask/simple-comic
brew install Caskroom/cask/slack
brew install Caskroom/cask/sourcetree
brew install Caskroom/cask/spotify
brew install Caskroom/cask/steam
brew install Caskroom/cask/sublime-text
brew install Caskroom/cask/the-unarchiver
brew install Caskroom/cask/tower
brew install Caskroom/cask/transmission
brew install Caskroom/cask/virtualbox
brew install Caskroom/cask/vlc
brew install Caskroom/cask/xscreensaver

# install fonts
brew install Caskroom/cask/font-source-code-pro
brew install Caskroom/cask/font-source-code-pro-for-powerline
brew install Caskroom/cask/font-fira-sans

# cleanup unneeded files
brew cleanup

# Finished
echo "`basename $0` complete."
