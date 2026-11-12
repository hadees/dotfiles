#!/bin/sh
# CI only: put the fzf release named in .github/fzf-version on a runner.
#
#   sh .github/install-fzf.sh <directory>   download it, check it against the release's
#                                           own checksum file and the sha256 committed in
#                                           .github/fzf-sha256, install <directory>/fzf
#   sh .github/install-fzf.sh --check       fail unless the first fzf on PATH is that release
#
# Every job of .github/workflows/tests.yml that runs the suite does both. A runner image's
# package index is as old as the image (Homebrew's is frozen with auto-update off, a
# distribution's at its release), so an fzf taken from it is whatever the image held; the
# screen tests (tests/claude-peer-screen.bats) draw the picker, which needs 0.75 or newer.
# To move the pin, change the one line of .github/fzf-version and the four lines of
# .github/fzf-sha256 (`<sha256>  <asset>`, from the new release's checksum file), so a
# release re-published under the same version cannot pass. Not for a machine: those
# get fzf from the Brewfile and packages-apt.txt.
set -eu

[ $# -eq 1 ] || { echo 'usage: install-fzf.sh <directory> | --check' >&2; exit 2; }

here=$(cd "$(dirname "$0")" && pwd)
version=$(tr -d '[:space:]' <"$here/fzf-version")
case $version in
  ''|*[!0-9.]*) echo "install-fzf: $here/fzf-version does not hold a version: '$version'" >&2; exit 1;;
esac

if [ "$1" = --check ]; then
  found=$(command -v fzf) || { echo "install-fzf: no fzf on PATH; the pinned release is $version" >&2; exit 1; }
  got=$(fzf --version | sed -n 1p)
  got=${got%% *}
  [ "$got" = "$version" ] || { echo "install-fzf: the first fzf on PATH is $found, version $got, not the pinned $version" >&2; exit 1; }
  echo "fzf $got at $found (the pinned release)"
  exit 0
fi

dest=$1
case $(uname -s) in
  Darwin) os=darwin;;
  Linux) os=linux;;
  *) echo "install-fzf: no fzf asset is chosen here for $(uname -s)" >&2; exit 1;;
esac
case $(uname -m) in
  x86_64|amd64) arch=amd64;;
  arm64|aarch64) arch=arm64;;
  *) echo "install-fzf: no fzf asset is chosen here for $(uname -m)" >&2; exit 1;;
esac
asset=fzf-$version-${os}_$arch.tar.gz
base=https://github.com/junegunn/fzf/releases/download/v$version
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp/$asset" "$base/$asset"
curl -fsSL --retry 3 -o "$tmp/sums" "$base/fzf_${version}_checksums.txt"
want=$(awk -v f="$asset" '$2 == f { print $1 }' "$tmp/sums")
[ -n "$want" ] || { echo "install-fzf: fzf_${version}_checksums.txt has no line for $asset" >&2; exit 1; }
pinned=$(awk -v f="$asset" '$2 == f { print $1 }' "$here/fzf-sha256" 2>/dev/null)
[ -n "$pinned" ] || { echo "install-fzf: $here/fzf-sha256 has no line for $asset" >&2; exit 1; }
[ "$pinned" = "$want" ] || { echo "install-fzf: the release's checksum file says $want for $asset; $here/fzf-sha256 says $pinned" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$tmp/$asset"); else got=$(shasum -a 256 "$tmp/$asset"); fi
got=${got%% *}
[ "$got" = "$want" ] || { echo "install-fzf: $asset hashes to $got; the release's checksum file says $want" >&2; exit 1; }
tar -xzf "$tmp/$asset" -C "$tmp" fzf
mkdir -p "$dest"
cp "$tmp/fzf" "$dest/fzf"
chmod 755 "$dest/fzf"
got=$("$dest/fzf" --version | sed -n 1p)
got=${got%% *}
[ "$got" = "$version" ] || { echo "install-fzf: $dest/fzf says it is $got, not $version" >&2; exit 1; }
echo "fzf $got installed at $dest/fzf ($asset, sha256 $want)"
