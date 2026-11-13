#!/usr/bin/env bats

# pane-sight names another iTerm2 pane and decides, before anything is read,
# whether this profile may see it. These tests drive the real script under a
# sandboxed HOME against the REAL denyguard and the REAL dot_functions (through
# the seams), with stub ps, uname, defaults, claude-peer and tabname. Sessions
# are registry fixtures backed by live `sleep` processes; the ps stub answers
# from a table file. Nothing here talks to iTerm2. Every owner, repository and
# profile name is a fixture (see CLAUDE.md).

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
  unset XDG_STATE_HOME PANE_SIGHT_IT2 PANE_SIGHT_PYTHON PANE_SIGHT_SUPPORT
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
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_PYTHON3" > "$BIN/python3"
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
printf '%s\n' "${FAKE_API:-1}"
STUB
  # ps: from the table file, "pid TAB tty TAB command" per line
  export PS_TABLE="$BATS_TEST_TMPDIR/ps-table"
  : > "$PS_TABLE"
  cat > "$BIN/ps" <<'STUB'
#!/bin/sh
for last; do :; done
case "$*" in
  *"-o tty= -p "*) awk -F'\t' -v p="$last" '$1 == p { print $2; exit }' "$PS_TABLE" ;;
  *"-o pid= -t "*) awk -F'\t' -v t="$last" '$2 == t { printf "%5s\n", $1 }' "$PS_TABLE" ;;
  *"-Eww -o command= -p "*) awk -F'\t' -v p="$last" '$1 == p { print $3; exit }' "$PS_TABLE" ;;
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
  export PANE_SIGHT_PEER="$HOME/bin/claude-peer" PANE_SIGHT_TABNAME="$HOME/bin/tabname"
  export PANE_SIGHT_DENYGUARD="$BATS_TEST_DIRNAME/../bin/executable_denyguard"
  export PANE_SIGHT_FUNCTIONS="$BATS_TEST_DIRNAME/../dot_functions"

  MAIN="$(mk_repo octo-personal-main octo-personal/main)"
  cd "$MAIN"
}

teardown() {
  if [ -f "$BATS_TEST_TMPDIR/sleepers" ]; then
    while read -r p; do kill "$p" 2>/dev/null; done < "$BATS_TEST_TMPDIR/sleepers"
  fi
  return 0
}

# mk_repo <name> [<owner/repo>]: a repository under $HOME/code; its path.
mk_repo() {
  local r="$HOME/code/$1"
  mkdir -p "$r"
  git init -q "$r"
  [ -z "${2-}" ] || git -C "$r" remote add origin "git@github.com:$2.git"
  printf '%s\n' "$r"
}

# mk_session <profile dir> <name> <cwd> <tty> [<session uuid> [<suite>]]: a live
# registry session on a terminal; its pid is left in SPID.
mk_session() {
  sleep 600 3>&- >/dev/null 2>&1 &
  SPID=$!
  echo "$SPID" >> "$BATS_TEST_TMPDIR/sleepers"
  mkdir -p "$1/sessions"
  printf '{"pid": %s, "cwd": "%s", "name": "%s"}\n' "$SPID" "$3" "$2" > "$1/sessions/$SPID.json"
  local env=''
  [ -z "${5-}" ] || env="ITERM_SESSION_ID=w0t0p0:$5"
  [ -z "${6-}" ] || env="$env IT2_SUITE=$6"
  printf '%s\t%s\tclaude --resume %s\n' "$SPID" "$4" "$env" >> "$PS_TABLE"
}

# ps_row <pid> <tty>: a process with a terminal and nothing to show in its environment.
ps_row() { printf '%s\t%s\tsh\n' "$1" "$2" >> "$PS_TABLE"; }

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
  PANE_SIGHT_DENYGUARD="$BATS_TEST_TMPDIR/no-denyguard" run pane-sight why scribe
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: deny-unknown" ]
  [[ "$output" == *"denyguard could not say whether its directory is allowed"* ]]
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
  PANE_SIGHT_FUNCTIONS="$BATS_TEST_TMPDIR/no-functions" run pane-sight why alpha
  [ "$status" -eq 3 ]
  [ "$(val verdict)" = "refused: route-unknown" ]
  [[ "$output" == *"could not ask which profile its directory routes to"* ]]
  PANE_SIGHT_ZSH="$BATS_TEST_TMPDIR/no-zsh" run pane-sight why alpha
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
  printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/it2"; chmod +x "$BATS_TEST_TMPDIR/it2"
  printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/py"; chmod +x "$BATS_TEST_TMPDIR/py"
  export PANE_SIGHT_IT2="$BATS_TEST_TMPDIR/it2" PANE_SIGHT_PYTHON="$BATS_TEST_TMPDIR/py"
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
  [[ "$output" == *"it2:       $BATS_TEST_TMPDIR/it2"* ]]
  [[ "$output" == *"api:       on"* ]]
  [[ "$output" == *"audit:     1 reads, 1 shots, 1 refused, 1 failed"* ]]
  PANE_SIGHT_IT2="$BATS_TEST_TMPDIR/none" run pane-sight status --line
  [ "$output" = "not ready: it2 is missing" ]
  PANE_SIGHT_PYTHON="$BATS_TEST_TMPDIR/none" run pane-sight status --line
  [ "$output" = "not ready: no Python runtime with the iterm2 library" ]
  FAKE_API=0 run pane-sight status --line
  [ "$output" = "not ready: iTerm2's API is off" ]
  PANE_SIGHT_DENYGUARD="$BATS_TEST_TMPDIR/none" run pane-sight status --line
  [ "$output" = "not ready: denyguard is missing" ]
  PANE_SIGHT_FUNCTIONS="$BATS_TEST_TMPDIR/none" run pane-sight status --line
  [ "$output" = "not ready: the profile resolver is missing" ]
  # the runtime is found under iTerm2's own support directory
  unset PANE_SIGHT_PYTHON
  export PANE_SIGHT_SUPPORT="$BATS_TEST_TMPDIR/support"
  mkdir -p "$PANE_SIGHT_SUPPORT/iTerm2/iterm2env/versions/3.10/bin"
  cp "$BATS_TEST_TMPDIR/py" "$PANE_SIGHT_SUPPORT/iTerm2/iterm2env/versions/3.10/bin/python3"
  run pane-sight status
  [[ "$output" == *"runtime:   $PANE_SIGHT_SUPPORT/iTerm2/iterm2env/versions/3.10/bin/python3"* ]]
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

@test "usage, and not macOS: exit 2; read and shot are not built yet" {
  run pane-sight
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
  run pane-sight nonsense
  [ "$status" -eq 2 ]
  run pane-sight why
  [ "$status" -eq 2 ]
  run pane-sight why "$U1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not built yet"* ]]
  run pane-sight read alpha
  [ "$status" -eq 2 ]
  [[ "$output" == *"not built yet"* ]]
  run pane-sight shot alpha
  [ "$status" -eq 2 ]
  [[ "$output" == *"not built yet"* ]]
  FAKE_OS=Linux run pane-sight status
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs macOS"* ]]
}

@test "pane-read and pane-shot are the same script" {
  run pane-read alpha
  [ "$status" -eq 2 ]
  [[ "$output" == *"read: not built yet"* ]]
  run pane-shot alpha
  [ "$status" -eq 2 ]
  [[ "$output" == *"shot: not built yet"* ]]
  [ "$(readlink "$BIN/pane-read")" = pane-sight ]
}
