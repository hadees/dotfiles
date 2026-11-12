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
  write) printf '%s\n' "$*" >>"${FAKE_DEFAULTS_LOG:-/dev/null}"
         # were the store and the record already on disk when iTerm2 was repointed?
         if [ -f "${ITERM2_PREFS_DIR-}/com.googlecode.iterm2.plist" ] && [ -f "${ITERM2_PREFS_RECORD-}" ]; then
           echo files >>"${FAKE_DEFAULTS_LOG:-/dev/null}.order"; else echo nofiles >>"${FAKE_DEFAULTS_LOG:-/dev/null}.order"; fi;;
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

# truth_fixture <python expression>: the plist `capture --from "$TRUTH"` reads
truth_fixture() { TRUTH="$BATS_TEST_TMPDIR/truth.plist"; mkplist "$TRUTH" "$1"; }

@test "capture: lists changed and absent sourced keys with their owner and prints no value" {
  frag 10-one '{"Alpha": "src-alpha", "Beta": 2, "Gamma": 3}'
  frag 20-two '{"Delta": True}'
  truth_fixture '{"Alpha": "SENTINEL-VALUE", "Beta": 2, "Delta": True, "Local": 1}'
  run --separate-stderr sh "$BIN" capture --from "$TRUTH"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'changed\tAlpha\t10-one\nabsent\tGamma\t10-one')" ]
  [ "$stderr" = "iterm2-prefs: 1 changed, 1 absent" ]
  [[ "$output$stderr" != *SENTINEL* ]]
}

@test "capture --all: adds unsourced keys, never a reserved one, and counts dynamic profiles instead of listing them" {
  frag 10-one '{"New Bookmarks": [{"Guid": "AAAA-1", "Name": "Fixture"}]}'
  truth_fixture '{"Local": 1, "Workgroups": b"x", "NoSyncFixture": 1, "New Bookmarks": [
    {"Guid": "AAAA-1", "Name": "Fixture", "Extra": 1, "Triggers": []},
    {"Guid": "BBBB-2", "Name": "Dyn", "Dynamic Profile Filename": "x"}]}'
  run --separate-stderr sh "$BIN" capture --from "$TRUTH" --all
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'unsourced\tLocal\t-\nunsourced\tprofile/AAAA-1/Extra\t-')" ]
  [ "$stderr" = "iterm2-prefs: 0 changed, 0 absent, 2 unsourced; 1 dynamic profiles not listed" ]
  run --separate-stderr sh "$BIN" capture --from "$TRUTH"
  [ -z "$output" ]
  [ "$stderr" = "iterm2-prefs: 0 changed, 0 absent" ]
}

@test "capture --values: shows the source's and the truth's value for a changed key" {
  frag 10-one '{"Alpha": "src", "Blob": b"x"}'
  truth_fixture '{"Alpha": "mine", "Blob": b"yy"}'
  run --separate-stderr sh "$BIN" capture --from "$TRUTH" --values
  has "$(printf "changed\tAlpha\t10-one\t'src'\t'mine'")"
  has "$(printf 'changed\tBlob\t10-one\t<data 1 bytes>\t<data 2 bytes>')"
}

