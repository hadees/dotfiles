#!/usr/bin/env bats

# How claude() chooses its endpoint (dot_functions, docs/claude-proxy.md): the
# claude-codex proxy on loopback when it is installed and healthy, direct to
# Anthropic otherwise, a caller's own route left alone. The health check is a
# stubbed curl and the proxy is an empty executable: the endpoint is fixed at
# 127.0.0.1:18765, so nothing here may open a real connection to it (a real
# proxy may be running there). The `claude` stub prints what it was handed.
# The stderr notices are said only to an attended launch, so the tests about
# them run on a pseudo-terminal (`pty_zrun`, both streams in $output).

bats_require_minimum_version 1.5.0

setup() {
  # python3 resolved before HOME is sandboxed (an asdf shim fails under a fake HOME).
  REAL_PYTHON3=''
  REAL_PYTHON3="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)" || REAL_PYTHON3=''
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin" "$HOME/.cargo/bin"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  unset CLAUDE_PROFILE CLAUDE_CONFIG_DIR BROWSER OPEN_AS_ALIAS SSH_CONNECTION \
    CLAUDE_CODEX_PROXY CLAUDE_CODEX_ROUTE CLAUDE_CODEX_REASON CLAUDECODE \
    ANTHROPIC_BASE_URL ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_UNIX_SOCKET \
    CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY \
    CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING \
    ENABLE_TOOL_SEARCH CLAUDE_CODE_GATEWAY_HINT_HEADERS ITERM_SESSION_ID
  # No iTerm2 line on any launch.
  mkdir -p "$HOME/.local/state/iterm2"
  : > "$HOME/.local/state/iterm2/api-cookie"
  export ITERM2_APP="$BATS_TEST_TMPDIR/no-iterm2.app"

  # claude: report the routing environment and arguments, exit as told.
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'EOF'
#!/bin/sh
echo "ROUTE=${CLAUDE_CODEX_ROUTE-UNSET} REASON=${CLAUDE_CODEX_REASON-UNSET} URL=${ANTHROPIC_BASE_URL-UNSET}"
echo "FG=${CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING-UNSET} TS=${ENABLE_TOOL_SEARCH-UNSET} HINT=${CLAUDE_CODE_GATEWAY_HINT_HEADERS-UNSET}"
echo "KEY=${ANTHROPIC_API_KEY-UNSET} TOKEN=${ANTHROPIC_AUTH_TOKEN-UNSET} ARGS=$*"
exit "${STUB_CLAUDE_EXIT:-0}"
EOF
  # curl: answers per $BATS_TEST_TMPDIR/curl.mode and records its arguments.
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'EOF'
#!/bin/sh
printf "%s\n" "$*" >> "$BATS_TEST_TMPDIR/curl.args"
case "$(cat "$BATS_TEST_TMPDIR/curl.mode" 2>/dev/null)" in
  down) exit 7;;
  wrong-body) printf '<html>nope</html>\n200';;
  wrong-status) printf '{"ok":true}\n503';;
  *) printf '{"ok":true}\n200';;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/claude" "$BATS_TEST_TMPDIR/bin/curl"
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.cargo/bin/claude-codex"
  chmod +x "$HOME/.cargo/bin/claude-codex"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  DOTFUNCTIONS="$BATS_TEST_DIRNAME/../dot_functions"
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q "$REPO"
  OPTOUT_LINE='claude: direct by opt-out for Remote Control; GPT agents unavailable in this session.'
}

# Run zsh code with the wrapper sourced, stdout and stderr kept apart.
zrun() {
  run --separate-stderr zsh -c "source '$DOTFUNCTIONS'; cd '$REPO'; $1"
}

