#!/usr/bin/env bats

# ~/bin/iterm2-prefs: compose iTerm2's preferences from per-owner fragments.
# Everything runs in a sandboxed HOME against invented fixture plists; stub uname, ps
# and defaults stand in for the machine, so no test can read the developer's real iTerm2
# domain or write its preferences.

bats_require_minimum_version 1.5.0

setup() {
  BIN="$BATS_TEST_DIRNAME/../bin/executable_iterm2-prefs"
  # Pin python3 while HOME is still real: an asdf shim first on PATH finds no
  # version under the fake HOME and exits 126 instead of running.
  if py="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)"; then
    mkdir -p "$BATS_TEST_TMPDIR/pybin" && ln -s "$py" "$BATS_TEST_TMPDIR/pybin/python3"
    export PATH="$BATS_TEST_TMPDIR/pybin:$PATH"
  fi
  export HOME="$BATS_TEST_TMPDIR/home"
  unset XDG_CONFIG_HOME
  export XDG_STATE_HOME="$HOME/.local/state"
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR"
  FRAGS="$BATS_TEST_TMPDIR/frags"
  mkdir -p "$FRAGS"
  export ITERM2_PREFS_FRAGMENTS="$FRAGS"
  export ITERM2_PREFS_DIR="$BATS_TEST_TMPDIR/store"
  export ITERM2_PREFS_RECORD="$BATS_TEST_TMPDIR/record.plist"
  stubs
  mkplist "$BATS_TEST_TMPDIR/domain.plist" '{}'
  export FAKE_DOMAIN="$BATS_TEST_TMPDIR/domain.plist" FAKE_LOAD=0
}

stubs() {
  local b="$BATS_TEST_TMPDIR/bin"
  cat >"$b/uname" <<'STUB'
#!/bin/sh
printf '%s\n' "${FAKE_OS:-Darwin}"
STUB
  cat >"$b/ps" <<'STUB'
#!/bin/sh
for p in ${FAKE_PROCS:-}; do printf '%s\n' "$p"; done
STUB
  cat >"$b/defaults" <<'STUB'
#!/bin/sh
case $1 in
  read) case $3 in
          LoadPrefsFromCustomFolder) [ -n "${FAKE_LOAD-}" ] && printf '%s\n' "$FAKE_LOAD" || exit 1;;
          PrefsCustomFolder) printf '%s\n' "$FAKE_FOLDER";;
        esac;;
  export) cat "$FAKE_DOMAIN";;
esac
STUB
  chmod +x "$b"/uname "$b"/ps "$b"/defaults
  export PATH="$b:$PATH"
}

# mkplist <path> <python expression> [binary]: a plist from a Python literal
mkplist() {
  python3 -I -c 'import datetime, plistlib, sys
fmt = plistlib.FMT_BINARY if len(sys.argv) > 3 else plistlib.FMT_XML
with open(sys.argv[1], "wb") as f:
    plistlib.dump(eval(sys.argv[2]), f, fmt=fmt)' "$@"
}

# frag <name> <python expression>: a fragment in the fragment directory
frag() { mkplist "$FRAGS/$1.plist" "$2"; }

# pget <plist> <python expression over d>
pget() { python3 -I -c 'import plistlib, sys; d = plistlib.load(open(sys.argv[1], "rb")); print(eval(sys.argv[2]))' "$1" "$2"; }

# has <line>: the last run's output holds exactly this line
has() { grep -Fxq -- "$1" <<<"$output"; }

@test "lint: a well-formed fragment passes silently" {
  frag 10-one '{"Keep": 1, "New Bookmarks": [{"Guid": "AAAA-1", "Name": "Fixture"}]}'
  run sh "$BIN" lint "$FRAGS/10-one.plist"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "lint: each reserved key is named on its own line" {
  f="$FRAGS/10-one.plist"
  frag 10-one '{"Workgroups": b"x", "NoSyncFixture": 1, "PrefsCustomFolder": "x", "Keep": 1,
    "New Bookmarks": [{"Guid": "AAAA-1", "Name": "Fixture", "Triggers": [], "Dynamic Profile Filename": "x"}]}'
  run sh "$BIN" lint "$f"
  [ "$status" -eq 1 ]
  has "$f: reserved key Workgroups"
  has "$f: reserved key NoSyncFixture"
  has "$f: reserved key PrefsCustomFolder"
  has "$f: reserved key profile/AAAA-1/Triggers"
  has "$f: reserved key profile/AAAA-1/Dynamic Profile Filename"
  [ "$(grep -c . <<<"$output")" -eq 5 ]
}

