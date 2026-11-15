#!/usr/bin/env bats

# The waiting pane of ~/bin/claude-peer, drawn: the real pane runs in a detached
# tmux server of its own at a fixed size, its screen is captured with
# `capture-pane -p` and asserted on as a person would see it. tests/claude-peer.bats
# reads the script's text; this file reads the screen.
#
# SCREEN_TESTS_REQUIRE names what the caller promises is installed (tmux; fzf for an
# fzf of 0.75 or newer). A test that needs a missing tool skips, unless the tool is
# promised: then it fails. CI promises both on each job's `bats tests` line, and
# installs the fzf it promises itself (.github/install-fzf.sh).
#
# Every glyph the waiting screen draws is one column wide (▸ · … ↵ ⏎ ✻ ▀ ▄ ▬ │);
# the measuring below rests on it, and the harness test checks that tmux agrees.
# A red test prints the screen it saw (screen_show).
# Everything runs in a sandboxed HOME against a fixture repo with invented names.

bats_require_minimum_version 1.5.0

# --- the gate -----------------------------------------------------------------------

# have <tmux|fzf>: the tool is there (fzf: 0.75 or newer)
fzf_new() {
  fzf --version 2>/dev/null | sed -n 1p | awk '{ split($1, v, "."); exit !(v[1] + 0 > 0 || v[2] + 0 >= 75) }'
}
fzf_version() { fzf --version 2>/dev/null | sed -n 1p | awk '{ print $1 }'; }
have() {
  case $1 in
    tmux) command -v tmux >/dev/null 2>&1;;
    fzf) command -v fzf >/dev/null 2>&1 && fzf_new;;
    pgrep) command -v pgrep >/dev/null 2>&1;;
    curl) command -v curl >/dev/null 2>&1 && curl --version 2>/dev/null | grep -q UnixSockets;;
    *) return 1;;
  esac
}

# verdict <word> <1|0> "<list>": run, fail (missing and promised) or skip
verdict() {
  if [ "$2" = 1 ]; then echo run; return; fi
  case " $3 " in *" $1 "*) echo fail;; *) echo skip;; esac
}

reason() {
  case $1 in
    tmux) echo 'no tmux on PATH';;
    pgrep) echo 'no pgrep on PATH (procps)';;
    curl) echo 'no curl with UnixSockets on PATH (Rocky ships curl-minimal)';;
    *) if ! command -v fzf >/dev/null 2>&1; then echo 'no fzf on PATH'
       else echo "fzf $(fzf_version) is older than 0.75"; fi;;
  esac
}

# need <word>...: the first line of every test that draws
need() {
  local w ok
  for w; do
    if have "$w"; then ok=1; else ok=0; fi
    case $(verdict "$w" "$ok" "${SCREEN_TESTS_REQUIRE-}") in
      run) ;;
      skip) skip "$(reason "$w")";;
      fail) echo "SCREEN_TESTS_REQUIRE promises $w: $(reason "$w")"; return 1;;
    esac
  done
}

# --- the sandbox (tests/claude-peer.bats setup, the picker left unset) ---------------

setup() {
  BIN="$BATS_TEST_DIRNAME/../bin/executable_claude-peer"
  # Pin python3 while HOME is still real (tests/claude-peer.bats says why): the
  # Hermes pane's figure is drawn by it
  if py="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)"; then
    mkdir -p "$BATS_TEST_TMPDIR/pybin" && ln -s "$py" "$BATS_TEST_TMPDIR/pybin/python3"
    export PATH="$BATS_TEST_TMPDIR/pybin:$PATH"
  fi
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_STATE_HOME="$HOME/.local/state"
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR"
  export CLAUDE_PEER_SETTLE=0
  # a suite run from an iTerm2 tab must not inherit a real session or look directory
  unset ITERM_SESSION_ID CLAUDE_PEER_LOOK
  git config --global user.name octo
  git config --global user.email octo@example.com
  git config --global init.defaultBranch main
  # the sleeper's own tests unset this; the others keep their bare screens
  git config --global claude-peer.art false
  # and a figure that holds still; the tests of its movement set a limit of their own,
  # or are told when they are looked at (look_on)
  git config --global claude-peer.art-seconds 0
  cat >"$BATS_TEST_TMPDIR/bin/fakeshell" <<'STUB'
#!/bin/sh
echo "pwd=$PWD"
echo "peer=${CLAUDE_PEER_WORKTREE-unset}"
echo "hermeswait=${CLAUDE_PEER_HERMES_WAIT-unset}"
echo "args=$*"
[ -z "${FAKE_SHELL_LOG-}" ] || echo "pwd=$PWD args=$*" >>"$FAKE_SHELL_LOG"
[ -z "${FAKE_SHELL_PID-}" ] || echo $$ >"$FAKE_SHELL_PID"
[ -z "${FAKE_SHELL_LAST-}" ] || { for last; do :; done; printf '%s' "$last" >"$FAKE_SHELL_LAST"; echo $# >"$FAKE_SHELL_LAST.n"; }
[ -z "${FAKE_SHELL_SLEEP-}" ] || sleep "$FAKE_SHELL_SLEEP"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/fakeshell"
  export SHELL="$BATS_TEST_TMPDIR/bin/fakeshell"
  export FAKE_SHELL_LOG="$BATS_TEST_TMPDIR/shell.log"
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  REPO=$(cd "$BATS_TEST_TMPDIR/proj" && pwd -P)
  git -C "$REPO" init -q
  echo one >"$REPO/tracked.txt"
  git -C "$REPO" add .
  git -C "$REPO" commit -qm 'initial commit'
  git -C "$REPO" remote add origin git@example.invalid:octo/proj.git
  cd "$REPO"
  export CLAUDE_PEER_CONTEXTS="$BATS_TEST_DIRNAME/../dot_config/claude-peer/contexts"
  # tripwire: a real claude must never start in a pane
  cat >"$BATS_TEST_TMPDIR/bin/claude" <<STUB
#!/bin/sh
echo "\$*" >>"$BATS_TEST_TMPDIR/claude-ran"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  SOCK="cps$$-$BATS_TEST_NUMBER"
  # three lines, and a fourth for a tmux older than 3.3 only (tmux_old says why)
  printf '%s\n' 'set -g status off' 'set -g remain-on-exit on' 'set -g default-shell /bin/sh' >"$BATS_TEST_TMPDIR/tmux.conf"
  if tmux_old "$(tmux -V 2>/dev/null)"; then
    echo 'set -g window-size manual' >>"$BATS_TEST_TMPDIR/tmux.conf"
  fi
  : "${SCREEN_FZF_OPTS=--height 40% --layout=reverse --border --color=bg+:#262626,bg:#1a1a1a,header:#747369,pointer:#f2777a,prompt:#f2777a}"
}

teardown() {
  case ${CLAUDE_PEER_LOOK-} in /tmp/cpl.*) rm -rf "$CLAUDE_PEER_LOOK";; esac
  tm kill-server >/dev/null 2>&1 || true
  [ ! -e "$BATS_TEST_TMPDIR/claude-ran" ]
}