# The same on a pseudo-terminal, which is what makes a launch attended. Both
# streams arrive in $output, carriage returns stripped.
pty_zrun() {
  [ -n "$REAL_PYTHON3" ] || skip "python3 not installed"
  run "$REAL_PYTHON3" -I -c '
import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    os.execvp("zsh", ["zsh", "-c", sys.argv[1]])
while True:
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    sys.stdout.buffer.write(data)
os.waitpid(pid, 0)
' "source '$DOTFUNCTIONS'; cd '$REPO'; $1"
  output=${output//$'\r'/}
}

not_probed() { [ ! -e "$BATS_TEST_TMPDIR/curl.args" ]; }

@test "routed: a healthy proxy gets the loopback URL, the markers and the gateway defaults, quietly" {
  zrun 'claude one --two'
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "${lines[0]}" == "ROUTE=routed REASON=healthy URL=http://127.0.0.1:18765" ]]
  [[ "${lines[1]}" == "FG=1 TS=true HINT=1" ]]
  [[ "${lines[2]}" == *"ARGS=one --two" ]]
  # No credential is invented.
  [[ "${lines[2]}" == "KEY=UNSET TOKEN=UNSET "* ]]
}

@test "routed: the probe is a bare, proxy-free, credential-free, bounded curl with no redirects" {
  zrun 'claude'
  read -r args < "$BATS_TEST_TMPDIR/curl.args"
  [[ "$args" == "-q --noproxy * "* ]]
  [[ "$args" == *"--connect-timeout 1 --max-time 1"* ]]
  [[ "$args" == *"http://127.0.0.1:18765/healthz" ]]
  [[ "$args" != *" -L"* && "$args" != *"--location"* && "$args" != *"-H"* && "$args" != *"--user"* ]]
}

@test "routed: a caller's own gateway defaults stand, and a trailing slash is still ours" {
  zrun 'ENABLE_TOOL_SEARCH=false CLAUDE_CODE_GATEWAY_HINT_HEADERS=0 CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING=0 CLAUDE_CODEX_ROUTE=routed ANTHROPIC_BASE_URL=http://127.0.0.1:18765/ claude'
  [ -z "$stderr" ]
  [[ "${lines[0]}" == "ROUTE=routed REASON=healthy URL=http://127.0.0.1:18765" ]]
  [[ "${lines[1]}" == "FG=0 TS=false HINT=0" ]]
}

@test "routed: CLAUDE_CODEX_PROXY=1 and an empty value route like an unset one" {
  zrun 'CLAUDE_CODEX_PROXY=1 claude'
  [[ "${lines[0]}" == "ROUTE=routed "* ]]
  zrun 'CLAUDE_CODEX_PROXY= claude'
  [[ "${lines[0]}" == "ROUTE=routed "* ]]
}

@test "opt-out: one line naming Remote Control, even where the proxy was never installed" {
  pty_zrun 'CLAUDE_CODEX_PROXY=0 claude'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$OPTOUT_LINE"* ]]
  [[ "$output" == *"ROUTE=direct REASON=opt-out URL=UNSET"* ]]
  not_probed
  rm "$HOME/.cargo/bin/claude-codex"
  pty_zrun 'CLAUDE_CODEX_PROXY=0 claude'
  [[ "$output" == *"$OPTOUT_LINE"* ]]
}

@test "opt-out: direct, no base URL, no gateway defaults, no probe" {
  zrun 'CLAUDE_CODEX_PROXY=0 claude'
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "ROUTE=direct REASON=opt-out URL=UNSET" ]]
  [[ "${lines[1]}" == "FG=UNSET TS=UNSET HINT=UNSET" ]]
  not_probed
}

@test "opt-out: clears this integration's inherited loopback URL, but keeps no one else's" {
  zrun 'CLAUDE_CODEX_PROXY=0 CLAUDE_CODEX_ROUTE=routed ANTHROPIC_BASE_URL=http://127.0.0.1:18765 claude'
  [[ "${lines[0]}" == "ROUTE=direct REASON=opt-out URL=UNSET" ]]
  zrun 'CLAUDE_CODEX_PROXY=0 ANTHROPIC_BASE_URL=http://127.0.0.1:9999 claude'
  [[ "${lines[0]}" == "ROUTE=external REASON=external-base-url URL=http://127.0.0.1:9999" ]]
}

@test "not installed: no executable means direct with one line, and no probe" {
  rm "$HOME/.cargo/bin/claude-codex"
  zrun 'claude hello'
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "${lines[0]}" == "ROUTE=direct REASON=not-installed URL=UNSET" ]]
  [[ "${lines[2]}" == *"ARGS=hello" ]]
  not_probed
}

