#!/usr/bin/env bats

# bin/lndir.sh mirrors a directory tree with hard links. It must exit non-zero
# when a link or directory could not be made.

setup() {
  LNDIR="$BATS_TEST_DIRNAME/../bin/executable_lndir.sh"
  SRC="$BATS_TEST_TMPDIR/src"
  DST="$BATS_TEST_TMPDIR/dst"
  mkdir -p "$SRC/sub"
  echo one > "$SRC/a"
  echo two > "$SRC/sub/b"
}

@test "lndir.sh: a clean run exits 0 and shares inodes" {
  run "$LNDIR" "$SRC" "$DST"
  [ "$status" -eq 0 ]
  [ "$SRC/a" -ef "$DST/a" ]
  [ "$SRC/sub/b" -ef "$DST/sub/b" ]
}

@test "lndir.sh: a destination that already holds the file makes it exit non-zero" {
  mkdir -p "$DST"
  echo other > "$DST/a"
  run "$LNDIR" "$SRC" "$DST"
  [ "$status" -ne 0 ]
}
