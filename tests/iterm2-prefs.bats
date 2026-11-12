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
  export FAKE_DEFAULTS_LOG="$BATS_TEST_TMPDIR/defaults.log"
  LIVEF="$ITERM2_PREFS_DIR/com.googlecode.iterm2.plist"
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
  write) printf '%s\n' "$*" >>"${FAKE_DEFAULTS_LOG:-/dev/null}";;
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

# installed_fixture: iTerm2 loads the composed folder (named with a trailing slash)
installed_fixture() { export FAKE_LOAD=1 FAKE_FOLDER="$ITERM2_PREFS_DIR/"; }

# edit_live <python statements over d>: change the store the way iTerm2 would at quit
edit_live() {
  python3 -I -c 'import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
exec(sys.argv[2])
plistlib.dump(d, open(sys.argv[1], "wb"))' "$LIVEF" "$1"
}

sums() { shasum "$LIVEF" "$ITERM2_PREFS_RECORD" 2>&1; }

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

@test "capture and install are not built yet" {
  for v in capture install; do
    run sh "$BIN" $v
    [ "$status" -eq 1 ]
    [ "$output" = "iterm2-prefs: $v is not built yet" ]
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

@test "compose: where iTerm2 does not load the composed folder it refuses and names install; --auto says nothing and exits 0" {
  frag 10-one '{"Keep": 1}'
  run sh "$BIN" compose
  [ "$status" -eq 1 ]
  [ "$output" = "iterm2-prefs: iTerm2 does not load $ITERM2_PREFS_DIR (iterm2-prefs install)" ]
  run sh "$BIN" compose --auto
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ ! -e "$LIVEF" ]]
  # a folder reached through a symlink is the composed folder all the same
  mkdir -p "$ITERM2_PREFS_DIR"
  ln -s "$ITERM2_PREFS_DIR" "$BATS_TEST_TMPDIR/link"
  export FAKE_LOAD=1 FAKE_FOLDER="$BATS_TEST_TMPDIR/link"
  run sh "$BIN" compose
  [ "$status" -eq 0 ]
  [ -f "$LIVEF" ]
}

@test "compose: while iTerm2 runs it refuses with the count; --auto prints the waiting line only when a source moved; neither writes the store or the record" {
  installed_fixture
  frag 10-one '{"Keep": 1}'
  sh "$BIN" compose >/dev/null
  mkplist "$FAKE_DOMAIN" '{"Keep": 1}'
  export FAKE_PROCS=iTerm2
  before=$(sums)
  run sh "$BIN" compose --auto
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  frag 10-one '{"Keep": 2}'
  run sh "$BIN" compose
  [ "$status" -eq 1 ]
  [ "$output" = "iterm2-prefs: iTerm2 is running and writes its preferences at quit; quit it first (1 source changes wait)" ]
  run sh "$BIN" compose --auto
  [ "$status" -eq 0 ]
  [ "$output" = "iterm2-prefs: 1 source changes wait for iTerm2 to quit (then: iterm2-prefs compose)" ]
  [ "$(sums)" = "$before" ]
}

@test "compose: into an empty store every sourced key lands, and the record is written" {
  installed_fixture
  frag 10-one '{"Keep": 1, "New Bookmarks": [{"Guid": "AAAA-1", "Name": "Fixture", "Font": "x"}]}'
  run sh "$BIN" compose
  [ "$status" -eq 0 ]
  [ "$output" = "iterm2-prefs: 3 units applied from 1 fragments; 0 kept as changed in iTerm2 (iterm2-prefs capture); 0 reserved keys ignored" ]
  [ "$(pget "$LIVEF" 'd["Keep"]')" = 1 ]
  [ "$(pget "$LIVEF" 'd["New Bookmarks"]')" = "[{'Font': 'x', 'Guid': 'AAAA-1', 'Name': 'Fixture'}]" ]
  [ "$(pget "$ITERM2_PREFS_RECORD" 'd')" = "{'profiles': {'AAAA-1': {'Font': 'x', 'Name': 'Fixture'}}, 'top': {'Keep': 1}}" ]
  [[ ! -e "$FAKE_DEFAULTS_LOG" ]]
}

@test "compose: a source change lands when iTerm2 left the key alone" {
  installed_fixture
  frag 10-one '{"Keep": 1, "Other": 1}'
  sh "$BIN" compose >/dev/null
  frag 10-one '{"Keep": 2, "Other": 1}'
  run sh "$BIN" compose
  [ "$output" = "iterm2-prefs: 1 units applied from 1 fragments; 0 kept as changed in iTerm2 (iterm2-prefs capture); 0 reserved keys ignored" ]
  [ "$(pget "$LIVEF" 'd["Keep"]')" = 2 ]
}

