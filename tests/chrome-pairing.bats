#!/usr/bin/env bats

# bin/chrome-pairing answers, from disk, which Claude-in-Chrome pairing (the
# extension's per-profile device id) belongs to a browser profile — so a
# Claude Code session can select its browser outright instead of asking or
# broadcasting a Connect prompt. Three sources are faked here exactly in the
# shape the real ones have: Chrome's Local State (profile name -> dir), the
# extension's LevelDB storage (a byte layout observed on 1.0.9x, not an
# interface), and the Finicky config — the real public composer and lib
# with FIXTURE fragments, evaluated under Node the way tests/finicky.bats
# does. All names are fixtures; nothing here touches a real Chrome.

setup() {
  command -v node >/dev/null || skip "node not installed"
  NODE="$(node -e 'console.log(process.execPath)' 2>/dev/null)" || skip "node not runnable"
  "$NODE" --experimental-strip-types -e '' 2>/dev/null || skip "node too old to run .ts (need >= 22.6)"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.config/finicky" "$BATS_TEST_TMPDIR/bin"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  unset OPEN_AS_ALIAS CLAUDE_CHROME_EXTENSION_ID
  SRC="$BATS_TEST_DIRNAME/.."
  cp "$SRC/bin/executable_chrome-pairing" "$BATS_TEST_TMPDIR/bin/chrome-pairing"
  chmod +x "$BATS_TEST_TMPDIR/bin/chrome-pairing"
  # A version-manager shim would look for its node under the sandbox HOME;
  # put the real binary first.
  export PATH="$BATS_TEST_TMPDIR/bin:$(dirname "$NODE"):$PATH"

  # Finicky: real composer + lib, fixture fragments with tagged() rules.
  cp "$SRC/dot_finicky.ts" "$HOME/.finicky.ts"
  cp "$SRC/dot_config/finicky/lib.ts" "$HOME/.config/finicky/lib.ts"
  cat > "$HOME/.config/finicky/work.ts" <<'EOF'
import { chrome, hosts, tagged } from "./lib.ts";
export const rewrite = [];
export default [
  { match: hosts("work.example"), browser: chrome("Work Profile") },
  { match: tagged("wk94fjq2x"), browser: chrome("Work Profile") },
];
EOF
  cat > "$HOME/.config/finicky/personal.ts" <<'EOF'
import { chrome, tagged } from "./lib.ts";
export const defaultBrowser = chrome("Personal Profile");
export const rewrite = [];
export default [
  { match: tagged("sd83hnq2x"), browser: chrome("Side Project Profile") },
  { match: tagged("pe11rsq2x"), browser: chrome("Personal Profile") },
];
EOF
  git config --file "$GIT_CONFIG_GLOBAL" browser.tag.work wk94fjq2x
  git config --file "$GIT_CONFIG_GLOBAL" browser.tag.side sd83hnq2x
  git config --file "$GIT_CONFIG_GLOBAL" browser.tag.personal pe11rsq2x
  # "orphan" has a token but no Finicky rule claims it.
  git config --file "$GIT_CONFIG_GLOBAL" browser.tag.orphan zz00zzq2x

  # Chrome: Local State + extension storage per profile.
  export CHROME_USER_DATA_DIR="$BATS_TEST_TMPDIR/chrome"
  EXT=fcoeoabgfenejglbffodgkkbkcdhcgfn
  mkdir -p "$CHROME_USER_DATA_DIR"
  cat > "$CHROME_USER_DATA_DIR/Local State" <<'EOF'
{"profile":{"info_cache":{
  "Default":   {"name":"Personal Profile"},
  "Profile 2": {"name":"Work Profile"},
  "Profile 3": {"name":"Side Project Profile"},
  "Profile 4": {"name":"Unpaired Profile"}
}}}
EOF
  # Observed byte shape: key, a few control bytes, quoted id; the adjacent
  # displayName key arrives prefix-compressed as "isplayName".
  pair() { # dir file id name
    mkdir -p "$CHROME_USER_DATA_DIR/$1/Local Extension Settings/$EXT"
    printf 'junk\001bridgeDeviceId\001\t\000\005@\330"%s"\a\022\nisplayName\001a\b\000\001<\260"%s"\002more' "$3" "$4" \
      > "$CHROME_USER_DATA_DIR/$1/Local Extension Settings/$EXT/$2"
  }
  pair Default   000010.ldb 11111111-1111-4111-8111-111111111111 "Personal Chrome"
  pair "Profile 2" 000010.ldb 22222222-2222-4222-8222-222222222222 "Work Chrome"
  pair "Profile 3" 000010.ldb 33333333-3333-4333-8333-333333333333 "Side Chrome"
  # Profile 4 has the extension directory but never paired.
  mkdir -p "$CHROME_USER_DATA_DIR/Profile 4/Local Extension Settings/$EXT"
  : > "$CHROME_USER_DATA_DIR/Profile 4/Local Extension Settings/$EXT/000003.log"
}

