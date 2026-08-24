#!/usr/bin/env bats

# iterm2-doctor in dot_functions reports what this machine's iTerm2 is, and
# — the part that earns its keep — whether the .claude/skills/iterm2 skill
# was written against that version. Everything is read off a bundle on disk,
# so every test here builds a fake iTerm.app and stubs defaults(1); no test
# may touch a real iTerm2 or open a dialog.
#
# The skill's own checker, scripts/verify.sh, is exercised the same way.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  unset CLAUDECODE ITERM_SESSION_ID
  export TERM_PROGRAM=bats

  DOTFUNCTIONS="$BATS_TEST_DIRNAME/../dot_functions"
  SKILL="$BATS_TEST_DIRNAME/../.claude/skills/iterm2"

  # A stub defaults(1) that answers only from files the test writes, so the
  # doctor can never read (or write) the caller's real preferences.
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB" "$BATS_TEST_TMPDIR/prefs"
  cat > "$STUB/defaults" <<'EOF'
#!/bin/sh
# defaults read <domain-or-plist-path> <key>
[ "$1" = read ] || exit 1
domain=$2; key=$3
case $domain in
  */Contents/Info) file="$domain.answers" ;;
  *)               file="$PREFS/$domain" ;;
esac
[ -f "$file" ] || exit 1
val=$(sed -n "s/^$key=//p" "$file")
[ -n "$val" ] || exit 1
printf '%s\n' "$val"
EOF
  chmod +x "$STUB/defaults"
  export PREFS="$BATS_TEST_TMPDIR/prefs"
  PATH="$STUB:$PATH"
}

# Build a fake iTerm.app whose bundle version is $1.
make_app() {
  APP="$BATS_TEST_TMPDIR/iTerm.app"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/utilities"
  : > "$APP/Contents/Info.plist"
  printf 'CFBundleShortVersionString=%s\n' "$1" > "$APP/Contents/Info.answers"
  export ITERM2_APP="$APP"
}

# An Info.plist with CFBundleShortVersionString=$2 plus the "key value"
# pairs on the lines of $3.
write_info_plist() {
  local app=$1 ver=$2 pairs=$3 k v
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n'
    printf '\t<key>CFBundleShortVersionString</key>\n\t<string>%s</string>\n' "$ver"
    while read -r k v; do
      [ -n "$k" ] || continue
      printf '\t<key>%s</key>\n\t<string>%s</string>\n' "$k" "$v"
    done <<< "$pairs"
    printf '</dict>\n</plist>\n'
  } > "$app/Contents/Info.plist"
}

doctor() {
  run zsh -c "source '$DOTFUNCTIONS'; iterm2-doctor"
}

# The stamp the doctor carries, extracted from the source rather than typed
# out again here — a test that repeats the literal would pass while the
# doctor and the skill disagreed.
doctor_stamp() {
  sed -n 's/^[[:space:]]*local stamp=\([^;]*\);.*/\1/p' "$DOTFUNCTIONS"
}

@test "iterm2-doctor: reads the version off the bundle and reports a match" {
  make_app "$(doctor_stamp)"
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"defined: ok (3 helpers)"* ]]
  [[ "$output" == *"app:     $APP ($(doctor_stamp))"* ]]
  [[ "$output" == *"skill:   written against iTerm2 $(doctor_stamp) — matches"* ]]
  # House style: every label is padded so its value starts in column 10, the
  # way the other doctors print. A ragged report is harder to skim, and these
  # get pasted into issues.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [[ "$line" =~ ^[a-z]+:\ +[^\ ] ]]
    [[ "${line:0:9}" =~ ^[a-z]+:\ *$ ]]
    [[ "${line:9:1}" != " " ]]
  done <<< "$output"
}

@test "iterm2-doctor: a newer installed version nudges towards the changelog" {
  make_app 3.99.0
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed is 3.99.0; refresh it and check the changelog"* ]]
  [[ "$output" == *"references/releases.md"* ]]
  [[ "$output" != *"which is OLDER"* ]]
}

@test "iterm2-doctor: an older installed version says so instead" {
  make_app 3.0.0
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed is 3.0.0, which is OLDER"* ]]
  [[ "$output" != *"refresh it and check the changelog"* ]]
}

