#!/usr/bin/env bats

# pane-sight names another iTerm2 pane and decides, before anything is read,
# whether this profile may see it. These tests drive the real script under a
# sandboxed HOME against the REAL denyguard and the REAL dot_functions, copied to
# the fixed places the script reads them from (it has no seam to point elsewhere),
# with stub ps, uname, defaults, claude-peer, tabname and it2. Sessions are
# registry fixtures backed by live `sleep` processes; the ps stub answers from a
# table file. Nothing here talks to iTerm2. Every owner, repository and profile
# name is a fixture (see CLAUDE.md).

bats_require_minimum_version 1.5.0

setup() {
  REAL_PYTHON3=''
  REAL_PYTHON3="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)" || REAL_PYTHON3=''
  [ -n "$REAL_PYTHON3" ] || skip "python3 not installed"
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  mkdir -p "$BATS_TEST_TMPDIR/home"
  export HOME
  HOME="$(cd "$BATS_TEST_TMPDIR/home" && pwd -P)"
  export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  # the script unsets GIT_CONFIG_GLOBAL, so git reads $HOME/.gitconfig and the XDG
  # config of the sandbox; none of these may point at the developer's own
  unset XDG_STATE_HOME XDG_CONFIG_HOME GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS PANE_SIGHT_PYTHON
  gc() { git config --file "$GIT_CONFIG_GLOBAL" "$@"; }
  gc init.defaultBranch main
  gc credential.https://github.com/octo-personal.username personal-account
  gc credential.https://github.com/octo-work-org.username work-account
  gc claude.profile.personal-account '~/.claude-personal'
  gc claude.profile.work-account '~/.claude-work'
  PERSONAL="$HOME/.claude-personal"
  WORK="$HOME/.claude-work"
  mkdir -p "$PERSONAL/sessions" "$WORK/sessions" "$HOME/bin" "$HOME/code"
  # this session is the personal profile's; a CLAUDE_PROFILE left in the
  # environment must not leak into the route question
  export CLAUDE_CONFIG_DIR="$PERSONAL" CLAUDE_PROFILE=work-account

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  # FAKE_TTYP_FAIL makes the python inside tty_procs (the one given PS_NAMES) fail
  printf '#!/bin/sh\n[ -z "${FAKE_TTYP_FAIL-}" ] || [ -z "${PS_NAMES-}" ] || exit 1\nexec "%s" "$@"\n' "$REAL_PYTHON3" > "$BIN/python3"
  ln -sf "$(command -v git)" "$BIN/git"
  cp "$BATS_TEST_DIRNAME/../bin/executable_pane-sight" "$BIN/pane-sight"
  ln -s pane-sight "$BIN/pane-read"
  ln -s pane-sight "$BIN/pane-shot"
  export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export FAKE_OS=Darwin
  cat > "$BIN/uname" <<'STUB'
#!/bin/sh
printf '%s\n' "${FAKE_OS:-Darwin}"
STUB
  cat > "$BIN/defaults" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "${DEFAULTS_LOG:-/dev/null}"
printf '%s\n' "${FAKE_API:-1}"
STUB
  # ps: from the table file, "pid TAB tty TAB ucomm TAB command TAB ppid" per line;
  # every call is logged. A pid the table does not hold has $FAKE_PARENT for a
  # parent (that is the script's own pid). The terminal listings can be made to
  # fail (FAKE_PS_T_FAIL), to print nothing (FAKE_PS_T_EMPTY) or to leave one pid
  # out (FAKE_PS_HIDE).
  export PS_TABLE="$BATS_TEST_TMPDIR/ps-table" PS_LOG="$BATS_TEST_TMPDIR/ps-log"
  : > "$PS_TABLE"; : > "$PS_LOG"
  cat > "$BIN/ps" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$PS_LOG"
for last; do :; done
case "$*" in
  *" -t "*) [ -z "${FAKE_PS_T_FAIL-}" ] || exit 1; [ -z "${FAKE_PS_T_EMPTY-}" ] || exit 0 ;;
esac
case "$*" in
  *"-o tty= -p "*) awk -F'\t' -v p="$last" '$1 == p { print $2; exit }' "$PS_TABLE" ;;
  *"-o ppid= -p "*) awk -F'\t' -v p="$last" -v d="${FAKE_PARENT-}" '$1 == p { print $5; f = 1; exit } END { if (!f) print d }' "$PS_TABLE" ;;
  *"-o ucomm= -p "*) awk -F'\t' -v p="$last" '$1 == p { print $3; exit }' "$PS_TABLE" ;;
  *"-o pid=,ucomm= -t "*) awk -F'\t' -v t="$last" -v h="${FAKE_PS_HIDE-}" '$2 == t && $1 != h { printf "%5s %s\n", $1, $3 }' "$PS_TABLE" ;;
  *"-Eww -o pid=,command= -t "*) awk -F'\t' -v t="$last" -v h="${FAKE_PS_HIDE-}" '$2 == t && $1 != h { printf "%5s %s\n", $1, $4 }' "$PS_TABLE" ;;
  *"-Eww -o command= -p "*) awk -F'\t' -v p="$last" '$1 == p { print $4; exit }' "$PS_TABLE" ;;
esac
exit 0
STUB
  # claude-peer: `panes` prints the fixture rows
  export PANES_FILE="$BATS_TEST_TMPDIR/panes" PEER_LOG="$BATS_TEST_TMPDIR/peer-log"
  : > "$PANES_FILE"; : > "$PEER_LOG"
  cat > "$HOME/bin/claude-peer" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$PEER_LOG"
[ "$1" = panes ] && cat "$PANES_FILE"
exit 0
STUB
  # tabname: the directory's base name; --role puts a role in front
  cat > "$HOME/bin/tabname" <<'STUB'
#!/bin/sh
if [ "$1" = --role ]; then shift; printf 'peer\t%s\n' "$(basename "$1")"; exit 0; fi
basename "$1"
STUB
  chmod +x "$BIN/uname" "$BIN/defaults" "$BIN/ps" "$BIN/python3" "$HOME/bin/claude-peer" "$HOME/bin/tabname"
  # it2, at the one place the script looks: logs its arguments, the suite and the
  # cookie it was given; any verb but `session read` and `session get-var tty|path`
  # is exit 97 and is recorded
  export IT2_LOG="$BATS_TEST_TMPDIR/it2-log" IT2_BAD="$BATS_TEST_TMPDIR/it2-bad" DEFAULTS_LOG="$BATS_TEST_TMPDIR/defaults-log"
  export FAKE_SCREEN="$BATS_TEST_TMPDIR/screen"
  : > "$IT2_LOG"; : > "$IT2_BAD"; : > "$FAKE_SCREEN"
  export FAKE_TTY='"\/dev\/ttys010"' FAKE_PATH="Variable 'path' not set"
  mkdir -p "$HOME/.config/iterm2"
  IT2="$HOME/.config/iterm2/it2"
  cat > "$IT2" <<'STUB'
#!/bin/sh
printf '%s\tsuite=%s\tcookie=%s\n' "$*" "${IT2_SUITE-}" "${ITERM2_COOKIE-}" >> "$IT2_LOG"
[ -z "${FAKE_IT2_SLEEP-}" ] || sleep "$FAKE_IT2_SLEEP"
case "$1 $2 $3" in
  "session read --session") cat "$FAKE_SCREEN" ;;
  "session get-var tty") printf '%s\n' "$FAKE_TTY" ;;
  "session get-var path") printf '%s\n' "$FAKE_PATH" ;;
  *) printf '%s\n' "$*" >> "$IT2_BAD"; exit 97 ;;
esac
STUB
  chmod +x "$IT2"
  # the runtime: a fake iterm2 package, so no real iTerm2 is ever asked. A shot
  # may only come from rpc.async_screenshot; screencapture and osascript are
  # stubs that record that they ran.
  export RT_LOG="$BATS_TEST_TMPDIR/rt-log" FORBIDDEN_LOG="$BATS_TEST_TMPDIR/forbidden-log" FAKE_PNG="$BATS_TEST_TMPDIR/fake.png"
  : > "$RT_LOG"; : > "$FORBIDDEN_LOG"
  export FAKE_SHOT_STATUS=0
  "$REAL_PYTHON3" -c 'import sys; sys.stdout.buffer.write(b"\x89PNG\r\n\x1a\n" + (13).to_bytes(4, "big") + b"IHDR" + (640).to_bytes(4, "big") + (480).to_bytes(4, "big") + b"\x08\x06\x00\x00\x00" + b"pixels")' > "$FAKE_PNG"
  mkdir -p "$BATS_TEST_TMPDIR/rtpy/iterm2"
  cat > "$BATS_TEST_TMPDIR/rtpy/iterm2/__init__.py" <<'PY'
import asyncio
def run_until_complete(main): asyncio.run(main(object()))
PY
  cat > "$BATS_TEST_TMPDIR/rtpy/iterm2/rpc.py" <<'PY'
import asyncio, os, types
async def async_screenshot(connection, session):
    open(os.environ["RT_LOG"], "a").write("%s\tsuite=%s\n" % (session, os.environ.get("IT2_SUITE", "")))
    if os.environ.get("FAKE_RT_SLEEP"): await asyncio.sleep(float(os.environ["FAKE_RT_SLEEP"]))
    png = open(os.environ["FAKE_PNG"], "rb").read() if int(os.environ["FAKE_SHOT_STATUS"]) == 0 else b""
    return types.SimpleNamespace(screenshot_response=types.SimpleNamespace(status=int(os.environ["FAKE_SHOT_STATUS"]), png=png))
