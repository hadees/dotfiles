#!/usr/bin/env bats

# The work board's LaunchAgent (Library/LaunchAgents/local.workboard.plist.tmpl),
# its verbs (dot_local/libexec/workboard/service.py: `workboard install` and
# `uninstall`) and `workboard-doctor` in dot_functions. launchctl and uname are
# stubs that log or answer from files; nothing here loads a real agent. All names
# are fixtures (see CLAUDE.md).

bats_require_minimum_version 1.5.0

load helpers/workboard

chez() {
  HOME="$TMPHOME" \
  XDG_CONFIG_HOME="$TMPHOME/.config" \
  XDG_DATA_HOME="$TMPHOME/.local/share" \
  XDG_STATE_HOME="$TMPHOME/.local/state" \
  XDG_CACHE_HOME="$TMPHOME/.cache" \
    chezmoi "$@"
}

setup() {
  wb_setup
  SRC="$WB_ROOT"
  PLIST_TMPL="$SRC/Library/LaunchAgents/local.workboard.plist.tmpl"
  DEPLOYED="$HOME/Library/LaunchAgents/local.workboard.plist"
  CALLS="$BATS_TEST_TMPDIR/calls.log"
  LC="$BATS_TEST_TMPDIR/launchctl-state"
  mkdir -p "$LC"
  : > "$CALLS"
  # launchctl: logs every call; `print` succeeds while $LC/loaded exists, and for
  # two more calls after `bootout` (launchd tearing the job down); `bootstrap`
  # loads it again.
  cat > "$BATS_TEST_TMPDIR/bin/launchctl-stub" <<EOF
#!/bin/sh
echo "\$*" >> "$CALLS"
case "\$1" in
  print)
    [ -e "$LC/loaded" ] || exit 1
    if [ -e "$LC/drain" ]; then
      n=\$(cat "$LC/drain")
      if [ "\$n" -gt 0 ]; then echo \$((n - 1)) > "$LC/drain"; exit 0; fi
      rm -f "$LC/loaded" "$LC/drain"; exit 1
    fi
    exit 0 ;;
  bootout) [ -e "$LC/loaded" ] && echo 2 > "$LC/drain"; exit 0 ;;
  bootstrap) : > "$LC/loaded"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/launchctl-stub"
  export WORKBOARD_LAUNCHCTL="$BATS_TEST_TMPDIR/bin/launchctl-stub"
  printf '#!/bin/sh\necho "${UNAME_OUT:-Darwin}"\n' > "$BATS_TEST_TMPDIR/bin/uname"
  chmod +x "$BATS_TEST_TMPDIR/bin/uname"
  UID_NOW="$(id -u)"
  TARGET="gui/$UID_NOW/local.workboard"
  HEALTH_PID=
  wb_modules service > /dev/null
  MODDIR="$WORKBOARD_LIBEXEC"
}

teardown() {
  [ -z "${HEALTH_PID-}" ] || kill "$HEALTH_PID" 2> /dev/null || true
}

deploy_plist() {
  mkdir -p "$HOME/Library/LaunchAgents"
  printf 'stand-in plist\n' > "$DEPLOYED"
}

# A server that answers /health on the configured workboard.port.
start_health() {
  local port dir="$BATS_TEST_TMPDIR/health"
  port="$(wb_free_port)"
  mkdir -p "$dir"
  printf '{"ok": true}\n' > "$dir/health"
  git config --file "$GIT_CONFIG_GLOBAL" workboard.port "$port"
  $WB_PY -m http.server "$port" --bind 127.0.0.1 --directory "$dir" > /dev/null 2>&1 &
  HEALTH_PID=$!
  PORT="$port"
}

# run_verb <verb> [args]: the registered command, through the stub App.
run_verb() {
  WB_VERB="$1" WB_ARGV="${*:2}" wb_driver "$MODDIR" <<'PY'
import os, sys
import app, service
a = app.App()
service.register(a)
sys.exit(dict(a.commands)[os.environ["WB_VERB"]](os.environ["WB_ARGV"].split()))
PY
}

# Print the rendered plist's value for the python expression $1 (it sees `p`).
plist_get() {
  $WB_PY -c 'import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
print(eval(sys.argv[2]))' "$BATS_TEST_TMPDIR/out.plist" "$1"
}

