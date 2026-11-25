# Sourced by every work-board test file (`load helpers/workboard`); each calls
# wb_setup in its setup, wb_teardown in its teardown and wb_no_pycache last.
#
# wb_demo and wb_modules export a variable AND print a path: call them plainly
# (`wb_demo >/dev/null`), not inside $( ), or the export is lost with the
# subshell.

WB_HELPERS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WB_ROOT="$(cd "$WB_HELPERS/../.." && pwd)"
WB_FIXTURES="$WB_ROOT/tests/fixtures/workboard"

wb_setup() {
  # python3 is resolved to its real interpreter before HOME is sandboxed, and
  # re-exposed under a stub on PATH below: an asdf shim resolves relative to
  # $HOME and exits 126 the moment that is overridden (CLAUDE.md, "Running tests").
  local real
  real="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)" || real=''
  [ -n "$real" ] || skip "python3 not installed"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude" "$HOME/.claude-personal" "$BATS_TEST_TMPDIR/bin"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  unset XDG_STATE_HOME CLAUDE_CONFIG_DIR CLAUDE_PROFILE CLAUDECODE WORKBOARD_DEMO WORKBOARD_LIBEXEC WORKBOARD_STUB_RAISE
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  # A clone another user owns (CI runs as root) is trusted on every git version.
  git config --file "$GIT_CONFIG_GLOBAL" safe.directory '*'
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-work-org.username work-acct
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-personal.username personal-acct
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.work-acct '~/.claude'
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.personal-acct '~/.claude-personal'

  printf '#!/bin/sh\nexec "%s" "$@"\n' "$real" > "$BATS_TEST_TMPDIR/bin/python3"
  chmod +x "$BATS_TEST_TMPDIR/bin/python3"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  WB_SRC="$WB_ROOT/dot_local/libexec/workboard"
  WB_STUBS="$WB_ROOT/tests/workboard-stubs"
  if [ -n "${WORKBOARD_PYTHON-}" ]; then WB_PY="$WORKBOARD_PYTHON -I -B"
  elif [ -x /usr/bin/python3 ]; then WB_PY="/usr/bin/python3 -I -B"
  else WB_PY="python3 -I -B"; fi
  # The stub App is importable from wb_driver without exposing the stub verbs
  # (a test of "verbs not installed" needs `import verbs` to fail).
  WB_APPDIR="$BATS_TEST_TMPDIR/wb-app"
  mkdir -p "$WB_APPDIR"
  ln -sf "$WB_STUBS/app.py" "$WB_APPDIR/app.py"
  export WB_SRC WB_STUBS WB_PY WB_APPDIR
  # The server's Unix socket lives here. Not under BATS_TEST_TMPDIR: that path
  # is too long for a socket (sun_path is 104 bytes on macOS).
  WORKBOARD_RUNTIME="$(mktemp -d /tmp/wb.XXXXXX)" || return 1
  export WORKBOARD_RUNTIME
}

# wb_teardown: removes the runtime directory wb_setup made. Call it from
# `teardown`, which bats runs after a failed test too.
wb_teardown() {
  if [ -n "${WORKBOARD_RUNTIME-}" ]; then rm -rf "$WORKBOARD_RUNTIME"; fi
}

# wb_demo: a copy of the demo documents with /wb-fixture replaced by a new
# directory, the directories the local document names created, WORKBOARD_DEMO
# exported; prints the directory.
wb_demo() {
  local d f
  d="$(mktemp -d "$BATS_TEST_TMPDIR/demo.XXXXXX")" || return 1
  for f in github local who inbox board; do
    sed "s|/wb-fixture|$d|g" "$WB_FIXTURES/demo/$f.json" > "$d/$f.json" || return 1
  done
  $WB_PY - "$d/local.json" <<'PY' | while IFS= read -r f; do mkdir -p "$f"; done
import json, sys
doc = json.load(open(sys.argv[1]))
for r in doc["repos"]:
    print(r["dir"]); print(r["common"]); print(r["profile"])
for w in doc["worktrees"]:
    print(w["path"])
PY
  export WORKBOARD_DEMO="$d"
  printf '%s\n' "$d"
}

# wb_modules <name>...: a module directory of symlinks, each to the real file
# for a name given (failing when there is none) and to step 1's stub for every
# other module that has one; exports WORKBOARD_LIBEXEC and prints it.
wb_modules() {
  local all="board model github local who inbox verbs mcp_endpoint service notice pane" n d
  for n in "$@"; do
    case " $all " in *" $n "*) ;; *) echo "wb_modules: no such module $n" >&2; return 1 ;; esac
    [ -f "$WB_SRC/$n.py" ] || { echo "wb_modules: $WB_SRC/$n.py does not exist" >&2; return 1; }
  done
  d="$(mktemp -d "$BATS_TEST_TMPDIR/modules.XXXXXX")" || return 1
  for n in $all; do
    case " $* " in
      *" $n "*) ln -s "$WB_SRC/$n.py" "$d/$n.py" ;;
      *) if [ -f "$WB_STUBS/$n.py" ]; then ln -s "$WB_STUBS/$n.py" "$d/$n.py"; fi ;;
    esac
  done
  export WORKBOARD_LIBEXEC="$d"
  printf '%s\n' "$d"
}

# wb_driver <module directory> <<python: run the python on stdin with that
# directory first on sys.path (then the stub App's).
wb_driver() {
  { printf 'import os, sys\nsys.path[:0] = [os.environ["WB_DRIVER_DIR"], os.environ["WB_APPDIR"]]\n'; cat; } |
    WB_DRIVER_DIR="$1" $WB_PY -
}

# wb_shape <kind> <file>: the checker.
wb_shape() {
  $WB_PY "$WB_HELPERS/workboard-shape.py" "$@"
}

wb_free_port() {
  $WB_PY -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

wb_no_pycache() {
  [ ! -e "$WB_SRC/__pycache__" ]
}
