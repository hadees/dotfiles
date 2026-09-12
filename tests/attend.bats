#!/usr/bin/env bats

# bin/attend colours iTerm2 tabs by Claude Code session state: a hook paints
# the tab its own session sits in (red while blocked on you, amber while
# sitting on a finished turn) and a bounded watcher dims that colour once you
# have actually looked at the tab. These tests drive the real script under a
# sandboxed HOME with stub osascript/ps/uname/date binaries — no window is ever
# opened, no real session registry is read, and no tab of yours is painted. The
# one place real bytes matter is painting, so those tests hand the script a
# pseudo-terminal of their own and read back what it wrote. All names here are
# fixtures: no real account, profile, or project name may appear (see
# CLAUDE.md).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  # profile_dirs starts from CLAUDE_CONFIG_DIR, which is exported in every
  # Claude Code session — including the one bats may be run from, where it
  # names a real profile directory.
  unset CLAUDE_CONFIG_DIR XDG_STATE_HOME

  AT="$BATS_TEST_DIRNAME/../bin/executable_attend"
  export ATTEND_STATE="$BATS_TEST_TMPDIR/state"
  STATE="$ATTEND_STATE"
  TABS="$STATE/tabs"
  LOCK="$STATE/watch.lock"

  # A directory that is not a git repo: the script asks git config for the
  # profile mapping and the poll interval, and a repo-local config under the
  # clone bats was started in must not reach the answer.
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
  cd "$WORK" || return 1

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  export PS_STEP="$BATS_TEST_TMPDIR/ps-step"
  export PTY_LOG="$BATS_TEST_TMPDIR/pty.log"
  : > "$PTY_LOG"
  export FAKE_OS=Darwin
  export FAKE_PS_CHAIN=""
  export FAKE_FRONT=""
  export FAKE_FOCUS=""

  # ps -o ppid=,tty= -p <pid>. The answer comes from FAKE_PS_CHAIN, one step
  # per call ("<ppid>:<tty>"), so the parent-chain walk is deterministic
  # whatever the real pids are: step 1 answers for the process attend was
  # started from, step 2 for its parent, and so on. `??` is what ps prints for
  # a process with no controlling terminal; `@pty` stands for the
  # pseudo-terminal this run was handed. FAKE_PS_PAD=0 drops the padding real
  # ps applies to both columns.
  cat > "$BIN/ps" <<'STUB'
#!/bin/sh
n=0
[ -f "$PS_STEP" ] && read -r n < "$PS_STEP"
n=$((n + 1)); printf '%s\n' "$n" > "$PS_STEP"
i=0
for step in ${FAKE_PS_CHAIN:-}; do
  i=$((i + 1))
  [ "$i" = "$n" ] || continue
  pp=${step%%:*}; t=${step#*:}
  [ "$t" = @pty ] && t=${ATTEND_PTY_NAME:-ttys999}
  case ${FAKE_PS_PAD:-1} in
    0) printf '%s %s\n' "$pp" "$t" ;;
    *) printf '%8s %-10s\n' "$pp" "$t" ;;
  esac
  exit 0
done
exit 1
STUB
  # focused_tty asks one AppleScript two questions — is iTerm2 frontmost, and
  # what is the current session's tty — and every branch of it answers with a
  # line, so "not iTerm2" and "no window" are both an empty answer.
  cat > "$BIN/osascript" <<'STUB'
#!/bin/sh
cat > /dev/null
[ "${FAKE_FRONT:-}" = iTerm2 ] || { printf '\n'; exit 0; }
f=${FAKE_FOCUS:-}
[ "$f" = @pty ] && f=${ATTEND_PTY:-}
printf '%s\n' "$f"
STUB
  cat > "$BIN/uname" <<'STUB'
