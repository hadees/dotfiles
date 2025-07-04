#!/usr/bin/env bats

@test "macos script syntax is valid" {
  run bash -n "$BATS_TEST_DIRNAME/../.macos"
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