@test "list: one row per Chrome profile — name, directory, device id, pairing name; unpaired shows dashes" {
  run chrome-pairing list
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'Personal Profile\tDefault\t11111111-1111-4111-8111-111111111111\tPersonal Chrome')" ]
  [ "${lines[1]}" = "$(printf 'Work Profile\tProfile 2\t22222222-2222-4222-8222-222222222222\tWork Chrome')" ]
  [ "${lines[2]}" = "$(printf 'Side Project Profile\tProfile 3\t33333333-3333-4333-8333-333333333333\tSide Chrome')" ]
  [ "${lines[3]}" = "$(printf 'Unpaired Profile\tProfile 4\t-\t-')" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "route: asks Finicky itself what a tagged link would do" {
  run chrome-pairing route work
  [ "$status" -eq 0 ]
  [ "$output" = "Work Profile" ]
  run chrome-pairing route side
  [ "$output" = "Side Project Profile" ]
  # A token no rule claims is not "the default profile" — it is no answer.
  run chrome-pairing route orphan
  [ "$status" -eq 1 ]
  [ "$output" = "" ] || [[ "$output" == *"no Finicky rule routes"* ]]
  run chrome-pairing route nosuchalias
  [ "$status" -eq 1 ]
}

@test "for: alias -> Finicky -> profile -> device id; a profile name works directly" {
  run chrome-pairing for personal
  [ "$status" -eq 0 ]
  [ "$output" = "11111111-1111-4111-8111-111111111111" ]
  run chrome-pairing for "Work Profile"
  [ "$output" = "22222222-2222-4222-8222-222222222222" ]
  run chrome-pairing for "Unpaired Profile"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no Claude in Chrome pairing on disk"* ]]
  run chrome-pairing for nobody
  [ "$status" -eq 1 ]
  [[ "$output" == *"neither an open-as alias"* ]]
}

@test "for: the newest file holding the key wins, and its last occurrence" {
  # An older compacted file with a stale id, a newer log with the current one.
  EXT=fcoeoabgfenejglbffodgkkbkcdhcgfn
  d="$CHROME_USER_DATA_DIR/Default/Local Extension Settings/$EXT"
  printf 'bridgeDeviceId\001\t\000\005@\330"99999999-9999-4999-8999-999999999999"\002x' > "$d/000004.ldb"
  touch -t 202001010000 "$d/000004.ldb"
  printf 'x\001bridgeDeviceId\001\t\000\005@\330"88888888-8888-4888-8888-888888888888"\002y\001bridgeDeviceId\001\t\000\005@\330"77777777-7777-4777-8777-777777777777"\002z' > "$d/000012.log"
  touch -t 203001010000 "$d/000012.log"
  run chrome-pairing for personal
  [ "$output" = "77777777-7777-4777-8777-777777777777" ]
}

@test "session: reads the alias the claude() wrapper exported; without it, says so and exits 1" {
  OPEN_AS_ALIAS=work run chrome-pairing session
  [ "$status" -eq 0 ]
  [ "$output" = "22222222-2222-4222-8222-222222222222" ]
  run chrome-pairing session
  [ "$status" -eq 1 ]
  [[ "$output" == *"OPEN_AS_ALIAS is not set"* ]]
}

@test "usage errors exit 2; a missing Local State is a clear error, not a crash" {
  run chrome-pairing
  [ "$status" -eq 2 ]
  run chrome-pairing for
  [ "$status" -eq 2 ]
  run chrome-pairing bogus
  [ "$status" -eq 2 ]
  CHROME_USER_DATA_DIR="$BATS_TEST_TMPDIR/nowhere" run chrome-pairing list
  [ "$status" -eq 1 ]
  [[ "$output" == *"no readable Chrome Local State"* ]]
}