#!/bin/sh
printf '%s\n' "${FAKE_OS:-Darwin}"
STUB
  chmod +x "$BIN"/*
  export PATH="$BIN:$PATH"

  # Hand the script a pseudo-terminal to paint: paint() insists on a character
  # device it can write, so no plain file will do, and a pty is the only one a
  # test can own and read back. The child is given its path in ATTEND_PTY and
  # the part of it ps reports in its tty column in ATTEND_PTY_NAME — the path
  # under /dev rather than the basename, because a Linux pty is /dev/pts/N and
  # ps says `pts/N`; whatever is written to it lands in $PTY_LOG.
  PTYRUN="$BATS_TEST_TMPDIR/ptyrun.py"
  cat > "$PTYRUN" <<'PY'
import os, pty, select, subprocess, sys, tty

master, slave = pty.openpty()
try:
    tty.setraw(master)          # no ONLCR: the bytes read back are the bytes written
except Exception:
    pass
name = os.ttyname(slave)
env = dict(os.environ, ATTEND_PTY=name, ATTEND_PTY_NAME=name[len("/dev/"):])
rc = subprocess.call(sys.argv[1:], env=env)
buf = b""
while True:                     # the slave stays open, so a drained pty just times out
    if not select.select([master], [], [], 0.3)[0]:
        break
    chunk = os.read(master, 65536)
    if not chunk:
        break
    buf += chunk
log = os.environ.get("PTY_LOG")
if log:
    with open(log, "ab") as fh:
        fh.write(buf)
sys.exit(rc)
PY

  # A hook whose tab is unseen starts a watcher. Holding the lock with a pid
  # that outlives the test (bats' own) keeps that spawn from happening behind
  # every unrelated test; the tests that are about the watcher call `unlock`.
  mkdir -p "$LOCK"
  printf '%s\n' "$$" > "$LOCK/pid"
  mkdir -p "$TABS" "$HOME/.claude/sessions"
}

teardown() {
  # A watcher a test deliberately let the hook spawn exits at its next pass
  # once there is nothing unseen left; removing the state bounds that to one
  # interval rather than the rest of the run.
  rm -rf "$STATE" 2>/dev/null
  return 0
}

at() { # run the script; paint lands on a device the test cannot read
  printf '0\n' > "$PS_STEP"
  run sh "$AT" "$@"
}

pty_run() { # run anything with a real pty to paint; bytes -> $PTY_LOG
  printf '0\n' > "$PS_STEP"
  run python3 "$PTYRUN" "$@"
}

unlock() { rm -rf "$LOCK"; }

tab() { # pid state seen tty [since]
  mkdir -p "$TABS"
  printf '%s %s %s %s\n' "$2" "$3" "$4" "${5:-1700000000}" > "$TABS/$1"
}

field() { # pid n -> the nth word of that tab's state file
  awk -v n="$2" '{print $n}' "$TABS/$1"
}

# A session registry entry. Claude Code names these files for the pid; the
# reader globs *.json and takes the pid from inside, so an explicit id lets one
# fixture pid stand behind several rows.
session() { # profile-dir id pid status since-ms name cwd
  mkdir -p "$1/sessions"
  cat > "$1/sessions/$2.json" <<EOF
{ "pid": $3, "sessionId": "fixture-$2", "status": "$4",
  "statusUpdatedAt": $5, "name": "$6", "cwd": "$7" }
EOF
}

dead_pid() { # a pid that is certainly gone
  sh -c 'echo $$'
}

esc() { printf '\033'; }

# --- tty discovery ----------------------------------------------------------

@test "owner_of: the walk passes a process with no tty and reports the one that has it" {
  # The hook itself has no controlling terminal — Claude Code starts it
  # detached — so the answer is always at least one hop up. Keying the tab on
  # the hook's own parent was the bug: the state file must be named for the
  # process that owns the tty, not for the pid the walk started at.
  FAKE_PS_CHAIN="7001:?? 7002:ttys900" at hook waiting
  [ "$status" -eq 0 ]
  [ "$(ls "$TABS")" = 7001 ]
  [ "$(field 7001 3)" = /dev/ttys900 ]
}

@test "owner_of: the walk gives up rather than climbing forever" {
  # Eight hops of `??` and no tty anywhere: a hook must come back, not spin.
  FAKE_PS_CHAIN="1:?? 1:?? 1:?? 1:?? 1:?? 1:?? 1:?? 1:?? 1:?? 1:??" at hook waiting
  [ "$status" -eq 0 ]
  [ -z "$(ls "$TABS")" ]
}

@test "owner_of: the parse survives ps padding, and its absence" {
  FAKE_PS_CHAIN="7001:?? 7002:ttys901" at hook waiting
  [ "$(field 7001 3)" = /dev/ttys901 ]
  rm -f "$TABS"/*
  FAKE_PS_PAD=0 FAKE_PS_CHAIN="7001:?? 7002:ttys901" at hook waiting
  [ "$(field 7001 3)" = /dev/ttys901 ]
}

@test "owner_of: the ?? ps prints for no tty is never expanded as a glob" {
  # An unquoted split globs, and `??` matches any two-character name in the
  # cwd — which for a hook is the project directory. A repo with a `ui/` in it
  # reported the tty as /dev/ui and painted nothing, silently and only there.
  globby="$BATS_TEST_TMPDIR/globby"
  mkdir -p "$globby/ui"
  printf '0\n' > "$PS_STEP"
  FAKE_PS_CHAIN="7001:?? 7002:ttys902" \
    run sh -c "cd '$globby' && sh '$AT' hook waiting"
  [ "$status" -eq 0 ]
  [ "$(field 7001 3)" = /dev/ttys902 ]
}

# --- the hook ---------------------------------------------------------------

@test "hook: every event name and every state name lands on the same four states" {
  # settings.json may pass either its own vocabulary or Claude Code's, so both
  # spellings of each transition must agree.
  for e in waiting Notification; do
    rm -f "$TABS"/*
    FAKE_PS_CHAIN="7001:?? 7002:ttys900" at hook "$e"
    [ "$(field 7001 1)" = waiting ]
  done
  for e in idle Stop; do
    rm -f "$TABS"/*
    FAKE_PS_CHAIN="7001:?? 7002:ttys900" at hook "$e"
    [ "$(field 7001 1)" = idle ]
  done
}

@test "hook: an event that means 'you are here' clears the tab and forgets it" {
  for e in busy UserPromptSubmit end SessionEnd; do
    tab 7001 waiting 0 /dev/ttys900
    FAKE_PS_CHAIN="7001:?? 7002:ttys900" at hook "$e"
    [ "$status" -eq 0 ]
    [ ! -f "$TABS/7001" ]
  done
}

@test "hook: an event it does not recognise clears rather than guessing" {
  # A wrong colour that never goes away is worse than no colour.
  tab 7001 waiting 0 /dev/ttys900
  FAKE_PS_CHAIN="7001:?? 7002:ttys900" at hook PreToolUse
  [ "$status" -eq 0 ]
  [ ! -f "$TABS/7001" ]
}

@test "hook: re-alerting a tab you had already seen makes it new again" {
  tab 7001 waiting 1 /dev/ttys900
  FAKE_PS_CHAIN="7001:?? 7002:ttys900" at hook idle
  [ "$(field 7001 1)" = idle ]
  [ "$(field 7001 2)" = 0 ]
}

@test "hook: no tty anywhere, no arguments, and no ps at all still exit 0" {
  # A hook that fails takes the session down with it.
  FAKE_PS_CHAIN="" at hook waiting
  [ "$status" -eq 0 ]
  [ -z "$(ls "$TABS")" ]
  at hook
  [ "$status" -eq 0 ]
  FAKE_PS_CHAIN="7001:?? 7002:ttys900" FAKE_OS=Linux at hook waiting
  [ "$status" -eq 0 ]
}

@test "hook: off macOS nothing is spawned to watch the tab" {
  unlock
  FAKE_OS=Linux FAKE_PS_CHAIN="7001:?? 7002:ttys900" at hook waiting
  [ "$status" -eq 0 ]
  [ -f "$TABS/7001" ]
  [ ! -d "$LOCK" ]
}

# --- painting ---------------------------------------------------------------

@test "paint: a colour is three OSC 6 writes to the tab's tty, one per channel" {
  FAKE_PS_CHAIN="7001:?? 7002:@pty" pty_run sh "$AT" hook waiting
  [ "$status" -eq 0 ]
  e=$(esc); a=$'\a'
  want="${e}]6;1;bg;red;brightness;242${a}"
  want="${want}${e}]6;1;bg;green;brightness;119${a}"
  want="${want}${e}]6;1;bg;blue;brightness;122${a}"
  [ "$(cat "$PTY_LOG")" = "$want" ]
}

@test "paint: clearing is the single *;default form, not a colour" {
  FAKE_PS_CHAIN="7001:?? 7002:@pty" pty_run sh "$AT" hook end
  [ "$status" -eq 0 ]
  [ "$(cat "$PTY_LOG")" = "$(printf '\033]6;1;bg;*;default\a')" ]
}

@test "paint: a device it cannot write is refused, and the tab recorded anyway" {
  # paint takes only a character device it can write, and /dev/fd is a
  # directory — so nothing is written. The tab is still recorded: it is real,
  # this process just cannot reach it, and losing it would lose the colour at
  # the next sweep too. Recording before painting is what makes that true.
  FAKE_PS_CHAIN="7001:?? 7002:fd" pty_run sh "$AT" hook waiting
  [ "$status" -eq 0 ]
  [ "$(field 7001 1)" = waiting ]
  [ "$(field 7001 3)" = /dev/fd ]
  [ ! -s "$PTY_LOG" ]
  # The same hook, pointed at a device it can write, does write.
  rm -f "$TABS"/*
  FAKE_PS_CHAIN="7001:?? 7002:@pty" pty_run sh "$AT" hook waiting
  [ -s "$PTY_LOG" ]
}

# --- the watcher ------------------------------------------------------------

@test "watch: a tab is seen only when it is the focused one and iTerm2 is in front" {
  tab "$$" waiting 0 /dev/ttys900
  FAKE_FRONT=iTerm2 FAKE_FOCUS=/dev/ttys901 at watch --once
  [ "$(field "$$" 2)" = 0 ]
  FAKE_FRONT=iTerm2 FAKE_FOCUS=/dev/ttys900 at watch --once
  [ "$(field "$$" 2)" = 1 ]
}

@test "watch: a tab in a background window stays unseen however focused it is" {
  # The tty answer alone would say "seen": it is the current session of the
  # current window, in a window nobody is looking at.
  tab "$$" waiting 0 /dev/ttys900
  FAKE_FRONT=Terminal FAKE_FOCUS=/dev/ttys900 at watch --once
  [ "$status" -eq 0 ]
  [ "$(field "$$" 2)" = 0 ]
}

@test "watch: a seen tab keeps its hue and loses its shout" {
  # Red means "since you last looked"; dim red means "you know about this
  # one". The distinction is worthless if the hue moves with the brightness.
  FAKE_PS_CHAIN="1:@pty" FAKE_FRONT=iTerm2 FAKE_FOCUS=@pty \
    pty_run sh -c "sh '$AT' hook waiting; sh '$AT' watch --once"
  [ "$status" -eq 0 ]
  f=$(ls "$TABS")
  [ "$(field "$f" 2)" = 1 ]

  e=$(esc); a=$'\a'
  bright="${e}]6;1;bg;red;brightness;242${a}"
  bright="${bright}${e}]6;1;bg;green;brightness;119${a}"
  bright="${bright}${e}]6;1;bg;blue;brightness;122${a}"
  dim="${e}]6;1;bg;red;brightness;134${a}"
  dim="${dim}${e}]6;1;bg;green;brightness;72${a}"
  dim="${dim}${e}]6;1;bg;blue;brightness;74${a}"
  [ "$bright" != "$dim" ]
  [ "$(cat "$PTY_LOG")" = "${bright}${dim}" ]
}

@test "watch: the timestamp survives being seen, so age still means age" {
  tab "$$" idle 0 /dev/ttys900 1700000042
  FAKE_FRONT=iTerm2 FAKE_FOCUS=/dev/ttys900 at watch --once
  [ "$(field "$$" 1)" = idle ]
  [ "$(field "$$" 4)" = 1700000042 ]
}

@test "watch: a tab whose process is gone is cleared and forgotten" {
  d=$(dead_pid)
  tab "$d" waiting 0 /dev/ttys900
  tab "$$" idle 0 /dev/ttys901
  FAKE_FRONT="" at watch --once
  [ "$status" -eq 0 ]
  [ ! -f "$TABS/$d" ]
  [ -f "$TABS/$$" ]
}

@test "watch: a state file that is not named for a pid is thrown away" {
  : > "$TABS/not-a-pid"
  tab "$$" idle 0 /dev/ttys900
  FAKE_FRONT="" at watch --once
  [ ! -f "$TABS/not-a-pid" ]
  [ -f "$TABS/$$" ]
}

@test "watch: --once is a single pass and takes no lock" {
  unlock
  tab "$$" waiting 0 /dev/ttys900
  FAKE_FRONT=iTerm2 FAKE_FOCUS=/dev/ttys901 at watch --once
  [ "$status" -eq 0 ]
  [ ! -d "$LOCK" ]
  [ "$(field "$$" 2)" = 0 ]
}

@test "watch: the loop exits as soon as nothing is unseen" {
  # Bounded rather than resident: it runs exactly while something is asking
  # for your attention. The one unseen tab is seen on the first pass, so the
  # loop must come straight back rather than sleeping.
  unlock
  tab "$$" waiting 0 /dev/ttys900
  FAKE_FRONT=iTerm2 FAKE_FOCUS=/dev/ttys900 at watch
  [ "$status" -eq 0 ]
  [ "$(field "$$" 2)" = 1 ]
  [ ! -d "$LOCK" ]
}

@test "watch: needs macOS; everything read-only does not" {
  FAKE_OS=Linux at watch --once
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs macOS"* ]]
  FAKE_OS=Linux at sweep
  [ "$status" -ne 0 ]
  FAKE_OS=Linux at list
  [ "$status" -eq 0 ]
}

# --- the watcher lock -------------------------------------------------------

@test "lock: a second watcher does not start while one is running" {
  unlock
  mkdir -p "$LOCK"
  printf '%s\n' "$$" > "$LOCK/pid"
  tab "$$" waiting 0 /dev/ttys900
  FAKE_FRONT=iTerm2 FAKE_FOCUS=/dev/ttys900 at watch
  [ "$status" -eq 0 ]
  # It did no pass at all, and left the running watcher's lock alone.
  [ "$(field "$$" 2)" = 0 ]
  [ "$(cat "$LOCK/pid")" = "$$" ]
}

@test "lock: a lock whose owner is dead is stolen, not deadlocked on" {
  unlock
  mkdir -p "$LOCK"
  printf '%s\n' "$(dead_pid)" > "$LOCK/pid"
  tab "$$" waiting 0 /dev/ttys900
  FAKE_FRONT=iTerm2 FAKE_FOCUS=/dev/ttys900 at watch
  [ "$status" -eq 0 ]
  [ "$(field "$$" 2)" = 1 ]
  # …and released again on the way out.
  [ ! -d "$LOCK" ]
}

@test "lock: a lock directory with no pid file in it is stolen too" {
  unlock
  mkdir -p "$LOCK"
  tab "$$" waiting 0 /dev/ttys900
  FAKE_FRONT=iTerm2 FAKE_FOCUS=/dev/ttys900 at watch
  [ "$status" -eq 0 ]
  [ "$(field "$$" 2)" = 1 ]
}

# --- sweep ------------------------------------------------------------------

@test "sweep: a tab already seen in the state it is still in stays seen" {
  session "$HOME/.claude" one "$$" waiting 1700000000000 alpha "$WORK/repo-one"
  tab "$$" waiting 1 /dev/ttys900
  FAKE_PS_CHAIN="1:ttys900" at sweep
  [ "$status" -eq 0 ]
  [ "$(field "$$" 1)" = waiting ]
  [ "$(field "$$" 2)" = 1 ]
}

@test "sweep: a tab whose state has changed since you looked is new again" {
  session "$HOME/.claude" one "$$" idle 1700000000000 alpha "$WORK/repo-one"
  tab "$$" waiting 1 /dev/ttys900
  FAKE_PS_CHAIN="1:ttys900" at sweep
  [ "$(field "$$" 1)" = idle ]
  [ "$(field "$$" 2)" = 0 ]
}

@test "sweep: a session that is neither waiting nor idle is cleared, not coloured" {
  session "$HOME/.claude" one "$$" busy 1700000000000 alpha "$WORK/repo-one"
  tab "$$" waiting 0 /dev/ttys900
  FAKE_PS_CHAIN="1:ttys900" at sweep
  [ "$status" -eq 0 ]
  [ ! -f "$TABS/$$" ]
}

@test "sweep: a session whose tty cannot be found is skipped, not crashed on" {
  session "$HOME/.claude" one "$$" waiting 1700000000000 alpha "$WORK/repo-one"
  FAKE_PS_CHAIN="" at sweep
  [ "$status" -eq 0 ]
  [ -z "$(ls "$TABS")" ]
}

# --- the session registry ---------------------------------------------------

@test "mapped_dirs: the mapping, ~/.claude, ~ expansion, and dedupe" {
  mkdir -p "$HOME/.p-alpha/sessions" "$HOME/.p-beta/sessions" "$HOME/.p-gamma"
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.acct-a "$HOME/.p-alpha"
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.acct-b '~/.p-beta'
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.acct-c "$HOME/.p-gamma"
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.acct-d "$HOME/.claude"
  at status
  [ "$status" -eq 0 ]
  line=$(printf '%s\n' "$output" | sed -n 's/^profiles:  //p')
  # ~/.claude is both the default and one of the mapped values: named once.
  [ "$(printf '%s\n' $line | grep -cx "$HOME/.claude")" -eq 1 ]
  [ "$(printf '%s\n' $line | grep -cx "$HOME/.p-alpha")" -eq 1 ]
  # A leading ~/ is expanded, not passed through to a directory test as text.
  [ "$(printf '%s\n' $line | grep -cx "$HOME/.p-beta")" -eq 1 ]
  # A profile that has never run a session still has to be listed, and still
  # has to have its wiring reported: it is exactly the one you run `status`
  # to check after adding it, and hiding it would make a missing hook block
  # indistinguishable from a correct one.
  [ "$(printf '%s\n' $line | grep -cx "$HOME/.p-gamma")" -eq 1 ]
  [[ "$output" == *"hooks:     .p-gamma"* ]]
}

@test "registry reads only the profiles that have a sessions/ dir" {
  mkdir -p "$HOME/.p-gamma"
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.acct-c "$HOME/.p-gamma"
  session "$HOME/.claude" live "$$" waiting 1700000000000 alpha "$WORK/repo-one"
  at list
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"* ]]
  [[ "$output" != *"p-gamma"* ]]
}

@test "registry: a session file that outlived its process is not a session" {
  session "$HOME/.claude" live "$$" waiting 1700000000000 alpha "$WORK/repo-one"
  session "$HOME/.claude" stale "$(dead_pid)" waiting 1700000000000 ghost "$WORK/repo-two"
  at list
  [ "$status" -eq 0 ]
  [[ "$output" == *alpha* ]]
  [[ "$output" != *ghost* ]]
}

@test "registry: every mapped profile is read, not just the one we run in" {
  mkdir -p "$HOME/.p-alpha/sessions"
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.acct-a "$HOME/.p-alpha"
  session "$HOME/.claude" one "$$" idle 1700000000000 first "$WORK/repo-one"
  session "$HOME/.p-alpha" two "$$" idle 1700000000000 second "$WORK/repo-two"
  at list
  [[ "$output" == *first* ]]
  [[ "$output" == *second* ]]
}

# --- list -------------------------------------------------------------------

@test "list: most neglected first — waiting, idle, shell, then everything else" {
  now=$(date +%s)
  session "$HOME/.claude" e "$$" busy    "$(( (now - 10) * 1000 ))" busy-one  "$WORK/r5"
  session "$HOME/.claude" d "$$" shell   "$(( (now - 20) * 1000 ))" shell-one "$WORK/r4"
  session "$HOME/.claude" c "$$" idle    "$(( (now - 30) * 1000 ))" idle-one  "$WORK/r3"
  session "$HOME/.claude" b "$$" waiting "$(( (now - 40) * 1000 ))" wait-new  "$WORK/r2"
  session "$HOME/.claude" a "$$" waiting "$(( (now - 900) * 1000 ))" wait-old "$WORK/r1"
  at list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 5 ]
  # Within a band, oldest first: the one waiting longest is the most forgotten.
  [[ "${lines[0]}" == *wait-old* ]]
  [[ "${lines[1]}" == *wait-new* ]]
  [[ "${lines[2]}" == *idle-one* ]]
  [[ "${lines[3]}" == *shell-one* ]]
  [[ "${lines[4]}" == *busy-one* ]]
}

@test "list: the age column reads in the unit that fits" {
  now=$(date +%s)
  session "$HOME/.claude" a "$$" waiting "$(( (now - 7200) * 1000 ))" old-one "$WORK/r1"
  session "$HOME/.claude" b "$$" idle    "$(( (now - 300) * 1000 ))"  mid-one "$WORK/r2"
  session "$HOME/.claude" c "$$" shell   "$(( (now - 5) * 1000 ))"    new-one "$WORK/r3"
  at list
  [[ "${lines[0]}" == *"2h"*old-one* ]]
  [[ "${lines[1]}" == *"5m"*mid-one* ]]
  # Seconds keep counting between the stamp above and the listing, so a
  # slow runner prints 6s or 12s here — assert the unit, not the number.
  [[ "${lines[2]}" == *[0-9]"s "*new-one* ]]
}

@test "list: the mark says painted-and-unread, painted-and-seen, or unpainted" {
  session "$HOME/.claude" a "$$" waiting 1700000000000 alpha "$WORK/repo-one"
  at list
  [[ "${lines[0]}" == " waiting"* ]]
  tab "$$" waiting 0 /dev/ttys900
  at list
  [[ "${lines[0]}" == "*waiting"* ]]
  tab "$$" waiting 1 /dev/ttys900
  at list
  [[ "${lines[0]}" == ".waiting"* ]]
}

@test "list: no live sessions says so instead of printing an empty table" {
  at list
  [ "$status" -eq 0 ]
  [[ "$output" == *"no live Claude Code sessions"* ]]
}

# --- clear ------------------------------------------------------------------

@test "clear: every recorded tab is forgotten" {
  tab "$$" waiting 0 /dev/ttys900
  tab 7001 idle 1 /dev/ttys901
  FAKE_PS_CHAIN="" at clear
  [ "$status" -eq 0 ]
  [ -z "$(ls "$TABS")" ]
}

# --- status and dispatch ----------------------------------------------------

@test "status: reports the state dir, the interval, and each painted tab" {
  git config --file "$GIT_CONFIG_GLOBAL" attend.interval 7
  # Both pids must be live: status reaps state for dead ones before printing.
  tab "$$" waiting 0 /dev/ttys900
  tab "$PPID" idle 1 /dev/ttys901
  at status
  [ "$status" -eq 0 ]
  [[ "$output" == *"state:     $STATE"* ]]
  [[ "$output" == *"interval:  7s"* ]]
  [[ "$output" == *"waiting"*"unseen"*"ttys900"* ]]
  [[ "$output" == *"idle"*"seen"*"ttys901"* ]]
}

# A session killed while its tab was already *seen* is never revisited by the
# watcher, which only runs while something is unseen. Left alone its state
# file outlives it, and a reused pid in the same state would make sweep treat
# a genuinely new alert as one already acknowledged.
@test "status and list reap state whose process is gone" {
  tab "$$" waiting 0 /dev/ttys900
  tab 7001 idle 1 /dev/ttys901
  at status
  [ "$status" -eq 0 ]
  [[ "$output" == *"ttys900"* ]]
  [[ "$output" != *"ttys901"* ]]
  [ -f "$STATE/tabs/$$" ]
  [ ! -e "$STATE/tabs/7001" ]
}

@test "status: a nonsense interval falls back rather than being used" {
  git config --file "$GIT_CONFIG_GLOBAL" attend.interval nonsense
  at status
  [[ "$output" == *"interval:  2s"* ]]
  git config --file "$GIT_CONFIG_GLOBAL" attend.interval 0
  at status
  [[ "$output" == *"interval:  2s"* ]]
}

@test "status: says whether each profile calls the hook" {
  printf '{ "hooks": { "Stop": [{ "hooks": [{ "command": "~/bin/attend hook idle" }] }] } }\n' \
    > "$HOME/.claude/settings.json"
  at status
  [[ "$output" == *"hooks:"*".claude wired"* ]]
  printf '{ "hooks": {} }\n' > "$HOME/.claude/settings.json"
  at status
  [[ "$output" == *"NOT wired"* ]]
}

@test "install prints the wiring and edits nothing" {
  at install
  [ "$status" -eq 0 ]
  [[ "$output" == *'"Notification"'* ]]
  [[ "$output" == *"attend hook waiting"* ]]
  [ ! -f "$HOME/.claude/settings.json" ]
}

@test "dir prints the state directory" {
  at dir
  [ "$status" -eq 0 ]
  [ "$output" = "$STATE" ]
}

@test "an unknown command and --help both explain themselves" {
  at --help
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"attend watch"* ]]
  at bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command 'bogus'"* ]]
  # No subcommand at all is the list, not an error.
  at
  [ "$status" -eq 0 ]
}
