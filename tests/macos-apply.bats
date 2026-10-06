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

@test "Touch ID for sudo is enabled in sudo_local" {
  grep -Eq '^auth[[:space:]]+sufficient[[:space:]]+pam_tid\.so' /etc/pam.d/sudo_local
}

@test "the global sudo timestamp is in effect and its file parses" {
  sudo -n visudo -cf /etc/sudoers.d/timestamp
  sudo -n -l | grep -q 'timestamp_type=global'
}

@test ".macos is idempotent for the sudo settings" {
  cd "$BATS_TEST_DIRNAME/.."
  ./.macos > "$BATS_TEST_TMPDIR/macos2.log" 2>&1
  # Anchored: the template's commented-out line also says pam_tid.so.
  [ "$(grep -Ec '^auth[[:space:]]+sufficient[[:space:]]+pam_tid\.so' /etc/pam.d/sudo_local)" = 1 ]
  [ "$(grep -c 'timestamp_type' /etc/sudoers.d/timestamp)" = 1 ]
  [ "$(stat -f %Lp /etc/sudoers.d/timestamp)" = 440 ]
}
