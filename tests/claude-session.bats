#!/usr/bin/env bats

# bin/claude-session reopens the day's Claude Code sessions after a restart:
# one iTerm2 window per Claude Code profile, one tab per project, each tab
# typing `cd <project> && claude` into a login shell so the claude() wrapper
# in ~/.functions picks the account. These tests drive the real script under a
# sandboxed HOME with the real dot_functions installed as ~/.functions, and
# with stub osascript/open/launchctl/ps/uname binaries that record their argv
# — no window is ever opened. All names here are fixtures: no real account,
# project, or window name may appear (see CLAUDE.md).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  unset CLAUDE_PROFILE CLAUDE_CONFIG_DIR CLAUDE_SESSION_STATE XDG_STATE_HOME
  export CLAUDE_SESSION_STATE="$BATS_TEST_TMPDIR/state"

  # The window a session lands in is asked of claude_profile_dir in
  # ~/.functions — the same helper claude() uses — so the real file is
  # installed, not a stand-in.
  cp "$BATS_TEST_DIRNAME/../dot_functions" "$HOME/.functions"

  # Fixture pins: two owners on two Claude Code profiles.
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-work-org.username work-account
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-personal.username personal-account
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.work-account "$HOME/.claude"
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.personal-account "$HOME/.claude-side"
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  export OSA_LOG="$BATS_TEST_TMPDIR/osascript.log"
  export OSA_SCRIPT="$BATS_TEST_TMPDIR/osascript.script"
  export OPEN_LOG="$BATS_TEST_TMPDIR/open.log"
  export LAUNCHCTL_LOG="$BATS_TEST_TMPDIR/launchctl.log"
  : > "$OSA_LOG"; : > "$OPEN_LOG"; : > "$LAUNCHCTL_LOG"
  export FAKE_OS=Darwin
  export FAKE_PROCS="Dock loginwindow"     # iTerm2 deliberately absent
  export FAKE_MARKS=""

  # osascript: record the script it was handed; answer the marker query with
  # FAKE_MARKS so `status` has something to report.
  cat > "$BIN/osascript" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$OSA_LOG"
cat > "$OSA_SCRIPT"
case "$(cat "$OSA_SCRIPT")" in
  *"return out"*) printf '%s\n' "${FAKE_MARKS:-}";;
esac
[ -z "${FAKE_OSA_FAIL:-}" ] || { echo "-1743: not authorised" >&2; exit 1; }
exit 0
STUB
  cat > "$BIN/open" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$OPEN_LOG"
FAKE_PROCS="$FAKE_PROCS iTerm2"
printf '%s\n' "$FAKE_PROCS" > "$BATS_TEST_TMPDIR/procs"
STUB
  cat > "$BIN/launchctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"
case "$1 $2" in
  "print gui/"*/local.claude-session)
    [ -n "${FAKE_AGENT_LOADED:-}" ] || exit 1
    echo "	state = running";;
esac
exit 0
STUB
  # ps: the script asks it whether iTerm2/Dock are running, padded the way the
  # real `ps -Ao ucomm=` pads its column.
  cat > "$BIN/ps" <<'STUB'
#!/bin/sh
procs=$FAKE_PROCS
[ -f "$BATS_TEST_TMPDIR/procs" ] && procs=$(cat "$BATS_TEST_TMPDIR/procs")
for p in $procs; do printf '%-16s\n' "$p"; done
STUB
  cat > "$BIN/uname" <<'STUB'