@test "not installed: silent even on an attended launch, with or without the mode set" {
  rm "$HOME/.cargo/bin/claude-codex"
  pty_zrun 'claude --hello'
  [[ "$output" == "ROUTE=direct REASON=not-installed"* ]]
  [[ "$output" != *"claude: "* ]]
  pty_zrun 'CLAUDE_CODEX_PROXY=1 claude --hello'
  [[ "$output" != *"claude: "* ]]
}

@test "not installed: a non-executable file does not count as installed" {
  chmod -x "$HOME/.cargo/bin/claude-codex"
  zrun 'claude'
  [[ "${lines[0]}" == "ROUTE=direct REASON=not-installed "* ]]
}

@test "down: an unreachable proxy launches direct with one line" {
  echo down > "$BATS_TEST_TMPDIR/curl.mode"
  pty_zrun 'claude'
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude: direct because proxy is unreachable; GPT agents unavailable in this session."* ]]
  [[ "$output" == *"ROUTE=direct REASON=unreachable URL=UNSET"* ]]
}

@test "notice: not said to an unattended, print or subcommand launch, or when claude.proxy-check is false" {
  echo down > "$BATS_TEST_TMPDIR/curl.mode"
  zrun 'claude'
  [ -z "$stderr" ]
  pty_zrun 'claude -p hi'
  [[ "$output" == *"REASON=unreachable"* && "$output" != *"claude: direct"* ]]
  pty_zrun 'claude mcp list'
  [[ "$output" == *"REASON=unreachable"* && "$output" != *"claude: direct"* ]]
  pty_zrun 'claude'
  [[ "$output" == *"claude: direct because proxy is unreachable"* ]]
  git config --file "$GIT_CONFIG_GLOBAL" claude.proxy-check false
  pty_zrun 'claude'
  [[ "$output" == *"REASON=unreachable"* && "$output" != *"claude: direct"* ]]
  pty_zrun 'CLAUDE_CODEX_PROXY=0 claude'
  [[ "$output" == *"ROUTE=direct REASON=opt-out"* && "$output" != *"claude: direct"* ]]
}

@test "notice: without the executable or the mode, a caller's own route and credentials are not remarked on" {
  rm "$HOME/.cargo/bin/claude-codex"
  pty_zrun 'ANTHROPIC_BASE_URL=https://gw.example.test claude'
  [[ "$output" == *"ROUTE=external"* && "$output" != *"claude: "* ]]
  pty_zrun 'CLAUDE_CODE_USE_BEDROCK=1 claude'
  [[ "$output" == *"ROUTE=external"* && "$output" != *"claude: "* ]]
  pty_zrun 'ANTHROPIC_API_KEY=sk-fixture claude'
  [[ "$output" == *"REASON=credential-override"* && "$output" != *"claude: "* ]]
  # Setting the mode is opting in, even to a mistake.
  pty_zrun 'CLAUDE_CODEX_PROXY=maybe claude'
  [[ "$output" == *"claude: direct because CLAUDE_CODEX_PROXY is neither 0 nor 1"* ]]
}

@test "unexpected health: a wrong body or a wrong status launches direct with its own reason" {
  echo wrong-body > "$BATS_TEST_TMPDIR/curl.mode"
  pty_zrun 'claude'
  [[ "$output" == *"claude: direct because the proxy answered its health check unexpectedly; GPT agents unavailable in this session."* ]]
  [[ "$output" == *"ROUTE=direct REASON=unexpected-health URL=UNSET"* ]]
  echo wrong-status > "$BATS_TEST_TMPDIR/curl.mode"
  zrun 'claude'
  [[ "${lines[0]}" == "ROUTE=direct REASON=unexpected-health URL=UNSET" ]]
}

