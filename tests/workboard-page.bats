#!/usr/bin/env bats

# The work board's page (dot_local/share/workboard/board.html), as text: no
# resource from outside, no way to put markup on the page but textContent, and
# every name of the frozen board document and of the panel's colours that the
# page is meant to read is in the file (so a field it never reads is noticed
# here). Where it draws is looked at by hand: Lead serves it with the demo
# board. All names here are fixtures (see CLAUDE.md).

bats_require_minimum_version 1.5.0

load helpers/workboard

setup() {
  wb_setup
  PAGE="$WB_ROOT/dot_local/share/workboard/board.html"
}

teardown() { wb_teardown; }

has() {
  grep -qF -- "$1" "$PAGE"
}

@test "the page is one file that exists" {
  [ -f "$PAGE" ]
}

@test "the page refers to no resource by http:, https: or a // address" {
  run grep -nE 'https?:|(^|[^<*])//' "$PAGE"
  [ "$status" -eq 1 ]
}

@test "the page uses no way to put markup or code on the page but textContent" {
  has textContent
  run grep -nE 'innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval' "$PAGE"
  [ "$status" -eq 1 ]
}

@test "the page holds no private-use code point (U+E000 to U+F8FF)" {
  run $WB_PY - "$PAGE" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
bad = [hex(ord(c)) for c in text if 0xE000 <= ord(c) <= 0xF8FF]
sys.exit(1 if bad else 0)
PY
  [ "$status" -eq 0 ]
}

@test "the page names board.json, go, open and X-Workboard, by absolute path" {
  has '"/b/board.json"'
  has '"/b/go"'
  has '"/b/open"'
  has 'X-Workboard'
}

@test "the page holds the token marker exactly once, on a line of its own inside head" {
  [ "$(grep -cF '<!--workboard:token-->' "$PAGE")" -eq 1 ]
  [ "$(grep -cxF '<!--workboard:token-->' "$PAGE")" -eq 1 ]
  local m h e
  m="$(grep -nF '<!--workboard:token-->' "$PAGE" | cut -d: -f1)"
  h="$(grep -n '<head>' "$PAGE" | head -1 | cut -d: -f1)"
  e="$(grep -n '</head>' "$PAGE" | head -1 | cut -d: -f1)"
  [ "$m" -gt "$h" ]
  [ "$m" -lt "$e" ]
}

@test "the page takes its key from the response and keeps it in sessionStorage, not an address" {
  local w
  for w in workboard-token wb-token replaceState Authorization sessionStorage; do
    has "$w"
  done
  run grep -nE 'fetch\("board\.json"|localStorage|document\.cookie' "$PAGE"
  [ "$status" -eq 1 ]
}

@test "the page says what it is missing when it has no key" {
  has 'This page has no key.'
  has 'Run workboard open.'
}

@test "the page has all five column titles, in the signed order" {
  local t last=0 at
  for t in 'Needs you' 'Inbox' 'Building' 'In review / CI' 'Merged · trial'; do
    at="$(grep -nF -- "title: \"$t\"" "$PAGE" | head -1 | cut -d: -f1)"
    [ -n "$at" ]
    [ "$at" -gt "$last" ]
    last="$at"
  done
}

@test "the page names all four stage words and both source words" {
  local w
  for w in inbox building review landed session job; do
    has "\"$w\""
  done
}

@test "the page has every session colour of the panel" {
  local c
  for c in '"blocked": "#5f87ff"' '"asked": "#ffd75f"' '"failed": "#ff5f5f"' '"quiet": "#af8700"' \
    '"finished": "#00d75f"' '"finished-bg": "#00d75f"' '"#888888"' '#00d75f'; do
    has "$c"
  done
}

@test "the page reads the card and health fields of the board document" {
  local f
  for f in queue seat stale in_needs unattended takeable trial_day holders log \
    panel panel_age jobs inbox_errors; do
    grep -qE "\.$f\b" "$PAGE"
  done
}

@test "the page has a light scheme and keeps the look's base colours" {
  has 'prefers-color-scheme: light'
  has 'prefers-reduced-motion'
  has '#1a1a1a'
  has '#d3d0c8'
  has '#747369'
  has '#2d2d2d'
  has '#393939'
  has 'max-width: 719px'
}

@test "the page's script is valid JavaScript" {
  command -v node >/dev/null 2>&1 && node --version >/dev/null 2>&1 || skip "node not installed"
  $WB_PY - "$PAGE" "$BATS_TEST_TMPDIR/page.js" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
open(sys.argv[2], "w").write(re.search(r"<script>(.*?)</script>", text, re.S).group(1))
PY
  run node --check "$BATS_TEST_TMPDIR/page.js"
  [ "$status" -eq 0 ]
}

@test "the page is not an executable, and nothing in this file wrote a __pycache__" {
  [ ! -x "$PAGE" ]
  wb_no_pycache
}
