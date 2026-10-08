#!/usr/bin/env bats

@test "macos script syntax is valid" {
  run zsh -n "$BATS_TEST_DIRNAME/../.macos"
  [ "$status" -eq 0 ]
}

@test "macos disables natural scrolling" {
  run grep -q 'com.apple.swipescrolldirection -bool false' "$BATS_TEST_DIRNAME/../.macos"
  [ "$status" -eq 0 ]
}

@test "macos sets screenshot location" {
  run grep -q 'com.apple.screencapture location -string "${HOME}/Desktop"' "$BATS_TEST_DIRNAME/../.macos"
  [ "$status" -eq 0 ]
}

@test "macos sets highlight color" {
  run grep -q 'AppleHighlightColor -string "0.764700 0.976500 0.568600"' "$BATS_TEST_DIRNAME/../.macos"
  [ "$status" -eq 0 ]
}

@test "macos enables Touch ID for sudo through sudo_local, never /etc/pam.d/sudo" {
  run grep -q 'pam_tid.so' "$BATS_TEST_DIRNAME/../.macos"
  [ "$status" -eq 0 ]
  run grep -E 'tee.*/etc/pam\.d/sudo([^_]|$)' "$BATS_TEST_DIRNAME/../.macos"
  [ "$status" -ne 0 ]
}

@test "macos makes one sudo authorisation cover every process, and validates the sudoers file" {
  run grep -q 'Defaults timestamp_type=global' "$BATS_TEST_DIRNAME/../.macos"
  [ "$status" -eq 0 ]
  # Validated before it is installed, and installed at the mode sudo wants.
  run grep -q 'visudo -cf "$sudoers_tmp"' "$BATS_TEST_DIRNAME/../.macos"
  [ "$status" -eq 0 ]
  run grep -q 'install -m 0440 -o root -g wheel "$sudoers_tmp" /etc/sudoers.d/timestamp' "$BATS_TEST_DIRNAME/../.macos"
  [ "$status" -eq 0 ]
}
