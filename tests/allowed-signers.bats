#!/usr/bin/env bats

# ~/bin/git-allowed-signers composes ~/.config/git/allowed_signers from the
# per-overlay fragments in allowed_signers.d/. Everything here runs against a
# sandboxed dir pair via the two env overrides — no real HOME is touched, and
# no identity appears in this file: the fixtures are invented signers.

setup() {
  BIN="$BATS_TEST_DIRNAME/../bin/executable_git-allowed-signers"
  TMP="$(mktemp -d)"
  export GIT_ALLOWED_SIGNERS_DIR="$TMP/allowed_signers.d"
  export GIT_ALLOWED_SIGNERS_FILE="$TMP/allowed_signers"
  mkdir -p "$GIT_ALLOWED_SIGNERS_DIR"
}

teardown() { rm -rf "$TMP"; }

@test "composes every fragment present" {
  echo 'alice@example.com ssh-ed25519 AAAAfake1' > "$GIT_ALLOWED_SIGNERS_DIR/10-one"
  echo 'bob@example.com ssh-ed25519 AAAAfake2'   > "$GIT_ALLOWED_SIGNERS_DIR/20-two"
  run sh "$BIN"
  [ "$status" -eq 0 ]
  grep -q 'alice@example.com ssh-ed25519 AAAAfake1' "$GIT_ALLOWED_SIGNERS_FILE"
  grep -q 'bob@example.com ssh-ed25519 AAAAfake2' "$GIT_ALLOWED_SIGNERS_FILE"
}

@test "a machine missing an overlay composes the file without its lines" {
  # The whole point: no conditionals, the absent fragment is simply absent.
  echo 'alice@example.com ssh-ed25519 AAAAfake1' > "$GIT_ALLOWED_SIGNERS_DIR/10-one"
  run sh "$BIN"
  [ "$status" -eq 0 ]
  grep -q 'alice@example.com' "$GIT_ALLOWED_SIGNERS_FILE"
  ! grep -q 'bob@example.com' "$GIT_ALLOWED_SIGNERS_FILE"
}

@test "no fragments at all still writes a readable file, not a missing one" {
  run sh "$BIN"
  [ "$status" -eq 0 ]
  [ -f "$GIT_ALLOWED_SIGNERS_FILE" ]
  grep -q 'no overlay fragments' "$GIT_ALLOWED_SIGNERS_FILE"
}

@test "output is 0644 and marked generated" {
  echo 'alice@example.com ssh-ed25519 AAAAfake1' > "$GIT_ALLOWED_SIGNERS_DIR/10-one"
  run sh "$BIN"
  [ "$(stat -f '%Lp' "$GIT_ALLOWED_SIGNERS_FILE" 2> /dev/null \
       || stat -c '%a' "$GIT_ALLOWED_SIGNERS_FILE")" = "644" ]
  head -1 "$GIT_ALLOWED_SIGNERS_FILE" | grep -q 'GENERATED'
}

@test "rerunning is idempotent" {
  echo 'alice@example.com ssh-ed25519 AAAAfake1' > "$GIT_ALLOWED_SIGNERS_DIR/10-one"
  sh "$BIN"
  cp "$GIT_ALLOWED_SIGNERS_FILE" "$TMP/first"
  sh "$BIN"
  diff "$TMP/first" "$GIT_ALLOWED_SIGNERS_FILE"
}

@test "removing a fragment removes its lines on the next run" {
  echo 'alice@example.com ssh-ed25519 AAAAfake1' > "$GIT_ALLOWED_SIGNERS_DIR/10-one"
  echo 'bob@example.com ssh-ed25519 AAAAfake2'   > "$GIT_ALLOWED_SIGNERS_DIR/20-two"
  sh "$BIN"
  rm "$GIT_ALLOWED_SIGNERS_DIR/20-two"
  sh "$BIN"
  ! grep -q 'bob@example.com' "$GIT_ALLOWED_SIGNERS_FILE"
}

@test "--print writes to stdout and touches nothing" {
  echo 'alice@example.com ssh-ed25519 AAAAfake1' > "$GIT_ALLOWED_SIGNERS_DIR/10-one"
  run sh "$BIN" --print
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'alice@example.com'
  [ ! -e "$GIT_ALLOWED_SIGNERS_FILE" ]
}

@test "--check fails when stale or missing, passes when current" {
  run sh "$BIN" --check
  [ "$status" -eq 1 ]
  echo 'alice@example.com ssh-ed25519 AAAAfake1' > "$GIT_ALLOWED_SIGNERS_DIR/10-one"
  sh "$BIN"
  run sh "$BIN" --check
  [ "$status" -eq 0 ]
  echo 'bob@example.com ssh-ed25519 AAAAfake2' > "$GIT_ALLOWED_SIGNERS_DIR/20-two"
  run sh "$BIN" --check
  [ "$status" -eq 1 ]
}

@test "an unknown option is refused, not silently treated as regenerate" {
  run sh "$BIN" --wat
  [ "$status" -eq 2 ]
}

@test "the composed path is what .gitconfig points git at" {
  grep -q 'allowedSignersFile = ~/.config/git/allowed_signers$' \
    "$BATS_TEST_DIRNAME/../dot_gitconfig"
}

@test "dotfiles() composes after applying every overlay" {
  # Order is the whole correctness argument: fragments only exist once the
  # overlays have applied, so the call must come after that loop.
  run awk '/^function dotfiles/,/^}/' "$BATS_TEST_DIRNAME/../dot_functions"
  echo "$output" | grep -q 'git-allowed-signers'
  loop=$(echo "$output" | grep -n 'chezmoi --config' | tail -1 | cut -d: -f1)
  call=$(echo "$output" | grep -n 'git-allowed-signers' | tail -1 | cut -d: -f1)
  [ "$call" -gt "$loop" ]
}