@test "capture --file: writes the named units into a new plist, and the result lints" {
  frag 10-one '{"Alpha": "src"}'
  truth_fixture '{"Alpha": "mine", "New Bookmarks": [{"Guid": "AAAA-1", "Name": "Fixture", "Other": 1}]}'
  out="$BATS_TEST_TMPDIR/new/dir/out.plist"
  run sh "$BIN" capture --from "$TRUTH" --file "$out" Alpha profile/AAAA-1/Name
  [ "$status" -eq 0 ]
  [ "$output" = "iterm2-prefs: wrote 2 units to $out; commit it there, then run dotfiles" ]
  [ "$(pget "$out" 'd')" = "{'Alpha': 'mine', 'New Bookmarks': [{'Guid': 'AAAA-1', 'Name': 'Fixture'}]}" ]
  [ "$(python3 -I -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$out")" = 0o644 ]
  run sh "$BIN" lint "$out"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "capture --owned: takes every changed key that fragment owns and none of another's" {
  frag 10-one '{"Alpha": "a", "Beta": "b"}'
  frag 20-two '{"Delta": "d", "Epsilon": "e"}'
  truth_fixture '{"Alpha": "A", "Beta": "b", "Delta": "D"}'
  out="$BATS_TEST_TMPDIR/out.plist"
  run sh "$BIN" capture --from "$TRUTH" --owned 20-two --file "$out"
  [ "$status" -eq 0 ]
  [ "$output" = "iterm2-prefs: wrote 2 units to $out; commit it there, then run dotfiles" ]
  [ "$(pget "$out" 'd')" = "{'Delta': 'D'}" ]
  rm "$out"
  run sh "$BIN" capture --from "$TRUTH" --owned 10-one --file "$out"
  [ "$(pget "$out" 'd')" = "{'Alpha': 'A'}" ]
  run sh "$BIN" capture --from "$TRUTH" --owned 30-none --file "$out"
  [ "$status" -eq 1 ]
}

@test "capture: a key the truth lacks is removed from the destination, and a profile left with only its Guid goes too" {
  out="$BATS_TEST_TMPDIR/out.plist"
  mkplist "$out" '{"Gamma": 1, "Keep": 1, "New Bookmarks": [{"Guid": "AAAA-1", "Name": "Fixture"},
    {"Guid": "BBBB-2"}, {"Guid": "CCCC-3", "Name": "Other"}]}'
  truth_fixture '{"Keep": 2}'
  run sh "$BIN" capture --from "$TRUTH" --file "$out" Gamma profile/AAAA-1/Name
  [ "$status" -eq 0 ]
  [ "$(pget "$out" 'd')" = "{'Keep': 1, 'New Bookmarks': [{'Guid': 'BBBB-2'}, {'Guid': 'CCCC-3', 'Name': 'Other'}]}" ]
}

@test "capture profile/<guid>: takes every key of the profile but its reserved ones" {
  truth_fixture '{"New Bookmarks": [{"Guid": "AAAA-1", "Name": "Fixture", "Extra": 1, "Triggers": [],
    "Dynamic Profile Filename": "x"}, {"Guid": "BBBB-2", "Name": "Other"}]}'
  out="$BATS_TEST_TMPDIR/out.plist"
  run sh "$BIN" capture --from "$TRUTH" --file "$out" profile/AAAA-1
  [ "$status" -eq 0 ]
  [ "$output" = "iterm2-prefs: wrote 2 units to $out; commit it there, then run dotfiles" ]
  [ "$(pget "$out" 'd')" = "{'New Bookmarks': [{'Extra': 1, 'Guid': 'AAAA-1', 'Name': 'Fixture'}]}" ]
}