@test "compose: a key changed in iTerm2 is kept and counted, and is still kept after its source changes too" {
  installed_fixture
  frag 10-one '{"Keep": 1}'
  sh "$BIN" compose >/dev/null
  edit_live 'd["Keep"] = 99'
  frag 10-one '{"Keep": 2}'
  run sh "$BIN" compose
  [ "$output" = "iterm2-prefs: 0 units applied from 1 fragments; 1 kept as changed in iTerm2 (iterm2-prefs capture); 0 reserved keys ignored" ]
  [ "$(pget "$LIVEF" 'd["Keep"]')" = 99 ]
  # the record moved on to 2 although nothing was applied: a value iTerm2 holds
  # that only equals the OLD record must not read as "iTerm2 left it alone"
  edit_live 'd["Keep"] = 1'
  frag 10-one '{"Keep": 3}'
  run sh "$BIN" compose
  [ "$(pget "$LIVEF" 'd["Keep"]')" = 1 ]
  [[ "$output" == *"; 1 kept as changed in iTerm2"* ]]
}

@test "compose --reset: every sourced key takes the source value and local keys stay" {
  installed_fixture
  frag 10-one '{"Keep": 1}'
  sh "$BIN" compose >/dev/null
  edit_live 'd["Keep"] = 99; d["Local"] = 5'
  run sh "$BIN" compose --reset
  [ "$status" -eq 0 ]
  [ "$output" = "iterm2-prefs: 1 units applied from 1 fragments; 0 kept as changed in iTerm2 (iterm2-prefs capture); 0 reserved keys ignored" ]
  [ "$(pget "$LIVEF" 'd["Keep"]')" = 1 ]
  [ "$(pget "$LIVEF" 'd["Local"]')" = 5 ]
}

@test "compose: Workgroups, a profile's Triggers, a dynamic profile and an unsourced key come through unchanged" {
  installed_fixture
  mkdir -p "$ITERM2_PREFS_DIR"
  mkplist "$LIVEF" '{"Workgroups": b"live", "Local": 7,
    "New Bookmarks": [{"Guid": "AAAA-1", "Name": "Fixture", "Triggers": ["live"]},
                      {"Guid": "BBBB-2", "Name": "Dyn", "Dynamic Profile Filename": "x"}]}'
  frag 10-one '{"Keep": 1, "Workgroups": b"frag",
    "New Bookmarks": [{"Guid": "AAAA-1", "Name": "Fixture", "Triggers": ["frag"]}]}'
  run sh "$BIN" compose
  [ "$status" -eq 0 ]
  [ "$output" = "iterm2-prefs: 1 units applied from 1 fragments; 0 kept as changed in iTerm2 (iterm2-prefs capture); 2 reserved keys ignored" ]
  [ "$(pget "$LIVEF" 'd["Workgroups"]')" = "b'live'" ]
  [ "$(pget "$LIVEF" 'd["New Bookmarks"][0]["Triggers"]')" = "['live']" ]
  [ "$(pget "$LIVEF" 'd["New Bookmarks"][1]')" = "{'Dynamic Profile Filename': 'x', 'Guid': 'BBBB-2', 'Name': 'Dyn'}" ]
  [ "$(pget "$LIVEF" 'repr(d["Local"]) + type(d["Local"]).__name__')" = "7int" ]
}

@test "compose: a key that left the sources is deleted when iTerm2 left it alone and kept when it did not" {
  installed_fixture
  frag 10-one '{"A": 1, "B": 2}'
  sh "$BIN" compose >/dev/null
  frag 10-one '{"A": 1}'
  run sh "$BIN" compose
  [ "$output" = "iterm2-prefs: 1 units applied from 1 fragments; 0 kept as changed in iTerm2 (iterm2-prefs capture); 0 reserved keys ignored" ]
  [ "$(pget "$LIVEF" 'sorted(d)')" = "['A']" ]
  rm -rf "$ITERM2_PREFS_DIR" "$ITERM2_PREFS_RECORD"
  frag 10-one '{"A": 1, "B": 2}'
  sh "$BIN" compose >/dev/null
  edit_live 'd["B"] = 5'
  frag 10-one '{"A": 1}'
  run sh "$BIN" compose
  [ "$output" = "iterm2-prefs: 0 units applied from 1 fragments; 1 kept as changed in iTerm2 (iterm2-prefs capture); 0 reserved keys ignored" ]
  [ "$(pget "$LIVEF" 'd["B"]')" = 5 ]
}

