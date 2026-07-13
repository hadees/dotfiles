#!/usr/bin/env bats

# op inject parses ALL of .extra.tmpl — comments included — and errors on
# any curly-brace pair or bare op:// text that isn't a real brace-wrapped
# secret reference. These tests enforce that invariant without needing the
# op CLI (CI runners don't have it); real references only ever appear on
# non-comment export lines.

TMPL=".extra.tmpl"

@test "extra.tmpl comment lines contain no curly braces" {
  cd "$BATS_TEST_DIRNAME/.."
  run grep -nE '^[[:space:]]*#.*(\{\{|\}\})' "$TMPL"
  [ "$status" -ne 0 ]
}

@test "extra.tmpl comment lines contain no op:// references" {
  cd "$BATS_TEST_DIRNAME/.."
  run grep -nE '^[[:space:]]*#.*op://' "$TMPL"
  [ "$status" -ne 0 ]
}

@test "extra.tmpl secret references are brace-wrapped and well-formed" {
  cd "$BATS_TEST_DIRNAME/.."
  # Any op:// on an active line must look like "{{ op://vault/item/field }}"
  # (at least three path segments) — a bare or malformed reference is a
  # render error waiting to happen.
  while IFS= read -r line; do
    [[ "$line" =~ \{\{\ *op://[^/]+/[^/]+/[^}]+\ *\}\} ]]
  done < <(grep -E '^[^#]*op://' "$TMPL" || true)
}
