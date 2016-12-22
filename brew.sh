#!/usr/bin/env bash

# Install command-line tools using Homebrew.

# Make sure we’re using the latest Homebrew.
brew update

# Upgrade any already-installed formulae.
brew upgrade

# Install GNU core utilities (those that come with macOS are outdated).
# Don’t forget to add `$(brew --prefix coreutils)/libexec/gnubin` to `$PATH`.
brew install coreutils

# Install some other useful utilities like `sponge`.
brew install moreutils
# Install GNU `find`, `locate`, `updatedb`, and `xargs`, `g`-prefixed.
brew install findutils
# Install GNU `sed`, overwriting the built-in `sed`.
brew install gnu-sed --with-default-names
# Install Bash 4.
# Note: don’t forget to add `/usr/local/bin/bash` to `/etc/shells` before
# running `chsh`.
brew install bash
brew tap homebrew/versions
brew install bash-completion2

# Switch to using brew-installed bash as default shell
if ! fgrep -q '/usr/local/bin/bash' /etc/shells; then
  echo '/usr/local/bin/bash' | sudo tee -a /etc/shells;
  chsh -s /usr/local/bin/bash;
fi;

# Install `wget` with IRI support.
brew install wget --with-iri

# Install more recent versions of some macOS tools.
brew install vim --with-override-system-vi
brew install homebrew/dupes/grep
brew install homebrew/dupes/openssh
brew install homebrew/dupes/screen
brew install homebrew/php/php56 --with-gmp

# Install font tools.
brew tap bramstein/webfonttools
brew install sfnt2woff
brew install sfnt2woff-zopfli
brew install woff2


# Install other useful binaries.
brew install ack
brew install aircrack-ng
brew install awscli
brew install bfg
brew install binutils
brew install binwalk
brew install cifer
brew install dark-mode
brew install dex2jar
brew install dns2tcp
brew install elasticsearch
brew install fcrackzip
brew install ffmpeg
brew install foremost
brew install git
brew install git-flow-avh
brew install git-lfs
brew install hashpump
brew install heroku-toolbelt
brew install hub
brew install hydra
brew install imagemagick --with-webp
brew install john
brew install knock
brew install libxml2
brew install lua
brew install lynx
brew install netpbm
brew install ngrep
brew install nmap
brew install node
brew install p7zip
brew install pigz
brew install pngcheck
brew install postgres
brew install pv
brew install rbenv
brew install redis
brew install rename
brew install ruby-build
brew install socat
brew install speedtest_cli
brew install speedtest_cli
brew install sqlmap
brew install ssh-copy-id
brew install tcpflow
brew install tcpreplay
brew install tcptrace
brew install testssl
brew install tree
brew install ucspi-tcp # `tcpserver` etc.
brew install vbindiff
brew install webkit2png
brew install xpdf
brew install xz
brew install zopfli

# Remove outdated versions from the cellar.
brew cleanup