@test "missing curl: the probe says so, and the launch goes direct" {
  rm "$BATS_TEST_TMPDIR/bin/curl"
  # PATH without any curl: zsh and git by absolute path, claude from the stub dir.
  mkdir -p "$BATS_TEST_TMPDIR/nocurl"
  ln -s "$BATS_TEST_TMPDIR/bin/claude" "$BATS_TEST_TMPDIR/nocurl/claude"
  ln -s "$(command -v git)" "$BATS_TEST_TMPDIR/nocurl/git"
  run --separate-stderr "$(command -v zsh)" -c "PATH='$BATS_TEST_TMPDIR/nocurl'; source '$DOTFUNCTIONS'; cd '$REPO'; claude_proxy_probe; echo probe=\$? \$REPLY; claude"
  [[ "${lines[0]}" == "probe=1 missing-curl" ]]
  [[ "${lines[1]}" == "ROUTE=direct REASON=missing-curl URL=UNSET" ]]
  zrun 'claude_proxy_notice missing-curl'
  [ "${lines[0]}" = "claude: direct because curl is missing, so the proxy cannot be checked; GPT agents unavailable in this session." ]
}

@test "external: a nonlocal base URL is preserved, named without its value, and never probed" {
  pty_zrun 'ANTHROPIC_BASE_URL="https://gw.example.test/v1?token=hunter2" claude'
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude: external base URL preserved; GPT routing is unverified in this session."* ]]
  [[ "$output" == *"ROUTE=external REASON=external-base-url URL=https://gw.example.test/v1?token=hunter2"* ]]
  [[ "$output" == *"FG=UNSET TS=UNSET HINT=UNSET"* ]]
  [[ "$(printf '%s\n' "$output" | grep '^claude:')" != *hunter2* ]]
  not_probed
}

@test "external: a loopback URL on our port is the caller's own proxy unless the routed marker came with it" {
  rm "$HOME/.cargo/bin/claude-codex"
  zrun 'ANTHROPIC_BASE_URL=http://127.0.0.1:18765 claude'
  [[ "${lines[0]}" == "ROUTE=external REASON=external-base-url URL=http://127.0.0.1:18765" ]]
  zrun 'ANTHROPIC_BASE_URL=http://127.0.0.1:18765 CLAUDE_CODEX_ROUTE=direct claude'
  [[ "${lines[0]}" == "ROUTE=external REASON=external-base-url URL=http://127.0.0.1:18765" ]]
  not_probed
  # With the marker it is ours, and a launch that cannot route drops it.
  zrun 'ANTHROPIC_BASE_URL=http://127.0.0.1:18765 CLAUDE_CODEX_ROUTE=routed claude'
  [[ "${lines[0]}" == "ROUTE=direct REASON=not-installed URL=UNSET" ]]
}

@test "external: an Anthropic Unix socket and each enabled provider selector are preserved" {
  zrun 'ANTHROPIC_UNIX_SOCKET=/tmp/s.sock claude'
  [[ "${lines[0]}" == "ROUTE=external REASON=external-base-url URL=UNSET" ]]
  for v in CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS; do
    pty_zrun "$v=1 claude"
    [[ "$output" == *"claude: external provider preserved; GPT routing is unverified in this session."* ]]
    [[ "$output" == *"ROUTE=external REASON=external-provider "* ]]
  done
}

@test "external: false and empty provider spellings are disabled" {
  for v in '' 0 false FALSE no off; do
    zrun "CLAUDE_CODE_USE_BEDROCK='$v' claude"
    [[ "${lines[0]}" == "ROUTE=routed "* ]]
  done
}

@test "credentials: an API key or auth token declines routing and is passed on untouched" {
  pty_zrun 'ANTHROPIC_API_KEY=sk-fixture claude'
  [[ "$output" == *"claude: direct because an API key or auth token is set; GPT agents unavailable in this session."* ]]
  [[ "$output" == *"ROUTE=direct REASON=credential-override URL=UNSET"* ]]
  [[ "$output" == *"KEY=sk-fixture TOKEN=UNSET "* ]]
  zrun 'ANTHROPIC_AUTH_TOKEN=tok-fixture claude'
  [[ "${lines[2]}" == "KEY=UNSET TOKEN=tok-fixture "* ]]
  not_probed
}

@test "invalid mode: anything but 0, 1 or empty goes direct and says so" {
  pty_zrun 'CLAUDE_CODEX_PROXY=maybe claude'
  [[ "$output" == *"claude: direct because CLAUDE_CODEX_PROXY is neither 0 nor 1; GPT agents unavailable in this session."* ]]
  [[ "$output" == *"ROUTE=direct REASON=invalid-mode URL=UNSET"* ]]
}