@test "the plist renders to the specified service, shipped disabled, with home-relative paths" {
  command -v chezmoi > /dev/null 2>&1 || skip "chezmoi not installed"
  # A home with a space, '&', '<' and a quote: each must stay inside one XML string.
  TMPHOME="$BATS_TEST_TMPDIR/h o&m<e'"
  mkdir -p "$TMPHOME"
  chez init --source "$SRC" --promptString machineClass=mac > /dev/null
  chez execute-template --source "$SRC" < "$PLIST_TMPL" > "$BATS_TEST_TMPDIR/out.plist"
  command -v plutil > /dev/null 2>&1 && plutil -lint "$BATS_TEST_TMPDIR/out.plist"
  [ "$(plist_get 'p["Label"]')" = local.workboard ]
  [ "$(plist_get 'p["Disabled"]')" = True ]
  [ "$(plist_get 'p["KeepAlive"]')" = True ]
  [ "$(plist_get 'p["RunAtLoad"]')" = True ]
  [ "$(plist_get 'p["ThrottleInterval"]')" = 30 ]
  [ "$(plist_get 'p["LimitLoadToSessionType"]')" = Aqua ]
  [ "$(plist_get 'len(p["ProgramArguments"])')" = 3 ]
  [ "$(plist_get 'p["ProgramArguments"][0]')" = /bin/sh ]
  [ "$(plist_get 'p["ProgramArguments"][1]')" = "$TMPHOME/bin/workboard" ]
  [ "$(plist_get 'p["ProgramArguments"][2]')" = serve ]
  [ "$(plist_get 'p["StandardOutPath"]')" = "$TMPHOME/Library/Logs/workboard.log" ]
  [ "$(plist_get 'p["StandardErrorPath"]')" = "$TMPHOME/Library/Logs/workboard.log" ]
  [ "$(plist_get 'p["WorkingDirectory"]')" = "$TMPHOME" ]
  [ "$(plist_get 'sorted(p["EnvironmentVariables"])')" = "['HOME', 'PATH']" ]
  [ "$(plist_get 'p["EnvironmentVariables"]["HOME"]')" = "$TMPHOME" ]
  [ "$(plist_get 'p["EnvironmentVariables"]["PATH"]')" = /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin ]
  # Loopback only: the plist names no address and no credential.
  ! grep -Ei 'token|secret|password|0\.0\.0\.0' "$BATS_TEST_TMPDIR/out.plist" || { echo "the plist names a credential or all interfaces"; false; }
}

@test "register records install and uninstall as client commands, and nothing else" {
  run wb_driver "$MODDIR" <<'PY'
import app, service
a = app.App()
service.register(a)
print([n for n, _ in a.commands], a.apis, a.clis, a.routes, a.after_githubs, a.statuses)
PY
  [ "$status" -eq 0 ]
  [ "$output" = "['install', 'uninstall'] [] [] [] [] []" ]
}

@test "install with no deployed plist is exit 1, says the dotfiles deploy it, and calls no launchctl" {
  run -1 run_verb install
  [[ "$output" == *"the dotfiles deploy it on the mac class"* ]]
  [ ! -s "$CALLS" ]
}