# until_ok '<command>': retry for ten seconds
until_ok() {
  local i
  for i in $(seq 1 100); do
    eval "$1" && return 0
    sleep 0.1
  done
  return 1
}

# --- the harness ------------------------------------------------------------------------

# tmux_old "<what tmux -V prints>": a tmux of 2.9 to 3.2a. That tmux sizes a detached
# session by the terminal of the client that made it (80x24 when it has none), whatever
# -x and -y say, unless window-size is manual. From 3.3 on -x and -y are honoured without
# it, and 3.3 to 3.6a must not be given it: a new window under a global
# `window-size manual` reads a window that is not there yet, and the server dies
# ("server exited unexpectedly"; tmux issue 4849, fixed in 3.7).
tmux_old() {
  case $1 in
    'tmux 2.9'*|'tmux 3.'[012]|'tmux 3.'[012][!0-9]*) return 0;;
    *) return 1;;
  esac
}

# Every tmux call: our own socket (-L: a short name under /tmp/tmux-<uid>/), our own
# config, never the caller's server, and never bats' descriptor 3 (a server would hold it).
tm() { env -u TMUX -u TMUX_PANE tmux -L "$SOCK" -f "$BATS_TEST_TMPDIR/tmux.conf" "$@" 3>&-; }

# screen_run <cols> <rows> <command> [argument…]: a detached session `s` of that size
screen_run() {
  SCREEN_COLS=$1 SCREEN_ROWS=$2; shift 2
  tm new-session -d -s s -x "$SCREEN_COLS" -y "$SCREEN_ROWS" -c "$REPO" \
    env SHELL="$SHELL" TERM=xterm-256color COLORTERM=truecolor "$@"
  PANE_PID=$(tm display-message -p -t s '#{pane_pid}')
  # checked here, where the size is made: tmux 3.2a without `window-size manual`
  # gives 80x24 whatever is asked, and a test then fails on a wrapped line far away
  local got
  got=$(tm display-message -p -t s '#{pane_width}x#{pane_height}')
  [ "$got" = "${SCREEN_COLS}x$SCREEN_ROWS" ] || {
    echo "screen_run: asked $(tm -V) for ${SCREEN_COLS}x$SCREEN_ROWS and got $got"
    return 1
  }
}

# screen_open <cols> <rows> [VAR=value…]: the waiting pane of slot $SCREEN_SLOT (alpha)
screen_open() {
  local c=$1 r=$2 sl=${SCREEN_SLOT:-alpha}; shift 2
  screen_run "$c" "$r" env FZF_DEFAULT_OPTS="$SCREEN_FZF_OPTS" "$@" sh "$BIN" run --as "$sl" --wait
  until_ok "[ -f '$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/claude-peer.wait/$sl.$PANE_PID' ]"
}

screen_close() {
  tm kill-server >/dev/null 2>&1 || true
  until_ok "! kill -0 $PANE_PID 2>/dev/null" && return 0
  # dead but never reaped still answers kill -0: process 1 here is not an init
  case $(ps -o stat= -p "$PANE_PID" 2>/dev/null | tr -d ' ') in
    Z*) echo "screen_close: pane $PANE_PID is a zombie: process 1 here does not reap (a container needs an init: docker run --init)";;
    *) echo "screen_close: pane $PANE_PID is still running ten seconds after kill-server";;
  esac
  return 1
}

screen_keys() { tm send-keys -t s "$@"; }
screen_type() { tm send-keys -t s -l "$1"; }

screen_grab() {
  SCREEN=$(tm capture-pane -p -t s)
  SCREEN_E=$(tm capture-pane -p -e -t s)
}

# screen_wait '<ERE>' [seconds]: until a line of the screen matches
screen_wait() {
  local i n=$(( ${2:-15} * 10 ))
  for i in $(seq 1 "$n"); do
    screen_grab
    printf '%s\n' "$SCREEN" | grep -Eq -- "$1" && return 0
    sleep 0.1
  done
  echo "screen_wait: nothing matched $1"
  screen_show
  return 1
}

# screen_still [count] [gap] [seconds]: until count captures in a row are identical
screen_still() {
  local count=${1:-3} gap=${2:-0.2} limit=${3:-15} same=0 prev= now start=$SECONDS
  while [ $((SECONDS - start)) -lt "$limit" ]; do
    now=$(tm capture-pane -p -t s)
    if [ "$now" = "$prev" ]; then same=$((same + 1)); else same=1 prev=$now; fi
    if [ "$same" -ge "$count" ]; then
      SCREEN=$now
      SCREEN_E=$(tm capture-pane -p -e -t s)
      [ "$(tm capture-pane -p -t s)" = "$SCREEN" ] && return 0
      same=0
    fi
    sleep "$gap"
  done
  SCREEN=$prev
  echo "screen_still: the screen never held still"
  screen_show
  return 1
}

# --- looking ------------------------------------------------------------------------------

screen_show() {
  echo "--- screen ${SCREEN_COLS}x$SCREEN_ROWS"
  awk -v c="$SCREEN_COLS" 'BEGIN { for (i = 1; i <= c; i++) printf "%d", i % 10; print "" }'
  printf '%s\n' "$SCREEN" | sed 's/$/|/'
}

# one byte per column (UTF-8 continuation bytes dropped): for measuring only
flat() { LC_ALL=C tr -d '\200-\277'; }

# indent_of '<ERE>': leading spaces of the first matching line (spaces are ASCII: no flat)
indent_of() {
  printf '%s\n' "$SCREEN" | LC_ALL=C awk -v re="$1" '$0 ~ re { match($0, /^ */); print RLENGTH; f = 1; exit } END { if (!f) print -1 }'
}
widest() { printf '%s\n' "$SCREEN" | flat | LC_ALL=C awk '{ if (length($0) > w) w = length($0) } END { print w + 0 }'; }
filled() { printf '%s\n' "$SCREEN" | grep -c '[^ ]'; }
count_lines() { printf '%s\n' "$SCREEN" | grep -Ec -- "$1"; }
marked() { printf '%s\n' "$SCREEN" | grep -E '^ *▸'; }

no_cut() {
  if printf '%s\n' "$SCREEN" | grep -qF '··'; then echo 'no_cut: a line holds ··'; screen_show; return 1; fi
}
no_border() {
  if printf '%s\n' "$SCREEN" | grep -qE '[╭╮╰╯┌┐└┘─═]|^ *[│┃║]'; then
    echo 'no_border: a border is drawn'; screen_show; return 1
  fi
}

# line <n>: the n-th line of SCREEN
line() { printf '%s\n' "$SCREEN" | sed -n "$1p"; }

# --- the gate and CI ------------------------------------------------------------------------

@test "gate: a promised tool that is missing fails, an unpromised one skips, a present one runs" {
  [ "$(verdict tmux 0 'tmux fzf')" = fail ]
  [ "$(verdict fzf 0 tmux)" = skip ]
  [ "$(verdict fzf 0 '')" = skip ]
  [ "$(verdict tmux 1 '')" = run ]
  [ "$(verdict fzf 0 'tmux fzf')" = fail ]
  [ "$(verdict fzf 0 'tmux fzfx xfzf')" = skip ]
}