PY
  printf '#!/bin/sh\nPYTHONPATH="%s" exec "%s" "$@"\n' "$BATS_TEST_TMPDIR/rtpy" "$REAL_PYTHON3" > "$BIN/fakepy"
  for f in screencapture osascript; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "${0##*/}" "$*" >> "$FORBIDDEN_LOG"\n' > "$BIN/$f"
    chmod +x "$BIN/$f"
  done
  chmod +x "$BIN/fakepy"
  export PANE_SIGHT_PYTHON="$BIN/fakepy" TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  # the judges, at the fixed places under the sandboxed HOME
  cp "$BATS_TEST_DIRNAME/../bin/executable_denyguard" "$HOME/bin/denyguard"
  cp "$BATS_TEST_DIRNAME/../dot_functions" "$HOME/.functions"
  chmod +x "$HOME/bin/denyguard"

  MAIN="$(mk_repo octo-personal-main octo-personal/main)"
  cd "$MAIN"
}

teardown() {
  if [ -f "$BATS_TEST_TMPDIR/sleepers" ]; then
    while read -r p; do kill "$p" 2>/dev/null; done < "$BATS_TEST_TMPDIR/sleepers"
  fi
  # nothing but `session read` and `session get-var` ever reached it2, and no
  # second way to make an image was ever used
  [ ! -s "$IT2_BAD" ]
  [ ! -s "$FORBIDDEN_LOG" ]
}

# mk_repo <name> [<owner/repo>]: a repository under $HOME/code; its path.
mk_repo() {
  local r="$HOME/code/$1"
  mkdir -p "$r"
  git init -q "$r"
  [ -z "${2-}" ] || git -C "$r" remote add origin "git@github.com:$2.git"
  printf '%s\n' "$r"
}

# mk_session <profile dir> <name> <cwd> <tty> [<session uuid> [<suite> [<config dir in its environment>]]]:
# a live registry session on a terminal; its pid is left in SPID.
mk_session() {
  sleep 600 3>&- >/dev/null 2>&1 &
  SPID=$!
  echo "$SPID" >> "$BATS_TEST_TMPDIR/sleepers"
  mkdir -p "$1/sessions"
  printf '{"pid": %s, "cwd": "%s", "name": "%s"}\n' "$SPID" "$3" "$2" > "$1/sessions/$SPID.json"
  local env=''
  [ -z "${5-}" ] || env="ITERM_SESSION_ID=w0t0p0:$5"
  [ -z "${6-}" ] || env="$env IT2_SUITE=$6"
  [ -z "${7-}" ] || env="$env CLAUDE_CONFIG_DIR=$7"
  printf '%s\t%s\tclaude\tclaude --resume %s\n' "$SPID" "$4" "$env" >> "$PS_TABLE"
}

# end_session <profile dir> <pid>: the session ends, its process leaves the terminal.
end_session() {
  kill "$2"; rm "$1/sessions/$2.json"
  grep -v "^$2"$'\t' "$PS_TABLE" > "$PS_TABLE.new" || true
  mv "$PS_TABLE.new" "$PS_TABLE"
}

# ps_row <pid> <tty> [<ucomm> [<command with its environment> [<ppid>]]]: a process
# with a terminal; by default a shell with nothing to show in its environment.
ps_row() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-sh}" "${4:-sh}" "${5-}" >> "$PS_TABLE"; }

# set_ppid <pid> <ppid>: the parent ps answers for a process already in the table.
set_ppid() {
  awk -F'\t' -v OFS='\t' -v p="$1" -v pp="$2" '$1 == p { $5 = pp } { print }' "$PS_TABLE" > "$PS_TABLE.new"
  mv "$PS_TABLE.new" "$PS_TABLE"
}

# pane_row <slot> <running|waiting> <pid> <leader> <worktree> <session id> <suite>
pane_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$PANES_FILE"; }

# val <key>: a value of the last `why` output
val() { printf '%s\n' "$output" | awk -F'\t' -v k="$1" '$1 == k { print $2 }'; }

U1=11111111-1111-1111-1111-111111111111
U2=22222222-2222-2222-2222-222222222222
U3=33333333-3333-3333-3333-333333333333
U4=44444444-4444-4444-4444-444444444444
U5=55555555-5555-5555-5555-555555555555

@test "why: a running peer by its slot, through panes, is readable" {
  wt="$MAIN/.claude/worktrees/alpha"; mkdir -p "$wt"
  mk_session "$PERSONAL" scribe "$wt" ttys010
  ps_row 90001 ttys010
  pane_row alpha running 90001 "$MAIN" "$wt" "$U1" -
  run pane-sight why alpha
  [ "$status" -eq 0 ]
  [ "$(val name)" = alpha ]
  [ "$(val kind)" = peer-running ]
  [ "$(val label)" = alpha ]
  [ "$(val pid)" = 90001 ]
  [ "$(val tty)" = /dev/ttys010 ]
  [ "$(val session)" = "$U1" ]
  [ "$(val suite)" = - ]
  [ "$(val dir)" = "$wt" ]
  [ "$(val verdict)" = readable ]
}

@test "why: a waiting pane uses its recorded id and its leader's directory" {
  ps_row 90002 ttys011
  pane_row beta waiting 90002 "$MAIN" "$MAIN/.claude/worktrees/beta" "$U2" bench
  run pane-sight why beta
  [ "$status" -eq 0 ]
  [ "$(val kind)" = peer-waiting ]
  [ "$(val label)" = Beta ]
  [ "$(val session)" = "$U2" ]
  [ "$(val suite)" = bench ]
  [ "$(val dir)" = "$MAIN" ]
  [ "$(val verdict)" = readable ]
}

@test "why: a waiting pane with no recorded id is exit 4 and says to reopen its tab" {
  ps_row 90002 ttys011
  pane_row beta waiting 90002 "$MAIN" "$MAIN/.claude/worktrees/beta" - -
  run pane-sight why beta
  [ "$status" -eq 4 ]
  [[ "$output" == *"Beta's pane has no recorded iTerm2 session"* ]]
  [[ "$output" == *"reopen its tab"* ]]
}

@test "why: a running peer with no recorded id is found through the registry and its process environment" {
  wt="$MAIN/.claude/worktrees/alpha"; mkdir -p "$wt"
  mk_session "$PERSONAL" scribe "$wt" ttys012 "$U4" bench
  ps_row 90003 ttys012
  pane_row alpha running 90003 "$MAIN" "$wt" - -
  run pane-sight why alpha
  [ "$status" -eq 0 ]
  [ "$(val session)" = "$U4" ]
  [ "$(val suite)" = bench ]
  [ "$(val verdict)" = readable ]
}

@test "why: a session by name, by tabname label and by pid" {
  mk_session "$PERSONAL" scribe "$MAIN" ttys013 "$U3"
  for n in scribe octo-personal-main "$SPID"; do
    run pane-sight why "$n"
    [ "$status" -eq 0 ]
    [ "$(val kind)" = session ]
    [ "$(val label)" = octo-personal-main ]
    [ "$(val pid)" = "$SPID" ]
    [ "$(val session)" = "$U3" ]
    [ "$(val dir)" = "$MAIN" ]
    [ "$(val verdict)" = readable ]
  done
}

@test "why: two sessions with one name is exit 4 and names both pids" {
  mk_session "$PERSONAL" twin "$MAIN" ttys014 "$U1"; a=$SPID
  mk_session "$PERSONAL" twin "$MAIN" ttys015 "$U2"; b=$SPID
  run pane-sight why twin
  [ "$status" -eq 4 ]
  [[ "$output" == *"more than one session"* ]]
  [[ "$output" == *"$a"* && "$output" == *"$b"* ]]
}

@test "refused: a pane whose terminal carries another profile's session, even in a directory this profile may open" {
  mk_session "$WORK" ledger "$MAIN" ttys016 "$U1"
  run pane-sight why ledger
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: other-profile" ]
  [[ "$output" == *"pane-sight: refused: octo-personal-main: its pane runs a Claude session of the work profile; this session is personal"* ]]
}

@test "refused: a directory inside this profile's deny rule" {
  secret="$(mk_repo octo-secret octo-personal/secret)"
  printf '{"permissions": {"deny": ["Read(~/code/octo-secret/**)"]}}\n' > "$PERSONAL/settings.json"
  mk_session "$PERSONAL" vault "$secret" ttys017 "$U1"
  run pane-sight why vault
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: denied" ]
  [[ "$output" == *"its directory is inside a deny rule of this profile"* ]]
  # a plain shell in the same directory is refused the same way
  ps_row 90005 ttys018
  pane_row gamma waiting 90005 "$secret" "$secret/.claude/worktrees/gamma" "$U2" -
  run pane-sight why gamma
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: denied" ]
}

@test "refused: denyguard missing, and a settings.json that does not parse" {
  mk_session "$PERSONAL" scribe "$MAIN" ttys019 "$U1"
  mv "$HOME/bin/denyguard" "$BATS_TEST_TMPDIR/denyguard.away"
  run pane-sight why scribe
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: deny-unknown" ]
  [[ "$output" == *"denyguard could not say whether its directory is allowed"* ]]
  mv "$BATS_TEST_TMPDIR/denyguard.away" "$HOME/bin/denyguard"
  printf '{not json\n' > "$PERSONAL/settings.json"
  run pane-sight why scribe
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: deny-unknown" ]
  printf '{"permissions": {"deny": ["Read(/rel/**)"]}}\n' > "$PERSONAL/settings.json"
  run pane-sight why scribe
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: deny-unknown" ]
}

