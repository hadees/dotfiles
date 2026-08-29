#!/usr/bin/env bats

# Sanity floor for the per-OS package lists: non-empty, one package per
# line, no duplicates. The Brewfile additionally gets a real parse by
# `brew bundle` where Homebrew exists (macOS runners), so a stray quote or
# unknown directive fails CI instead of the next `chezmoi apply` on a Mac.

@test "packages-apt.txt is non-empty with no duplicates" {
  cd "$BATS_TEST_DIRNAME/.."
  pkgs=$(grep -vE '^[[:space:]]*(#|$)' packages-apt.txt)
  [ -n "$pkgs" ]
  [ -z "$(echo "$pkgs" | sort | uniq -d)" ]
  # One package name per line, no stray whitespace
  ! echo "$pkgs" | grep -qE '[[:space:]]'
}

@test "packages-apt-wsl.txt is non-empty with no duplicates" {
  cd "$BATS_TEST_DIRNAME/.."
  pkgs=$(grep -vE '^[[:space:]]*(#|$)' packages-apt-wsl.txt)
  [ -n "$pkgs" ]
  [ -z "$(echo "$pkgs" | sort | uniq -d)" ]
  ! echo "$pkgs" | grep -qE '[[:space:]]'
}

@test "the wsl list adds to the shared list rather than repeating it" {
  cd "$BATS_TEST_DIRNAME/.."
  # Both lists are installed on the wsl class, in order. A name in both would
  # be installed twice and, worse, could drift apart between the two files.
  base=$(grep -vE '^[[:space:]]*(#|$)' packages-apt.txt | sort)
  wsl=$(grep -vE '^[[:space:]]*(#|$)' packages-apt-wsl.txt | sort)
  [ -z "$(comm -12 <(echo "$base") <(echo "$wsl"))" ]
}

@test "Brewfile has no duplicate entries" {
  cd "$BATS_TEST_DIRNAME/.."
  entries=$(grep -E '^(tap|brew|cask|mas|vscode) ' Brewfile | sed -E 's/[[:space:]]*#.*$//; s/,.*$//')
  [ -n "$entries" ]
  [ -z "$(echo "$entries" | sort | uniq -d)" ]
}

@test "Brewfile parses with brew bundle" {
  command -v brew >/dev/null || skip "Homebrew not installed"
  cd "$BATS_TEST_DIRNAME/.."
  # No network, no auto-update: just parse the file and list every entry.
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 run brew bundle list --file=Brewfile --all
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'finicky'
}
