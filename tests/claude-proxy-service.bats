#!/usr/bin/env bats

# The claude-codex LaunchAgent (Library/LaunchAgents/local.claude-codex.plist.tmpl)
# and the proxy's managed configuration (dot_config/claude-codex/config.json).
# Everything here renders or applies into a throwaway $HOME. launchctl and
# claude-codex are stubs that log any call, and the tests assert the logs stay
# empty: nothing in the source loads the service or starts the proxy.

chez() {
  HOME="$TMPHOME" \
  XDG_CONFIG_HOME="$TMPHOME/.config" \
  XDG_DATA_HOME="$TMPHOME/.local/share" \
  XDG_STATE_HOME="$TMPHOME/.local/state" \
  XDG_CACHE_HOME="$TMPHOME/.cache" \
    chezmoi "$@"
}

# The plist deploys only once the proxy binary exists in the (fake) home.
fake_proxy_install() {
  mkdir -p "$TMPHOME/.cargo/bin"
  : > "$TMPHOME/.cargo/bin/claude-codex"
}

setup() {
  command -v chezmoi > /dev/null 2>&1 || skip "chezmoi not installed"
  # python3 is resolved to its real interpreter before HOME is faked: an asdf
  # shim resolves relative to $HOME and exits 126 under a fake one.
  PY="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)" || PY=''
  [ -n "$PY" ] || skip "python3 not installed"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PLIST_TMPL="$SRC/Library/LaunchAgents/local.claude-codex.plist.tmpl"
  # The home holds a space, '&', '<' and a quote: each must stay inside one
  # XML string element.
  TMPHOME="$BATS_TEST_TMPDIR/h o&m<e'"
  mkdir -p "$TMPHOME"

  # Stubs ahead of everything on PATH, each recording that it was called.
  STUBS="$BATS_TEST_TMPDIR/stubs"
  CALLS="$BATS_TEST_TMPDIR/calls.log"
  mkdir -p "$STUBS"
  : > "$CALLS"
  local name
  for name in launchctl claude-codex; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$name" "$CALLS" > "$STUBS/$name"
    chmod +x "$STUBS/$name"
  done
  PATH="$STUBS:$PATH"
}

render_plist() {
  chez init --source "$SRC" --promptString machineClass=mac > /dev/null
  chez execute-template --source "$SRC" < "$PLIST_TMPL" > "$BATS_TEST_TMPDIR/out.plist"
}

# Print the rendered plist's value for the python expression $1 (it sees `p`).
plist_get() {
  "$PY" -I -c 'import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
print(eval(sys.argv[2]))' "$BATS_TEST_TMPDIR/out.plist" "$1"
}