@test "refused: a waiting pane whose leader is a repository pinned to another profile; readable when it routes here" {
  pinned="$(mk_repo octo-personal-pinned octo-personal/pinned)"
  git config --file "$GIT_CONFIG_GLOBAL" claude.octo-personal/pinned.profile work-account
  ps_row 90006 ttys020; ps_row 90007 ttys021
  pane_row alpha waiting 90006 "$pinned" "$pinned/.claude/worktrees/alpha" "$U1" -
  pane_row beta waiting 90007 "$MAIN" "$MAIN/.claude/worktrees/beta" "$U2" -
  run pane-sight why alpha
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: other-route" ]
  [[ "$output" == *"no Claude session runs there and its directory routes to the work profile; this session is personal"* ]]
  run pane-sight why beta
  [ "$status" -eq 0 ]
  [ "$(val verdict)" = readable ]
}

@test "refused: the resolver cannot be asked" {
  ps_row 90008 ttys022
  pane_row alpha waiting 90008 "$MAIN" "$MAIN/.claude/worktrees/alpha" "$U1" -
  mv "$HOME/.functions" "$BATS_TEST_TMPDIR/functions.away"
  run pane-sight why alpha
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: route-unknown" ]
  [[ "$output" == *"could not ask which profile its directory routes to"* ]]
  mv "$BATS_TEST_TMPDIR/functions.away" "$HOME/.functions"
  # a zsh that does not run, first on PATH
  printf '#!/bin/sh\nexit 127\n' > "$BIN/zsh"; chmod +x "$BIN/zsh"
  run pane-sight why alpha
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: route-unknown" ]
}

@test "a session of this profile in a directory that routes elsewhere is readable" {
  other="$(mk_repo octo-work-thing octo-work-org/thing)"
  mk_session "$PERSONAL" scribe "$other" ttys023 "$U1"
  run pane-sight why scribe
  [ "$status" -eq 0 ]
  [ "$(val verdict)" = readable ]
  # with no session there, the same directory is refused
  ps_row 90009 ttys024
  pane_row alpha waiting 90009 "$other" "$other/.claude/worktrees/alpha" "$U2" -
  run pane-sight why alpha
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: other-route" ]
}

@test "a pane whose process has no terminal is exit 4 and never a candidate" {
  ps_row 90010 '??'
  pane_row alpha waiting 90010 "$MAIN" "$MAIN/.claude/worktrees/alpha" "$U1" -
  run pane-sight why alpha
  [ "$status" -eq 4 ]
  [[ "$output" == *"alpha (pid 90010) has no terminal"* ]]
  # the orphan beside a live pane of the same slot is skipped, not ambiguous
  ps_row 90011 ttys025
  pane_row alpha waiting 90011 "$MAIN" "$MAIN/.claude/worktrees/alpha" "$U2" -
  run pane-sight why alpha
  [ "$status" -eq 0 ]
  [ "$(val pid)" = 90011 ]
  # a session whose process has none
  mk_session "$PERSONAL" ghost "$MAIN" '??' "$U3"
  run pane-sight why ghost
  [ "$status" -eq 4 ]
  [[ "$output" == *"has no terminal"* ]]
}

@test "two waiting panes of one slot: the caller's own leader wins; with none of them the caller's, exit 4" {
  here="$MAIN"
  elsewhere="$(mk_repo octo-personal-other octo-personal/other)"
  third="$(mk_repo octo-personal-third octo-personal/third)"
  ps_row 90012 ttys026; ps_row 90013 ttys027
  pane_row delta waiting 90012 "$elsewhere" "$elsewhere/.claude/worktrees/delta" "$U1" -
  pane_row delta waiting 90013 "$here" "$here/.claude/worktrees/delta" "$U2" -
  run pane-sight why delta
  [ "$status" -eq 0 ]
  [ "$(val pid)" = 90013 ]
  [ "$(val session)" = "$U2" ]
  cd "$third"
  run pane-sight why delta
  [ "$status" -eq 4 ]
  [[ "$output" == *"more than one waiting pane"* ]]
  [[ "$output" == *"90012"* && "$output" == *"90013"* ]]
}

@test "list: every pane with its verdict, a refused one named with its profile" {
  pinned="$(mk_repo octo-personal-pinned octo-personal/pinned)"
  git config --file "$GIT_CONFIG_GLOBAL" claude.octo-personal/pinned.profile work-account
  wt="$MAIN/.claude/worktrees/alpha"; mkdir -p "$wt"
  mk_session "$PERSONAL" scribe "$wt" ttys030 "$U1"; scribe=$SPID
  ps_row 90020 ttys030
  pane_row alpha running 90020 "$MAIN" "$wt" "$U1" -
  ps_row 90021 ttys031
  pane_row beta waiting 90021 "$pinned" "$pinned/.claude/worktrees/beta" "$U2" -
  mk_session "$WORK" ledger "$MAIN" ttys032 "$U3"; ledger=$SPID
  mk_session "$PERSONAL" ghost "$MAIN" ttys033; ghost=$SPID
  run pane-sight list
  [ "$status" -eq 0 ]
  [[ "$output" == *$'alpha\tpeer-running\t90020\tpersonal\treadable'* ]]
  [[ "$output" == *$'beta\tpeer-waiting\t90021\t-\trefused: other-route'* ]]
  [[ "$output" == *"ledger"$'\t'"session"$'\t'"$ledger"$'\t'"work"$'\t'"refused: other-profile"* ]]
  [[ "$output" == *"ghost"$'\t'"session"$'\t'"$ghost"$'\t'"personal"$'\t'"unaddressable"* ]]
  # the session a running peer already shows is not listed twice
  [[ "$output" != *"scribe"* ]]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 4 ]
}

@test "status --line: ready, and each not-ready reason" {
  printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/py"; chmod +x "$BATS_TEST_TMPDIR/py"
  export PANE_SIGHT_PYTHON="$BATS_TEST_TMPDIR/py"
  run pane-sight status --line
  [ "$status" -eq 0 ]
  [ "$output" = "ready (0 reads, 0 shots, 0 refused)" ]
  mkdir -p "$HOME/.local/state/pane-sight"
  printf '%s\n' \
    "t	read	ok	peer-running	Alpha	-	lines=3 masked=0" \
    "t	shot	ok	peer-running	Alpha	-	bytes=9 file=/x" \
    "t	read	refused:denied	session	Vault	-	" \
    "t	shot	failed:drawn	session	Vault	-	" > "$HOME/.local/state/pane-sight/audit.log"
  run pane-sight status --line
  [ "$output" = "ready (1 reads, 1 shots, 1 refused)" ]
  run pane-sight status
  [ "$status" -eq 0 ]
  [[ "$output" == *"it2:       $HOME/.config/iterm2/it2"* ]]
  [[ "$output" == *"api:       on"* ]]
  [[ "$output" == *"audit:     1 reads, 1 shots, 1 refused, 1 failed"* ]]
  mv "$IT2" "$BATS_TEST_TMPDIR/it2.away"
  run pane-sight status --line
  [ "$output" = "not ready: it2 is missing" ]
  mv "$BATS_TEST_TMPDIR/it2.away" "$IT2"
  PANE_SIGHT_PYTHON="$BATS_TEST_TMPDIR/none" run pane-sight status --line
  [ "$output" = "not ready: no Python runtime with the iterm2 library" ]
  FAKE_API=0 run pane-sight status --line
  [ "$output" = "not ready: iTerm2's API is off" ]
  mv "$HOME/bin/denyguard" "$BATS_TEST_TMPDIR/denyguard.away"
  run pane-sight status --line
  [ "$output" = "not ready: denyguard is missing" ]
  mv "$BATS_TEST_TMPDIR/denyguard.away" "$HOME/bin/denyguard"
  mv "$HOME/.functions" "$BATS_TEST_TMPDIR/functions.away"
  run pane-sight status --line
  [ "$output" = "not ready: the profile resolver is missing" ]
  # the runtime is found under iTerm2's own support directory
  unset PANE_SIGHT_PYTHON
  support="$HOME/Library/Application Support"
  mkdir -p "$support/iTerm2/iterm2env/versions/3.10/bin"
  cp "$BATS_TEST_TMPDIR/py" "$support/iTerm2/iterm2env/versions/3.10/bin/python3"
  run pane-sight status
  [[ "$output" == *"runtime:   $support/iTerm2/iterm2env/versions/3.10/bin/python3"* ]]
}

@test "a public-only machine (no pins, no settings.json) reads its own default profile's panes" {
  unset CLAUDE_CONFIG_DIR CLAUDE_PROFILE
  : > "$GIT_CONFIG_GLOBAL"
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  mkdir -p "$HOME/.claude/sessions"
  bare="$(mk_repo scratch-repo)"
  cd "$bare"
  mk_session "$HOME/.claude" scribe "$bare" ttys040 "$U1"
  ps_row 90030 ttys041
  pane_row alpha waiting 90030 "$bare" "$bare/.claude/worktrees/alpha" "$U2" -
  run pane-sight why scribe
  [ "$status" -eq 0 ]
  [ "$(val verdict)" = readable ]
  run pane-sight why alpha
  [ "$status" -eq 0 ]
  [ "$(val verdict)" = readable ]
}

@test "usage, and not macOS: exit 2" {
  run pane-sight
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
  run pane-sight nonsense
  [ "$status" -eq 2 ]
  run pane-sight why
  [ "$status" -eq 2 ]
  run pane-sight shot
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
  FAKE_OS=Linux run pane-sight status
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs macOS"* ]]
}

@test "pane-read and pane-shot are the same script" {
  run pane-read alpha
  [ "$status" -eq 4 ]
  [[ "$output" == *"no pane named alpha"* ]]
  run pane-shot alpha
  [ "$status" -eq 4 ]
  [[ "$output" == *"no pane named alpha"* ]]
  [ "$(readlink "$BIN/pane-read")" = pane-sight ]
}

# --- read ----------------------------------------------------------------------------

# peer_alpha: a running peer on ttys010, the terminal FAKE_TTY names.
peer_alpha() {
  wt="$MAIN/.claude/worktrees/alpha"; mkdir -p "$wt"
  ps_row 90001 ttys010
  pane_row alpha running 90001 "$MAIN" "$wt" "$U1" -
}

