#!/usr/bin/env bats

# bin/executable_git-credential-gh-user deploys to ~/bin/git-credential-gh-user,
# a git credential helper that answers `get` with the gh keyring token for
# whatever username git hands it (pinned per URL via credential.<url>.username
# in gitconfig). In every failure mode — no username pinned, wrong action, gh
# missing, gh with no token — it must decline *silently* (empty output, exit 0)
# so the next helper in git's chain gets a chance to answer. These tests run
# the source copy under sh against a stub gh earlier in PATH; all usernames
# here are fixtures — no real account names may appear (see CLAUDE.md).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  HELPER="$BATS_TEST_DIRNAME/../bin/executable_git-credential-gh-user"

  # Stub gh: records its argv, prints a fake token.
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/emptybin"
  export GH_STUB_LOG="$BATS_TEST_TMPDIR/gh-args"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$GH_STUB_LOG"
echo fake-token-123
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Run the helper with action $1, feeding it the standard credential request
# git would send for a pinned https://github.com remote.
ask() {
  run sh -c "printf 'protocol=https\nhost=github.com\nusername=octo\n' | sh '$HELPER' $1"
}

@test "get with a username answers with that username and the gh token" {
  ask get
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "username=octo" ]
  [ "${lines[1]}" = "password=fake-token-123" ]
  [ "${#lines[@]}" -eq 2 ]
  # The token must come from that username's keyring entry, not the active
  # account.
  [ "$(cat "$GH_STUB_LOG")" = "auth token --user octo" ]
}

@test "declines silently when git sends no username" {
  run sh -c "printf 'protocol=https\nhost=github.com\n' | sh '$HELPER' get"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$GH_STUB_LOG" ]
}

@test "ignores actions other than get" {
  ask store
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$GH_STUB_LOG" ]
}

@test "declines silently when gh is not installed" {
  # Empty PATH for the helper only: every command it needs is a sh builtin,
  # so nothing else breaks, and command -v gh cannot find the real binary.
  run sh -c "printf 'protocol=https\nhost=github.com\nusername=octo\n' | PATH='$BATS_TEST_TMPDIR/emptybin' /bin/sh '$HELPER' get"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "declines silently when gh has no token for the user" {
  printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/gh"
  ask get
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "declines silently when gh fails (account not logged in)" {
  printf '#!/bin/sh\necho "no keyring entry" >&2\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/gh"
  ask get
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