@test "lint: a binary plist, a non-plist, a non-dictionary root and a profile without a Guid each fail with their own line" {
  mkplist "$BATS_TEST_TMPDIR/bin.plist" '{"Keep": 1}' binary
  echo hello >"$BATS_TEST_TMPDIR/text.plist"
  mkplist "$BATS_TEST_TMPDIR/array.plist" '[1, 2]'
  mkplist "$BATS_TEST_TMPDIR/noguid.plist" '{"New Bookmarks": [{"Guid": "AAAA-1"}, {"Name": "Fixture"}]}'
  run sh "$BIN" lint "$BATS_TEST_TMPDIR"/{bin,text,array,noguid}.plist
  [ "$status" -eq 1 ]
  has "$BATS_TEST_TMPDIR/bin.plist: binary property list (fragments are XML)"
  has "$BATS_TEST_TMPDIR/text.plist: not a property list"
  has "$BATS_TEST_TMPDIR/array.plist: root is not a dictionary"
  has "$BATS_TEST_TMPDIR/noguid.plist: profile 1 has no Guid"
  [ "$(grep -c . <<<"$output")" -eq 4 ]
}

@test "lint: one Guid twice in a fragment fails" {
  frag 10-one '{"New Bookmarks": [{"Guid": "AAAA-1"}, {"Guid": "AAAA-1", "Name": "x"}]}'
  run sh "$BIN" lint "$FRAGS/10-one.plist"
  [ "$status" -eq 1 ]
  [ "$output" = "$FRAGS/10-one.plist: profile Guid AAAA-1 appears twice" ]
}

@test "lint --public: a data value, a date, a home path, a path, a URL outside AitermURL, an at-sign and a non-empty Bound Hosts each fail; a URL in AitermURL passes" {
  f="$FRAGS/10-one.plist"
  frag 10-one '{"Blob": b"x", "When": datetime.datetime(2020, 1, 1), "Dir": "/" + "home/fixture/x",
    "Where": "/opt/fixture", "Link": "https://example.invalid/x", "Mail": "fixture" + chr(64) + "example.invalid",
    "AitermURL": "https://example.invalid/v1",
    "New Bookmarks": [{"Guid": "AAAA-1", "Bound Hosts": ["host1"], "Command": "", "Tags": []}]}'
  run sh "$BIN" lint "$f"
  [ "$status" -eq 0 ]
  run sh "$BIN" lint --public "$f"
  [ "$status" -eq 1 ]
  has "$f: data value at Blob"
  has "$f: date value at When"
  has "$f: home path in Dir"
  has "$f: path or URL in Dir"
  has "$f: path or URL in Where"
  has "$f: path or URL in Link"
  has "$f: address in Mail"
  has "$f: profile/AAAA-1/Bound Hosts must be empty or absent"
  [ "$(grep -c . <<<"$output")" -eq 8 ]
  frag 10-two '{"AitermURL": "https://example.invalid/v1"}'
  run sh "$BIN" lint --public "$FRAGS/10-two.plist"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "compose --print: one fragment gives its keys back, typed as they went in" {
  frag 10-one '{"Flag": True, "Count": 1, "Ratio": 1.0, "Blob": b"\x00\x01"}'
  sh "$BIN" compose --print >"$BATS_TEST_TMPDIR/out.plist"
  [ "$(pget "$BATS_TEST_TMPDIR/out.plist" 'type(d["Flag"]).__name__')" = bool ]
  [ "$(pget "$BATS_TEST_TMPDIR/out.plist" 'type(d["Count"]).__name__')" = int ]
  [ "$(pget "$BATS_TEST_TMPDIR/out.plist" 'type(d["Ratio"]).__name__')" = float ]
  [ "$(pget "$BATS_TEST_TMPDIR/out.plist" 'd["Blob"]')" = "b'\\x00\\x01'" ]
  [ "$(pget "$BATS_TEST_TMPDIR/out.plist" 'len(d)')" = 4 ]
}

@test "compose --print: the later fragment wins a key both set, and renaming it flips the answer" {
  frag 10-one '{"Shared": "one", "OnlyOne": 1}'
  frag 20-two '{"Shared": "two"}'
  sh "$BIN" compose --print >"$BATS_TEST_TMPDIR/out.plist"
  [ "$(pget "$BATS_TEST_TMPDIR/out.plist" 'd["Shared"]')" = two ]
  [ "$(pget "$BATS_TEST_TMPDIR/out.plist" 'd["OnlyOne"]')" = 1 ]
  mv "$FRAGS/20-two.plist" "$FRAGS/05-two.plist"
  sh "$BIN" compose --print >"$BATS_TEST_TMPDIR/out.plist"
  [ "$(pget "$BATS_TEST_TMPDIR/out.plist" 'd["Shared"]')" = one ]
}