# lines <from> <to>: "line<n>" per row
lines() { seq "$1" "$2" | sed 's/^/line/'; }

# rd <args>: read with the summary line dropped
rd() { pane-sight read "$@" 2>/dev/null; }

# audit_rows: the audit log
audit_rows() { cat "$HOME/.local/state/pane-sight/audit.log"; }

@test "read prints the last 60 lines by default and --lines n of them; 0 and 501 are usage" {
  peer_alpha
  lines 1 100 > "$FAKE_SCREEN"
  run --separate-stderr pane-sight read alpha
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 60 ]
  [ "${lines[0]}" = line41 ]
  [ "${lines[59]}" = line100 ]
  [[ "$stderr" == *"pane-sight: alpha (peer-running): 60 of 100 lines, 0 masked"* ]]
  run rd alpha --lines 5
  [ "$output" = "$(lines 96 100)" ]
  run rd --lines 2 alpha
  [ "$output" = "$(lines 99 100)" ]
  for bad in 0 501 abc -3 ''; do
    run pane-sight read alpha --lines "$bad"
    [ "$status" -eq 2 ]
  done
  run rd alpha --lines
  [ "$status" -eq 2 ]
  run pane-sight read
  [ "$status" -eq 2 ]
}

@test "the blank rows under the last line of the screen are not counted" {
  peer_alpha
  printf 'one   \ntwo \t\n\n\n   \n' > "$FAKE_SCREEN"
  run --separate-stderr pane-sight read alpha
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'one\ntwo')" ]
  [[ "$stderr" == *"2 of 2 lines"* ]]
  : > "$FAKE_SCREEN"
  run --separate-stderr pane-sight read alpha
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"0 of 0 lines"* ]]
  # it2 was asked to read the whole screen, never for a number of lines
  ! grep -q -- '--lines' "$IT2_LOG" || { echo "it2 was given --lines"; false; }
}

@test "each mask: one positive and one near miss" {
  peer_alpha
  # secret-shaped fixtures are built in pieces so this file never trips tests/no-secrets.bats
  gh1="gh""p_""abcdefghij0123456789abcd"
  gh2="github""_pat_""abcdefghij0123456789abcd"
  sk="sk-""abcdefghij0123456789abcd"
  sl="xox""b-""1234567890-abcdef"
  aws="AKI""A""ABCDEFGHIJKLMNOP"
  jwt="eyJ""hbGciOiJI.eyJzdWIiOiIx.c2lnbmF0dXJl1"
  {
    echo "a $gh1 b"
    echo "$gh2"
    echo "k $sk"
    echo "$sl"
    echo "id $aws ok"
    echo "t $jwt"
    echo "Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123"
    echo "export API_TOKEN=abcd1234efgh5678ijkl"
  } > "$FAKE_SCREEN"
  run --separate-stderr pane-sight read alpha
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' 'a [masked:github] b' '[masked:github]' 'k [masked:key]' '[masked:slack]' \
    'id [masked:aws] ok' 't [masked:jwt]' 'Authorization: Bearer [masked:bearer]' 'export API_TOKEN=[masked:value]')" ]
  [[ "$stderr" == *"8 of 8 lines, 8 masked"* ]]
  # near misses stay exactly as they were
  {
    echo "gh""p_short and github""_pat_short"
    echo "sk-short"
    echo "xox""b-12"
    echo "AKI""A1234 and AKI""A""ABCDEFGHIJKLMNOPQ"
    echo "eyJabc.def.ghi"
    echo "the bearer of bad news"
    echo "password: short"
    echo "the token is mentioned in a sentence"
    echo "secret=abcdefghijklmnopqrstuvwxyz"
    echo "token = 12345678901234567890"
    echo "-----BEGIN CERTIFICATE-----"
  } > "$BATS_TEST_TMPDIR/near"
  cp "$BATS_TEST_TMPDIR/near" "$FAKE_SCREEN"
  run --separate-stderr pane-sight read alpha
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$BATS_TEST_TMPDIR/near")" ]
  [[ "$stderr" == *"11 of 11 lines, 0 masked"* ]]
}

@test "a key block that runs off the screen is masked to the last line" {
  peer_alpha
  {
    echo before
    echo "-----BEGIN"" RSA PRIVATE"" KEY-----"
    echo MIIEowIBAAKCAQEAxxxxxxxx
    echo yyyyyyyyyyyyyyyyyyyyyyyy
  } > "$FAKE_SCREEN"
  run --separate-stderr pane-sight read alpha
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'before\n[masked:pem]')" ]
  [[ "$stderr" == *", 1 masked"* ]]
  # a block with its end is masked through it; a block that began above the window stays masked
  {
    echo "-----BEGIN"" PRIVATE"" KEY-----"
    echo MIIEowIBAAKCAQEAxxxxxxxx
    echo "-----END"" PRIVATE"" KEY-----"
    echo after
  } > "$FAKE_SCREEN"
  run rd alpha --lines 1
  [ "$output" = after ]
  run rd alpha --lines 2
  [ "$output" = "$(printf '[masked:pem]\nafter')" ]
}

@test "a refused pane: it2 is never run, exit 3, one refused row in the audit log" {
  mk_session "$WORK" ledger "$MAIN" ttys016 "$U1"
  echo "ledger secrets" > "$FAKE_SCREEN"
  run --separate-stderr pane-sight read ledger
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"pane-sight: refused: octo-personal-main: its pane runs a Claude session of the work profile"* ]]
  [ ! -s "$IT2_LOG" ]
  [ ! -s "$DEFAULTS_LOG" ]
  [ "$(audit_rows | wc -l)" -eq 1 ]
  [ "$(audit_rows | cut -f2-5)" = "$(printf 'read\trefused:other-profile\tsession\toctopus-nothing' | sed 's/octopus-nothing/octo-personal-main/')" ]
}

@test "the audit row is written before the text; an audit log that cannot be written prints nothing and exits 1" {
  peer_alpha
  echo visible > "$FAKE_SCREEN"
  CLAUDE_CODE_SESSION_ID=sess-1 run --separate-stderr pane-sight read alpha
  [ "$status" -eq 0 ]
  [ "$output" = visible ]
  row=$(audit_rows)
  [ "$(printf '%s\n' "$row" | awk -F'\t' '{ print NF }')" -eq 7 ]
  [ "$(printf '%s\n' "$row" | cut -f2-7)" = "$(printf 'read\tok\tpeer-running\talpha\tsess-1\tlines=1 masked=0 noted=1')" ]
  [[ "$(printf '%s\n' "$row" | cut -f1)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  [[ "$(ls -ld "$HOME/.local/state/pane-sight" | cut -c1-10)" == "drwx------" ]]
  [[ "$(ls -l "$HOME/.local/state/pane-sight/audit.log" | cut -c1-10)" == "-rw-------" ]]
  # a state directory that cannot be made: the text is never shown
  rm -r "$HOME/.local/state/pane-sight"; : > "$HOME/.local/state/pane-sight"
  run --separate-stderr pane-sight read alpha
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"cannot write $HOME/.local/state/pane-sight/audit.log; nothing was shown"* ]]
}

@test "the session id and the terminal must agree, or nothing is read" {
  peer_alpha
  echo secrets > "$FAKE_SCREEN"
  FAKE_TTY='"\/dev\/ttys099"' run --separate-stderr pane-sight read alpha
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"iTerm2 says session $U1 is on /dev/ttys099, not /dev/ttys010; nothing was read"* ]]
  ! grep -q 'session read' "$IT2_LOG" || { echo "it2 read the screen"; false; }
  [[ "$(audit_rows)" == *$'\tread\tfailed:binding\t'* ]]
  # a session iTerm2 no longer has answers nothing
  FAKE_TTY='' run --separate-stderr pane-sight read alpha
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "a pane under a suite is read with IT2_SUITE set and its own API switch; the default suite runs with IT2_SUITE unset even when the caller has one" {
  mk_session "$PERSONAL" scribe "$MAIN" ttys010 "$U1" bench
  echo hello > "$FAKE_SCREEN"
  run rd scribe
  [ "$status" -eq 0 ]
  [ "$output" = hello ]
  grep -q $'session read --session '"$U1"$'\tsuite=bench\t' "$IT2_LOG"
  [ "$(grep -c 'suite=bench' "$IT2_LOG")" -eq "$(wc -l < "$IT2_LOG")" ]
  grep -qx 'read bench EnableAPIServer' "$DEFAULTS_LOG"
  # the default suite, with the caller itself in a suite
  : > "$IT2_LOG"; : > "$DEFAULTS_LOG"
  mk_session "$PERSONAL" plain "$MAIN" ttys010 "$U2"
  end_session "$PERSONAL" "$(sed -n 1p "$BATS_TEST_TMPDIR/sleepers")"
  IT2_SUITE=other run pane-sight read plain
  [ "$status" -eq 0 ]
  [ -s "$IT2_LOG" ]
  [ "$(grep -c $'\tsuite=\t' "$IT2_LOG")" -eq "$(wc -l < "$IT2_LOG")" ]
  grep -qx 'read com.googlecode.iterm2 EnableAPIServer' "$DEFAULTS_LOG"
}