@test "compose: a profile that left the sources is dropped whole when untouched and kept whole when one of its keys changed" {
  installed_fixture
  both='{"New Bookmarks": [{"Guid": "AAAA-1", "Name": "Fixture"}, {"Guid": "BBBB-2", "Name": "Second", "Tag": "t"}]}'
  frag 10-one "$both"
  sh "$BIN" compose >/dev/null
  edit_live 'd["New Bookmarks"][1]["Local"] = 1'
  frag 10-one '{"New Bookmarks": [{"Guid": "AAAA-1", "Name": "Fixture"}]}'
  sh "$BIN" compose >/dev/null
  [ "$(pget "$LIVEF" '[p["Guid"] for p in d["New Bookmarks"]]')" = "['AAAA-1']" ]
  rm -rf "$ITERM2_PREFS_DIR" "$ITERM2_PREFS_RECORD"
  frag 10-one "$both"
  sh "$BIN" compose >/dev/null
  edit_live 'd["New Bookmarks"][1]["Name"] = "Changed"'
  frag 10-one '{"New Bookmarks": [{"Guid": "AAAA-1", "Name": "Fixture"}]}'
  run sh "$BIN" compose
  [ "$output" = "iterm2-prefs: 0 units applied from 1 fragments; 1 kept as changed in iTerm2 (iterm2-prefs capture); 0 reserved keys ignored" ]
  [ "$(pget "$LIVEF" '[p["Guid"] for p in d["New Bookmarks"]]')" = "['AAAA-1', 'BBBB-2']" ]
  [ "$(pget "$LIVEF" 'd["New Bookmarks"][1]')" = "{'Guid': 'BBBB-2', 'Name': 'Changed', 'Tag': 't'}" ]
}

@test "compose: a new source profile is appended and the existing profiles keep their order" {
  installed_fixture
  frag 10-one '{"New Bookmarks": [{"Guid": "AAAA-1", "Name": "Fixture"}]}'
  sh "$BIN" compose >/dev/null
  edit_live 'd["New Bookmarks"].append({"Guid": "CCCC-3", "Name": "Local"})'
  frag 10-one '{"New Bookmarks": [{"Guid": "BBBB-2", "Name": "Second"}, {"Guid": "AAAA-1", "Name": "Fixture"}]}'
  sh "$BIN" compose >/dev/null
  [ "$(pget "$LIVEF" '[p["Guid"] for p in d["New Bookmarks"]]')" = "['AAAA-1', 'CCCC-3', 'BBBB-2']" ]
}

@test "compose: true, 1 and 1.0 are three values" {
  installed_fixture
  frag 10-one '{"Flag": True, "Num": 1}'
  sh "$BIN" compose >/dev/null
  edit_live 'd["Flag"] = 1; d["Num"] = 1.0'
  run sh "$BIN" compose
  [ "$output" = "iterm2-prefs: 0 units applied from 1 fragments; 2 kept as changed in iTerm2 (iterm2-prefs capture); 0 reserved keys ignored" ]
  [ "$(pget "$LIVEF" 'type(d["Flag"]).__name__ + type(d["Num"]).__name__')" = "intfloat" ]
}

@test "compose: a fragment that does not parse leaves store and record as they were" {
  installed_fixture
  frag 10-one '{"Keep": 1}'
  sh "$BIN" compose >/dev/null
  before=$(sums)
  echo garbage >"$FRAGS/20-two.plist"
  run sh "$BIN" compose
  [ "$status" -eq 1 ]
  [ "$output" = "iterm2-prefs: $FRAGS/20-two.plist: not a property list; nothing composed" ]
  [ "$(sums)" = "$before" ]
}

@test "compose: a second run prints nothing and leaves the store byte for byte" {
  installed_fixture
  frag 10-one '{"Keep": 1, "New Bookmarks": [{"Guid": "AAAA-1", "Name": "Fixture"}]}'
  sh "$BIN" compose >/dev/null
  before=$(sums)
  run sh "$BIN" compose
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(sums)" = "$before" ]
}

@test "compose --print: lays the merge over the store with the three-way rule, touches nothing, and works while iTerm2 runs and when not installed" {
  frag 10-one '{"Keep": 1, "Other": 1}'
  mkdir -p "$ITERM2_PREFS_DIR"
  mkplist "$LIVEF" '{"Keep": 9, "Local": 5}'
  mkplist "$ITERM2_PREFS_RECORD" '{"top": {"Keep": 0}, "profiles": {}}'
  export FAKE_PROCS=iTerm2
  before=$(sums)
  sh "$BIN" compose --print >"$BATS_TEST_TMPDIR/out.plist"
  [ "$(pget "$BATS_TEST_TMPDIR/out.plist" 'sorted(d.items())')" = "[('Keep', 9), ('Local', 5), ('Other', 1)]" ]
  [ "$(sums)" = "$before" ]
}

