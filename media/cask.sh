#!/usr/bin/env bash

# Start
echo "`basename $0` starting."

# Link Homebrew casks in `/Applications` rather than `~/Applications`
export HOMEBREW_CASK_OPTS="--appdir=/Applications"

# Ask for the administrator password upfront
sudo -v

# setup taps
brew tap caskroom/versions
brew tap caskroom/fonts

# install cask
brew install caskroom/cask/brew-cask

# install applications
brew cask install kodi
brew cask install vlc
brew cask install java
brew cask install google-chrome
brew cask install transmission
brew cask install vlc
brew cask install crashplan
brew cask install handbrake
brew cask install airserver
brew cask install alfred
brew cask install spotify


# install fonts
brew cask install font-source-code-pro
brew cask install font-source-code-pro-for-powerline
brew cask install font-fira-sans

# cleanup unneeded files
brew cleanup

# Finished
echo "`basename $0` complete."