@test "the cookie: a fresh one is exported, a stale one is not, one already in the environment is kept" {
  peer_alpha
  echo hello > "$FAKE_SCREEN"
  mkdir -p "$HOME/.local/state/iterm2" "$HOME/Library/Application Support/iTerm2/private"
  ck="$HOME/.local/state/iterm2/api-cookie"
  sock="$HOME/Library/Application Support/iTerm2/private/socket"
  printf 'cookieword keyword\n' > "$ck"
  touch -t 202001010000 "$sock"
  run rd alpha
  [ "$status" -eq 0 ]
  grep -q $'cookie=cookieword$' "$IT2_LOG"
  # stale: older than the socket
  : > "$IT2_LOG"
  touch -t 202001010000 "$ck"; touch "$sock"
  run rd alpha
  [ "$status" -eq 0 ]
  [ -s "$IT2_LOG" ]
  ! grep -q 'cookieword' "$IT2_LOG" || { echo "a stale cookie was exported"; false; }
  # one already in the environment is kept, fresh file or not
  : > "$IT2_LOG"
  touch "$ck"; touch -t 202001010000 "$sock"
  ITERM2_COOKIE=mine run pane-sight read alpha
  [ "$status" -eq 0 ]
  grep -q $'cookie=mine$' "$IT2_LOG"
  ! grep -q 'cookieword' "$IT2_LOG" || { echo "the environment's cookie was replaced"; false; }
}

@test "the API is off: exit 1 naming the setting, it2 not run" {
  peer_alpha
  FAKE_API=0 run --separate-stderr pane-sight read alpha
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"iTerm2's API is off (Settings > General > Magic > Enable Python API)"* ]]
  [ ! -s "$IT2_LOG" ]
  [[ "$(audit_rows)" == *$'\tread\tfailed:it2\t'* ]]
}

@test "it2 does not answer: exit 1 after the limit" {
  peer_alpha
  PANE_SIGHT_TIMEOUT=1 FAKE_IT2_SLEEP=5 run --separate-stderr pane-sight read alpha
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"iTerm2 did not answer within 1s (an API permission prompt may be waiting in iTerm2)"* ]]
}

@test "a session id: readable when its terminal carries this profile's session; refused other-profile when it carries another's; refused no-directory when it carries none" {
  export FAKE_TTY='"\/dev\/ttys050"'
  echo idtext > "$FAKE_SCREEN"
  # no session on the terminal, and path answers "Variable 'path' not set"
  ps_row 90040 ttys050
  run --separate-stderr pane-sight read "$U1"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"refused: ${U1:0:8}: cannot tell which directory its pane is in"* ]]
  ! grep -q 'session read' "$IT2_LOG" || { echo "a refused id was read"; false; }
  # a session of this profile on that terminal
  mk_session "$PERSONAL" scribe "$MAIN" ttys050 "$U2"
  run pane-sight why "w3t1p0:$U1"
  [ "$status" -eq 0 ]
  [ "$(val kind)" = id ]
  [ "$(val session)" = "$U1" ]
  [ "$(val pid)" = - ]
  [ "$(val tty)" = /dev/ttys050 ]
  [ "$(val verdict)" = readable ]
  run rd "$U1"
  [ "$status" -eq 0 ]
  [ "$output" = idtext ]
  # a session of another profile on it
  mk_session "$WORK" ledger "$MAIN" ttys050 "$U3"
  run --separate-stderr pane-sight read "$U1"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"its pane runs a Claude session of the work profile"* ]]
  # a path iTerm2 does answer is used when it is a directory that exists
  ps_row 90041 ttys051
  FAKE_TTY='"\/dev\/ttys051"' FAKE_PATH="$MAIN" run pane-sight why "$U1"
  [ "$status" -eq 0 ]
  [ "$(val dir)" = "$MAIN" ]
  FAKE_TTY='"\/dev\/ttys051"' FAKE_PATH="$MAIN/not-a-dir" run pane-sight why "$U1"
  [ "$status" -eq 3 ]
  [ "$(val dir)" = - ]
  # iTerm2 has no such session
  FAKE_TTY='' run pane-sight why "$U1"
  [ "$status" -eq 4 ]
  [[ "$output" == *"iTerm2 has no session $U1"* ]]
}

@test "a get-var answer as iTerm2 prints it, in quotes with escaped slashes, is decoded; an unquoted one is taken as printed; one that does not parse is empty" {
  peer_alpha
  echo hello > "$FAKE_SCREEN"
  FAKE_TTY='"\/dev\/ttys010"' run pane-sight read alpha
  [ "$status" -eq 0 ]
  FAKE_TTY='/dev/ttys010' run pane-sight read alpha
  [ "$status" -eq 0 ]
  FAKE_TTY='"/dev/ttys010' run --separate-stderr pane-sight read alpha
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"is on an unknown terminal, not /dev/ttys010"* ]]
  FAKE_TTY='"\/dev\/ttys010"x' run --separate-stderr pane-sight read alpha
  [ "$status" -eq 1 ]
  FAKE_TTY='["\/dev\/ttys010"]' run --separate-stderr pane-sight read alpha
  [ "$status" -eq 1 ]
}

@test "a peer read leaves one claude-peer log note, and no second one within ten minutes" {
  peer_alpha
  echo hello > "$FAKE_SCREEN"
  export CLAUDE_CODE_SESSION_ID=sess-1
  notes() { grep -c '^log note read of alpha' "$PEER_LOG" || true; }
  run rd alpha
  [ "$status" -eq 0 ]
  [ "$(notes)" -eq 1 ]
  grep -qx "log note read of alpha's pane" "$PEER_LOG"
  run rd alpha
  [ "$status" -eq 0 ]
  [ "$(notes)" -eq 1 ]
  [ "$(audit_rows | grep -c 'noted=1')" -eq 1 ]
  # another caller is noted on its own
  CLAUDE_CODE_SESSION_ID=sess-2 run pane-sight read alpha
  [ "$(notes)" -eq 2 ]
  # once the noted row is older than ten minutes the next read notes again
  sed -i.bak '1s/^[^\t]*/2020-01-01T00:00:00Z/' "$HOME/.local/state/pane-sight/audit.log"
  run rd alpha
  [ "$(notes)" -eq 3 ]
  # a session is not a peer: no note
  mk_session "$PERSONAL" scribe "$MAIN" ttys010 "$U2"
  run rd scribe
  [ "$status" -eq 0 ]
  [ "$(notes)" -eq 3 ]
}

# --- shot ----------------------------------------------------------------------------

# sh_ <args>: shot with stdout only (the summary line dropped)
sh_() { pane-sight shot "$@" 2>/dev/null; }

@test "shot writes a PNG, mode 0600, in a 0700 directory under TMPDIR, and prints its absolute path and nothing else on stdout" {
  peer_alpha
  run --separate-stderr pane-sight shot alpha
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  [[ "$output" == "$TMPDIR/pane-sight/alpha-"*.png ]]
  [[ "$output" =~ -[0-9]{8}T[0-9]{6}Z\.png$ ]]
  cmp "$output" "$FAKE_PNG"
  [[ "$(ls -l "$output" | cut -c1-10)" == "-rw-------" ]]
  [[ "$(ls -ld "$TMPDIR/pane-sight" | cut -c1-10)" == "drwx------" ]]
  [[ "$stderr" == *"pane-sight: alpha (peer-running): 640x480 px, $(wc -c < "$FAKE_PNG" | tr -d ' ') bytes"* ]]
  row=$(audit_rows)
  [ "$(printf '%s\n' "$row" | cut -f2-5)" = "$(printf 'shot\tok\tpeer-running\talpha')" ]
  [[ "$(printf '%s\n' "$row" | cut -f7)" == "bytes="*" file=$output noted=1" ]]
  grep -qx "log note shot of alpha's pane" "$PEER_LOG"
  # a second shot within ten minutes leaves no second note
  : > "$PEER_LOG"
  run sh_ alpha
  [ "$status" -eq 0 ]
  ! grep -q 'log note' "$PEER_LOG" || { echo "second note"; false; }
}

@test "shot --out writes there and refuses a file that exists" {
  peer_alpha
  run sh_ alpha --out "$BATS_TEST_TMPDIR/mine.png"
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/mine.png" ]
  cmp "$BATS_TEST_TMPDIR/mine.png" "$FAKE_PNG"
  run --separate-stderr pane-sight shot alpha --out "$BATS_TEST_TMPDIR/mine.png"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"exists; shot will not overwrite it"* ]]
  run --separate-stderr pane-sight shot alpha --out "$BATS_TEST_TMPDIR/nodir/x.png"
  [ "$status" -eq 2 ]
  # --out leaves the default directory alone
  [ ! -e "$TMPDIR/pane-sight" ]
}

@test "shot of a refused pane: the runtime is never started and it2 is never run" {
  mk_session "$WORK" ledger "$MAIN" ttys016 "$U1"
  run --separate-stderr pane-sight shot ledger
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"pane-sight: refused: octo-personal-main: its pane runs a Claude session of the work profile"* ]]
  [ ! -s "$RT_LOG" ]
  [ ! -s "$IT2_LOG" ]
  [ ! -e "$TMPDIR/pane-sight" ]
  [ "$(audit_rows | cut -f2-3)" = "$(printf 'shot\trefused:other-profile')" ]
}

@test "the picture comes from the one render and from nowhere else" {
  peer_alpha
  run sh_ alpha
  [ "$status" -eq 0 ]
  # it2 saw the binding check and nothing that reads the screen
  [ "$(wc -l < "$IT2_LOG")" -eq 1 ]
  grep -q '^session get-var tty --session' "$IT2_LOG"
  ! grep -q 'session read' "$IT2_LOG" || { echo "shot read the pane's text"; false; }
  # the runtime saw one session id, and screencapture and osascript never ran (teardown asserts it too)
  [ "$(cat "$RT_LOG")" = "$(printf '%s\tsuite=' "$U1")" ]
  [ ! -s "$FORBIDDEN_LOG" ]
  # the script itself has no second way to make an image
  ! grep -v '^ *#' "$BATS_TEST_DIRNAME/../bin/executable_pane-sight" | grep -Eq 'screencapture|osascript' ||
    { echo "pane-sight runs screencapture or osascript"; false; }
}

