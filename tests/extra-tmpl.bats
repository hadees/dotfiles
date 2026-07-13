#!/usr/bin/env bats

# chezmoi parses private_dot_extra.tmpl as a Go template — comments
# included — so a stray {{ }} anywhere breaks rendering. These tests
# enforce the invariants that keep the template renderable; real template
# actions only ever appear on non-comment export lines.

TMPL="private_dot_extra.tmpl"

@test "extra template comment lines contain no template actions" {
  cd "$BATS_TEST_DIRNAME/.."
  run grep -nE '^[[:space:]]*#.*(\{\{|\}\})' "$TMPL"
  [ "$status" -ne 0 ]
}

@test "extra template secret reads are well-formed onepasswordRead calls" {
  cd "$BATS_TEST_DIRNAME/.."
  # Any op:// on an active line must sit inside a onepasswordRead action
  # with vault/item/field segments.
  while IFS= read -r line; do
    [[ "$line" =~ \{\{\ *onepasswordRead\ \"op://[^/]+/[^/]+/[^\"]+\" ]]
  done < <(grep -E '^[^#]*op://' "$TMPL" || true)
}

@test "extra template renders as a valid Go template" {
  command -v chezmoi > /dev/null 2>&1 || skip "chezmoi not installed"
  cd "$BATS_TEST_DIRNAME/.."
  # Reference-free today, so this needs no 1Password auth; if references
  # are ever added, CI would need op or this becomes a syntax-only check.
  # XDG dirs pinned alongside HOME — CI runners export XDG_CONFIG_HOME,
  # which chezmoi prefers, and state must not leak between tests.
  TMPHOME="$(mktemp -d)"
  chez() {
    HOME="$TMPHOME" XDG_CONFIG_HOME="$TMPHOME/.config" \
    XDG_DATA_HOME="$TMPHOME/.local/share" XDG_STATE_HOME="$TMPHOME/.local/state" \
    XDG_CACHE_HOME="$TMPHOME/.cache" chezmoi "$@"
  }
  chez init --source "$PWD" --promptString machineClass=linux
  run chez execute-template --source "$PWD" < "$TMPL"
  rm -rf "$TMPHOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"machine-local secrets"* ]]
}