@test "a missing or failing decision helper launches direct with helper-error, never aborts" {
  pty_zrun 'unfunction claude_proxy_decide; claude --go'
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude: direct because the routing helper failed; GPT agents unavailable in this session."* ]]
  [[ "$output" == *"ROUTE=direct REASON=helper-error URL=UNSET"* ]]
  zrun 'unfunction claude_proxy_probe; claude go'
  [[ "${lines[0]}" == "ROUTE=direct REASON=helper-error URL=UNSET" ]]
  zrun 'unfunction claude_proxy_notice; claude go'
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "ROUTE=routed "* ]]
}

@test "help and version flags route nothing, probe nothing and say nothing" {
  rm "$HOME/.cargo/bin/claude-codex"
  for flag in --version -v --help -h; do
    zrun "claude $flag"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [[ "${lines[0]}" == "ROUTE=UNSET REASON=UNSET URL=UNSET" ]]
  done
  not_probed
}

@test "a launch recomputes: inherited markers and loopback URL do not outlive a dead proxy" {
  echo down > "$BATS_TEST_TMPDIR/curl.mode"
  zrun 'CLAUDE_CODEX_ROUTE=routed CLAUDE_CODEX_REASON=healthy ANTHROPIC_BASE_URL=http://127.0.0.1:18765 claude'
  [[ "${lines[0]}" == "ROUTE=direct REASON=unreachable URL=UNSET" ]]
  echo ok > "$BATS_TEST_TMPDIR/curl.mode"
  zrun 'CLAUDE_CODEX_ROUTE=direct CLAUDE_CODEX_REASON=opt-out claude'
  [[ "${lines[0]}" == "ROUTE=routed REASON=healthy URL=http://127.0.0.1:18765" ]]
}