@test "iterm2-doctor: no app is reported, not crashed, and still shows the stamp" {
  export ITERM2_APP="$BATS_TEST_TMPDIR/nowhere.app"
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"app:     NOT INSTALLED"* ]]
  [[ "$output" == *"skill:   written against iTerm2 $(doctor_stamp)"* ]]
}

@test "iterm2-doctor: prefs, api, and startup keys come from the domain, absent ones say so" {
  make_app "$(doctor_stamp)"
  cat > "$PREFS/com.googlecode.iterm2" <<'EOF'
LoadPrefsFromCustomFolder=1
PrefsCustomFolder=~/somewhere
EnableAPIServer=1
OpenNoWindowsAtStartup=1
EOF
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"prefs:   LoadPrefsFromCustomFolder=1, PrefsCustomFolder=~/somewhere"* ]]
  [[ "$output" == *"api:     EnableAPIServer=1"* ]]
  [[ "$output" == *"startup: OpenNoWindowsAtStartup=1, OpenArrangementAtStartup=<unset>, AlwaysOpenWindowAtStartup=<unset>"* ]]
}

@test "iterm2-doctor: counts dynamic profiles and autolaunch scripts, never names them" {
  make_app "$(doctor_stamp)"
  support="$HOME/Library/Application Support/iTerm2"
  mkdir -p "$support/DynamicProfiles" "$support/Scripts/AutoLaunch"
  : > "$support/DynamicProfiles/a-private-hostname.json"
  : > "$support/DynamicProfiles/another.json"
  : > "$support/Scripts/AutoLaunch/a-private-script.py"
  : > "$support/Scripts/AutoLaunch.scpt"
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"dynamic: 2 profile file(s)"* ]]
  [[ "$output" == *"scripts: AutoLaunch.scpt present, 1 AutoLaunch python script(s)"* ]]
  # Names of profiles and scripts are the user's business, not the report's.
  [[ "$output" != *"a-private-hostname"* ]]
  [[ "$output" != *"a-private-script"* ]]
}

@test "iterm2-doctor: reports shell integration and the plugin bundles when present" {
  make_app "$(doctor_stamp)"
  : > "$HOME/.iterm2_shell_integration.zsh"
  mkdir -p "$HOME/.iterm2"
  for p in iTermAI iTermBrowserPlugin; do
    mkdir -p "$BATS_TEST_TMPDIR/$p.app/Contents"
    : > "$BATS_TEST_TMPDIR/$p.app/Contents/Info.plist"
    printf 'CFBundleShortVersionString=9.9\n' > "$BATS_TEST_TMPDIR/$p.app/Contents/Info.answers"
  done
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"integ:   zsh; utilities in ~/.iterm2"* ]]
  [[ "$output" == *"plugins: iTermAI 9.9, iTermBrowserPlugin 9.9"* ]]
}

@test "iterm2-doctor: no plugins and no integration are stated, not omitted" {
  make_app "$(doctor_stamp)"
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"plugins: none installed"* ]]
  [[ "$output" == *"integ:   not installed"* ]]
}

# --- the stamp is the whole point, so it may not drift ---------------------

@test "the doctor's stamp, the manifest's, and the skill's prose all agree" {
  local from_doctor from_manifest
  from_doctor="$(doctor_stamp)"
  [ -n "$from_doctor" ]
  from_manifest="$(sed -n 's/^version //p' "$SKILL/scripts/manifest.txt")"
  [ "$from_doctor" = "$from_manifest" ]
  # The stamp a human reads first is the one in SKILL.md.
  grep -qF "Written against iTerm2 $from_doctor." "$SKILL/SKILL.md"
}

@test "the skill ships every file SKILL.md sends the reader to" {
  [ -x "$SKILL/scripts/verify.sh" ]
  [ -f "$SKILL/scripts/manifest.txt" ]
  for f in applescript python-api dynamic-profiles preferences \
           shell-integration ai-plugin releases; do
    [ -f "$SKILL/references/$f.md" ]
    grep -qF "references/$f.md" "$SKILL/SKILL.md"
  done
}