@test "iTerm2 returns no image: exit 1, not drawn, no file; a peer gets the second line" {
  peer_alpha
  FAKE_SHOT_STATUS=3 run --separate-stderr pane-sight shot alpha
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"not drawn: iTerm2 returned no image for alpha"* ]]
  [[ "$stderr" == *"a peer that has never been shown may have nothing to draw"* ]]
  [ -z "$(ls "$TMPDIR/pane-sight")" ]
  [[ "$(audit_rows)" == *$'\tshot\tfailed:not-drawn\t'* ]]
  mk_session "$PERSONAL" scribe "$MAIN" ttys010 "$U2"
  FAKE_SHOT_STATUS=3 run --separate-stderr pane-sight shot scribe
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"not drawn: iTerm2 returned no image for"* ]]
  [[ "$stderr" != *"never been shown"* ]]
}

@test "iTerm2 has no such session: exit 1" {
  peer_alpha
  FAKE_SHOT_STATUS=1 run --separate-stderr pane-sight shot alpha
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"iTerm2 has no session $U1"* ]]
  [ -z "$(ls "$TMPDIR/pane-sight")" ]
}

@test "bytes that are not a PNG: exit 1 and no file" {
  peer_alpha
  echo "not a picture at all, but long enough to pass a size check" > "$FAKE_PNG"
  run --separate-stderr pane-sight shot alpha
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"not drawn"* ]]
  [ -z "$(ls "$TMPDIR/pane-sight")" ]
}

@test "no runtime: exit 1 with the fix, and iTerm2 was asked nothing" {
  peer_alpha
  PANE_SIGHT_PYTHON= run --separate-stderr pane-sight shot alpha
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"no Python runtime with the iterm2 library (iTerm2 > Scripts > Manage > Install Python Runtime, or set PANE_SIGHT_PYTHON)"* ]]
  [ ! -s "$IT2_LOG" ]
  [ ! -s "$DEFAULTS_LOG" ]
}

@test "the runtime does not answer: exit 1 after the limit, no file" {
  peer_alpha
  PANE_SIGHT_TIMEOUT=1 FAKE_RT_SLEEP=5 run --separate-stderr pane-sight shot alpha
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"iTerm2 did not answer within 1s"* ]]
  [ -z "$(ls "$TMPDIR/pane-sight")" ]
}

@test "the default directory keeps its 20 newest shots" {
  peer_alpha
  mkdir -p "$TMPDIR/pane-sight"
  for i in $(seq -w 1 25); do
    : > "$TMPDIR/pane-sight/old$i.png"
    touch -t "20200101$(printf '%02d' "$i")00" "$TMPDIR/pane-sight/old$i.png"
  done
  : > "$TMPDIR/pane-sight/notes.txt"
  run sh_ alpha
  [ "$status" -eq 0 ]
  [ "$(ls "$TMPDIR/pane-sight" | grep -c '\.png$')" -eq 20 ]
  [ -e "$output" ]
  [ ! -e "$TMPDIR/pane-sight/old01.png" ]
  [ -e "$TMPDIR/pane-sight/old25.png" ]
  [ -e "$TMPDIR/pane-sight/notes.txt" ]
  # a --out path is never pruned
  run sh_ alpha --out "$BATS_TEST_TMPDIR/keep.png"
  [ -e "$BATS_TEST_TMPDIR/keep.png" ]
  [ "$(ls "$TMPDIR/pane-sight" | grep -c '\.png$')" -eq 20 ]
}

@test "a pane under a suite is rendered with IT2_SUITE set" {
  mk_session "$PERSONAL" scribe "$MAIN" ttys010 "$U1" bench
  run sh_ scribe
  [ "$status" -eq 0 ]
  [ "$(cat "$RT_LOG")" = "$(printf '%s\tsuite=bench' "$U1")" ]
  [ "$(grep -c 'suite=bench' "$IT2_LOG")" -eq "$(wc -l < "$IT2_LOG")" ]
  : > "$RT_LOG"
  end_session "$PERSONAL" "$SPID"
  mk_session "$PERSONAL" plain "$MAIN" ttys010 "$U2"
  IT2_SUITE=other run sh_ plain
  [ "$status" -eq 0 ]
  [ "$(cat "$RT_LOG")" = "$(printf '%s\tsuite=' "$U2")" ]
}

@test "the shot's audit row holds the size and the path; when it cannot be written the file is removed and the exit is 1" {
  peer_alpha
  run --separate-stderr pane-sight shot alpha --out "$BATS_TEST_TMPDIR/a.png"
  [ "$(audit_rows | cut -f7)" = "bytes=$(wc -c < "$FAKE_PNG" | tr -d ' ') file=$BATS_TEST_TMPDIR/a.png noted=1" ]
  rm -r "$HOME/.local/state/pane-sight"; : > "$HOME/.local/state/pane-sight"
  run --separate-stderr pane-sight shot alpha --out "$BATS_TEST_TMPDIR/b.png"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"cannot write $HOME/.local/state/pane-sight/audit.log; nothing was shown"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/b.png" ]
}

@test "an option shot does not know (--window) is usage" {
  peer_alpha
  run pane-sight shot alpha --window
  [ "$status" -eq 2 ]
  run pane-sight shot --window alpha
  [ "$status" -eq 2 ]
  run pane-sight shot alpha beta
  [ "$status" -eq 2 ]
  run pane-sight shot alpha --out
  [ "$status" -eq 2 ]
  [ ! -s "$RT_LOG" ]
}

# --- who is on the terminal -------------------------------------------------------------

# pin_dir <name>: a profile directory outside every claude.profile.* pin, named only
# by a per-repo pin (a profile started by directory); its path.
pin_dir() {
  local d="$HOME/profiles/$1"
  mkdir -p "$d/sessions"
  git config --file "$GIT_CONFIG_GLOBAL" "claude.octo-personal/$1.profile" "$d"
  printf '%s\n' "$d"
}

# no_it2_read: nothing was read from iTerm2.
no_it2_read() { ! grep -q 'session read' "$IT2_LOG" || { echo "a refused pane was read"; false; }; }

@test "a session of a profile directory named only by a per-repo pin is refused other-profile, with that directory's label" {
  d="$(pin_dir pinned-dir)"
  mk_session "$d" ledger "$MAIN" ttys060 "$U1"
  run pane-sight why ledger
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: other-profile" ]
  [[ "$output" == *"its pane runs a Claude session of the pinned-dir profile; this session is personal"* ]]
  run --separate-stderr pane-read ledger
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  no_it2_read
}

@test "a Claude process under a directory no config names is refused other-profile from its environment alone" {
  ps_row 91001 ttys061 claude "claude CLAUDE_CONFIG_DIR=$HOME/elsewhere/prof ITERM_SESSION_ID=w0t0p0:$U1"
  pane_row alpha waiting 91001 "$MAIN" "$MAIN/.claude/worktrees/alpha" "$U1" -
  run pane-sight why alpha
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: other-profile" ]
  [[ "$output" == *"its pane runs a Claude session of the prof profile; this session is personal"* ]]
  run --separate-stderr pane-read alpha
  [ "$status" -eq 3 ]
  no_it2_read
}

@test "a child of such a session is enough: the claude process's own environment hidden, the variable on a child refuses" {
  ps_row 91002 ttys062 claude "claude --resume"
  ps_row 91003 ttys062 node "node server.js CLAUDE_CONFIG_DIR=$HOME/elsewhere/prof"
  pane_row alpha waiting 91002 "$MAIN" "$MAIN/.claude/worktrees/alpha" "$U1" -
  run pane-sight why alpha
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: other-profile" ]
  [[ "$output" == *"of the prof profile"* ]]
}

@test "a process named claude that this profile's registry does not hold, with no environment shown, is refused unknown-session and the line names its pid" {
  ps_row 91004 ttys063 claude "claude --resume"
  pane_row alpha waiting 91004 "$MAIN" "$MAIN/.claude/worktrees/alpha" "$U1" -
  run pane-sight why alpha
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: unknown-session" ]
  [[ "$output" == *"pane-sight: refused: Alpha: its pane runs a Claude process (pid 91004) that is not a session of this profile (personal)"* ]]
  run --separate-stderr pane-read alpha
  [ "$status" -eq 3 ]
  no_it2_read
  # a process that only has claude in its name is not one
  ps_row 91008 ttys067 claudette "claudette --resume"
  pane_row beta waiting 91008 "$MAIN" "$MAIN/.claude/worktrees/beta" "$U2" -
  run pane-sight why beta
  [ "$status" -eq 0 ]
}

@test "this profile's own session with its children (the same directory in their environment, helpers named node) is readable, and the deny check runs on the session's cwd" {
  mk_session "$PERSONAL" scribe "$MAIN" ttys064 "$U1"
  ps_row 91005 ttys064 node "node mcp.js CLAUDE_CONFIG_DIR=$PERSONAL"
  ps_row 91006 ttys064 'Google Chrome He' "Google Chrome Helper CLAUDE_CONFIG_DIR=$PERSONAL"
  run pane-sight why scribe
  [ "$status" -eq 0 ]
  [ "$(val verdict)" = readable ]
  secret="$(mk_repo octo-secret octo-personal/secret)"
  printf '{"permissions": {"deny": ["Read(~/code/octo-secret/**)"]}}\n' > "$PERSONAL/settings.json"
  mk_session "$PERSONAL" vault "$secret" ttys065 "$U2"
  ps_row 91009 ttys065 node "node mcp.js CLAUDE_CONFIG_DIR=$PERSONAL"
  run pane-sight why vault
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: denied" ]
}