@test "ci: every job that runs the suite says what the screen tests may not skip" {
  local wf="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml" pin="$BATS_TEST_DIRNAME/../.github/fzf-version"
  local suite=' bats ((--[a-z-]+|"[^"]*"|\$[a-z]+) )*tests$'
  [ "$(grep -cE "$suite" "$wf")" -eq 3 ]
  [ "$(grep -cE "SCREEN_TESTS_REQUIRE='tmux fzf'( setsid -w)?$suite" "$wf")" -eq 3 ]
  # each of the three installs the pinned fzf, then checks that it is the first on PATH
  [ "$(grep -c 'sh \.github/install-fzf\.sh [^-]' "$wf")" -eq 3 ]
  [ "$(grep -c '^ *run: sh \.github/install-fzf\.sh --check$' "$wf")" -eq 3 ]
  # and none takes an fzf from its image's packages
  [ "$(grep -cE '(apt-get install|brew install|dnf install|additional-packages).*fzf' "$wf")" -eq 0 ]
  # the pin is a release the picker accepts (fzf_new's rule, which is the pane's fzf_ok)
  [ "$(awk 'NR == 1 { split($1, v, "."); print (v[1] + 0 > 0 || v[2] + 0 >= 75) }' "$pin")" = 1 ]
}

# --- the harness itself: the probe for every assumption the rest rests on ---------------------

