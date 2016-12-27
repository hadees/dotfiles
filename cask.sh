#!/usr/bin/env bash

# Start
echo "`basename $0` starting."

# Link Homebrew casks in `/Applications` rather than `~/Applications`
export HOMEBREW_CASK_OPTS="--appdir=/Applications"

# Ask for the administrator password upfront
sudo -v

# setup taps
brew tap caskroom/fonts

# install cask
brew install caskroom/cask/brew-cask

# install applications
brew cask install 1password
brew cask install airserver
brew cask install alfred
brew cask install anki
brew cask install bartender
brew cask install caffeine
brew cask install cocktail
brew cask install colloquy
brew cask install controlplane
brew cask install crashplan
brew cask install dropbox
brew cask install fantastical
brew cask install firefox
brew cask install flux
brew cask install github-desktop
brew cask install google-chrome
brew cask install google-drive
brew cask install handbrake
brew cask install horndis
brew cask install istat-menus
brew cask install iterm2
brew cask install java
brew cask install jdiskreport
brew cask install kodi
brew cask install libreoffice
brew cask install little-snitch
brew cask install macvim
brew cask install moom
brew cask install namechanger
brew cask install ngrok
brew cask install nzbvortex
brew cask install opera
brew cask install screenhero
brew cask install simple-comic
brew cask install slack
brew cask install sourcetree
brew cask install spotify
brew cask install steam
brew cask install the-unarchiver
brew cask install tower
brew cask install transmission
brew cask install virtualbox
brew cask install vlc
brew cask install xscreensaver

# install fonts
brew cask install font-source-code-pro
brew cask install font-source-code-pro-for-powerline
brew cask install font-fira-sans

# cleanup unneeded files
brew cleanup

# Finished
echo "`basename $0` complete."