@test "install calls enable, bootout, bootstrap, kickstart in order, waits out the teardown, and writes nothing under LaunchAgents" {
  deploy_plist
  start_health
  : > "$LC/loaded"
  before="$(cksum < "$DEPLOYED"; ls -la "$HOME/Library/LaunchAgents" | awk 'NR > 1 { print $1, $5, $NF }')"
  run -0 run_verb install
  [[ "$output" == *"listening on http://127.0.0.1:$PORT/"*"workboard connect"* ]]
  [ "$(grep -v '^print ' "$CALLS")" = "enable $TARGET
bootout $TARGET
bootstrap gui/$UID_NOW $DEPLOYED
kickstart -k $TARGET" ]
  # print was polled until it failed, all of it between bootout and bootstrap.
  [ "$(awk '/^bootout/ { on = 1; next } /^bootstrap/ { on = 0 } on && /^print / { n++ } END { print n + 0 }' "$CALLS")" -ge 3 ]
  after="$(cksum < "$DEPLOYED"; ls -la "$HOME/Library/LaunchAgents" | awk 'NR > 1 { print $1, $5, $NF }')"
  [ "$before" = "$after" ]
}

@test "install ends a detached server named in the pid file, and leaves a pid that is not board.py alone" {
  deploy_plist
  start_health
  mkdir -p "$HOME/.local/state/workboard"
  # Reparented to init (a subshell), so a killed one is gone and not a zombie.
  ( $WB_PY -c 'import time; time.sleep(60)' board.py & echo $! > "$BATS_TEST_TMPDIR/detached.pid" )
  ( $WB_PY -c 'import time; time.sleep(60)' other.py & echo $! > "$BATS_TEST_TMPDIR/other.pid" )
  detached="$(cat "$BATS_TEST_TMPDIR/detached.pid")"
  other="$(cat "$BATS_TEST_TMPDIR/other.pid")"
  printf '%s %s\n' "$detached" 47601 > "$HOME/.local/state/workboard/pid"
  kill -0 "$detached"
  run -0 run_verb install
  ! kill -0 "$detached" 2> /dev/null || { echo "the detached server still runs"; false; }
  printf '%s %s\n' "$other" 47601 > "$HOME/.local/state/workboard/pid"
  run -0 run_verb install
  kill -0 "$other"
  kill "$other"
}

@test "install --print runs nothing and prints the four launchctl lines with the real uid and path" {
  run -0 run_verb install --print
  [ ! -s "$CALLS" ]
  [ "${#lines[@]}" -eq 4 ]
  [[ "${lines[0]}" == *" enable $TARGET" ]]
  [[ "${lines[1]}" == *" bootout $TARGET" ]]
  [[ "${lines[2]}" == *" bootstrap gui/$UID_NOW $DEPLOYED" ]]
  [[ "${lines[3]}" == *" kickstart -k $TARGET" ]]
}

@test "install with an argument it does not know is usage and exit 2" {
  run -2 run_verb install --bogus
  [ ! -s "$CALLS" ]
}

@test "uninstall calls bootout, then disable" {
  run -0 run_verb uninstall
  [ "$(cat "$CALLS")" = "bootout $TARGET
disable $TARGET" ]
}

@test "off macOS install and uninstall are one line and exit 2, and call no launchctl" {
  export UNAME_OUT=Linux
  deploy_plist
  for verb in install "install --print" uninstall; do
    run -2 run_verb $verb
    [ "${#lines[@]}" -eq 1 ]
  done
  [ ! -s "$CALLS" ]
}

# workboard-doctor, in a plain zsh the way the other doctors are driven.
# A workboard already deployed on this machine's PATH is dropped, so the test sees only its own.
doctor() {
  local p=$PATH real
  real=$(command -v workboard 2>/dev/null) || true
  if [[ -n "$real" && "${real#"$BATS_TEST_TMPDIR"}" == "$real" ]]; then
    p=$(tr ':' '\n' <<<"$PATH" | grep -vxF -- "${real%/workboard}" | paste -sd: -)
  fi
  run zsh -c "PATH='$BATS_TEST_TMPDIR/bin':'$p'; source '$WB_ROOT/dot_functions'; workboard-doctor"
}

@test "workboard-doctor with the script absent: wrapper, defined, script NOT FOUND, agent, no status" {
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == "wrapper: <none"*"defined: <none"*"script:  NOT FOUND"*"chezmoi apply; macOS only)"*"agent:   no plist" ]]
}

@test "workboard-doctor with the script present: its path, the agent states, then the status indented" {
  mkdir -p "$HOME/bin"
  printf '#!/bin/sh\necho "server: not running"\n' > "$HOME/bin/workboard"
  chmod +x "$HOME/bin/workboard"
  PATH="$HOME/bin:$PATH"
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"script:  $HOME/bin/workboard"*"agent:   no plist"*"  server: not running" ]]
  [[ "$output" != *WARNING* ]]
  deploy_plist
  doctor
  [[ "$output" == *"agent:   deployed, not loaded"*"  server: not running" ]]
  : > "$LC/loaded"
  doctor
  [[ "$output" == *"agent:   loaded"*"  server: not running" ]]
  # Another package owns the name.
  mv "$HOME/bin/workboard" "$BATS_TEST_TMPDIR/bin/workboard"
  doctor
  [[ "$output" == *"WARNING: that is not ~/bin/workboard"* ]]
}

@test "nothing in this file wrote a __pycache__ into the module directory" {
  wb_no_pycache
}
