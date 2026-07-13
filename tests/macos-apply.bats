#!/usr/bin/env bats

# Executes .macos for real and asserts a sample of settings stuck. This
# mutates system preferences, so it must only run on a throwaway machine —
# CI runners are ephemeral VMs. Guarded twice (macOS only, plus an explicit
# MACOS_APPLY_OK opt-in) so a plain `bats tests` on a real Mac never
# triggers it.

setup() {
  [ "$(uname)" = "Darwin" ] || skip "macOS only"
  [ "$MACOS_APPLY_OK" = "1" ] || skip "set MACOS_APPLY_OK=1 to run (mutates system preferences)"
}

@test ".macos runs to completion" {
  cd "$BATS_TEST_DIRNAME/.."
  # Log to a file rather than letting bats capture output: the script's
  # background sudo keep-alive inherits a captured pipe and would hold it
  # open for up to 60s after exit.
  ./.macos > "$BATS_TEST_TMPDIR/macos.log" 2>&1
}

@test "natural scrolling is disabled" {
  [ "$(defaults read NSGlobalDomain com.apple.swipescrolldirection)" = "0" ]
}

@test "screenshot location is set to Desktop" {
  [ "$(defaults read com.apple.screencapture location)" = "$HOME/Desktop" ]
}

@test "highlight color is set" {
  [ "$(defaults read NSGlobalDomain AppleHighlightColor)" = "0.764700 0.976500 0.568600" ]
}