# fake_chezmoi: source-path answers from $FAKE_CHEZ/<config file name>, "default" without --config
fake_chezmoi() {
  mkdir -p "$BATS_TEST_TMPDIR/chez" "$HOME/.config/chezmoi"
  touch "$HOME/.config/chezmoi/chezmoi.toml" "$HOME/.config/chezmoi/a.toml" "$HOME/.config/chezmoi/b.toml"
  cat >"$BATS_TEST_TMPDIR/bin/chezmoi" <<'STUB'
#!/bin/sh
cfg=default
if [ "$1" = --config ]; then cfg=${2##*/}; shift 2; fi
[ "$1" = source-path ] || exit 2
[ -f "$FAKE_CHEZ/$cfg" ] && { cat "$FAKE_CHEZ/$cfg"; exit 0; }
echo "chezmoi: $2: not managed" >&2
exit 1
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/chezmoi"
  export FAKE_CHEZ="$BATS_TEST_TMPDIR/chez"
}

@test "capture --into: finds the source through chezmoi, the default config first, then each overlay config; an unmanaged fragment exits 1" {
  fake_chezmoi
  frag 10-one '{"Alpha": "src"}'
  before="$(shasum "$FRAGS/10-one.plist")"
  truth_fixture '{"Alpha": "mine"}'
  mkdir -p "$BATS_TEST_TMPDIR/src" "$BATS_TEST_TMPDIR/src2"
  src="$BATS_TEST_TMPDIR/src/10-one.plist"
  src2="$BATS_TEST_TMPDIR/src2/10-one.plist"
  # the default config answers with a path that is no file; a.toml with a file; b.toml with another
  printf '%s\n' "$BATS_TEST_TMPDIR/src/absent.plist" >"$FAKE_CHEZ/default"
  printf '%s\n' "$src2" >"$FAKE_CHEZ/a.toml"
  printf '%s\n' "$src" >"$FAKE_CHEZ/b.toml"
  mkplist "$src" '{}'; mkplist "$src2" '{}'
  run sh "$BIN" capture --from "$TRUTH" --into 10-one Alpha
  [ "$status" -eq 0 ]
  [ "$output" = "iterm2-prefs: wrote 1 units to $src2; commit it there, then run dotfiles" ]
  [ "$(pget "$src2" 'd')" = "{'Alpha': 'mine'}" ]
  printf '%s\n' "$src" >"$FAKE_CHEZ/default"
  run sh "$BIN" capture --from "$TRUTH" --into 10-one Alpha
  [ "$output" = "iterm2-prefs: wrote 1 units to $src; commit it there, then run dotfiles" ]
  [ "$(shasum "$FRAGS/10-one.plist")" = "$before" ]
  rm -f "$FAKE_CHEZ/default" "$FAKE_CHEZ/a.toml" "$FAKE_CHEZ/b.toml"
  run sh "$BIN" capture --from "$TRUTH" --into 10-one Alpha
  [ "$status" -eq 1 ]
  [ "$output" = "iterm2-prefs: no chezmoi source manages $FRAGS/10-one.plist" ]
}

@test "capture --from: a plist path is read as given; the domain is filtered as iTerm2 filters it" {
  frag 10-one '{"Alpha": "src"}'
  mkplist "$FAKE_DOMAIN" '{"Alpha": "dom", "NoSyncFixture": 1, "Local": 1}'
  run --separate-stderr sh "$BIN" capture --from domain --all
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'changed\tAlpha\t10-one\nunsourced\tLocal\t-')" ]
  # no --from: the domain while iTerm2 runs, the store (here the composed file) otherwise
  installed_fixture
  mkdir -p "$ITERM2_PREFS_DIR"
  mkplist "$LIVEF" '{"Alpha": "src"}'
  run --separate-stderr sh "$BIN" capture
  [ -z "$output" ]
  FAKE_PROCS=iTerm2 run --separate-stderr sh "$BIN" capture
  [ "$output" = "$(printf 'changed\tAlpha\t10-one')" ]
  # a plist path needs no macOS
  truth_fixture '{"Alpha": "mine"}'
  FAKE_OS=Linux run sh "$BIN" capture --from "$TRUTH"
  [ "$status" -eq 0 ]
  FAKE_OS=Linux run sh "$BIN" capture --from store
  [ "$status" -eq 2 ]
}

@test "capture then compose: once the captured file is the deployed fragment, nothing is kept" {
  installed_fixture
  frag 10-one '{"Alpha": "src"}'
  sh "$BIN" compose >/dev/null
  edit_live 'd["Alpha"] = "mine"'
  run sh "$BIN" compose
  [[ "$output" == *"; 1 kept as changed"* ]]
  out="$BATS_TEST_TMPDIR/captured.plist"
  run sh "$BIN" capture --file "$out" Alpha
  [ "$status" -eq 0 ]
  cp "$out" "$FRAGS/10-one.plist"
  run sh "$BIN" compose
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run sh "$BIN" status
  has "kept: 0 units changed in iTerm2 (iterm2-prefs capture)"
  [ "$(pget "$LIVEF" 'd["Alpha"]')" = mine ]
}

@test "capture: a reserved unit is refused by name" {
  truth_fixture '{"Workgroups": b"x", "NoSyncFixture": 1, "New Bookmarks": [{"Guid": "AAAA-1", "Triggers": []}]}'
  out="$BATS_TEST_TMPDIR/out.plist"
  for u in Workgroups NoSyncFixture profile/AAAA-1/Triggers; do
    run sh "$BIN" capture --from "$TRUTH" --file "$out" "$u"
    [ "$status" -eq 1 ]
    [ "$output" = "iterm2-prefs: $u is reserved and cannot be captured" ]
  done
  [[ ! -e "$out" ]]
}

@test "capture: a destination needs a selection, a selection needs a destination, and the deployed files are never written" {
  frag 10-one '{"Alpha": "src"}'
  truth_fixture '{"Alpha": "mine"}'
  out="$BATS_TEST_TMPDIR/out.plist"
  run sh "$BIN" capture --from "$TRUTH" --file "$out"
  [ "$status" -eq 2 ]
  run sh "$BIN" capture --from "$TRUTH" Alpha
  [ "$status" -eq 2 ]
  run sh "$BIN" capture --from "$TRUTH" --bogus
  [ "$status" -eq 2 ]
  before="$(shasum "$FRAGS/10-one.plist")"
  run sh "$BIN" capture --from "$TRUTH" --file "$FRAGS/10-one.plist" Alpha
  [ "$status" -eq 1 ]
  [ "$(shasum "$FRAGS/10-one.plist")" = "$before" ]
  run sh "$BIN" capture --from "$TRUTH" --file "$LIVEF" Alpha
  [ "$status" -eq 1 ]
  [[ ! -e "$LIVEF" ]]
}

