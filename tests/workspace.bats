#!/usr/bin/env bats

# bin/workspace puts a set of terminal tabs back on screen: one iTerm2 window
# per group, one tab per entry, each tab typing `cd <dir> && <command>` into a
# login shell so any wrapper in ~/.functions still applies. These tests drive
# the real script under a sandboxed HOME with stub osascript/open/ps/uname/
# osacompile binaries that record their argv — no window is ever opened. All
# names here are fixtures: no real account, project, or group name may appear
# (see CLAUDE.md).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  unset XDG_STATE_HOME
  export WORKSPACE_STATE="$BATS_TEST_TMPDIR/state"
  export ITERM_SCRIPTS="$BATS_TEST_TMPDIR/Scripts"
  export ITERM_PROFILES="$BATS_TEST_TMPDIR/DynamicProfiles"
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

  WS="$BATS_TEST_DIRNAME/../bin/executable_workspace"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  export OSA_LOG="$BATS_TEST_TMPDIR/osascript.log"
  export OSA_SCRIPT="$BATS_TEST_TMPDIR/osascript.script"
  export OPEN_LOG="$BATS_TEST_TMPDIR/open.log"
  : > "$OSA_LOG"; : > "$OPEN_LOG"
  export FAKE_OS=Darwin
  export FAKE_PROCS="iTerm2"
  export FAKE_MARKS=""
  export FAKE_OPENED=""
  export FAKE_ORPHANS=0

  # osascript: record what it was handed. Answer the marker query with
  # FAKE_MARKS, and the start script with FAKE_OPENED — the start script now
  # returns the entries it actually opened, which is what the summary reports.
  # Its first line is the count of sessions carrying the profile but no tag.
  cat > "$BIN/osascript" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$OSA_LOG"
cat > "$OSA_SCRIPT"
[ -z "${FAKE_OSA_FAIL:-}" ] || { echo "-1743: not authorised" >&2; exit 1; }
case "$(cat "$OSA_SCRIPT")" in
  *"return out"*)          printf '%s\n' "${FAKE_MARKS:-}";;
  *"orphans="*) printf 'orphans=%s\n' "${FAKE_ORPHANS:-0}"
                [ -z "${FAKE_OPENED:-}" ] || printf '%s\n' "$FAKE_OPENED";;
esac
exit 0
STUB
  export PROCS_FILE="$BATS_TEST_TMPDIR/procs"
  cat > "$BIN/open" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$OPEN_LOG"
# launching it makes it visible to the next ps, as the real thing would
printf 'iTerm2\n' > "$PROCS_FILE"
exit 0
STUB
  cat > "$BIN/uname" <<'STUB'
#!/bin/sh
printf '%s\n' "${FAKE_OS:-Darwin}"
STUB
  cat > "$BIN/ps" <<'STUB'
#!/bin/sh
if [ -f "${PROCS_FILE:-}" ]; then cat "$PROCS_FILE"; exit 0; fi
for p in ${FAKE_PROCS:-}; do printf '%s\n' "$p"; done
STUB
  cat > "$BIN/osacompile" <<'STUB'
#!/bin/sh
# -o <out> <src> : copy the source through so its text stays greppable, which
# is how the real script recognises its own AutoLaunch.scpt.
out=""; src=""
while [ $# -gt 0 ]; do
  case $1 in -o) out=$2; shift 2;; *) src=$1; shift;; esac
