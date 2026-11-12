#!/usr/bin/env bats

# bin/has-glyphs caches its verdict per terminal, font and query. A check that
# could not run (python3 missing or crashing) is not a verdict, so it must not
# be cached as "no glyphs". These tests drive the real script on the Darwin
# path with a stub python3, a stub uname, and a sandboxed HOME and cache.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$HOME"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  printf '#!/bin/sh\necho Darwin\n' > "$BIN/uname"
  chmod +x "$BIN/uname"
  export PATH="$BIN:$PATH"
  HG="$BATS_TEST_DIRNAME/../bin/executable_has-glyphs"
}

stub_python() {
  printf '#!/bin/sh\nexit %s\n' "$1" > "$BIN/python3"
  chmod +x "$BIN/python3"
}

@test "has-glyphs: a python3 that cannot run is not cached as no glyphs" {
  stub_python 126
  run "$HG" e0a0
  [ "$status" -ne 0 ]
  [ -z "$(ls -A "$XDG_CACHE_HOME/has-glyphs")" ]
}

@test "has-glyphs: a verdict of some glyphs missing is cached" {
  stub_python 1
  run "$HG" e0a0
  [ "$status" -eq 1 ]
  [ "$(cat "$XDG_CACHE_HOME"/has-glyphs/*)" = 1 ]
}

@test "has-glyphs: a verdict of every glyph rendering is cached" {
  stub_python 0
  run "$HG" e0a0
  [ "$status" -eq 0 ]
  [ "$(cat "$XDG_CACHE_HOME"/has-glyphs/*)" = 0 ]
}