# old_folder: iTerm2 loads a folder store of its own, holding Keep=1, a local key and a data value
old_folder() {
  OLD="$BATS_TEST_TMPDIR/old"
  mkdir -p "$OLD"
  mkplist "$OLD/com.googlecode.iterm2.plist" '{"Keep": 1, "Local": "x", "Workgroups": b"w"}'
  export FAKE_LOAD=1 FAKE_FOLDER="$OLD"
}

# phys: the physical path of the composed folder, as install hands it to defaults
phys() { (cd -P "$ITERM2_PREFS_DIR" && pwd); }

@test "install: refuses while iTerm2 runs" {
  old_folder
  frag 10-one '{"Keep": 2}'
  export FAKE_PROCS=iTerm2
  run sh "$BIN" install
  [ "$status" -eq 1 ]
  [ "$output" = "iterm2-prefs: quit iTerm2 first: it rewrites its preferences at quit" ]
  [[ ! -e "$LIVEF" ]]
  [[ ! -e "$FAKE_DEFAULTS_LOG" ]]
  FAKE_OS=Linux run sh "$BIN" install
  [ "$status" -eq 2 ]
}

@test "install: refuses a composed folder inside a git repository, and when git cannot be asked" {
  repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo"
  git init -q "$repo"
  top=$(cd -P "$repo" && pwd)
  export ITERM2_PREFS_DIR="$repo/sub/store"
  frag 10-one '{"Keep": 2}'
  run sh "$BIN" install
  [ "$status" -eq 1 ]
  [ "$output" = "iterm2-prefs: $ITERM2_PREFS_DIR is inside the git repository $top; the composed store must be outside every repository" ]
  [[ ! -e "$repo/sub" ]]
  [[ ! -e "$FAKE_DEFAULTS_LOG" ]]
  # no git on PATH: the check fails closed
  export ITERM2_PREFS_DIR="$BATS_TEST_TMPDIR/store"
  mkdir -p "$BATS_TEST_TMPDIR/nogit"
  for t in awk python3 uname ps defaults; do ln -s "$(command -v "$t")" "$BATS_TEST_TMPDIR/nogit/$t"; done
  PATH="$BATS_TEST_TMPDIR/nogit" run /bin/sh "$BIN" install
  [ "$status" -eq 1 ]
  [ "$output" = "iterm2-prefs: cannot tell whether $ITERM2_PREFS_DIR is inside a git repository (git is not available)" ]
  [[ ! -e "$ITERM2_PREFS_DIR/com.googlecode.iterm2.plist" ]]
}

@test "install: refuses when there is no fragment" {
  run sh "$BIN" install
  [ "$status" -eq 1 ]
  [ "$output" = "iterm2-prefs: no fragments in $FRAGS; run dotfiles first" ]
  [[ ! -e "$FAKE_DEFAULTS_LOG" ]]
}