done
[ -n "$out" ] && cp "$src" "$out"
exit 0
STUB
  chmod +x "$BIN"/*
  export PATH="$BIN:$PATH"

  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/one" "$PROJ/two" "$PROJ/three"
}

entry() { # name key value
  git config --file "$GIT_CONFIG_GLOBAL" "workspace.$1.$2" "$3"
}

ws() { run sh "$WS" "$@"; }

# --- configuration ----------------------------------------------------------

@test "list: entries come back in config order, not sorted" {
  entry zeta dir "$PROJ/one"
  entry alpha dir "$PROJ/two"
  entry mid dir "$PROJ/three"
  ws list
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = zeta ]
  [ "${lines[1]}" = alpha ]
  [ "${lines[2]}" = mid ]
}

@test "list: an entry is named once however many keys it has" {
  entry solo dir "$PROJ/one"
  entry solo command "true"
  entry solo title "Solo"
  entry solo window grp
  ws list
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = solo ]
}

@test "a key with no subsection is not mistaken for an entry" {
  entry real dir "$PROJ/one"
  git config --file "$GIT_CONFIG_GLOBAL" workspace.something bare
  ws list
  [ "$output" = real ]
}

@test "~ in dir expands to HOME" {
  mkdir -p "$HOME/inside"
  entry tilde dir '~/inside'
  ws plan
  [[ "$output" == *"$HOME/inside"* ]]
  [[ "$output" == *$'\t'ok$'\t'* ]]
}

@test "an invalid entry name is warned about and skipped, never silently dropped" {
  entry good dir "$PROJ/one"
  # Both shapes git will happily store. A space is the interesting one: it used
  # to vanish during name extraction, so the entry did nothing and said nothing.
  git config --file "$GIT_CONFIG_GLOBAL" 'workspace.bad name.dir' "$PROJ/two"
  git config --file "$GIT_CONFIG_GLOBAL" 'workspace.bad!name.dir' "$PROJ/three"
  ws plan
  [[ "$output" == *"ignoring workspace.bad name."*"may only hold letters, digits"* ]]
  [[ "$output" == *"ignoring workspace.bad!name."*"may only hold letters, digits"* ]]
  [[ "$output" == *good* ]]
  # …and neither reaches the plan as an openable row.
  [ "$(printf '%s\n' "$output" | awk -F'\t' '$3=="ok"' | wc -l | tr -d ' ')" -eq 1 ]
}

# --- grouping ---------------------------------------------------------------

@test "an explicit window key groups entries together" {
  entry one dir "$PROJ/one"; entry one window shared
  entry two dir "$PROJ/two"; entry two window shared
  ws plan
  [ "$(printf '%s\n' "$output" | awk -F'\t' '$1=="shared"' | wc -l | tr -d ' ')" -eq 2 ]
}

@test "an entry with no window key gets a window of its own, named for it" {
  entry lonely dir "$PROJ/one"
  ws plan
  [[ "$output" == lonely$'\t'lonely$'\t'ok* ]]
}

@test "groups: reports each group with its openable count" {
  entry a dir "$PROJ/one"; entry a window pair
  entry b dir "$PROJ/two"; entry b window pair
  entry c dir "$PROJ/three"
  ws groups
  [[ "$output" == *"pair"$'\t'"2"$'\t'"0"* ]]
  [[ "$output" == *"c"$'\t'"1"$'\t'"0"* ]]
}

@test "groups: an already-open tab counts as open" {
  entry a dir "$PROJ/one"; entry a window pair
  entry b dir "$PROJ/two"; entry b window pair
  FAKE_MARKS="a" ws groups
  [[ "$output" == *"pair"$'\t'"2"$'\t'"1"* ]]
}

@test "groups: a disabled or missing-dir entry is not counted as openable" {
  entry ok1 dir "$PROJ/one"; entry ok1 window grp
  entry gone dir "$PROJ/nowhere"; entry gone window grp
  entry off dir "$PROJ/two"; entry off window grp; entry off disabled true
  ws groups
  [[ "$output" == *"grp"$'\t'"1"$'\t'"0"* ]]
}

# --- the plan ---------------------------------------------------------------

@test "plan: a command is appended to the cd, and omitted when unset" {
  entry withcmd dir "$PROJ/one"; entry withcmd command 'some-cmd --flag'
  entry nocmd dir "$PROJ/two"
  ws plan
  [[ "$output" == *"cd -- '$PROJ/one' && some-cmd --flag"* ]]
  [[ "$output" == *"cd -- '$PROJ/two'"* ]]
  [[ "$output" != *"$PROJ/two' &&"* ]]
}

@test "plan: a directory with a quote in it is still safely quoted" {
  mkdir -p "$PROJ/it's"
  entry quoted dir "$PROJ/it's"
  ws plan
  [[ "$output" == *"'$PROJ/it'\\''s'"* ]]
}

@test "plan: a missing directory is no-dir, a disabled entry is disabled" {
  entry gone dir "$PROJ/nowhere"
  entry off dir "$PROJ/one"; entry off disabled true
  entry fine dir "$PROJ/two"
  ws plan
  [[ "$output" == *$'\t'gone$'\t'no-dir* ]]
  [[ "$output" == *$'\t'off$'\t'disabled* ]]
  [[ "$output" == *$'\t'fine$'\t'ok* ]]
}

@test "plan: an entry with no dir at all is no-dir, not a crash" {
  entry nodir title "Has no directory"
  ws plan
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\t'nodir$'\t'no-dir* ]]
}

@test "plan: title defaults to the entry name and is overridable" {
  entry plain dir "$PROJ/one"
  entry fancy dir "$PROJ/two"; entry fancy title 'A Nicer Name'
  ws plan
  [[ "$output" == *$'\t'plain$'\t'ok$'\t'plain$'\t'* ]]
  [[ "$output" == *$'\t'fancy$'\t'ok$'\t'"A Nicer Name"$'\t'* ]]
}

# --- selectors --------------------------------------------------------------

@test "plan: a selector may name a single entry" {
  entry a dir "$PROJ/one"; entry b dir "$PROJ/two"
  ws plan a
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *$'\t'a$'\t'* ]]
}

@test "plan: a selector may name a whole group" {
  entry a dir "$PROJ/one"; entry a window grp
  entry b dir "$PROJ/two"; entry b window grp
  entry c dir "$PROJ/three"
  ws plan grp
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" != *$'\t'c$'\t'* ]]
}

@test "plan: selectors combine without duplicating a row" {
  entry a dir "$PROJ/one"; entry a window grp
  entry b dir "$PROJ/two"; entry b window grp
  ws plan grp a
  [ "${#lines[@]}" -eq 2 ]
}

@test "plan: an unknown selector is an error, not an empty plan" {
  entry a dir "$PROJ/one"
  ws plan nonesuch
  [ "$status" -ne 0 ]
  [[ "$output" == *"no entry or group 'nonesuch'"* ]]
}

# --- generated AppleScript --------------------------------------------------

@test "script: only openable rows reach the plan, and each carries its command" {
  entry a dir "$PROJ/one"; entry a command 'run-a'
  entry gone dir "$PROJ/nowhere"
  entry off dir "$PROJ/two"; entry off disabled true
  ws script
  [[ "$output" == *'set end of thePlan to {"a", "a", "a", "export WORKSPACE_GROUP='"'"'a'"'"'; cd -- '"'"$PROJ/one"'"' && run-a"}'* ]]
  [[ "$output" != *gone* ]]
  [[ "$output" != *'"off"'* ]]
}

@test "script: a session variable, not a title, identifies a tab" {
  entry a dir "$PROJ/one"
  ws script
  [[ "$output" == *'set variable named "user.workspaceSession" to n'* ]]
  [[ "$output" == *'set variable named "user.workspaceWindow" to g'* ]]
}

@test "script: an unset iTerm2 variable is tested, never coerced blindly" {
  entry a dir "$PROJ/one"
  ws script
  [[ "$output" == *"if v is not missing value then set m to (v as text)"* ]]
}

@test "script: windows are addressed by id and nothing is ever closed" {
  entry a dir "$PROJ/one"
  ws script
  [[ "$output" == *"first window whose id is"* ]]
  [[ "$output" != *"close "* ]]
}

# --- start ------------------------------------------------------------------

@test "start: nothing configured says so and opens nothing" {
  ws start
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing configured"* ]]
  [ ! -s "$OSA_LOG" ]
}

@test "start: a missing directory is warned about and the rest still opens" {
  entry gone dir "$PROJ/nowhere"
  entry fine dir "$PROJ/one"
  FAKE_OPENED="fine" ws start
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping 'gone'"* ]]
  [[ "$output" == *"opened fine -> window fine"* ]]
}

@test "start: only entries the script actually opened are reported" {
  entry a dir "$PROJ/one"; entry a window grp
  entry b dir "$PROJ/two"; entry b window grp
  # `a` was already on screen: the AppleScript returns only `b`.
  FAKE_OPENED="b" ws start
  [[ "$output" == *"opened b -> window grp"* ]]
  [[ "$output" != *"opened a"* ]]
}

@test "start: a re-run that opens nothing says so rather than claiming credit" {
  entry a dir "$PROJ/one"
  FAKE_OPENED="" ws start
  [ "$status" -eq 0 ]
  [[ "$output" == *"everything already open"* ]]
  [[ "$output" != *"opened a"* ]]
}

@test "start: every openable entry is disabled -> nothing openable" {
  entry off dir "$PROJ/one"; entry off disabled true
  ws start
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing openable"* ]]
}

@test "start: a refused Apple Event fails loudly with the remediation" {
  entry a dir "$PROJ/one"
  FAKE_OSA_FAIL=1 ws start
  [ "$status" -ne 0 ]
  [[ "$output" == *"Automation"* ]]
}

@test "start: iTerm2 not running is launched first, then driven" {
  entry a dir "$PROJ/one"
  FAKE_PROCS="" FAKE_OPENED="a" ws start
  [ "$status" -eq 0 ]
  # It had to launch it...
  [ -s "$OPEN_LOG" ]
  [[ "$(cat "$OPEN_LOG")" == *iterm2* ]] || [[ "$(cat "$OPEN_LOG")" == *iTerm* ]]
  # ...and then actually script it, rather than giving up.
  [ -s "$OSA_LOG" ]
  [[ "$output" == *"opened a"* ]]
}

# --- Alfred -----------------------------------------------------------------

@test "alfred: emits one item per group with a stable order" {
  entry a dir "$PROJ/one"; entry a window zeta
  entry b dir "$PROJ/two"; entry b window alpha
  ws alfred
  [ "$status" -eq 0 ]
  # skipknowledge keeps config order instead of letting Alfred reorder.
  [[ "$output" == *'"skipknowledge":true'* ]]
  [[ "$output" == *'"uid":"zeta"'* ]]
  [[ "$output" == *'"arg":"alpha"'* ]]
  # zeta is configured first and must stay first
  [[ "${output%%alpha*}" == *zeta* ]]
}

@test "alfred: output is valid JSON" {
  entry a dir "$PROJ/one"; entry a window grp
  entry b dir "$PROJ/two"
  ws alfred
  run python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert len(d["items"])==2; print("ok")' "$output"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
}

@test "alfred: no entries at all still emits valid, empty JSON" {
  ws alfred
  run python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["items"]==[]; print("ok")' "$output"
  [ "$status" -eq 0 ]
}

@test "alfred: the subtitle distinguishes open from unopened groups" {
  entry a dir "$PROJ/one"; entry a window grp
  entry b dir "$PROJ/two"; entry b window grp
  ws alfred
  [[ "$output" == *"none open yet"* ]]
  FAKE_MARKS=$'a\nb' ws alfred
  [[ "$output" == *"all 2 open"* ]]
  FAKE_MARKS="a" ws alfred
  [[ "$output" == *"1 of 2 open"* ]]
}

# --- the AutoLaunch trigger -------------------------------------------------

@test "install: writes an AutoLaunch script that calls this script by absolute path" {
  entry a dir "$PROJ/one"
  ws install
  [ "$status" -eq 0 ]
  [ -f "$ITERM_SCRIPTS/AutoLaunch.scpt" ]
  # It must not depend on PATH: Alfred and iTerm2 both run scripts without ~/bin.
  [[ "$(cat "$ITERM_SCRIPTS/AutoLaunch.scpt")" == *"$WS"*"start"* ]]
  # Detached, or it can sit behind the very script runner it is waiting on.
  [[ "$(cat "$ITERM_SCRIPTS/AutoLaunch.scpt")" == *nohup*"&\""* ]]
}

@test "install: says no Automation grant is needed" {
  ws install
  [[ "$output" == *"no Automation permission is needed"* ]]
}

@test "install: refuses to clobber an AutoLaunch script it did not write" {
  mkdir -p "$ITERM_SCRIPTS"
  printf 'display dialog "someone else"\n' > "$ITERM_SCRIPTS/AutoLaunch.scpt"
  ws install
  [ "$status" -ne 0 ]
  [[ "$output" == *"not written by workspace"* ]]
  [[ "$output" == *"do shell script"* ]]   # tells you the line to add by hand
  [[ "$(cat "$ITERM_SCRIPTS/AutoLaunch.scpt")" == *"someone else"* ]]
}

@test "uninstall: removes ours and refuses to remove somebody else's" {
  ws install
  [ -f "$ITERM_SCRIPTS/AutoLaunch.scpt" ]
  ws uninstall
  [ ! -f "$ITERM_SCRIPTS/AutoLaunch.scpt" ]

  mkdir -p "$ITERM_SCRIPTS"
  printf 'display dialog "someone else"\n' > "$ITERM_SCRIPTS/AutoLaunch.scpt"
  ws uninstall
  [ "$status" -ne 0 ]
  [ -f "$ITERM_SCRIPTS/AutoLaunch.scpt" ]
}

@test "status: reports the trigger, and each entry as open or closed" {
  entry a dir "$PROJ/one"; entry a window grp
  entry b dir "$PROJ/two"; entry b window grp
  ws status
  [[ "$output" == *"trigger:  not installed"* ]]
  ws install
  FAKE_MARKS="a" ws status
  [[ "$output" == *"trigger:  AutoLaunch.scpt installed"* ]]
  [[ "$output" == *"a"*"[open]"* ]]
  [[ "$output" == *"b"*"[closed]"* ]]
}

@test "status: nothing configured is stated, not an empty table" {
  ws status
  [ "$status" -eq 0 ]
  [[ "$output" == *"none configured"* ]]
}

# --- portability ------------------------------------------------------------

@test "read-only commands work off macOS; the ones that drive iTerm2 refuse" {
  entry a dir "$PROJ/one"
  FAKE_OS=Linux ws plan
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\t'a$'\t'ok* ]]
  FAKE_OS=Linux ws alfred
  [ "$status" -eq 0 ]
  FAKE_OS=Linux ws start
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs macOS"* ]]
  FAKE_OS=Linux ws install
  [ "$status" -ne 0 ]
}

@test "an unknown command and no command at all both explain themselves" {
  ws
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage: workspace"* ]]
  ws bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command 'bogus'"* ]]
}

# --- the dedicated iTerm2 profile ---------------------------------------------

@test "script: tabs are created with the workspace profile, falling back if absent" {
  entry a dir "$PROJ/one"
  ws script
  [ "$status" -eq 0 ]
  # Ownership is set by the same command that creates the session, not a step
  # after it, so there is no instant where the tab exists untagged.
  [[ "$output" == *'create window with profile "Workspace"'* ]]
  [[ "$output" == *'create tab with profile "Workspace"'* ]]
  # …but a machine that never ran `install` must still get its tabs.
  [[ "$output" == *"create window with default profile"* ]]
  [[ "$output" == *"create tab with default profile"* ]]
}

@test "script: WORKSPACE_PROFILE renames the profile everywhere it is used" {
  entry a dir "$PROJ/one"
  WORKSPACE_PROFILE=Scratch ws script
  [ "$status" -eq 0 ]
  [[ "$output" == *'create window with profile "Scratch"'* ]]
  [[ "$output" == *'is "Scratch" then'* ]]
  [[ "$output" != *'"Workspace"'* ]]
}

@test "start: warns about tabs carrying the profile but no tag" {
  entry a dir "$PROJ/one"
  FAKE_ORPHANS=2 FAKE_OPENED="a" ws start
  [ "$status" -eq 0 ]
  # An interrupted run leaves a tab that can never be reused. Today that was
  # silent and the next run simply opened a duplicate beside it.
  [[ "$output" == *"2 tab(s)"* ]]
  [[ "$output" == *"interrupted"* ]]
  [[ "$output" == *"opened a"* ]]
}

@test "start: says nothing about orphans when there are none" {
  entry a dir "$PROJ/one"
  FAKE_ORPHANS=0 FAKE_OPENED="a" ws start
  [ "$status" -eq 0 ]
  [[ "$output" != *"interrupted"* ]]
  [[ "$output" == *"opened a"* ]]
}

@test "start: the orphan count is never mistaken for an opened entry" {
  entry a dir "$PROJ/one"
  FAKE_ORPHANS=1 FAKE_OPENED="" ws start
  [ "$status" -eq 0 ]
  [[ "$output" == *"everything already open"* ]]
  [[ "$output" != *"opened orphans"* ]]
}

@test "install: writes a dynamic profile that inherits Default" {
  entry a dir "$PROJ/one"
  ws install
  [ "$status" -eq 0 ]
  prof="$ITERM_PROFILES/workspace.json"
  [ -f "$prof" ]
  run python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['Profiles'][0]; print(d['Name'], d['Dynamic Profile Parent Name'], d['Guid'])" "$prof"
  [ "$status" -eq 0 ]
  # Inherited, not copied: it cannot drift from Default the way a duplicate would.
  [[ "$output" == "Workspace Default workspace-launcher-profile" ]]
}

@test "install: reinstalling keeps one profile rather than adding another" {
  entry a dir "$PROJ/one"
  ws install
  first=$(cat "$ITERM_PROFILES/workspace.json")
  ws install
  [ "$status" -eq 0 ]
  [ "$(ls "$ITERM_PROFILES" | wc -l | tr -d ' ')" = 1 ]
  [ "$(cat "$ITERM_PROFILES/workspace.json")" = "$first" ]
}

@test "uninstall: removes the profile along with the trigger" {
  entry a dir "$PROJ/one"
  ws install
  [ -f "$ITERM_PROFILES/workspace.json" ]
  ws uninstall
  [ "$status" -eq 0 ]
  [ ! -f "$ITERM_PROFILES/workspace.json" ]
}

@test "status: reports whether the profile is installed" {
  entry a dir "$PROJ/one"
  ws status
  [[ "$output" == *"profile:"*"not installed"* ]]
  ws install
  ws status
  [ "$status" -eq 0 ]
  [[ "$output" == *"profile:"*"Workspace"* ]]
  [[ "$output" != *"not installed"* ]]
}

@test "script: the generated AppleScript is emitted without running anything" {
  entry a dir "$PROJ/one"
  ws script
  [ "$status" -eq 0 ]
  # The AppleScript is built with an unquoted heredoc, so a backtick or a $(…)
  # anywhere in it — a comment included — is command substitution: the shell
  # runs it and drops the output into the script. A prose backtick around a
  # command name did exactly that.
  [[ "$output" != *"command not found"* ]]
  [[ "$output" != *'`'* ]]
  [[ "$output" == *'"workspace install" was never run'* ]]
}

# --- the group reaches the prompt ---------------------------------------------

@test "plan: every command exports its group so the prompt can prefix the title" {
  entry a dir "$PROJ/one"
  entry a window grp
  entry b dir "$PROJ/two"
  entry b command "run-b"
  entry b window grp
  ws plan
  [ "$status" -eq 0 ]
  # The launcher cannot set the tab title itself: precmd rewrites it at the
  # first prompt, and iTerm2's Custom Tab Title renders once at session
  # creation, before the session is tagged. Exporting is what survives.
  [[ "${lines[0]}" == *"export WORKSPACE_GROUP='grp'; cd -- "* ]]
  [[ "${lines[1]}" == *"export WORKSPACE_GROUP='grp'; cd -- "*"&& run-b"* ]]
}

@test "plan: a group name with a quote in it is still shell-safe" {
  entry a dir "$PROJ/one"
  entry a window "it's"
  ws plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"export WORKSPACE_GROUP='it'\\''s';"* ]]
}