@test "compose --print: a second fragment sets one key of the first one's profile and adds a profile of its own, after it" {
  frag 10-one '{"New Bookmarks": [{"Guid": "AAAA-1", "Name": "Fixture", "Font": "x"}]}'
  frag 20-two '{"New Bookmarks": [{"Guid": "BBBB-2", "Name": "Second"}, {"Guid": "AAAA-1", "Font": "y"}]}'
  sh "$BIN" compose --print >"$BATS_TEST_TMPDIR/out.plist"
  [ "$(pget "$BATS_TEST_TMPDIR/out.plist" '[p["Guid"] for p in d["New Bookmarks"]]')" = "['AAAA-1', 'BBBB-2']" ]
  [ "$(pget "$BATS_TEST_TMPDIR/out.plist" 'd["New Bookmarks"][0]["Name"]')" = Fixture ]
  [ "$(pget "$BATS_TEST_TMPDIR/out.plist" 'd["New Bookmarks"][0]["Font"]')" = y ]
  [ "$(pget "$BATS_TEST_TMPDIR/out.plist" 'd["New Bookmarks"][1]["Name"]')" = Second ]
}

@test "compose --print: a reserved key in a fragment is left out and the rest still composes" {
  frag 10-one '{"Workgroups": b"x", "NoSyncFixture": 1, "Keep": 1,
    "New Bookmarks": [{"Guid": "AAAA-1", "Name": "Fixture", "Triggers": []}]}'
  sh "$BIN" compose --print >"$BATS_TEST_TMPDIR/out.plist"
  [ "$(pget "$BATS_TEST_TMPDIR/out.plist" 'sorted(d)')" = "['Keep', 'New Bookmarks']" ]
  [ "$(pget "$BATS_TEST_TMPDIR/out.plist" 'sorted(d["New Bookmarks"][0])')" = "['Guid', 'Name']" ]
}

@test "compose --print: no fragment directory, or an empty one, prints an empty dictionary and exits 0" {
  sh "$BIN" compose --print >"$BATS_TEST_TMPDIR/out.plist"
  [ "$(pget "$BATS_TEST_TMPDIR/out.plist" 'd')" = "{}" ]
  ITERM2_PREFS_FRAGMENTS="$BATS_TEST_TMPDIR/nope" sh "$BIN" compose --print >"$BATS_TEST_TMPDIR/out.plist"
  [ "$(pget "$BATS_TEST_TMPDIR/out.plist" 'd')" = "{}" ]
}

@test "compose --print: a file not named NN-<name>.plist is not read" {
  frag 10-one '{"Keep": 1}'
  for n in notes.plist 1-x.plist 10-Upper.plist 10-x.txt .10-hidden.plist; do
    mkplist "$FRAGS/$n" '{"Stray": 1}'
  done
  echo garbage >"$FRAGS/readme.plist"
  sh "$BIN" compose --print >"$BATS_TEST_TMPDIR/out.plist"
  [ "$(pget "$BATS_TEST_TMPDIR/out.plist" 'sorted(d)')" = "['Keep']" ]
}

@test "compose --print: a fragment that does not parse composes nothing and names the file" {
  frag 10-one '{"Keep": 1}'
  echo garbage >"$FRAGS/20-two.plist"
  run sh "$BIN" compose --print
  [ "$status" -eq 1 ]
  [ "$output" = "iterm2-prefs: $FRAGS/20-two.plist: not a property list; nothing composed" ]
}

@test "lint and compose --print run where uname is not Darwin" {
  export FAKE_OS=Linux
  frag 10-one '{"Keep": 1}'
  run sh "$BIN" lint "$FRAGS/10-one.plist"
  [ "$status" -eq 0 ]
  run sh "$BIN" compose --print
  [ "$status" -eq 0 ]
  [[ "$output" == '<?xml'* ]]
}

@test "status, capture, install and a compose that writes are not built yet" {
  for v in status capture install compose "compose --auto"; do
    run sh "$BIN" $v
    [ "$status" -eq 1 ]
    [ "$output" = "iterm2-prefs: ${v%% *} is not built yet" ]
  done
}

@test "no verb or an unknown one is usage, exit 2" {
  run sh "$BIN"
  [ "$status" -eq 2 ]
  [[ "$output" == *"iterm2-prefs lint [--public] <file>..."* ]]
  run sh "$BIN" bogus
  [ "$status" -eq 2 ]
  run sh "$BIN" lint
  [ "$status" -eq 2 ]
}