@test "the default profile as caller: its own session, with no variable anywhere, is readable; a terminal whose processes carry another directory is refused" {
  unset CLAUDE_CONFIG_DIR CLAUDE_PROFILE
  mkdir -p "$HOME/.claude/sessions"
  mk_session "$HOME/.claude" scribe "$MAIN" ttys066 "$U1"
  run pane-sight why scribe
  [ "$status" -eq 0 ]
  [ "$(val verdict)" = readable ]
  ps_row 91010 ttys066 node "node mcp.js CLAUDE_CONFIG_DIR=$PERSONAL"
  run pane-sight why scribe
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: other-profile" ]
  [[ "$output" == *"of the personal profile; this session is default"* ]]
}

@test "a trailing slash or a dot-dot in the variable is not a difference" {
  mk_session "$PERSONAL" scribe "$MAIN" ttys067 "$U1"
  ps_row 91011 ttys067 node "node a.js CLAUDE_CONFIG_DIR=$PERSONAL/"
  ps_row 91012 ttys067 node "node b.js CLAUDE_CONFIG_DIR=$PERSONAL/sessions/.."
  run pane-sight why scribe
  [ "$status" -eq 0 ]
  [ "$(val verdict)" = readable ]
  CLAUDE_CONFIG_DIR="$PERSONAL/sessions/../" run pane-sight why scribe
  [ "$status" -eq 0 ]
  [ "$(val verdict)" = readable ]
}

@test "a terminal with no Claude process and no variable goes to the deny list and the route exactly as before" {
  secret="$(mk_repo octo-secret octo-personal/secret)"
  printf '{"permissions": {"deny": ["Read(~/code/octo-secret/**)"]}}\n' > "$PERSONAL/settings.json"
  pinned="$(mk_repo octo-personal-pinned octo-personal/pinned)"
  git config --file "$GIT_CONFIG_GLOBAL" claude.octo-personal/pinned.profile work-account
  ps_row 91013 ttys068; ps_row 91014 ttys069; ps_row 91015 ttys070
  pane_row alpha waiting 91013 "$MAIN" "$MAIN/.claude/worktrees/alpha" "$U1" -
  pane_row beta waiting 91014 "$secret" "$secret/.claude/worktrees/beta" "$U2" -
  pane_row gamma waiting 91015 "$pinned" "$pinned/.claude/worktrees/gamma" "$U3" -
  run pane-sight why alpha
  [ "$status" -eq 0 ]
  run pane-sight why beta
  [ "$(val verdict)" = "refused: denied" ]
  run pane-sight why gamma
  [ "$(val verdict)" = "refused: other-route" ]
}

@test "list names the pin-directory session with its profile and refused: other-profile" {
  d="$(pin_dir pinned-dir)"
  mk_session "$d" ledger "$MAIN" ttys071 "$U1"
  run pane-sight list
  [ "$status" -eq 0 ]
  [[ "$output" == *"ledger"$'\t'"session"$'\t'"$SPID"$'\t'"pinned-dir"$'\t'"refused: other-profile"* ]]
}

@test "a pin naming a mapped account adds nothing; a pin naming a directory that does not exist is skipped; a tilde pin is read" {
  # a directory called work-account sits in the current directory; the pin that
  # names the account must not turn it into a profile
  mk_session "$MAIN/work-account" bystander "$MAIN" ttys072 "$U1"
  git config --file "$GIT_CONFIG_GLOBAL" claude.octo-personal/x.profile work-account
  git config --file "$GIT_CONFIG_GLOBAL" claude.octo-personal/y.profile "$HOME/not-there"
  mkdir -p "$HOME/profiles/tilde-dir/sessions"
  git config --file "$GIT_CONFIG_GLOBAL" claude.octo-personal/z.profile '~/profiles/tilde-dir'
  mk_session "$HOME/profiles/tilde-dir" ledger "$MAIN" ttys073 "$U2"
  run pane-sight list
  [ "$status" -eq 0 ]
  [[ "$output" == *"ledger"$'\t'"session"$'\t'"$SPID"$'\t'"tilde-dir"$'\t'"refused: other-profile"* ]]
  [[ "$output" != *"bystander"* ]]
}

@test "scope asks ps about the terminal twice and no more" {
  mk_session "$PERSONAL" scribe "$MAIN" ttys074 "$U1"
  : > "$PS_LOG"
  run pane-sight why scribe
  [ "$status" -eq 0 ]
  [ "$(grep -c ' -t ' "$PS_LOG")" -eq 2 ]
  grep -qx -- '-o pid=,ucomm= -t ttys074' "$PS_LOG"
  grep -qx -- '-Eww -o pid=,command= -t ttys074' "$PS_LOG"
}

# --- who can see the terminal at all -----------------------------------------------------

@test "who is on the terminal cannot be listed: refused no-processes, before iTerm2 is asked anything" {
  peer_alpha
  echo secrets > "$FAKE_SCREEN"
  # the listing fails, prints nothing, leaves out the target's own pid, or its python fails
  for cause in FAKE_PS_T_FAIL=1 FAKE_PS_T_EMPTY=1 FAKE_PS_HIDE=90001 FAKE_TTYP_FAIL=1; do
    env "$cause" pane-sight read alpha > "$BATS_TEST_TMPDIR/out" 2> "$BATS_TEST_TMPDIR/err" && { echo "$cause: read"; false; }
    [ ! -s "$BATS_TEST_TMPDIR/out" ]
    grep -qx "pane-sight: refused: alpha: cannot tell who is on its terminal" "$BATS_TEST_TMPDIR/err" || { echo "$cause: $(cat "$BATS_TEST_TMPDIR/err")"; false; }
  done
  [ ! -s "$IT2_LOG" ]
  [ ! -s "$DEFAULTS_LOG" ]
  [ "$(audit_rows | cut -f3 | sort -u)" = "refused:no-processes" ]
  [ "$(audit_rows | wc -l)" -eq 4 ]
  FAKE_PS_T_EMPTY=1 run pane-sight why alpha
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: no-processes" ]
  # a bare session id has no pid of its own, but its terminal must list somebody
  FAKE_TTY='"\/dev\/ttys098"' run --separate-stderr pane-sight read "$U1"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"cannot tell who is on its terminal"* ]]
  no_it2_read
}

@test "a CLAUDE_CONFIG_DIR with a space in it is read cut at the space, and a cut value that matches nothing known refuses" {
  ps_row 91020 ttys097 node "node x.js CLAUDE_CONFIG_DIR=$HOME/My Profile ITERM_SESSION_ID=w0t0p0:$U1"
  pane_row alpha waiting 91020 "$MAIN" "$MAIN/.claude/worktrees/alpha" "$U1" -
  run pane-sight why alpha
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: other-profile" ]
  [[ "$output" == *"of the My profile"* ]]
  # as the caller's own ancestor: a Claude process whose cut value no registry holds
  ps_row 92060 ttys097 claude "claude CLAUDE_CONFIG_DIR=$HOME/My Profile"
  FAKE_PARENT=92060 run --separate-stderr pane-sight why alpha
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"this command runs under a Claude process (pid 92060) that no profile's registry holds"* ]]
}

# --- who is asking ----------------------------------------------------------------------------

# under <session pid> <shell pid>: this command runs in a shell whose parent is the session.
under() { ps_row "$2" ttys099 zsh zsh "$1"; export FAKE_PARENT=$2; }

@test "CLAUDE_CONFIG_DIR naming another profile, under this profile's session: caller-mismatch, nothing resolved, it2 not run, one audit row" {
  mk_session "$PERSONAL" host "$MAIN" ttys080 "$U1"; host=$SPID
  under "$host" 92001
  mk_session "$WORK" ledger "$MAIN" ttys081 "$U2"
  CLAUDE_CONFIG_DIR="$WORK" run --separate-stderr pane-sight read ledger
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"pane-sight: refused: CLAUDE_CONFIG_DIR names the work profile, but this command runs under a session of the personal profile"* ]]
  [ ! -s "$IT2_LOG" ]
  [ ! -s "$DEFAULTS_LOG" ]
  [ ! -s "$PEER_LOG" ]
  [ "$(audit_rows | wc -l)" -eq 1 ]
  [ "$(audit_rows | cut -f2-5)" = "$(printf 'read\trefused:caller-mismatch\t-\t-')" ]
  # a claim of a directory that holds a record of the same session is no way round it:
  # the registry that is not the claim's decides
  fake="$HOME/fake-prof"; mkdir -p "$fake/sessions"
  cp "$PERSONAL/sessions/$host.json" "$fake/sessions/"
  CLAUDE_CONFIG_DIR="$fake" run --separate-stderr pane-sight shot ledger
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"names the fake-prof profile, but this command runs under a session of the personal profile"* ]]
  [ "$(audit_rows | wc -l)" -eq 2 ]
  [ ! -s "$RT_LOG" ]
}

@test "the same variable in a shell with no session above it: the caller is what it says, and the pane is judged by that profile's rules" {
  mk_session "$WORK" ledger "$MAIN" ttys082 "$U1"
  CLAUDE_CONFIG_DIR="$WORK" run pane-sight why ledger
  [ "$status" -eq 0 ]
  [ "$(val verdict)" = readable ]
  printf '{"permissions": {"deny": ["Read(~/code/octo-personal-main/**)"]}}\n' > "$WORK/settings.json"
  CLAUDE_CONFIG_DIR="$WORK" run pane-sight why ledger
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: denied" ]
  # the default profile when nothing is set
  unset CLAUDE_CONFIG_DIR
  run pane-sight why ledger
  [ "$(val verdict)" = "refused: other-profile" ]
  [[ "$output" == *"this session is default"* ]]
}