@test "harness: a pane of the asked size, its own shell and colours, captured as drawn" {
  need tmux
  # which tmux gets the fourth config line: 2.9 to 3.2a, and no other
  local v
  for v in 'tmux 2.9' 'tmux 2.9a' 'tmux 3.0a' 'tmux 3.1c' 'tmux 3.2' 'tmux 3.2a'; do
    tmux_old "$v" || { echo "tmux_old says no to: $v"; false; }
  done
  for v in 'tmux 3.3' 'tmux 3.3a' 'tmux 3.4' 'tmux 3.5a' 'tmux 3.6' 'tmux 3.6a' 'tmux 3.8' 'tmux 3.10' 'tmux 3.20a' 'tmux 4.0' 'tmux next-3.9' 'tmux master' ''; do
    if tmux_old "$v"; then echo "tmux_old says yes to: $v"; false; fi
  done
  # the matching in this file reads a glyph as one character; in the C locale GNU grep
  # reads a set of glyphs as a set of bytes, and no_border finds a border in `▸`
  [ "$(locale charmap 2>/dev/null)" = UTF-8 ] || {
    echo "the locale's charmap is $(locale charmap 2>/dev/null), not UTF-8: the screen tests need a UTF-8 locale (LANG=C.UTF-8)"
    false
  }
  local script size cols rows
  # shellcheck disable=SC2016
  script='stty size; printf "%s\n" "$SHELL" "$TERM"; printf "\033[1mB\033[0m \033[48;2;217;119;87m \033[0mx ▸·…↵⏎✻▀▄▬"; sleep 30'
  for size in '80 24' '110 30'; do
    set -- $size; cols=$1 rows=$2
    screen_run "$cols" "$rows" sh -c "$script"
    screen_wait '▬'
    [ "$(line 1)" = "$rows $cols" ] || { screen_show; false; }
    # the stub shell's path can be longer than a line (macOS's $TMPDIR): k lines
    local k=$(( (${#SHELL} + cols - 1) / cols ))
    [ "$(printf '%s\n' "$SCREEN" | sed -n "2,$((k + 1))p" | tr -d '\n')" = "$SHELL" ] || { screen_show; false; }
    [ "$(line $((k + 2)))" = xterm-256color ] || { screen_show; false; }
    [ "$(line $((k + 3)))" = 'B  x ▸·…↵⏎✻▀▄▬' ] || { screen_show; false; }
    [ "$(tm display-message -p -t s '#{cursor_x}')" = 14 ] || { screen_show; false; }
    [[ "$SCREEN_E" == *'48;2;217;119;87'* ]]
    local l4 pre
    l4=$(printf '%s\n' "$SCREEN_E" | sed -n "$((k + 3))p")
    pre=${l4%%B*}
    [[ "$pre" =~ $'\033'\[([0-9]*[;:])*1([;:][0-9]*)*m ]] || { printf '%q\n' "$l4"; false; }
    screen_still
    screen_close
  done
}

# --- the numbered list ------------------------------------------------------------------------

@test "list: drawn at once, centred from 80 columns, every row whole" {
  need tmux
  git config --global claude-peer.picker list
  local size cols rows left i t
  for size in '80 24 11' '110 30 26' '60 20 0'; do
    set -- $size; cols=$1 rows=$2 left=$3
    screen_open "$cols" "$rows"
    screen_wait 'q shell$'
    screen_still
    [ "$(filled)" -eq 14 ] || { screen_show; false; }
    [ "$(printf '%s\n' "$SCREEN" | sed -n 1,12p | awk '{ printf "%s ", $2 }')" = \
      'fresh ask look-at plan prs audit catch-up team continue resume task shell ' ] || { screen_show; false; }
    while IFS= read -r t; do
      printf '%s\n' "$SCREEN" | grep -qF -- "$t" || { echo "missing title: $t"; screen_show; false; }
    done < <(sed -n 's/^title: //p' "$CLAUDE_PEER_CONTEXTS"/*.ctx
             printf '%s\n' 'A new session, no prompt' 'Pick up the last conversation' \
               'Choose an earlier conversation' 'Type a task and start it' 'Drop to a shell')
    [ "$(indent_of '^ *1  fresh')" -eq $((left + 1)) ] || { screen_show; false; }
    [ "$(indent_of '^ *10  resume')" -eq "$left" ] || { screen_show; false; }
    [ "$(indent_of 'q shell$')" -eq "$left" ] || { screen_show; false; }
    [ "$(indent_of 'Alpha ')" -eq "$left" ] || { screen_show; false; }
    [ "$(line 13)" = "$(printf "%${left}s" '')c continue · r resume · n task · s task, saved · q shell" ] || { screen_show; false; }
    no_cut
    no_border
    [[ "$SCREEN_E" != *'48;'* ]] || { screen_show; false; }
    screen_close
  done
}

@test "list: a number asks its question under the block, and the answer starts the session" {
  need tmux
  git config --global claude-peer.picker list
  screen_open 80 40 FAKE_SHELL_SLEEP=3
  screen_wait 'q shell$'
  screen_type 2
  screen_keys Enter
  screen_wait '^ {11}Question:$'
  screen_type why
  screen_keys Enter
  screen_wait '^Alpha · ask: why$'
  until_ok 'grep -qF "claude-peer proj-alpha" "$FAKE_SHELL_LOG"'
  until_ok 'screen_grab; [ "$(count_lines "q shell$")" -eq 2 ]' || { screen_show; false; }
  [[ "$SCREEN" != *21337* ]]
}

@test "list: a start from outside takes a pane that is drawing the list" {
  need tmux
  git config --global claude-peer.picker list
  screen_open 80 24 FAKE_SHELL_SLEEP=3
  screen_wait 'q shell$'
  run sh "$BIN" start alpha hello
  [ "$status" -eq 0 ]
  screen_wait '^Alpha · started by Lead · hello$'
}

@test "list: a start from outside puts its line under the prompt, for a new slot and for one that has its worktree" {
  need tmux
  local n
  git config --global claude-peer.picker list
  screen_open 80 60 FAKE_SHELL_SLEEP=3
  screen_wait 'q shell$'
  run sh "$BIN" start alpha hello
  [ "$status" -eq 0 ]
  screen_wait '^Alpha · started by Lead · hello$'
  n=$(lineno_of '^Alpha · started by Lead · hello$')
  [ "$(line $((n - 1)))" = '           Alpha ▸' ] || { screen_show; false; }
  [ "$(count_lines 'Preparing worktree')" -eq 0 ] || { screen_show; false; }
  until_ok 'screen_grab; [ "$(count_lines "q shell$")" -eq 2 ]' || { screen_show; false; }
  [ -d "$REPO/.claude/worktrees/alpha" ]
  run sh "$BIN" start alpha again
  [ "$status" -eq 0 ]
  screen_wait '^Alpha · started by Lead · again$'
  n=$(lineno_of '^Alpha · started by Lead · again$')
  [ "$(line $((n - 1)))" = '           Alpha ▸' ] || { screen_show; false; }
  [ "$(count_lines '▸ Alpha · started')" -eq 0 ] || { screen_show; false; }
}

@test "list: an fzf older than 0.75 gets the list, and the pane says so" {
  need tmux
  # an old fzf, first on PATH: it answers --version as apt's 0.44.1 does, and the pane
  # must never ask it for anything else
  cat >"$BATS_TEST_TMPDIR/bin/fzf" <<STUB
#!/bin/sh
[ "\${1-}" = --version ] && { echo '0.44.1 (debian)'; exit 0; }
echo "\$*" >>"$BATS_TEST_TMPDIR/fzf-ran"
exit 2
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/fzf"
  screen_open 80 24
  screen_wait 'q shell$'
  screen_still
  [ "$(line 1)" = 'claude-peer: fzf 0.44.1 is older than 0.75; using the list' ] || { screen_show; false; }
  [ "$(filled)" -eq 15 ] || { screen_show; false; }
  [ "$(indent_of '^ *1  fresh')" -eq 12 ] || { screen_show; false; }
  [ "$(indent_of '^ *10  resume')" -eq 11 ] || { screen_show; false; }
  [ "$(indent_of 'q shell$')" -eq 11 ] || { screen_show; false; }
  [ "$(indent_of 'Alpha ')" -eq 11 ] || { screen_show; false; }
  [ ! -e "$BATS_TEST_TMPDIR/fzf-ran" ] || { cat "$BATS_TEST_TMPDIR/fzf-ran"; false; }
}

# --- the fzf picker -----------------------------------------------------------------------------

HINT='↵ start · ^T type a task · ^S …and save it · esc hide'
SHORT='↵ start · ^T type a task · esc hide'
QUIET='Alpha: Return picks a context, c continues the last session, q leaves a shell'

# lineno_of '<ERE>': the number of the first line of SCREEN that matches, or 0
lineno_of() { printf '%s\n' "$SCREEN" | grep -nE -- "$1" | sed -n '1s/:.*//p' | grep . || echo 0; }

@test "fzf: the shipped catalogue at 80x24, 110x30 and 60x20, as a person sees it" {
  need tmux fzf
  local size cols rows left t n i mk
  for size in '80 24 11' '110 30 26' '60 20 0'; do
    set -- $size; cols=$1 rows=$2 left=$3
    screen_open "$cols" "$rows"
    screen_wait 'esc hide'
    screen_still
    [ "$(filled)" -eq 14 ] || { screen_show; false; }
    [ "$(line 1)" = "$(printf "%$((left + 2))s" '')$HINT" ] || { screen_show; false; }
    [ "$(line 2)" = "$(printf "%${left}s" '')Alpha ▸" ] || { screen_show; false; }
    [ "$(printf '%s\n' "$SCREEN" | sed -n 3,14p | sed 's/^ *▸//' | awk '{ printf "%s ", $1 }')" = \
      'fresh ask look-at plan prs audit catch-up team continue resume task shell ' ] || { screen_show; false; }
    while IFS= read -r t; do
      printf '%s\n' "$SCREEN" | grep -qF -- "$t" || { echo "missing title: $t"; screen_show; false; }
    done < <(sed -n 's/^title: //p' "$CLAUDE_PEER_CONTEXTS"/*.ctx
             printf '%s\n' 'A new session, no prompt' 'Pick up the last conversation' \
               'Choose an earlier conversation' 'Type a task and start it' 'Drop to a shell')
    mk=$(marked)
    [ "$(printf '%s\n' "$mk" | grep -c .)" -eq 1 ] || { screen_show; false; }
    [[ "$mk" =~ ^\ *▸\ fresh\  ]] || { screen_show; false; }
    [ "$(indent_of '^ *▸ fresh ')" -eq "$left" ] || { screen_show; false; }
    for i in $(seq 4 14); do
      [ "$(printf '%s\n' "$SCREEN" | sed -n "${i}p" | flat | LC_ALL=C awk '{ match($0, /^ */); print RLENGTH }')" -eq $((left + 2)) ] \
        || { echo "row on line $i"; screen_show; false; }
    done
    no_cut
    no_border
    ! printf '%s\n' "$SCREEN" | grep -qE 'file:|flag:|\(asks:' || { screen_show; false; }
    if [ "$cols" -ge 80 ]; then
      [ "$(widest)" -le $((left + 58)) ] || { screen_show; false; }
    fi
    n=$(lineno_of '^ *▸ fresh ')
    [ "$(printf '%s\n' "$SCREEN_E" | grep -c '48;2;38;38;38')" -eq 1 ] || { printf '%q\n' "$SCREEN_E"; false; }
    [[ "$(printf '%s\n' "$SCREEN_E" | sed -n "${n}p")" == *'48;2;38;38;38'* ]] || { printf '%q\n' "$SCREEN_E"; false; }
    [[ "$(printf '%s\n' "$SCREEN_E" | sed -n 1p)" == *$'\033[2m'* ]] || { printf '%q\n' "$SCREEN_E"; false; }
    screen_close
  done
}

@test "fzf: the widest row the rules allow is whole, and the block grows to hold it" {
  need tmux fzf
  local d="$BATS_TEST_TMPDIR/wide"
  mkdir -p "$d"
  printf 'title: A title that is exactly forty chars long\n\nWide.\n' >"$d/50-sixteen-chars-nm.ctx"
  screen_open 80 24 CLAUDE_PEER_CONTEXTS="$d"
  screen_wait 'esc hide'
  screen_still
  [ "$(indent_of 'Alpha ▸$')" -eq 9 ] || { screen_show; false; }
  printf '%s\n' "$SCREEN" | grep -q 'sixteen-chars-nm  A title that is exactly forty chars long$' || { screen_show; false; }
  [ "$(widest)" -eq 69 ] || { screen_show; false; }
  no_cut
  screen_close
  screen_open 64 20 CLAUDE_PEER_CONTEXTS="$d"
  screen_wait 'esc hide'
  screen_still
  [ "$(indent_of 'Alpha ▸$')" -eq 0 ] || { screen_show; false; }
  printf '%s\n' "$SCREEN" | grep -q 'sixteen-chars-nm  A title that is exactly forty chars long$' || { screen_show; false; }
  no_cut
}

@test "fzf: the hint is whole at 56 columns and at 55" {
  need tmux fzf
  screen_open 56 20
  screen_wait 'esc hide'
  screen_still
  [ "$(printf '%s\n' "$SCREEN" | grep -cxF -- "  $HINT")" -eq 1 ] || { screen_show; false; }
  no_cut
  screen_close
  screen_open 55 20
  screen_wait 'esc hide'
  screen_still
  [ "$(printf '%s\n' "$SCREEN" | grep -cxF -- "  $SHORT")" -eq 1 ] || { screen_show; false; }
  no_cut
}

@test "fzf: Down moves the mark, typing shows, Esc leaves one quiet line and no colour, Return draws the picker again" {
  need tmux fzf
  screen_open 80 24
  screen_wait 'esc hide'
  screen_keys Down
  screen_wait '^ {11}▸ ask '
  [ "$(marked | grep -c .)" -eq 1 ] || { screen_show; false; }
  screen_type pr
  screen_wait '^ {11}Alpha ▸ pr$'
  screen_keys Escape
  screen_wait '^Alpha: Return picks'
  screen_still
  [ "$(filled)" -eq 1 ] || { screen_show; false; }
  [ "$(line 1)" = "$QUIET" ] || { screen_show; false; }
  [[ "$SCREEN" != *▸* && "$SCREEN" != *'esc hide'* ]] || { screen_show; false; }
  [[ "$SCREEN_E" != *'48;'* ]] || { printf '%q\n' "$SCREEN_E"; false; }
  screen_keys Enter
  screen_wait 'esc hide'
  screen_still
  [ "$(line 1)" = "$QUIET" ] || { screen_show; false; }
  [ "$(count_lines 'esc hide')" -eq 1 ] || { screen_show; false; }
  [[ "$(marked)" =~ ^\ *▸\ fresh\  ]] || { screen_show; false; }
  [ "$(filled)" -eq 15 ] || { screen_show; false; }
  no_cut
}

@test "fzf: a start from outside clears the picker, the session runs, and the next picker is clean" {
  need tmux fzf
  screen_open 80 24 FAKE_SHELL_SLEEP=3
  screen_wait 'esc hide'
  run sh "$BIN" start alpha hello
  [ "$status" -eq 0 ]
  screen_wait '^Alpha · started by Lead · hello$'
  [ "$(line 1)" = 'Alpha · started by Lead · hello' ] || { screen_show; false; }
  [ "$(count_lines 'Preparing worktree')" -eq 0 ] || { screen_show; false; }
  [ "$(count_lines 'esc hide')" -eq 0 ] || { screen_show; false; }
  [ -z "$(marked)" ] || { screen_show; false; }
  [[ "$SCREEN" != *21337* ]] || { screen_show; false; }
  screen_wait 'esc hide'
  screen_still
  [ "$(count_lines 'esc hide')" -eq 1 ] || { screen_show; false; }
  [[ "$(marked)" =~ ^\ *▸\ fresh\  ]] || { screen_show; false; }
  no_cut
  screen_keys Down
  screen_wait '▸ ask '
}

@test "fzf: a start from outside cuts into a row's question, and its line goes under the question" {
  need tmux fzf
  local n
  git -C "$REPO" worktree add -q --detach "$REPO/.claude/worktrees/alpha"
  screen_open 80 24 FAKE_SHELL_SLEEP=3
  screen_wait 'esc hide'
  screen_keys Down
  screen_wait '^ {11}▸ ask '
  screen_keys Enter
  screen_wait '^ {11}Question:$'
  screen_still
  [ "$(count_lines 'esc hide')" -eq 0 ] || { screen_show; false; }
  run sh "$BIN" start alpha hello
  [ "$status" -eq 0 ]
  screen_wait '^Alpha · started by Lead · hello$'
  n=$(lineno_of '^Alpha · started by Lead · hello$')
  [ "$(line $((n - 1)))" = '           Question:' ] || { screen_show; false; }
  screen_wait 'esc hide'
  screen_still
  [ "$(count_lines 'esc hide')" -eq 1 ] || { screen_show; false; }
  [[ "$(marked)" =~ ^\ *▸\ fresh\  ]] || { screen_show; false; }
  no_cut
}

@test "fzf: a pane narrowed under 80 columns is left-aligned the next time the picker opens" {
  need tmux fzf
  screen_open 110 30
  screen_wait 'esc hide'
  screen_still
  [ "$(indent_of 'Alpha ▸$')" -eq 26 ] || { screen_show; false; }
  screen_keys Escape
  screen_wait '^Alpha: Return picks'
  tm resize-window -t s -x 60 -y 20
  SCREEN_COLS=60 SCREEN_ROWS=20
  screen_keys Enter
  screen_wait 'esc hide'
  screen_still
  [ "$(printf '%s\n' "$SCREEN" | grep 'Alpha ▸$' | tail -n 1 | flat | LC_ALL=C awk '{ match($0, /^ */); print RLENGTH }')" -eq 0 ] || { screen_show; false; }
  no_cut
}

# --- the sleeper ----------------------------------------------------------------------------------

# strip_sgr: every ESC[…m removed
strip_sgr() { sed $'s/\033\\[[0-9;:]*m//g'; }

# art_rows <slot> [art arguments…]: the figure as `claude-peer art` draws it, plain,
# trailing blanks removed (as capture-pane gives a line)
art_rows() {
  local s=$1; shift
  sh "$BIN" art --slot "$s" --truecolor "$@" | strip_sgr | sed 's/ *$//'
}

# from <n> <k>: SCREEN's lines with their first k columns removed (they are spaces), from line n
from_col() { printf '%s\n' "$SCREEN" | sed -n "$1,\$p" | while IFS= read -r l; do printf '%s\n' "${l:$2}"; done; }

@test "sleeper: above the picker, cell for cell, at 80x24, 110x30 and 60x20" {
  need tmux fzf
  git config --global --unset claude-peer.art
  local size cols rows left nrow art i want got z1
  for size in '80 24 11 12' '110 30 26 12' '60 20 0 6'; do
    set -- $size; cols=$1 rows=$2 left=$3 nrow=$4
    screen_open "$cols" "$rows"
    screen_wait 'esc hide'
    screen_still
    art=$(art_rows alpha)
    for i in $(seq 1 9); do
      want=$(printf '%s\n' "$art" | sed -n "${i}p")
      if [ "$cols" -ge 80 ] && [ "$i" -eq 5 ]; then want="$(printf '%-27s' "$want")  ✻ Alpha · proj"; fi
      if [ "$cols" -ge 80 ] && [ "$i" -eq 6 ]; then want="$(printf '%-27s' "$want")  waiting · ⏎ pick a context"; fi
      got=$(from_col 1 $((left + 2)) | sed -n "${i}p")
      [ "$got" = "$want" ] || { echo "art line $i"; screen_show; false; }
    done
    local top=9
    if [ "$cols" -lt 80 ]; then
      [ "$(line 10)" = '  ✻ Alpha · proj' ] || { screen_show; false; }
      [ "$(line 11)" = '  waiting · ⏎ pick a context' ] || { screen_show; false; }
      top=11
    fi
    z1=$(printf '%s\n' "$SCREEN" | sed -n 1,9p)
    [ "$(printf '%s' "$z1" | grep -o '▬' | wc -l | tr -d ' ')" -eq 4 ] || { screen_show; false; }
    [ "$(printf '%s' "$z1" | grep -o 'Z' | wc -l | tr -d ' ')" -eq 1 ] || { screen_show; false; }
    [ "$(printf '%s' "$z1" | grep -o 'z' | wc -l | tr -d ' ')" -eq 2 ] || { screen_show; false; }
    [ -z "$(line $((top + 1)))" ] || { screen_show; false; }
    [ "$(line $((top + 2)))" = "$(printf "%$((left + 2))s" '')$HINT" ] || { screen_show; false; }
    [ "$(line $((top + 3)))" = "$(printf "%${left}s" '')Alpha ▸" ] || { screen_show; false; }
    [ "$(printf '%s\n' "$SCREEN" | sed -n "$((top + 4)),\$p" | grep -c '[^ ]')" -eq "$nrow" ] || { screen_show; false; }
    [[ "$(line $((top + 4)))" =~ ^\ *▸\ fresh\  ]] || { screen_show; false; }
    if [ "$cols" -lt 80 ]; then
      ! printf '%s\n' "$SCREEN" | grep -q '│.' || { screen_show; false; }
    else
      # every row shown, and the screen exactly full: the far Z still on line 2, the last row on the last line
      [[ "$(line 2)" == *Z* ]] || { screen_show; false; }
      if [ "$rows" -eq 24 ]; then [[ "$(line 24)" =~ shell\ +Drop\ to\ a\ shell$ ]] || { screen_show; false; }; fi
      [ "$(indent_of 'Alpha ▸$')" -eq "$left" ] || { screen_show; false; }
      [ "$(widest)" -le $((left + 58)) ] || { screen_show; false; }
    fi
    no_cut
    no_border
    [[ "$SCREEN_E" == *'48;2;217;119;87'* && "$SCREEN_E" == *'153;204;153'* ]] || { printf '%q\n' "$SCREEN_E"; false; }
    [[ "$SCREEN_E" != *'116;115;105'* ]] || { printf '%q\n' "$SCREEN_E"; false; }
    # the far Z: bold, and in the terminal's own colour (no 38; before it on its line)
    local l2 pre
    l2=$(printf '%s\n' "$SCREEN_E" | sed -n 2p); pre=${l2%%Z*}
    [[ "$pre" =~ $'\033'\[([0-9]*[;:])*1([;:][0-9]*)*m ]] || { printf '%q\n' "$l2"; false; }
    [[ "$pre" != *$'\033[38;'* ]] || { printf '%q\n' "$l2"; false; }
    screen_close
  done
}

# sgr_before '<ERE>': the line of SCREEN_E whose plain text (SCREEN) first matches,
# up to its first ▸
sgr_before() { printf '%s\n' "$SCREEN_E" | sed -n "$(lineno_of "$1")p" | sed 's/▸.*//'; }

@test "sleeper: the selector takes the hat's colour, slot by slot; with the art off it does not" {
  need tmux fzf
  git config --global --unset claude-peer.art
  local each
  for each in 'alpha Alpha 153;204;153' 'beta Beta 90;120;200'; do
    set -- $each
    SCREEN_SLOT=$1 screen_open 80 24
    screen_wait 'esc hide'
    screen_still
    [[ "$(sgr_before '▸ fresh ')" == *"38;2;$3"* ]] || { screen_show; false; }
    [[ "$(sgr_before "^ *$2 ▸")" == *"38;2;$3"* ]] || { screen_show; false; }
    [[ "$SCREEN_E" == *"48;2;$3"* ]] || { screen_show; false; }   # the hat itself
    screen_close
  done
  git config --global claude-peer.art false
  screen_open 80 24
  screen_wait 'esc hide'
  screen_still
  [[ "$(sgr_before '▸ fresh ')" != *'38;2;153;204;153'* ]] || { screen_show; false; }
}

@test "sleeper: it stays whole while the list scrolls" {
  need tmux fzf
  git config --global --unset claude-peer.art
  local before i
  screen_open 60 20
  screen_wait 'esc hide'
  screen_still
  before=$(printf '%s\n' "$SCREEN" | sed -n 1,11p)
  for i in $(seq 1 8); do screen_keys Down; done
  screen_wait '▸ continue '
  screen_still
  [ "$(printf '%s\n' "$SCREEN" | sed -n 1,11p)" = "$before" ] || { screen_show; false; }
}

@test "sleeper: a pane of 15 rows shows the picker without it" {
  need tmux fzf
  git config --global --unset claude-peer.art
  screen_open 80 15
  screen_wait 'esc hide'
  screen_still
  [[ "$SCREEN" != *▬* ]] || { screen_show; false; }
  [ "$(line 1)" = "$(printf '%13s' '')$HINT" ] || { screen_show; false; }
  [ "$(filled)" -eq 14 ] || { screen_show; false; }
}

# below_args: SCREEN's lines after the stub shell's last `args=` line
below_args() { printf '%s\n' "$SCREEN" | sed -n "$((ARGS_AT + 1)),\$p"; }

@test "sleeper: Esc leaves it with the quiet line, and neither Return nor a mistyped line makes a second one" {
  need tmux fzf
  git config --global --unset claude-peer.art
  screen_open 110 30 FAKE_SHELL_SLEEP=1
  screen_wait 'esc hide'
  screen_keys Enter
  screen_wait '^args='
  until_ok 'screen_grab; [ "$(printf "%s\n" "$SCREEN" | sed -n "$(lineno_of "^args="),\$p" | grep -c "esc hide")" -ge 1 ]' || { screen_show; false; }
  screen_still
  ARGS_AT=$(lineno_of '^args=')
  local args_line want
  args_line=$(line "$ARGS_AT")
  screen_keys Escape
  screen_wait '⏎ picker · c continue · q shell'
  screen_still
  want=$(CLAUDE_PEER_SIZE='30 110' sh "$BIN" art --screen --slot alpha | strip_sgr | sed 's/ *$//')
  [ "$(below_args | sed -n "1,$(printf '%s\n' "$want" | wc -l | tr -d ' ')p")" = "$want" ] || { printf '%s\n' "$want"; screen_show; false; }
  [[ "$SCREEN" != *'Alpha: Return picks'* && "$SCREEN" != *'esc hide'* ]] || { screen_show; false; }
  screen_type x
  screen_keys Enter
  screen_still
  [ "$(below_args | grep -o '▬' | wc -l | tr -d ' ')" -eq 4 ] || { screen_show; false; }
  [ "$(below_args | grep -o '✻' | wc -l | tr -d ' ')" -eq 1 ] || { screen_show; false; }
  [ "$(line "$ARGS_AT")" = "$args_line" ] || { screen_show; false; }
  screen_keys Enter
  screen_wait 'esc hide'
  screen_still
  [ "$(below_args | grep -o '▬' | wc -l | tr -d ' ')" -eq 4 ] || { screen_show; false; }
  [ "$(below_args | grep -o '✻' | wc -l | tr -d ' ')" -eq 1 ] || { screen_show; false; }
  [ "$(line "$ARGS_AT")" = "$args_line" ] || { screen_show; false; }
  [[ "$(line $((ARGS_AT + 2)))" == *Z* ]] || { screen_show; false; }
}

@test "sleeper: above the list" {
  need tmux
  git config --global --unset claude-peer.art
  git config --global claude-peer.picker list
  screen_open 110 30
  screen_wait 'q shell$'
  screen_still
  local art i want
  art=$(art_rows alpha)
  for i in $(seq 1 9); do
    want=$(printf '%s\n' "$art" | sed -n "${i}p")
    [ "$i" -ne 5 ] || want="$(printf '%-27s' "$want")  ✻ Alpha · proj"
    [ "$i" -ne 6 ] || want="$(printf '%-27s' "$want")  waiting · ⏎ pick a context"
    [ "$(from_col 1 28 | sed -n "${i}p")" = "$want" ] || { echo "art line $i"; screen_show; false; }
  done
  [ -z "$(line 10)" ] || { screen_show; false; }
  [ "$(indent_of '^ *1  fresh')" -eq 27 ] || { screen_show; false; }
  [ "$(lineno_of '^ *1  fresh')" -eq 11 ] || { screen_show; false; }
  [ "$(printf '%s\n' "$SCREEN" | grep -o '▬' | wc -l | tr -d ' ')" -eq 4 ] || { screen_show; false; }
}

# --- the sleeper moves, and wakes ----------------------------------------------------------------

# art_matches <left> <row-5 text> <row-6 text> [art arguments…]: lines 1 to 9, less their
# first left + 2 columns, are that frame of `claude-peer art`, the texts beside rows 5 and 6
art_matches() {
  local left=$1 t5=$2 t6=$3 art i want got; shift 3
  art=$(art_rows alpha "$@")
  for i in $(seq 1 9); do
    want=$(printf '%s\n' "$art" | sed -n "${i}p")
    [ "$i" -ne 5 ] || [ -z "$t5" ] || want="$(printf '%-27s' "$want")  $t5"
    [ "$i" -ne 6 ] || [ -z "$t6" ] || want="$(printf '%-27s' "$want")  $t6"
    got=$(from_col 1 $((left + 2)) | sed -n "${i}p")
    [ "$got" = "$want" ] || { echo "art line $i"; screen_show; return 1; }
  done
}

top9() { printf '%s\n' "$SCREEN" | sed -n 1,9p; }

# fzf_kids: the children of the pane's fzf (its timer's shells)
fzf_kids() { local f; f=$(pgrep -P "$PANE_PID" -x fzf) || { echo 'no fzf under the pane'; return 1; }; pgrep -P "$f" || true; }

@test "sleeper: it moves, keeps what is typed, stops at the limit, and a key starts it again" {
  need tmux fzf pgrep
  git config --global --unset claude-peer.art
  git config --global claude-peer.art-seconds 3
  local first still
  screen_open 80 24
  screen_wait 'esc hide'
  first=$(top9)
  until_ok 'screen_grab; [ "$(top9)" != "$first" ]' || { screen_show; false; }
  screen_type pr
  screen_wait 'Alpha ▸ pr$'
  screen_still 5 0.5
  art_matches 11 '✻ Alpha · proj' 'waiting · ⏎ pick a context'
  [ -z "$(fzf_kids)" ] || { fzf_kids; false; }
  still=$(top9)
  screen_type s
  until_ok 'screen_grab; [ "$(top9)" != "$still" ]' || { screen_show; false; }
}

@test "sleeper: with art-seconds 0 it never moves" {
  need tmux fzf pgrep
  git config --global --unset claude-peer.art
  screen_open 80 24
  screen_wait 'esc hide'
  screen_still 5 0.5
  art_matches 11 '✻ Alpha · proj' 'waiting · ⏎ pick a context'
  [ -z "$(fzf_kids)" ] || { fzf_kids; false; }
}

# look_on: the look mode of the waiting pane: a look directory with the marker, a session
# id, and no limit of the user's own (the socket path must fit sun_path, so /tmp)
LOOK_ID=11111111-2222-3333-4444-555555555555
LOOK_ID2=66666666-7777-8888-9999-000000000000
look_on() {
  CLAUDE_PEER_LOOK=$(mktemp -d /tmp/cpl.XXXXXX)
  export CLAUDE_PEER_LOOK
  echo variable >"$CLAUDE_PEER_LOOK/kind"
  export ITERM_SESSION_ID=w0t0p0:$LOOK_ID
  git config --global --unset claude-peer.art
  git config --global --unset claude-peer.art-seconds
}

# look_sock: the pane's fzf is listening
look_sock() { [ -S "$CLAUDE_PEER_LOOK/$LOOK_ID.sock" ]; }

# moves: three pose changes in a row, each with no child under the fzf
moves() {
  local prev n
  for n in 1 2 3; do
    prev=$(top9)
    until_ok 'screen_grab; [ "$(top9)" != "$prev" ]' || { screen_show; return 1; }
    [ -z "$(fzf_kids)" ] || { fzf_kids; return 1; }
  done
}

@test "sleeper look: still until told, moves while it is looked at, stops when another session is" {
  need tmux fzf pgrep curl
  look_on
  screen_open 80 24
  screen_wait 'esc hide'
  until_ok look_sock
  screen_still 5 0.5
  [ -z "$(fzf_kids)" ] || { fzf_kids; false; }
  sh "$BIN" look gained "$LOOK_ID"
  moves
  screen_type pr
  screen_wait 'Alpha ▸ pr$'
  moves
  sh "$BIN" look gained "$LOOK_ID2"
  screen_still 5 0.5
  sh "$BIN" look gained "$LOOK_ID"
  moves
  sh "$BIN" look lost "$LOOK_ID"
  screen_still 5 0.5
}

@test "sleeper look: a pane that opens under the operator's eyes moves at once" {
  need tmux fzf pgrep curl
  look_on
  printf '%s\n' "$LOOK_ID" >"$CLAUDE_PEER_LOOK/focus"
  screen_open 80 24
  screen_wait 'esc hide'
  moves
}

@test "sleeper look: looked at or held still, the picker is drawn the same" {
  need tmux fzf curl
  look_on
  local size kept kept_e
  for size in '80 24' '110 30' '60 20'; do
    set -- $size
    git config --global claude-peer.art-seconds 0
    screen_open "$1" "$2"
    screen_wait 'esc hide'
    screen_still
    kept=$SCREEN kept_e=$SCREEN_E
    screen_close
    git config --global --unset claude-peer.art-seconds
    screen_open "$1" "$2"
    screen_wait 'esc hide'
    until_ok look_sock
    curl -s -o /dev/null -m 2 --unix-socket "$CLAUDE_PEER_LOOK/$LOOK_ID.sock" -X POST -d 'change-with-nth(6)' http://localhost/
    screen_still
    [ "$SCREEN" = "$kept" ] || { echo "SCREEN differs at $1x$2; held still:"; printf '%s\n' "$kept"; screen_show; false; }
    [ "$SCREEN_E" = "$kept_e" ] || { echo "SCREEN_E differs at $1x$2"; printf '%q\n%q\n' "$kept_e" "$SCREEN_E"; false; }
    screen_close
  done
}

# woke <header>: the figure above the session's header is awake, drawn once
woke() {
  art_matches 11 '✻ Alpha · proj' '' --frame wake-2 --z none
  local t; t=$(top9)
  [ "$(printf '%s' "$t" | grep -c '[▬Zz]')" -eq 0 ] || { screen_show; return 1; }
  [ -n "$(line 1)" ] || { screen_show; return 1; }
  [[ "$SCREEN_E" == *'48;2;15;15;15'* ]] || { screen_show; return 1; }
  [ "$(count_lines '✻')" -eq 1 ] || { screen_show; return 1; }
  [ "$(line 10)" = "$1" ] || { screen_show; return 1; }
  [ "$(count_lines 'esc hide')" -eq 0 ] || { screen_show; return 1; }
  [ "$(count_lines 'A new session, no prompt')" -eq 0 ] || { screen_show; return 1; }
}

@test "wake: picking a row opens the eyes above the session line" {
  need tmux fzf
  git config --global --unset claude-peer.art
  screen_open 80 24 FAKE_SHELL_SLEEP=6
  screen_wait 'esc hide'
  screen_keys Enter
  screen_wait '^Alpha$'
  screen_still
  woke Alpha
}

@test "wake: a start from outside wakes the same way" {
  need tmux fzf
  git config --global --unset claude-peer.art
  screen_open 80 24 FAKE_SHELL_SLEEP=6
  screen_wait 'esc hide'
  run sh "$BIN" start alpha hello
  [ "$status" -eq 0 ]
  screen_wait '^Alpha · started by Lead · hello$'
  screen_still
  woke 'Alpha · started by Lead · hello'
}

@test "wake: the list starts a session without one" {
  need tmux
  git config --global --unset claude-peer.art
  git config --global claude-peer.picker list
  screen_open 110 30 FAKE_SHELL_SLEEP=4
  screen_wait 'q shell$'
  screen_keys Enter
  screen_wait '^Alpha$'
  [ "$(printf '%s\n' "$SCREEN" | grep -o '▬' | wc -l | tr -d ' ')" -eq 4 ] || { screen_show; false; }
  [[ "$SCREEN_E" != *'48;2;15;15;15'* ]] || { screen_show; false; }
}

# --- the Hermes pane ----------------------------------------------------------------

# The Hermes peer's wait as `claude-peer hermes --wait` runs it: hermes_peer from
# dot_functions with the routing and hermes itself stubbed, claude-peer on PATH, and
# an installed Hermes whose banner holds a small invented figure.
hermes_open() {
  local d=$HOME/.hermes/hermes-agent/hermes_cli
  mkdir -p "$d"
  printf '%s\n' 'HERMES_CADUCEUS = """[#CD7F32]⢀⣀⣀⣀⣀⣀⡀[/]' '⣿⣿⣿⣿⣿⣿⣿' '⣿⣿⣿⣿⣿⣿⣿' '⠈⠉⠉⠉⠉⠉⠁"""' >"$d/banner.py"
  ln -sf "$BIN" "$BATS_TEST_TMPDIR/bin/claude-peer"
  screen_run 80 24 zsh -f -c "source '$BATS_TEST_DIRNAME/../dot_functions'
    hermes_profile() { print prof; }
    hermes() { print HERMES-RAN; }
    CLAUDE_PEER_HERMES_WAIT=1 hermes_peer; print LEFT; sleep 30"
}

@test "hermes: the caduceus glints, then holds still; Return starts Hermes and it waits again; q leaves" {
  need tmux
  git config --global --unset claude-peer.art
  git config --global claude-peer.art-seconds 2
  hermes_open
  screen_wait 'waiting · ⏎ to start Hermes'
  [ "$(line 1)" = '  ⢀⣀⣀⣀⣀⣀⡀' ] && [ "$(line 6)" = '  waiting · ⏎ to start Hermes · q for a shell' ] || { screen_show; false; }
  [ "$(count_lines 'Return starts hermes')" -eq 0 ] || { screen_show; false; }
  local first; first=$SCREEN_E
  until_ok 'screen_grab; [ "$SCREEN_E" != "$first" ]' || { screen_show; false; }
  screen_still 5 0.5
  [[ "$SCREEN_E" == *'150;92;36'* && "$SCREEN_E" != *'255;214;150'* ]] || { screen_show; false; }
  screen_keys Enter
  screen_wait '^HERMES-RAN'
  screen_wait 'waiting · ⏎ to start Hermes'
  [ "$(count_lines 'waiting · ⏎')" -eq 1 ] || { screen_show; false; }
  screen_type q; screen_keys Enter
  screen_wait '^LEFT'
  [ "$(count_lines 'waiting · ⏎')" -eq 0 ] || { screen_show; false; }
}

@test "hermes: with claude-peer.art false the figure is not drawn" {
  need tmux
  hermes_open
  screen_wait 'Hermes \(prof\): Return starts hermes here, q leaves a shell'
  [ "$(count_lines 'waiting · ⏎')" -eq 0 ] || { screen_show; false; }
}

@test "hermes: with no Hermes figure installed the pane asks as it always has" {
  need tmux
  git config --global --unset claude-peer.art
  ln -sf "$BIN" "$BATS_TEST_TMPDIR/bin/claude-peer"
  screen_run 80 24 zsh -f -c "source '$BATS_TEST_DIRNAME/../dot_functions'
    hermes_profile() { print prof; }
    hermes() { print HERMES-RAN; }
    CLAUDE_PEER_HERMES_WAIT=1 hermes_peer; print LEFT; sleep 30"
  screen_wait 'Hermes \(prof\): Return starts hermes here, q leaves a shell'
  screen_keys Enter
  screen_wait '^HERMES-RAN'
}