@test "the plist renders to the specified service, inactive, with home-relative paths" {
  render_plist
  command -v plutil > /dev/null 2>&1 && plutil -lint "$BATS_TEST_TMPDIR/out.plist"
  [ "$(plist_get 'p["Label"]')" = local.claude-codex ]
  [ "$(plist_get 'p["Disabled"]')" = True ]
  [ "$(plist_get 'p["KeepAlive"]')" = True ]
  [ "$(plist_get 'p["ThrottleInterval"]')" = 30 ]
  [ "$(plist_get 'p["WorkingDirectory"]')" = "$TMPHOME" ]
  # One element per argument, so the space in the home cannot split the path.
  [ "$(plist_get 'len(p["ProgramArguments"])')" = 5 ]
  [ "$(plist_get 'p["ProgramArguments"][0]')" = "$TMPHOME/.cargo/bin/claude-codex" ]
  [ "$(plist_get 'p["ProgramArguments"][1:]')" = "['serve', '--port', '18765', '--no-monitor']" ]
  [ "$(plist_get 'sorted(p["EnvironmentVariables"])')" = "['CCP_ALIAS_PROVIDER', 'CCP_ANTHROPIC_BASE_URL', 'CCP_BIND_ADDRESS', 'CCP_CONFIG_DIR', 'HOME']" ]
  [ "$(plist_get 'p["EnvironmentVariables"]["HOME"]')" = "$TMPHOME" ]
  [ "$(plist_get 'p["EnvironmentVariables"]["CCP_CONFIG_DIR"]')" = "$TMPHOME/.config/claude-codex" ]
  [ "$(plist_get 'p["EnvironmentVariables"]["CCP_BIND_ADDRESS"]')" = 127.0.0.1 ]
  [ "$(plist_get 'p["EnvironmentVariables"]["CCP_ALIAS_PROVIDER"]')" = anthropic ]
  [ "$(plist_get 'p["EnvironmentVariables"]["CCP_ANTHROPIC_BASE_URL"]')" = https://api.anthropic.com ]
}

@test "the plist names no credential, no other endpoint and no traffic capture" {
  render_plist
  ! grep -Ei 'token|api_key|secret|password|capture|CCP_AUTH' "$BATS_TEST_TMPDIR/out.plist"
  grep -q '<string>127.0.0.1</string>' "$BATS_TEST_TMPDIR/out.plist"
  ! grep -q '0\.0\.0\.0' "$BATS_TEST_TMPDIR/out.plist"
}

@test "the managed proxy configuration is exactly an empty JSON object" {
  [ "$("$PY" -I -c 'import json, sys; print(json.load(open(sys.argv[1])) == {})' "$SRC/dot_config/claude-codex/config.json")" = True ]
}

@test "the plist is ignored unless the OS is darwin and the class is mac; the config on ephemeral" {
  chez init --source "$SRC" --promptString machineClass=mac > /dev/null
  fake_proxy_install
  local os cls rendered
  for os in darwin linux; do
    for cls in mac linux wsl ephemeral; do
      rendered="$(chez execute-template --source "$SRC" \
        --override-data "{\"machineClass\":\"$cls\",\"chezmoi\":{\"os\":\"$os\"}}" < "$SRC/.chezmoiignore")"
      if [ "$os" = darwin ] && [ "$cls" = mac ]; then
        ! grep -qxF 'Library/LaunchAgents/local.claude-codex.plist' <<< "$rendered" || { echo "$os/$cls ignores the plist"; false; }
      else
        grep -qxF 'Library/LaunchAgents/local.claude-codex.plist' <<< "$rendered" || { echo "$os/$cls deploys the plist"; false; }
      fi
      if [ "$cls" = ephemeral ]; then
        grep -qxF '.config/claude-codex' <<< "$rendered" || { echo "$os/$cls deploys the config"; false; }
      else
        ! grep -qxF '.config/claude-codex' <<< "$rendered" || { echo "$os/$cls ignores the config"; false; }
      fi
    done
  done
}

@test "without the proxy installed the plist is ignored even on a mac-class Mac" {
  chez init --source "$SRC" --promptString machineClass=mac > /dev/null
  local rendered
  rendered="$(chez execute-template --source "$SRC" \
    --override-data '{"machineClass":"mac","chezmoi":{"os":"darwin"}}' < "$SRC/.chezmoiignore")"
  grep -qxF 'Library/LaunchAgents/local.claude-codex.plist' <<< "$rendered" \
    || { echo "the plist deploys with no claude-codex installed"; false; }
}

@test "a mac-class apply deploys the config, the plist only on macOS, and never calls launchctl or the proxy" {
  cd "$SRC"
  fake_proxy_install
  chez init --source "$SRC" --promptString machineClass=mac --apply --exclude scripts
  [ "$(cat "$TMPHOME/.config/claude-codex/config.json")" = '{}' ]
  if [ "$(uname -s)" = Darwin ]; then
    local deployed="$TMPHOME/Library/LaunchAgents/local.claude-codex.plist"
    [ -f "$deployed" ]
    command -v plutil > /dev/null 2>&1 && plutil -lint "$deployed"
    cp "$deployed" "$BATS_TEST_TMPDIR/out.plist"
    [ "$(plist_get 'p["Disabled"]')" = True ]
  else
    [ ! -e "$TMPHOME/Library/LaunchAgents/local.claude-codex.plist" ]
  fi
  [ ! -s "$CALLS" ] || { cat "$CALLS"; false; }
}

@test "an ephemeral apply deploys neither the config nor the plist" {
  cd "$SRC"
  chez init --source "$SRC" --promptString machineClass=ephemeral --apply --exclude scripts
  [ ! -e "$TMPHOME/.config/claude-codex" ]
  [ ! -e "$TMPHOME/Library/LaunchAgents/local.claude-codex.plist" ]
  [ ! -s "$CALLS" ] || { cat "$CALLS"; false; }
}

@test "a linux-class apply deploys the config and no LaunchAgent" {
  cd "$SRC"
  chez init --source "$SRC" --promptString machineClass=linux --apply --exclude scripts
  [ "$(cat "$TMPHOME/.config/claude-codex/config.json")" = '{}' ]
  [ ! -e "$TMPHOME/Library/LaunchAgents/local.claude-codex.plist" ]
  [ ! -s "$CALLS" ] || { cat "$CALLS"; false; }
}

@test "no systemd unit is shipped, and no chezmoi script or wrapper loads the service" {
  [ -z "$(git -C "$SRC" ls-files '*.service' '*systemd*')" ]
  ! grep -rn 'launchctl' "$SRC/.chezmoiscripts" "$SRC/dot_functions" "$SRC/dot_zshrc" "$SRC/dot_exports"
}