@test "an ancestor named claude that no registry holds: caller-unknown, naming its pid" {
  ps_row 92010 ttys083 zsh zsh 92011
  ps_row 92011 ttys083 claude "claude --resume"
  export FAKE_PARENT=92010
  run --separate-stderr pane-sight read alpha
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"pane-sight: refused: this command runs under a Claude process (pid 92011) that no profile's registry holds"* ]]
  [ "$(audit_rows | cut -f2-5)" = "$(printf 'read\trefused:caller-unknown\t-\t-')" ]
  [ ! -s "$PEER_LOG" ]
  # a process that only has claude in its name is not one
  ps_row 92012 ttys083 claudette "claudette" 
  FAKE_PARENT=92012 run pane-sight why alpha
  [ "$status" -eq 4 ]
}

@test "an ancestor session under a directory nothing names is found through its own environment: equal to the claim it proceeds, unequal it is a mismatch" {
  prof="$HOME/elsewhere/prof"; mkdir -p "$prof/sessions"
  mk_session "$prof" host "$MAIN" ttys084 "$U1" "" "$prof"; host=$SPID
  under "$host" 92020
  mk_session "$prof" scribe "$MAIN" ttys085 "$U2"
  CLAUDE_CONFIG_DIR="$prof" run pane-sight why scribe
  [ "$status" -eq 0 ]
  [ "$(val verdict)" = readable ]
  CLAUDE_CONFIG_DIR="$PERSONAL" run --separate-stderr pane-sight why scribe
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"names the personal profile, but this command runs under a session of the prof profile"* ]]
}

@test "the nearest registered ancestor decides" {
  mk_session "$WORK" outer "$MAIN" ttys086 "$U1"; outer=$SPID
  mk_session "$PERSONAL" inner "$MAIN" ttys087 "$U2"; inner=$SPID
  under "$inner" 92030
  ps_row 92031 ttys087 zsh zsh "$outer"
  set_ppid "$inner" 92031
  mk_session "$PERSONAL" scribe "$MAIN" ttys088 "$U3"
  run pane-sight why scribe
  [ "$status" -eq 0 ]
  [ "$(val verdict)" = readable ]
  CLAUDE_CONFIG_DIR="$WORK" run --separate-stderr pane-sight why scribe
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"names the work profile, but this command runs under a session of the personal profile"* ]]
}

# standin <name> <body>: an executable stand-in that records that it ran
standin() { printf '#!/bin/sh\n: >> "%s"\n%s\n' "$BATS_TEST_TMPDIR/standin-ran" "$2" > "$BATS_TEST_TMPDIR/$1"; chmod +x "$BATS_TEST_TMPDIR/$1"; }
not_run() { [ ! -e "$BATS_TEST_TMPDIR/standin-ran" ] || { echo "a stand-in ran"; false; }; }

# denied_pane / pinned_pane: a pane of this profile in a denied directory; a waiting pane
# whose directory routes elsewhere
denied_pane() {
  secret="$(mk_repo octo-secret octo-personal/secret)"
  printf '{"permissions": {"deny": ["Read(~/code/octo-secret/**)"]}}\n' > "$PERSONAL/settings.json"
  mk_session "$PERSONAL" vault "$secret" ttys110 "$U1"
}
pinned_pane() {
  pinned="$(mk_repo octo-personal-pinned octo-personal/pinned)"
  git config --file "$GIT_CONFIG_GLOBAL" claude.octo-personal/pinned.profile work-account
  ps_row 93001 ttys111
  pane_row alpha waiting 93001 "$pinned" "$pinned/.claude/worktrees/alpha" "$U2" -
}

@test "each variable that was a seam is ignored: PANE_SIGHT_DENYGUARD" {
  denied_pane
  standin allow 'exit 0'
  PANE_SIGHT_DENYGUARD="$BATS_TEST_TMPDIR/allow" run pane-sight why vault
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: denied" ]
  not_run
}

@test "each variable that was a seam is ignored: PANE_SIGHT_FUNCTIONS" {
  pinned_pane
  printf 'claude_profile_dir() { print -r -- "%s"; }\n' "$PERSONAL" > "$BATS_TEST_TMPDIR/functions"
  PANE_SIGHT_FUNCTIONS="$BATS_TEST_TMPDIR/functions" run pane-sight why alpha
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: other-route" ]
}

@test "each variable that was a seam is ignored: PANE_SIGHT_ZSH" {
  pinned_pane
  standin zsh 'echo same'
  PANE_SIGHT_ZSH="$BATS_TEST_TMPDIR/zsh" run pane-sight why alpha
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: other-route" ]
  not_run
}

@test "each variable that was a seam is ignored: PANE_SIGHT_PEER" {
  pinned_pane
  ps_row 93002 ttys112
  printf 'alpha\twaiting\t93002\t%s\t%s\t%s\t-\n' "$MAIN" "$MAIN/.claude/worktrees/alpha" "$U3" > "$BATS_TEST_TMPDIR/panes-permissive"
  standin peer 'cat "'"$BATS_TEST_TMPDIR"'/panes-permissive"'
  PANE_SIGHT_PEER="$BATS_TEST_TMPDIR/peer" run pane-sight why alpha
  [ "$status" -eq 3 ]
  [ "$(val pid)" = 93001 ]
  [ "$(val verdict)" = "refused: other-route" ]
  not_run
}

@test "each variable that was a seam is ignored: PANE_SIGHT_TABNAME" {
  mk_session "$WORK" ledger "$MAIN" ttys113 "$U1"
  standin tabname 'echo evil-label'
  PANE_SIGHT_TABNAME="$BATS_TEST_TMPDIR/tabname" run pane-sight why ledger
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: other-profile" ]
  [ "$(val label)" = octo-personal-main ]
  [[ "$output" != *evil-label* ]]
  not_run
}

@test "each variable that was a seam is ignored: PANE_SIGHT_IT2" {
  ps_row 93003 ttys114
  mk_session "$WORK" ledger "$MAIN" ttys114 "$U3"
  standin it2 'echo "\"\\/dev\\/ttys999\""'
  FAKE_TTY='"\/dev\/ttys114"' PANE_SIGHT_IT2="$BATS_TEST_TMPDIR/it2" run pane-sight why "$U1"
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: other-profile" ]
  [ "$(val tty)" = /dev/ttys114 ]
  not_run
}

@test "each variable that was a seam is ignored: PANE_SIGHT_SUPPORT" {
  mkdir -p "$BATS_TEST_TMPDIR/support/iTerm2/iterm2env/versions/3.10/bin"
  printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/support/iTerm2/iterm2env/versions/3.10/bin/python3"
  chmod +x "$BATS_TEST_TMPDIR/support/iTerm2/iterm2env/versions/3.10/bin/python3"
  unset PANE_SIGHT_PYTHON
  PANE_SIGHT_SUPPORT="$BATS_TEST_TMPDIR/support" run pane-sight status
  [[ "$output" == *"runtime:   MISSING"* ]]
}

@test "a HOME with nothing in it refuses every pane deny-unknown" {
  bare="$BATS_TEST_TMPDIR/bare"; mkdir -p "$bare"
  mk_session "$bare/.claude" scribe "$MAIN" ttys115 "$U1"
  run env -u CLAUDE_CONFIG_DIR HOME="$bare" pane-sight why scribe
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: deny-unknown" ]
}

@test "GIT_CONFIG_GLOBAL at an empty file, or a config given in the environment, does not change an other-route verdict" {
  pinned_pane
  : > "$BATS_TEST_TMPDIR/empty-gitconfig"
  GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/empty-gitconfig" run pane-sight why alpha
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: other-route" ]
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=claude.octo-personal/pinned.profile GIT_CONFIG_VALUE_0=personal-account run pane-sight why alpha
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: other-route" ]
}

@test "XDG_STATE_HOME does not move the audit row" {
  mk_session "$WORK" ledger "$MAIN" ttys116 "$U1"
  XDG_STATE_HOME="$BATS_TEST_TMPDIR/xdg" run pane-sight read ledger
  [ "$status" -eq 3 ]
  [ ! -e "$BATS_TEST_TMPDIR/xdg" ]
  [ "$(audit_rows | wc -l)" -eq 1 ]
}

@test "it2 comes from the one place: absent there, it2 is missing and the exit is 1" {
  peer_alpha
  cp "$IT2" "$BATS_TEST_TMPDIR/it2-elsewhere"
  rm "$IT2"
  PANE_SIGHT_IT2="$BATS_TEST_TMPDIR/it2-elsewhere" run --separate-stderr pane-sight read alpha
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"it2 is missing ($HOME/.config/iterm2/it2: iTerm2's Claude Code integration links it there)"* ]]
  [ ! -s "$IT2_LOG" ]
  [[ "$(audit_rows)" == *$'\tread\tfailed:it2\t'* ]]
}

@test "the script's text holds none of the seven names that were seams" {
  ! grep -Eq 'PANE_SIGHT_(PEER|DENYGUARD|TABNAME|FUNCTIONS|ZSH|IT2|SUPPORT)' "$BATS_TEST_DIRNAME/../bin/executable_pane-sight" ||
    { echo "a seam is back in pane-sight"; false; }
  grep -q 'unset GIT_CONFIG_GLOBAL GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS' "$BATS_TEST_DIRNAME/../bin/executable_pane-sight"
}

@test "why and list refuse a mismatched caller the same way, with no rows" {
  mk_session "$PERSONAL" host "$MAIN" ttys117 "$U1"
  under "$SPID" 92040
  mk_session "$WORK" ledger "$MAIN" ttys118 "$U2"
  for v in "why ledger" list; do
    CLAUDE_CONFIG_DIR="$WORK" run --separate-stderr pane-sight $v
    [ "$status" -eq 3 ]
    [ -z "$output" ]
    [[ "$stderr" == "pane-sight: refused: CLAUDE_CONFIG_DIR names the work profile, but this command runs under a session of the personal profile" ]]
  done
  # neither writes an audit row
  [ ! -e "$HOME/.local/state/pane-sight/audit.log" ]
}
