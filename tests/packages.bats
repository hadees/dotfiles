#!/usr/bin/env bats

# Sanity floor for the per-OS package lists: non-empty, one package per
# line, no duplicates. The Brewfile is covered by brew bundle itself.

@test "packages-apt.txt is non-empty with no duplicates" {
  cd "$BATS_TEST_DIRNAME/.."
  pkgs=$(grep -vE '^[[:space:]]*(#|$)' packages-apt.txt)
  [ -n "$pkgs" ]
  [ -z "$(echo "$pkgs" | sort | uniq -d)" ]
  # One package name per line, no stray whitespace
  ! echo "$pkgs" | grep -qE '[[:space:]]'
}