@test "the skill is invisible to chezmoi (dot-prefixed, and ignored)" {
  # A deployed skill directory would put repo internals in $HOME. The
  # .claude prefix is what keeps chezmoi from ever seeing it.
  [[ "$SKILL" == *"/.claude/skills/iterm2" ]]
  grep -qx '.claude' "$BATS_TEST_DIRNAME/../.chezmoiignore"
}

# --- verify.sh -------------------------------------------------------------

# Build a bundle that satisfies a manifest: a text "executable" holding every
# binstr line, an sdef holding every sdef line, the named utilities, and the
# recorded Info keys.
make_verifiable_app() {
  local manifest=$1 ver=$2
  APP="$BATS_TEST_TMPDIR/verify.app"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/utilities"
  # A real XML plist: verify.sh reads it the way it reads a real bundle
  # (PlistBuddy on macOS, an XML scrape where that does not exist).
  write_info_plist "$APP" "$ver" "$(sed -n 's/^info //p' "$manifest")"
  sed -n 's/^binstr //p' "$manifest" > "$APP/Contents/MacOS/iTerm2"
  sed -n 's/^sdef //p' "$manifest" > "$APP/Contents/Resources/iTerm2.sdef"
  while read -r u; do : > "$APP/Contents/Resources/utilities/$u"; done \
    < <(sed -n 's/^util //p' "$manifest")
  export ITERM2_APP="$APP"
}

@test "verify.sh: a bundle carrying every recorded fact passes" {
  M="$SKILL/scripts/manifest.txt"
  make_verifiable_app "$M" "$(sed -n 's/^version //p' "$M")"
  run bash "$SKILL/scripts/verify.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"— matches"* ]]
  [[ "$output" == *"OK - every recorded fact still holds"* ]]
  # Each class of fact was actually exercised, not silently skipped.
  for class in sdef binstr util info; do
    [[ "$output" == *"$class:"*"/"*" verified"* ]]
  done
}

@test "verify.sh: a vanished string, command, utility, or Info key is named" {
  M="$BATS_TEST_TMPDIR/manifest.txt"
  cat > "$M" <<'EOF'
version 9.9.9
sdef <command name="kept"
sdef <command name="removed"
binstr KeptKey
binstr RemovedKey
util it2kept
util it2removed
info SUFeedURLForFinal https://example.invalid/kept
EOF
  make_verifiable_app "$M" 9.9.9
  rm "$APP/Contents/Resources/utilities/it2removed"
  sed -i.bak '/removed/d;/Removed/d' "$APP/Contents/MacOS/iTerm2" \
    "$APP/Contents/Resources/iTerm2.sdef"
  write_info_plist "$APP" 9.9.9 "SUFeedURLForFinal https://example.invalid/moved"

  run bash "$SKILL/scripts/verify.sh" --manifest "$M"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No longer true of the installed iTerm2:"* ]]
  [[ "$output" == *'sdef: <command name="removed"'* ]]
  [[ "$output" == *"binstr: RemovedKey"* ]]
  [[ "$output" == *"util: it2removed"* ]]
  [[ "$output" == *"info: SUFeedURLForFinal is 'https://example.invalid/moved'"* ]]
  # The ones that still hold are not reported as failures.
  [[ "$output" != *"it2kept"* ]]
  [[ "$output" != *"KeptKey"* ]]
}

@test "verify.sh: a version bump fails and points at the changelog" {
  M="$SKILL/scripts/manifest.txt"
  make_verifiable_app "$M" 3.99.0
  run bash "$SKILL/scripts/verify.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"INSTALLED IS 3.99.0"* ]]
  [[ "$output" == *"https://iterm2.com/downloads.html"* ]]
  # It says plainly that passing checks are not proof of currency.
  [[ "$output" == *"new features add nothing for them to catch"* ]]
}

@test "verify.sh: no iTerm.app at all is a clear error, not a silent pass" {
  export ITERM2_APP="$BATS_TEST_TMPDIR/nowhere.app"
  run bash "$SKILL/scripts/verify.sh" --app "$BATS_TEST_TMPDIR/nowhere.app"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no iTerm.app found"* ]]
}