@test "the launch keeps its arguments, stdout and exit status" {
  zrun 'STUB_CLAUDE_EXIT=3 claude -p "a b" --flag'
  [ "$status" -eq 3 ]
  [[ "${lines[2]}" == *'ARGS=-p a b --flag' ]]
  [ ${#lines[@]} -eq 3 ]
  zrun 'STUB_CLAUDE_EXIT=4 CLAUDE_CODEX_PROXY=0 claude'
  [ "$status" -eq 4 ]
  [ ${#lines[@]} -eq 3 ]
}

@test "the launch does not leak its routing into the calling shell" {
  zrun 'claude >/dev/null; print -r -- "[${CLAUDE_CODEX_ROUTE-}${ANTHROPIC_BASE_URL-}]"'
  [ "${lines[-1]}" = "[]" ]
}

@test "session: no markers is unmarked-session, and markers that disagree are state-mismatch" {
  zrun 'claude_proxy_session; print -r -- "rc=$? ${(j:|:)reply}"'
  [ "${lines[0]}" = "rc=0 |unmarked-session|" ]
  # A routed marker without the loopback URL, a direct marker with a URL, an unknown route.
  zrun 'CLAUDE_CODEX_ROUTE=routed CLAUDE_CODEX_REASON=healthy; claude_proxy_session; print -r -- "rc=$? ${(j:|:)reply}"'
  [ "${lines[0]}" = "rc=2 |state-mismatch|" ]
  zrun 'CLAUDE_CODEX_ROUTE=direct CLAUDE_CODEX_REASON=opt-out ANTHROPIC_BASE_URL=http://127.0.0.1:18765; claude_proxy_session; print -r -- "rc=$? ${(j:|:)reply}"'
  [ "${lines[0]}" = "rc=2 |state-mismatch|" ]
  zrun 'CLAUDE_CODEX_ROUTE=routed CLAUDE_CODEX_REASON=healthy ANTHROPIC_BASE_URL=http://127.0.0.1:18765 CLAUDE_CODE_USE_VERTEX=1; claude_proxy_session; print -r -- "rc=$? ${(j:|:)reply}"'
  [ "${lines[0]}" = "rc=2 |state-mismatch|" ]
  zrun 'CLAUDE_CODEX_ROUTE=external CLAUDE_CODEX_REASON=external-base-url; claude_proxy_session; print -r -- "rc=$? ${(j:|:)reply}"'
  [ "${lines[0]}" = "rc=2 |state-mismatch|" ]
  zrun 'CLAUDE_CODEX_ROUTE=sideways CLAUDE_CODEX_REASON=healthy; claude_proxy_session; print -r -- "rc=$? ${(j:|:)reply}"'
  [ "${lines[0]}" = "rc=2 |state-mismatch|" ]
  zrun 'CLAUDE_CODEX_ROUTE=routed CLAUDE_CODEX_REASON=unreachable ANTHROPIC_BASE_URL=http://127.0.0.1:18765; claude_proxy_session; print -r -- "rc=$? ${(j:|:)reply}"'
  [ "${lines[0]}" = "rc=2 |state-mismatch|" ]
  not_probed
}

@test "session: each consistent state is read back as launched, without probing" {
  zrun 'CLAUDE_CODEX_ROUTE=routed CLAUDE_CODEX_REASON=healthy ANTHROPIC_BASE_URL=http://127.0.0.1:18765/; claude_proxy_session; print -r -- "rc=$? ${(j:|:)reply}"'
  [ "${lines[0]}" = "rc=0 routed|healthy|http://127.0.0.1:18765" ]
  zrun 'CLAUDE_CODEX_ROUTE=direct CLAUDE_CODEX_REASON=not-installed; claude_proxy_session; print -r -- "rc=$? ${(j:|:)reply}"'
  [ "${lines[0]}" = "rc=0 direct|not-installed|" ]
  zrun 'CLAUDE_CODEX_ROUTE=external CLAUDE_CODEX_REASON=external-provider CLAUDE_CODE_USE_BEDROCK=1; claude_proxy_session; print -r -- "rc=$? ${(j:|:)reply}"'
  [ "${lines[0]}" = "rc=0 external|external-provider|" ]
  not_probed
}

@test "decide: a missing probe or external helper is an internal failure, not a decision" {
  zrun 'unfunction claude_proxy_probe; claude_proxy_decide; print -r -- "rc=$?"'
  [ "${lines[0]}" = "rc=2" ]
  zrun 'unfunction claude_proxy_external; claude_proxy_decide; print -r -- "rc=$?"'
  [ "${lines[0]}" = "rc=2" ]
}

@test "preflight: a routed, answering session is ready, and the line says authentication is untested" {
  zrun 'CLAUDE_CODEX_ROUTE=routed CLAUDE_CODEX_REASON=healthy ANTHROPIC_BASE_URL=http://127.0.0.1:18765; claude_gpt_ready gpt-6-astra; print -r -- "rc=$?"'
  [ "${lines[0]}" = "GPT_ROUTE_READY model=gpt-6-astra auth=untested" ]
  [ "${lines[1]}" = "rc=0" ]
  [ -z "$stderr" ]
}

@test "preflight: a routed session whose daemon died is unavailable, not direct" {
  echo down > "$BATS_TEST_TMPDIR/curl.mode"
  zrun 'CLAUDE_CODEX_ROUTE=routed CLAUDE_CODEX_REASON=healthy ANTHROPIC_BASE_URL=http://127.0.0.1:18765; claude_gpt_ready gpt-6-astra; print -r -- "rc=$?"; claude_proxy_session; print -r -- "${reply[1]}"'
  [ "${lines[0]}" = "GPT_ROUTE_UNAVAILABLE reason=unreachable" ]
  [ "${lines[1]}" = "rc=1" ]
  [ "${lines[2]}" = "routed" ]
}

@test "preflight: a session that started direct stays unavailable when the daemon recovers" {
  zrun 'CLAUDE_CODEX_ROUTE=direct CLAUDE_CODEX_REASON=unreachable; claude_gpt_ready gpt-6-astra; print -r -- "rc=$?"'
  [ "${lines[0]}" = "GPT_ROUTE_UNAVAILABLE reason=unreachable" ]
  [ "${lines[1]}" = "rc=1" ]
  not_probed
}

@test "preflight: opt-out, external, unmarked and mismatched sessions each name their reason" {
  zrun 'CLAUDE_CODEX_ROUTE=direct CLAUDE_CODEX_REASON=opt-out; claude_gpt_ready gpt-x'
  [ "${lines[0]}" = "GPT_ROUTE_UNAVAILABLE reason=opt-out" ]
  zrun 'CLAUDE_CODEX_ROUTE=external CLAUDE_CODEX_REASON=external-base-url ANTHROPIC_BASE_URL=https://gw.example.test; claude_gpt_ready gpt-x'
  [ "${lines[0]}" = "GPT_ROUTE_UNAVAILABLE reason=external-base-url" ]
  zrun 'claude_gpt_ready gpt-x; print -r -- "rc=$?"'
  [ "${lines[0]}" = "GPT_ROUTE_UNAVAILABLE reason=unmarked-session" ]
  [ "${lines[1]}" = "rc=1" ]
  zrun 'CLAUDE_CODEX_ROUTE=routed CLAUDE_CODEX_REASON=healthy; claude_gpt_ready gpt-x'
  [ "${lines[0]}" = "GPT_ROUTE_UNAVAILABLE reason=state-mismatch" ]
}

@test "preflight: it never decides a launch again" {
  # With decide gone a decision-based preflight would report helper-error.
  zrun 'unfunction claude_proxy_decide; CLAUDE_CODEX_ROUTE=routed CLAUDE_CODEX_REASON=healthy ANTHROPIC_BASE_URL=http://127.0.0.1:18765; claude_gpt_ready gpt-6-astra'
  [ "${lines[0]}" = "GPT_ROUTE_READY model=gpt-6-astra auth=untested" ]
}

@test "preflight: a bad model id is an error, and so is a missing helper" {
  for m in '' sonnet gpt- 'gpt-6 astra' 'gpt-6;x' -gpt-6 GPT-6; do
    zrun "claude_gpt_ready '$m'; print -r -- \"rc=\$?\""
    [ "${lines[0]}" = "GPT_ROUTE_ERROR reason=invalid-model" ]
    [ "${lines[1]}" = "rc=2" ]
  done
  zrun 'claude_gpt_ready gpt-6-astra.1_b; print -r -- "rc=$?"'
  [ "${lines[0]}" = "GPT_ROUTE_UNAVAILABLE reason=unmarked-session" ]
  zrun 'unfunction claude_proxy_session; claude_gpt_ready gpt-6-astra; print -r -- "rc=$?"'
  [ "${lines[0]}" = "GPT_ROUTE_ERROR reason=helper-error" ]
  [ "${lines[1]}" = "rc=2" ]
  zrun 'unfunction claude_proxy_external; claude_gpt_ready gpt-6-astra; print -r -- "rc=$?"'
  [ "${lines[0]}" = "GPT_ROUTE_ERROR reason=helper-error" ]
  [ "${lines[1]}" = "rc=2" ]
}

@test "helpers print nothing: probe, decide and session only set their results" {
  zrun 'claude_proxy_probe; claude_proxy_decide; claude_proxy_session'
  [ -z "$output" ]
  [ -z "$stderr" ]
}

# --- claude-doctor ---------------------------------------------------------

doctor_line() {
  zrun "$1; claude-doctor"
  proxy_line=$(printf '%s\n' "$output" | grep '^proxy:')
}

@test "doctor: a routed session reports health, and a dead daemon makes GPT unavailable, still routed" {
  doctor_line 'export CLAUDE_CODEX_ROUTE=routed CLAUDE_CODEX_REASON=healthy ANTHROPIC_BASE_URL=http://127.0.0.1:18765'
  [ "$proxy_line" = "proxy:   scope=session mode=routed reason=healthy health=ok; GPT route ready, authentication untested" ]
  echo down > "$BATS_TEST_TMPDIR/curl.mode"
  doctor_line 'export CLAUDE_CODEX_ROUTE=routed CLAUDE_CODEX_REASON=healthy ANTHROPIC_BASE_URL=http://127.0.0.1:18765'
  [ "$proxy_line" = "proxy:   scope=session mode=routed reason=healthy health=unreachable; GPT unavailable" ]
}

@test "doctor: direct sessions say why, and the opt-out names Remote Control" {
  doctor_line 'export CLAUDE_CODEX_ROUTE=direct CLAUDE_CODEX_REASON=opt-out'
  [ "$proxy_line" = "proxy:   scope=session mode=direct reason=opt-out; Remote Control direct launch; GPT unavailable" ]
  doctor_line 'export CLAUDE_CODEX_ROUTE=direct CLAUDE_CODEX_REASON=not-installed'
  [ "$proxy_line" = "proxy:   scope=session mode=direct reason=not-installed; GPT unavailable" ]
  doctor_line 'export CLAUDE_CODEX_ROUTE=direct CLAUDE_CODEX_REASON=unreachable'
  [ "$proxy_line" = "proxy:   scope=session mode=direct reason=unreachable; GPT unavailable" ]
  # A direct session is never probed, so a recovered daemon cannot change it.
  not_probed
}

@test "doctor: an external session is unverified, and never prints the URL" {
  doctor_line 'export CLAUDE_CODEX_ROUTE=external CLAUDE_CODEX_REASON=external-base-url ANTHROPIC_BASE_URL="https://gw.example.test/?k=hunter2"'
  [ "$proxy_line" = "proxy:   scope=session mode=external reason=external-base-url; GPT route unverified" ]
  [[ "$output" != *hunter2* ]]
}

@test "doctor: outside a session it predicts the next launch, labelled as such" {
  doctor_line 'true'
  [ "$proxy_line" = "proxy:   scope=next-launch mode=routed reason=healthy health=ok" ]
  rm "$HOME/.cargo/bin/claude-codex"
  doctor_line 'true'
  [ "$proxy_line" = "proxy:   scope=next-launch mode=direct reason=not-installed" ]
  doctor_line 'export CLAUDE_CODEX_PROXY=0'
  [ "$proxy_line" = "proxy:   scope=next-launch mode=direct reason=opt-out" ]
}

@test "doctor: inside Claude Code without markers the session is unverified, not predicted" {
  doctor_line 'export CLAUDECODE=1'
  [[ "$proxy_line" == "proxy:   scope=session mode=unknown reason=unmarked-session; unverified"* ]]
  doctor_line 'export CLAUDECODE=1 CLAUDE_CODEX_ROUTE=routed CLAUDE_CODEX_REASON=healthy'
  [[ "$proxy_line" == "proxy:   scope=session mode=unknown reason=state-mismatch; unverified"* ]]
}

@test "doctor: the binary line shows the path, the pin and the Cargo metadata, or unknown" {
  zrun 'claude-doctor'
  [[ "$output" == *"proxybin: ~/.cargo/bin/claude-codex (present); pinned 0.8.0, installed unknown (Cargo metadata, executable not run)"* ]]
  cat > "$HOME/.cargo/.crates.toml" <<'EOF'
[v1]
"other-tool 1.2.3 (registry+https://github.com/rust-lang/crates.io-index)" = ["other-tool"]
"claude-codex 0.8.0 (registry+https://github.com/rust-lang/crates.io-index)" = ["claude-codex"]
EOF
  zrun 'claude-doctor'
  [[ "$output" == *"installed 0.8.0 (Cargo metadata"* ]]
  rm "$HOME/.cargo/bin/claude-codex"
  zrun 'claude-doctor'
  [[ "$output" == *"proxybin: ~/.cargo/bin/claude-codex (not installed; optional, see docs/claude-proxy.md); pinned"* ]]
  # MISSING only where something should have installed it.
  zrun 'CLAUDE_CODEX_PROXY=1 claude-doctor'
  [[ "$output" == *"proxybin: ~/.cargo/bin/claude-codex (MISSING)"* ]]
  # Opting out is not a reason it should have been installed.
  zrun 'CLAUDE_CODEX_PROXY=0 claude-doctor'
  [[ "$output" == *"proxybin: ~/.cargo/bin/claude-codex (not installed; optional"* ]]
  mkdir -p "$HOME/Library/LaunchAgents"
  : > "$HOME/Library/LaunchAgents/local.claude-codex.plist"
  zrun 'claude-doctor'
  [[ "$output" == *"proxybin: ~/.cargo/bin/claude-codex (MISSING)"* ]]
}

@test "doctor: with a routing helper gone it says so and still prints the rest" {
  zrun 'unfunction claude_proxy_session; claude-doctor'
  [[ "$output" == *"defined: MISSING claude_proxy_session"* ]]
  [[ "$output" == *"proxy:   unknown: the routing helpers are not defined"* ]]
  [[ "$output" == *"proxybin:"* ]]
}