@test "install: from a folder store, keeps its local keys, gives sourced keys the source value, repoints iTerm2 last and prints the way back" {
  old_folder
  frag 10-one '{"Keep": 2, "Fresh": 3}'
  run sh "$BIN" install
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "iterm2-prefs: iTerm2 now loads $LIVEF (was: folder $OLD/com.googlecode.iterm2.plist); 2 units from 1 fragments, 1 took the source value over the old store's; start iTerm2" ]
  [ "${lines[1]}" = "iterm2-prefs: to go back: defaults write com.googlecode.iterm2 PrefsCustomFolder -string '$OLD'" ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(pget "$LIVEF" 'd["Keep"], d["Fresh"], d["Local"], d["Workgroups"]')" = "(2, 3, 'x', b'w')" ]
  [ "$(pget "$ITERM2_PREFS_RECORD" 'd["top"]')" = "{'Fresh': 3, 'Keep': 2}" ]
  [ "$(cat "$FAKE_DEFAULTS_LOG")" = "write com.googlecode.iterm2 PrefsCustomFolder -string $(phys)
write com.googlecode.iterm2 LoadPrefsFromCustomFolder -bool true" ]
  [ "$(cat "$FAKE_DEFAULTS_LOG.order")" = "files
files" ]
  # the old store is not touched
  [ "$(pget "$OLD/com.googlecode.iterm2.plist" 'd["Keep"]')" = 1 ]
}

@test "install: from the domain, seeds only the keys iTerm2 syncs" {
  mkplist "$FAKE_DOMAIN" '{"Keep": 1, "Local": "x", "NoSyncFixture": 1, "NSFixture": 2, "PrefsCustomFolder": "z"}'
  frag 10-one '{"Keep": 2}'
  run sh "$BIN" install
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "iterm2-prefs: iTerm2 now loads $LIVEF (was: domain); 1 units from 1 fragments, 1 took the source value over the old store's; start iTerm2" ]
  [ "${lines[1]}" = "iterm2-prefs: to go back: defaults write com.googlecode.iterm2 LoadPrefsFromCustomFolder -bool false" ]
  [ "$(pget "$LIVEF" 'sorted(d)')" = "['Keep', 'Local']" ]
  [ "$(pget "$LIVEF" 'd["Keep"]')" = 2 ]
}

@test "install --no-seed: the store holds the sources alone" {
  old_folder
  frag 10-one '{"Keep": 2}'
  run sh "$BIN" install --no-seed
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"1 units from 1 fragments, 0 took the source value over the old store's"* ]]
  [ "$(pget "$LIVEF" 'd')" = "{'Keep': 2}" ]
}

@test "install --dry-run: prints would: lines and one differs row per differing key, writes nothing, and works while iTerm2 runs" {
  old_folder
  export FAKE_PROCS=iTerm2
  frag 10-one '{"Keep": 2, "Fresh": 3}'
  run sh "$BIN" install --dry-run
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "would: iterm2-prefs: iTerm2 now loads $LIVEF (was: folder $OLD/com.googlecode.iterm2.plist); 2 units from 1 fragments, 1 took the source value over the old store's; start iTerm2" ]
  [ "${lines[1]}" = "would: iterm2-prefs: to go back: defaults write com.googlecode.iterm2 PrefsCustomFolder -string '$OLD'" ]
  [ "${lines[2]}" = "$(printf 'differs\tKeep\t10-one')" ]
  [ "${#lines[@]}" -eq 3 ]
  [[ ! -e "$LIVEF" ]]
  [[ ! -e "$ITERM2_PREFS_RECORD" ]]
  [[ ! -e "$FAKE_DEFAULTS_LOG" ]]
  [[ ! -e "$ITERM2_PREFS_DIR" ]]
}

@test "install: where the composed folder is already loaded it composes and repoints nothing" {
  installed_fixture
  frag 10-one '{"Keep": 1}'
  run sh "$BIN" install
  [ "$status" -eq 0 ]
  [ "$output" = "iterm2-prefs: 1 units applied from 1 fragments; 0 kept as changed in iTerm2 (iterm2-prefs capture); 0 reserved keys ignored" ]
  [[ ! -e "$FAKE_DEFAULTS_LOG" ]]
  frag 10-one '{"Keep": 2}'
  before=$(sums)
  run sh "$BIN" install --dry-run
  [ "$status" -eq 0 ]
  [ "$output" = "would: iterm2-prefs: 1 units applied from 1 fragments; 0 kept as changed in iTerm2 (iterm2-prefs capture); 0 reserved keys ignored" ]
  [ "$(sums)" = "$before" ]
}

@test "install: an existing composed store is the seed, not the old folder" {
  old_folder
  mkplist "$OLD/com.googlecode.iterm2.plist" '{"Keep": 1, "OnlyOld": 1}'
  mkdir -p "$ITERM2_PREFS_DIR"
  mkplist "$LIVEF" '{"Keep": 1, "Local": "saved since"}'
  frag 10-one '{"Keep": 2}'
  run sh "$BIN" install
  [ "$status" -eq 0 ]
  [ "$(pget "$LIVEF" 'd')" = "{'Keep': 2, 'Local': 'saved since'}" ]
}

@test "install: a store loaded from a URL is refused" {
  export FAKE_LOAD=1 FAKE_FOLDER="https://example.invalid/prefs"
  frag 10-one '{"Keep": 2}'
  run sh "$BIN" install
  [ "$status" -eq 1 ]
  [ "$output" = "iterm2-prefs: iTerm2 loads its preferences from a URL (https://example.invalid/prefs); install repoints only a folder" ]
  [[ ! -e "$LIVEF" ]]
  [[ ! -e "$FAKE_DEFAULTS_LOG" ]]
}