#!/bin/sh
echo "${FAKE_OS:-Darwin}"
STUB
  cat > "$BIN/sleep" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "$BIN"/*
  cp "$BATS_TEST_DIRNAME/../bin/executable_claude-session" "$BIN/claude-session"
  chmod +x "$BIN/claude-session"
  CS="$BIN/claude-session"
  export PATH="$BIN:$PATH"
}

# repo <dir> <origin> — a git repo whose origin decides its Claude profile.
repo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" remote add origin "$2"
}

# session <name> <key> <value>…
session() {
  n=$1; shift
  while [ $# -gt 1 ]; do
    git config --file "$GIT_CONFIG_GLOBAL" "claude-session.$n.$1" "$2"
    shift 2
  done
}

@test "no configuration at all: nothing listed, nothing planned, nothing opened" {
  run "$CS" list
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run "$CS" plan
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run "$CS" start
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing configured"* ]]
  [ ! -s "$OSA_LOG" ]
  [ ! -s "$OPEN_LOG" ]

  run "$CS" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"sessions: <none configured"* ]]
}

@test "plan: the window comes from the Claude profile the directory resolves to" {
  repo "$HOME/work-one" 'git@github.com:octo-work-org/one.git'
  repo "$HOME/work-two" 'https://github.com/octo-work-org/two.git'
  repo "$HOME/mine" 'git@github.com:octo-personal/mine.git'
  session work-one dir "$HOME/work-one"
  session work-two dir "$HOME/work-two"
  session mine dir "$HOME/mine"

  run "$CS" plan
  [ "$status" -eq 0 ]
  # claude.profile.work-account -> ~/.claude, personal -> ~/.claude-side; the
  # label is that directory's name, so the two work repos share a window and
  # the personal one does not.
  [[ "${lines[0]}" == "claude	work-one	ok	work-one	$HOME/work-one	cd -- '$HOME/work-one' && claude" ]]
  [[ "${lines[1]}" == "claude	work-two	ok"* ]]
  [[ "${lines[2]}" == "claude-side	mine	ok"* ]]
}

@test "plan: an explicit window key outranks the derived one; args and profile shape the command" {
  repo "$HOME/mine" 'git@github.com:octo-personal/mine.git'
  session mine dir "$HOME/mine" window pinned args --continue profile side-profile title "my tab"

  run "$CS" plan
  [ "$status" -eq 0 ]
  [[ "$output" == "pinned	mine	ok	my tab	$HOME/mine	cd -- '$HOME/mine' && claude-as side-profile --continue" ]]
}

@test "plan: a directory nothing resolves gets a window of its own, never a shared one" {
  mkdir -p "$HOME/loose-a" "$HOME/loose-b"
  session loose-a dir "$HOME/loose-a"
  session loose-b dir "$HOME/loose-b"

  run "$CS" plan
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "loose-a	loose-a	ok"* ]]
  [[ "${lines[1]}" == "loose-b	loose-b	ok"* ]]
}

@test "plan: missing directory and disabled entries are stated, not silently dropped" {
  mkdir -p "$HOME/here"
  session here dir "$HOME/here"
  session gone dir "$HOME/not-there"
  session off dir "$HOME/here" disabled true
  session nodir window somewhere

  run "$CS" plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"	here	ok	"* ]]
  [[ "$output" == *"	gone	no-dir	"* ]]
  [[ "$output" == *"	off	disabled	"* ]]
  [[ "$output" == *"	nodir	no-dir	"* ]]
}

@test "plan: a tilde in the directory is expanded, and a name that is not a session is a typo" {
  mkdir -p "$HOME/tilde-project"
  session tilde dir '~/tilde-project'
  run "$CS" plan tilde
  [ "$status" -eq 0 ]
  [[ "$output" == *"	ok	tilde	$HOME/tilde-project	cd -- '$HOME/tilde-project' && claude" ]]

  run "$CS" plan nosuch
  [ "$status" -eq 1 ]
  [[ "$output" == *"no session 'nosuch'"* ]]
}

@test "script: one plan entry per openable session, quotes escaped, marker logic present" {
  repo "$HOME/mine" 'git@github.com:octo-personal/mine.git'
  mkdir -p "$HOME/od'd"
  session mine dir "$HOME/mine"
  session quoted dir "$HOME/od'd" window 'say "hi"'
  session gone dir "$HOME/not-there"

  run "$CS" script
  [ "$status" -eq 0 ]
  expected="set end of thePlan to {\"claude-side\", \"mine\", \"mine\", \"cd -- '$HOME/mine' && claude\"}"
  [[ "$output" == *"$expected"* ]]
  # A double quote in a window label survives as an escaped AppleScript quote.
  [[ "$output" == *'{"say \"hi\"", "quoted"'* ]]
  # The unopenable session is not in the script.
  [[ "$output" != *'"gone"'* ]]
  # Idempotency and grouping live in the AppleScript itself.
  [[ "$output" == *'set variable named "user.claudeSession" to n'* ]]
  [[ "$output" == *"if n is not in openMarks then"* ]]
  [[ "$output" == *"create window with default profile"* ]]
  [[ "$output" == *"create tab with default profile"* ]]
  # An unset iTerm2 variable answers `missing value`; coercing it to text
  # would tag every untagged session.
  [[ "$output" == *"is not missing value"* ]]
}

@test "start: launches iTerm2 when it is not running and hands the plan to osascript" {
  repo "$HOME/mine" 'git@github.com:octo-personal/mine.git'
  session mine dir "$HOME/mine"

  run "$CS" start
  [ "$status" -eq 0 ]
  [[ "$output" == *"mine -> window claude-side"* ]]
  [[ "$(cat "$OPEN_LOG")" == *"com.googlecode.iterm2"* ]]
  [[ "$(cat "$OSA_SCRIPT")" == *'"mine"'* ]]
  [[ "$(cat "$OSA_SCRIPT")" == *"tell application \"iTerm2\""* ]]
}

@test "start: an already-running iTerm2 is not launched again" {
  repo "$HOME/mine" 'git@github.com:octo-personal/mine.git'
  session mine dir "$HOME/mine"
  export FAKE_PROCS="Dock iTerm2"

  run "$CS" start
  [ "$status" -eq 0 ]
  [ ! -s "$OPEN_LOG" ]
  [ -s "$OSA_SCRIPT" ]
}

@test "start: a session whose directory is gone is warned about and left out" {
  mkdir -p "$HOME/here"
  session here dir "$HOME/here"
  session gone dir "$HOME/not-there"

  run "$CS" start
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping 'gone'"* ]]
  [[ "$(cat "$OSA_SCRIPT")" == *'"here"'* ]]
  [[ "$(cat "$OSA_SCRIPT")" != *'"gone"'* ]]
}

@test "start: nothing openable never reaches iTerm2" {
  session gone dir "$HOME/not-there"
  run "$CS" start
  [ "$status" -eq 0 ]
  [[ "$output" == *"no session is openable"* ]]
  [ ! -s "$OSA_LOG" ]
  [ ! -s "$OPEN_LOG" ]
}

@test "start: a refused Automation permission is reported with the way to grant it" {
  repo "$HOME/mine" 'git@github.com:octo-personal/mine.git'
  session mine dir "$HOME/mine"
  export FAKE_OSA_FAIL=1

  run "$CS" start
  [ "$status" -eq 1 ]
  [[ "$output" == *"Automation"* ]]
  # Retried rather than given up on the first refusal.
  [ "$(wc -l < "$OSA_LOG")" -ge 5 ]
}

@test "start: only the named sessions open" {
  repo "$HOME/mine" 'git@github.com:octo-personal/mine.git'
  mkdir -p "$HOME/other"
  session mine dir "$HOME/mine"
  session other dir "$HOME/other"

  run "$CS" start other
  [ "$status" -eq 0 ]
  [[ "$(cat "$OSA_SCRIPT")" == *'"other"'* ]]
  [[ "$(cat "$OSA_SCRIPT")" != *'"mine"'* ]]
}

@test "at-login: waits for the GUI, then starts; nothing configured exits silently" {
  run "$CS" at-login
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$OSA_LOG" ]

  repo "$HOME/mine" 'git@github.com:octo-personal/mine.git'
  session mine dir "$HOME/mine"
  run "$CS" at-login
  [ "$status" -eq 0 ]
  [[ "$output" == *"at-login start"* ]]
  [[ "$(cat "$OSA_SCRIPT")" == *'"mine"'* ]]
}

@test "install: an Aqua-only agent that runs at-login, and uninstall removes it" {
  run "$CS" install
  [ "$status" -eq 0 ]
  [[ "$output" == *"local.claude-session"* ]]
  plist="$HOME/Library/LaunchAgents/local.claude-session.plist"
  [ -f "$plist" ]
  [[ "$(cat "$plist")" == *"<string>$BIN/claude-session</string>"* ]]
  [[ "$(cat "$plist")" == *"<string>at-login</string>"* ]]
  [[ "$(cat "$plist")" == *"<key>RunAtLoad</key>"*"<true/>"* ]]
  # Aqua and nothing else: this job opens windows in a GUI login session.
  [[ "$(cat "$plist")" == *"<key>LimitLoadToSessionType</key>"*"<string>Aqua</string>"* ]]
  [[ "$(cat "$plist")" != *"Background"* ]]
  [[ "$(cat "$plist")" == *"$CLAUDE_SESSION_STATE/launch.log"* ]]
  # launchd parses it, so it must actually be a plist (macOS only).
  if command -v plutil >/dev/null; then plutil -lint "$plist"; fi
  [[ "$(cat "$LAUNCHCTL_LOG")" == *"bootstrap gui/"* ]]
  # Installing opens no window: that is `start`'s job, run by hand once so the
  # Automation prompt appears with someone there to answer it.
  [ ! -s "$OSA_LOG" ]
  [[ "$output" == *"claude-session start"* ]]

  run "$CS" uninstall
  [ "$status" -eq 0 ]
  [ ! -f "$plist" ]
  [[ "$(cat "$LAUNCHCTL_LOG")" == *"bootout gui/"* ]]
}

@test "status: agent state, per-session lines, and which tabs are already open" {
  repo "$HOME/mine" 'git@github.com:octo-personal/mine.git'
  mkdir -p "$HOME/other"
  session mine dir "$HOME/mine"
  session other dir "$HOME/other"
  export FAKE_PROCS="Dock iTerm2"
  export FAKE_MARKS="mine"
  export FAKE_AGENT_LOADED=1
  "$CS" install >/dev/null

  run "$CS" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent:    loaded (running)"* ]]
  [[ "$output" == *"mine"*"ok"*"$HOME/mine [open]"* ]]
  [[ "$output" == *"other"*"ok"*"$HOME/other [closed]"* ]]
}

@test "status: an installed-but-unloaded agent says so" {
  "$CS" install >/dev/null
  run "$CS" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"plist present, NOT loaded"* ]]
}

@test "off macOS: the read-only commands still work, the acting ones refuse" {
  mkdir -p "$HOME/here"
  session here dir "$HOME/here"
  export FAKE_OS=Linux

  run "$CS" plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"	here	ok	"* ]]

  run "$CS" script
  [ "$status" -eq 0 ]
  [[ "$output" == *'"here"'* ]]

  for c in start install uninstall at-login; do
    run "$CS" "$c"
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs macOS"* ]]
  done
  [ ! -s "$OSA_LOG" ]
}

@test "a session name that is not a plain label is refused, not passed to AppleScript" {
  mkdir -p "$HOME/here"
  git config --file "$GIT_CONFIG_GLOBAL" 'claude-session.bad name.dir' "$HOME/here"
  session here dir "$HOME/here"

  run "$CS" plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"	here	ok	"* ]]
  [[ "$output" != *"bad name"* ]]
}

@test "the top-level delay key is an option, not a session" {
  mkdir -p "$HOME/here"
  git config --file "$GIT_CONFIG_GLOBAL" claude-session.delay 7
  session here dir "$HOME/here"

  run "$CS" list
  [ "$status" -eq 0 ]
  [ "$output" = "here" ]
}

@test "no window is ever opened by list, plan, script, status, or logs" {
  repo "$HOME/mine" 'git@github.com:octo-personal/mine.git'
  session mine dir "$HOME/mine"
  mkdir -p "$CLAUDE_SESSION_STATE"
  : > "$CLAUDE_SESSION_STATE/launch.log"
  for c in list plan script logs; do
    run "$CS" "$c"
    [ "$status" -eq 0 ]
  done
  [ ! -s "$OPEN_LOG" ]
  # status may *query* a running iTerm2, but only read-only and never launches.
  run "$CS" status
  [ "$status" -eq 0 ]
  [ ! -s "$OPEN_LOG" ]
  [ ! -s "$OSA_LOG" ]
}

@test "claude-session-doctor reports the script, the agent, and the cwd's window" {
  repo "$HOME/mine" 'git@github.com:octo-personal/mine.git'
  session mine dir "$HOME/mine"
  export FAKE_PROCS="Dock iTerm2"
  export FAKE_MARKS=""

  run zsh -c "source '$BATS_TEST_DIRNAME/../dot_functions'; cd '$HOME/mine'; claude-session-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"defined: ok ("* ]]
  [[ "$output" == *"script:  $BIN/claude-session"* ]]
  [[ "$output" == *"agent:    not installed"* ]]
  [[ "$output" == *"sessions:"* ]]
  [[ "$output" == *"mine"* ]]
  [[ "$output" == *"window:  claude-side"* ]]
}

@test "claude-session-doctor without the script says the launcher is not there" {
  rm -f "$BIN/claude-session"
  run zsh -c "source '$BATS_TEST_DIRNAME/../dot_functions'; claude-session-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"script:  NOT FOUND"* ]]
}