@test "status: installed, prints store, iterm2, fragments, sourced, waiting, kept and ignored with their counts" {
  installed_fixture
  frag 10-one '{"Keep": 1, "Workgroups": b"x", "New Bookmarks": [{"Guid": "AAAA-1", "Name": "Fixture", "Font": "x"}]}'
  frag 20-two '{"Other": 2}'
  echo stray >"$FRAGS/notes.txt"
  run sh "$BIN" status
  [ "$status" -eq 0 ]
  expected="store: composed $LIVEF
iterm2: not running
fragments: 2 (10-one 20-two)
sourced: 4 units (2 top-level, 2 keys in 1 profiles)
waiting: 4 source changes not in the store
kept: 0 units changed in iTerm2 (iterm2-prefs capture)
ignored: 1 reserved keys in fragments: 10-one:Workgroups
skipped: 1 files in $FRAGS not named NN-<name>.plist"
  [ "$output" = "$expected" ]
  sh "$BIN" compose >/dev/null
  edit_live 'd["Keep"] = 9'
  run sh "$BIN" status
  has "waiting: 0 source changes not in the store"
  has "kept: 1 units changed in iTerm2 (iterm2-prefs capture)"
}

@test "status: a store inside a git repository says so and names install" {
  repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo/prefs"
  git init -q "$repo"
  top=$(cd -P "$repo" && pwd)
  export FAKE_LOAD=1 FAKE_FOLDER="$repo/prefs"
  run sh "$BIN" status
  [ "$status" -eq 0 ]
  has "store: folder $repo/prefs/com.googlecode.iterm2.plist, inside the git repository $top; not the composed folder (iterm2-prefs install)"
  [[ "$output" != *waiting:* ]]
  [[ "$output" != *kept:* ]]
  export FAKE_FOLDER="$BATS_TEST_TMPDIR/elsewhere"
  run sh "$BIN" status
  has "store: folder $BATS_TEST_TMPDIR/elsewhere/com.googlecode.iterm2.plist; not the composed folder (iterm2-prefs install)"
  export FAKE_LOAD=0
  run sh "$BIN" status
  has "store: domain; not the composed folder (iterm2-prefs install)"
}

@test "status: while iTerm2 runs, kept and waiting are counted against the domain, not the file" {
  installed_fixture
  frag 10-one '{"Keep": 1}'
  sh "$BIN" compose >/dev/null
  export FAKE_PROCS=iTerm2
  mkplist "$FAKE_DOMAIN" '{"Keep": 5}'
  run sh "$BIN" status
  has "iterm2: running"
  has "waiting: 0 source changes not in the store"
  has "kept: 1 units changed in iTerm2 (iterm2-prefs capture)"
  mkplist "$FAKE_DOMAIN" '{"Keep": 1}'
  frag 10-one '{"Keep": 2}'
  run sh "$BIN" status
  has "waiting: 1 source changes not in the store"
  has "kept: 0 units changed in iTerm2 (iterm2-prefs capture)"
}

@test "status --line: each form" {
  installed_fixture
  frag 10-one '{"Keep": 1}'
  run sh "$BIN" status --line
  [ "$output" = "composed, 1 waiting, 0 kept" ]
  sh "$BIN" compose >/dev/null
  run sh "$BIN" status --line
  [ "$output" = "composed, in sync" ]
  edit_live 'd["Keep"] = 9'
  run sh "$BIN" status --line
  [ "$output" = "composed, 0 waiting, 1 kept" ]
  repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo/prefs"
  git init -q "$repo"
  export FAKE_FOLDER="$repo/prefs"
  run sh "$BIN" status --line
  [ "$output" = "not composed (folder $repo/prefs/com.googlecode.iterm2.plist, inside a git repository)" ]
  export FAKE_FOLDER="$BATS_TEST_TMPDIR/elsewhere"
  run sh "$BIN" status --line
  [ "$output" = "not composed (folder $BATS_TEST_TMPDIR/elsewhere/com.googlecode.iterm2.plist)" ]
  export FAKE_LOAD=0
  run sh "$BIN" status --line
  [ "$output" = "not composed (domain)" ]
}

@test "status and compose exit 2 where uname is not Darwin; compose --print does not" {
  export FAKE_OS=Linux
  run sh "$BIN" status
  [ "$status" -eq 2 ]
  run sh "$BIN" compose
  [ "$status" -eq 2 ]
  run sh "$BIN" compose --print
  [ "$status" -eq 0 ]
}
