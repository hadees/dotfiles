#!/usr/bin/env bats

# bin/tailnet runs one userspace tailscaled per Tailscale network and decides,
# for a target host, which daemon (if any) should proxy it; the ssh/scp/sftp/
# curl wrappers in dot_functions pick the cwd's preferred tailnet from git
# config and act on that decision. These tests drive the real script and the
# real functions under a sandboxed HOME with stub tailscale/tailscaled/
# launchctl/systemctl/ssh/scp/sftp/curl binaries that record their argv and
# answer `status --json` from fixture files. All names here are fixtures — no
# real account, tailnet, or host names may appear (see CLAUDE.md).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  unset TAILNET TAILNET_STATE XDG_STATE_HOME XDG_CONFIG_HOME
  # bats inherits CLAUDECODE when run from a Claude Code session; the
  # doctor's shell: line reports it, so the default case must not see it.
  unset CLAUDECODE
  unset ALL_PROXY all_proxy HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy
  DOTFUNCTIONS="$BATS_TEST_DIRNAME/../dot_functions"
  # The state dir holds unix sockets, and a socket path is limited to ~104
  # bytes on macOS — bats' tmpdir is far deeper than that — so it lives in a
  # short scratch dir (TAILNET_STATE is the script's and the functions'
  # override), removed in teardown.
  export TAILNET_STATE="$(mktemp -d /tmp/tailnet-test.XXXXXX)"
  STATE="$TAILNET_STATE"

  # Fixture pins: personal repos map to tailnet "personal", work repos to
  # "work", one personal side project is pinned to the work tailnet.
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-work-org.username work-account
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-personal.username personal-account
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-newbie.username newbie-account
  git config --file "$GIT_CONFIG_GLOBAL" tailnet.profile.work-account work
  git config --file "$GIT_CONFIG_GLOBAL" tailnet.profile.personal-account personal
  git config --file "$GIT_CONFIG_GLOBAL" tailnet.profile.newbie-account never-installed
  git config --file "$GIT_CONFIG_GLOBAL" tailnet.octo-personal/side-project.profile work
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  # Alias -> opaque-token pins for open-as (overlay-supplied in real life);
  # "personal" deliberately has none, to cover the untagged fallback.
  git config --file "$GIT_CONFIG_GLOBAL" browser.tag.work wk94fjq2x

  # Two installed tailnets with live sockets: the system daemon (the app) is
  # on the personal one, so personal hosts go direct and work hosts via the
  # work daemon. `shared` is a node name that exists in both.
  export TS_FIXTURES="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$TS_FIXTURES" "$STATE/personal" "$STATE/work"
  echo 1055 > "$STATE/personal/port"
  echo 1056 > "$STATE/work/port"
  fixture personal personal-net.ts.net homebox 100.101.1.2 shared 100.101.1.3
  fixture work work-net.ts.net workbox 100.102.3.4 shared 100.102.3.5
  cp "$TS_FIXTURES/personal.json" "$TS_FIXTURES/system.json"
  make_socket personal
  make_socket work

  # Stubs. Every invocation's argv is appended to its log.
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  export TS_LOG="$BATS_TEST_TMPDIR/tailscale.log"
  export LAUNCHCTL_LOG="$BATS_TEST_TMPDIR/launchctl.log"
  export SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
  export SSH_LOG="$BATS_TEST_TMPDIR/ssh.log"
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  export OPEN_LOG="$BATS_TEST_TMPDIR/open.log"
  : > "$TS_LOG"; : > "$LAUNCHCTL_LOG"; : > "$SYSTEMCTL_LOG"; : > "$SSH_LOG"; : > "$CURL_LOG"; : > "$OPEN_LOG"
  export FAKE_OS=Darwin

  cat > "$BIN/tailscaled" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$TS_LOG"
STUB
  cat > "$BIN/tailscale" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$TS_LOG"
sock=
for a in "$@"; do case $a in --socket=*) sock=${a#--socket=};; esac; done
case " $* " in
  *" status --json"*)
    if [ -n "$sock" ]; then
      d=${sock%/tailscaled.sock}; name=${d##*/}
      cat "$TS_FIXTURES/$name.json"
    else
      cat "$TS_FIXTURES/system.json"
    fi;;
  *" switch --list "*) printf 'ID    Tailnet          Account\n0001  personal-net     someone@example.com*\n0002  work-net         someone@example.org\n';;
  *" nc "*) echo "NC: $*";;
  *" up "*)
    echo "UP: $*"
    if [ -n "${FAKE_UP_URL:-}" ]; then
      printf 'To authenticate, visit:\n\n\t%s\n' "$FAKE_UP_URL"
      sleep 3
    fi;;
esac
STUB
  cat > "$BIN/launchctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"
case "$1 $2" in
  "print gui/"*/homebrew.mxcl.tailscale) [ -n "$FAKE_BREW_SERVICE" ] || exit 1;;
  "print gui/"*/local.tailnet.*) echo "	pid = 4242"; echo "	state = running";;
esac
exit 0
STUB
  cat > "$BIN/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$*" in
  "--user show-environment") [ "$FAKE_OS" = Linux ] || exit 1;;
  "--user is-active "*) echo active;;
  "--user show -p MainPID --value "*) echo 4343;;
esac
exit 0
STUB
  cat > "$BIN/uname" <<'STUB'
#!/bin/sh
echo "${FAKE_OS:-Darwin}"
STUB
  cat > "$BIN/hostname" <<'STUB'
#!/bin/sh
echo Testbox.local
STUB
  cat > "$BIN/lsof" <<'STUB'
#!/bin/sh
exit 1
STUB
  # ssh -G: resolve `hostname` from the first operand the way ssh would
  # (skipping option values), echo proxyjump/proxycommand when -J/-o set them;
  # anything else records the run.
  cat > "$BIN/ssh" <<'STUB'
#!/bin/sh
if [ "$1" = -G ]; then
  shift; host=; skip=0; pj=; pc=
  for a in "$@"; do
    if [ $skip = 1 ]; then
      case $last in -J) pj=$a;; -o) case $a in ProxyCommand=*) pc=${a#ProxyCommand=};; esac;; esac
      skip=0; continue
    fi
    case $a in
      -p|-o|-i|-l|-J|-F|-c|-L|-R|-D|-W|-E|-e|-I|-m|-O|-Q|-S|-w) skip=1; last=$a;;
      -*) ;;
      *) [ -z "$host" ] && host=$a;;
    esac
  done
  [ -n "$host" ] || { echo "usage: ssh ..." >&2; exit 255; }
  case $host in *@*) host=${host#*@};; esac
  case $host in nohost.invalid) exit 255;; esac
  echo "user tester"
  echo "hostname $host"
  echo "port 22"
  [ -n "$pj" ] && echo "proxyjump $pj"
  [ -n "$pc" ] && echo "proxycommand $pc"
  exit 0
fi
printf '%s\n' "$*" >> "$SSH_LOG"
if [ -n "${FAKE_SSH_CHECK_URL:-}" ]; then
  # Tailscale SSH check mode: the server banner with the auth URL arrives on
  # stderr mid-session and the connection waits; the sleep gives the
  # wrapper's watcher (1s poll) time to see it before ssh "exits".
  printf '# Tailscale SSH requires an additional check.\n# To authenticate, visit: %s\n' "$FAKE_SSH_CHECK_URL" >&2
  sleep 3
fi
echo "RAN ssh: $*"
STUB
  cat > "$BIN/scp" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$SSH_LOG"
echo "RAN scp: $*"
STUB
  cat > "$BIN/sftp" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$SSH_LOG"
echo "RAN sftp: $*"
STUB
  cat > "$BIN/curl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$CURL_LOG"
echo "RAN curl: $*"
STUB
  # `open` records instead of opening (shadows the real /usr/bin/open on
  # macOS — the tests must never reach a browser).
  cat > "$BIN/open" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$OPEN_LOG"
STUB
  chmod +x "$BIN"/*
  cp "$BATS_TEST_DIRNAME/../bin/executable_tailnet" "$BIN/tailnet"
  cp "$BATS_TEST_DIRNAME/../bin/executable_open-as" "$BIN/open-as"
  chmod +x "$BIN/tailnet" "$BIN/open-as"
  TAILNET_BIN="$BIN/tailnet"
  export PATH="$BIN:$PATH"
}

# fixture <name> <suffix> <host1> <ip1> <host2> <ip2> — a status --json in the
# real layout: Self first, MagicDNSSuffix, then peers.
fixture() {
  cat > "$TS_FIXTURES/$1.json" <<EOF
{
  "Version": "1.0.0-fixture",
  "BackendState": "Running",
  "TailscaleIPs": [
    "100.100.0.1"
  ],
  "Self": {
    "ID": "selfid",
    "HostName": "Testbox-$1",
    "DNSName": "testbox-$1.$2.",
    "TailscaleIPs": [
      "100.100.0.1"
    ],
    "KeyExpiry": "2030-01-01T00:00:00Z"
  },
  "MagicDNSSuffix": "$2",
  "CurrentTailnet": {
    "Name": "$1-net",
    "MagicDNSSuffix": "$2"
  },
  "Peer": {
    "nodekey:aaaa": {
      "ID": "peer1",
      "HostName": "$3",
      "DNSName": "$3.$2.",
      "TailscaleIPs": [
        "$4",
        "fd7a:115c:a1e0::1"
      ],
      "Addrs": [
        "$4:41641"
      ]
    },
    "nodekey:bbbb": {
      "ID": "peer2",
      "HostName": "$5",
      "DNSName": "$5.$2.",
      "TailscaleIPs": [
        "$6"
      ]
    }
  }
}
EOF
}

# A unix socket file for tailnet <name>: `route` and `status` skip a daemon
# whose socket is missing without asking tailscale (a missing socket makes the
# real CLI stall for two seconds).
make_socket() {
  # zsh's socket module: present wherever the tests run, unlike a perl or
  # python that version-manager shims may hide once HOME is sandboxed.
  zsh -fc 'zmodload zsh/net/socket && zsocket -l "$1"' zsh "$STATE/$1/tailscaled.sock"
}

teardown() {
  [ -n "$TAILNET_STATE" ] && [ -d "$TAILNET_STATE" ] && rm -rf "$TAILNET_STATE"
  return 0
}

make_repo() {
  local dir="$BATS_TEST_TMPDIR/repo-$RANDOM"
  git init -q "$dir"
  git -C "$dir" remote add origin "$1"
  cd "$dir" && pwd -P
}

in_repo() { # <repo> <zsh code…>
  local repo=$1; shift
  # $ZOPTS, when set, is applied before the functions are sourced — to run
  # them under another program's zsh options (see CLAUDE_CODE_OPTS).
  run zsh -c "${ZOPTS:+setopt $ZOPTS;} source '$DOTFUNCTIONS'; cd '$repo'; $*"
}

# The option set Claude Code's Bash tool runs zsh with (read off `setopt` in
# such a session): bare glob qualifiers off, so a `(N)` is literal text and
# NOMATCH aborts the function that globbed. Every wrapper must behave the
# same there as in an interactive shell.
CLAUDE_CODE_OPTS="no_bare_glob_qual no_case_glob glob_star_short no_extended_glob nomatch"

# --- script: registry ------------------------------------------------------

@test "tailnet: names/port/sock/dir/proxy-url read the state dir" {
  run tailnet names
  [ "$status" -eq 0 ]
  [ "$output" = $'personal\nwork' ]
  run tailnet port work
  [ "$output" = 1056 ]
  run tailnet sock work
  [ "$output" = "$STATE/work/tailscaled.sock" ]
  run tailnet dir personal
  [ "$output" = "$STATE/personal" ]
  run tailnet proxy-url work
  [ "$output" = "socks5h://localhost:1056" ]
  run tailnet port never-installed
  [ "$status" -eq 1 ]
  [[ "$output" == *"not installed (run: tailnet install never-installed)"* ]]
  run tailnet port ../evil
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid tailnet name"* ]]
}

@test "tailnet: daemon-bin is tailscaled on PATH and cli its sibling, never the app's shim" {
  run tailnet daemon-bin
  [ "$output" = "$BIN/tailscaled" ]
  run tailnet cli
  [ "$output" = "$BIN/tailscale" ]
  # Without a tailscaled, a PATH tailscale that execs the app bundle is refused.
  # (PATH is cut down to the stubs + base system: the machine running the
  # tests may well have the real tailscaled and brew installed.)
  rm "$BIN/tailscaled" "$BIN/tailscale"
  printf '#!/bin/sh\nexec /Applications/Tailscale.app/Contents/MacOS/Tailscale "$@"\n' > "$BIN/tailscale"
  chmod +x "$BIN/tailscale"
  export PATH="$BIN:/usr/bin:/bin"
  run tailnet cli
  [ "$status" -eq 1 ]
  [[ "$output" == *"no usable tailscale CLI"* ]]
  run tailnet daemon-bin
  [ "$status" -eq 1 ]
}

# --- script: install / uninstall ------------------------------------------

@test "tailnet install (macOS): writes the launchd agent with the userspace flags and starts it" {
  run tailnet install extra 1060
  [ "$status" -eq 0 ]
  [[ "$output" == *"extra installed — proxy on 127.0.0.1:1060, agent local.tailnet.extra"* ]]
  [[ "$output" == *"next: tailnet up extra"* ]]
  [ "$(cat "$STATE/extra/port")" = 1060 ]
  [ -d "$STATE/extra/logs" ]
  plist="$HOME/Library/LaunchAgents/local.tailnet.extra.plist"
  [ -f "$plist" ]
  grep -q "<string>$BIN/tailscaled</string>" "$plist"
  grep -q "<string>--tun=userspace-networking</string>" "$plist"
  grep -q "<string>--statedir=$STATE/extra</string>" "$plist"
  grep -q "<string>--socket=$STATE/extra/tailscaled.sock</string>" "$plist"
  grep -q "<string>--socks5-server=localhost:1060</string>" "$plist"
  grep -q "<string>--outbound-http-proxy-listen=localhost:1060</string>" "$plist"
  grep -q "<key>TS_LOGS_DIR</key>" "$plist"
  grep -q "<string>$STATE/extra/logs</string>" "$plist"
  grep -q "<key>KeepAlive</key>" "$plist"
  grep -q "<key>RunAtLoad</key>" "$plist"
  uid=$(id -u)
  grep -q "^bootstrap gui/$uid $plist\$" "$LAUNCHCTL_LOG"
  grep -q "^kickstart -k gui/$uid/local.tailnet.extra\$" "$LAUNCHCTL_LOG"
  # No brew-services warning when it isn't loaded.
  [[ "$output" != *"brew services"* ]]
  # Re-install keeps the recorded port and re-bootstraps cleanly.
  run tailnet install extra
  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/extra/port")" = 1060 ]
  grep -q "^bootout gui/$uid/local.tailnet.extra\$" "$LAUNCHCTL_LOG"
}

@test "tailnet install: picks the first free port from 1055 and warns about the crash-looping brew service" {
  FAKE_BREW_SERVICE=1 run tailnet install third
  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/third/port")" = 1057 ]
  [[ "$output" == *"WARNING: brew services has tailscale loaded"* ]]
  [[ "$output" == *"brew services stop tailscale"* ]]
}

@test "tailnet install (Linux, systemd --user): writes and enables a user unit" {
  FAKE_OS=Linux run tailnet install extra 1060
  [ "$status" -eq 0 ]
  [[ "$output" == *"unit tailnet-extra"* ]]
  unit="$HOME/.config/systemd/user/tailnet-extra.service"
  [ -f "$unit" ]
  grep -q "^ExecStart=$BIN/tailscaled \"--tun=userspace-networking\" \"--statedir=$STATE/extra\" \"--socket=$STATE/extra/tailscaled.sock\" \"--socks5-server=localhost:1060\" \"--outbound-http-proxy-listen=localhost:1060\"\$" "$unit"
  grep -q "^Environment=TS_LOGS_DIR=$STATE/extra/logs\$" "$unit"
  grep -q "^Restart=always\$" "$unit"
  grep -q "^WantedBy=default.target\$" "$unit"
  grep -q "^--user daemon-reload\$" "$SYSTEMCTL_LOG"
  grep -q "^--user enable --now tailnet-extra\$" "$SYSTEMCTL_LOG"
  [ ! -s "$LAUNCHCTL_LOG" ]
}

@test "tailnet install: refuses without a tailscaled" {
  rm "$BIN/tailscaled"
  export PATH="$BIN:/usr/bin:/bin"
  run tailnet install extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"tailscaled not found"* ]]
  [ ! -e "$STATE/extra" ]
}

@test "tailnet uninstall: unloads the agent, forgets the port, --purge removes the state" {
  run tailnet uninstall work
  [ "$status" -eq 0 ]
  uid=$(id -u)
  grep -q "^bootout gui/$uid/local.tailnet.work\$" "$LAUNCHCTL_LOG"
  [ ! -e "$STATE/work/port" ]
  [ -d "$STATE/work" ]
  run tailnet names
  [ "$output" = personal ]
  run tailnet uninstall personal --purge
  [ "$status" -eq 0 ]
  [ ! -e "$STATE/personal" ]
}

@test "tailnet up: always the same fixed flag set on that daemon's socket" {
  run tailnet up work --ssh
  [ "$status" -eq 0 ]
  [ "$output" = "UP: --socket=$STATE/work/tailscaled.sock up --hostname=testbox-work --accept-routes --ssh" ]
  rm "$STATE/work/tailscaled.sock"
  run tailnet up work
  [ "$status" -eq 1 ]
  [[ "$output" == *"not running"* ]]
}

@test "tailnet run: execs tailscaled in the foreground with the unit's argv" {
  run tailnet run work
  [ "$status" -eq 0 ]
  [ "$(cat "$TS_LOG")" = "--tun=userspace-networking --statedir=$STATE/work --socket=$STATE/work/tailscaled.sock --socks5-server=localhost:1056 --outbound-http-proxy-listen=localhost:1056" ]
}

# --- script: peer / route / status ----------------------------------------

@test "tailnet peer: matches short name, FQDN, IPv4, case-folded; not a stranger" {
  run tailnet peer work workbox
  [ "$status" -eq 0 ]
  run tailnet peer work WorkBox
  [ "$status" -eq 0 ]
  run tailnet peer work workbox.work-net.ts.net
  [ "$status" -eq 0 ]
  run tailnet peer work workbox.work-net.ts.net.
  [ "$status" -eq 0 ]
  run tailnet peer work 100.102.3.4
  [ "$status" -eq 0 ]
  run tailnet peer work fd7a:115c:a1e0::1
  [ "$status" -eq 0 ]
  run tailnet peer work homebox
  [ "$status" -eq 1 ]
  run tailnet peer work box
  [ "$status" -eq 1 ]
  run tailnet peer work workbox.personal-net.ts.net
  [ "$status" -eq 1 ]
  # Never a DNS lookup or `tailscale ip`: only status --json was asked.
  ! grep -qv 'status --json' "$TS_LOG"
}

@test "tailnet route: work host via work, personal host direct (the system daemon is on it), stranger exit 1" {
  run tailnet route workbox
  [ "$status" -eq 0 ]
  [ "$output" = work ]
  run tailnet route homebox
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  run tailnet route nobody
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
}

@test "tailnet route: --prefer decides a name that exists in both tailnets" {
  run tailnet route --prefer work shared
  [ "$output" = work ]
  run tailnet route --prefer personal shared
  [ "$output" = "" ]           # personal, and the system daemon is on personal -> direct
  run tailnet route shared     # no preference: installed order, personal first
  [ "$output" = "" ]
}

@test "tailnet route: --force routes a non-node through the preferred tailnet unless the system daemon is on it" {
  run tailnet route --force --prefer work 10.9.8.7
  [ "$status" -eq 0 ]
  [ "$output" = work ]
  run tailnet route --force --prefer personal 10.9.8.7
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "tailnet route: a daemon whose socket is missing is skipped without asking tailscale" {
  rm "$STATE/personal/tailscaled.sock"
  run tailnet route shared
  [ "$output" = work ]
  ! grep -q "$STATE/personal/tailscaled.sock" "$TS_LOG"
}

@test "tailnet route: when the system daemon is off, every node is routed through its daemon" {
  : > "$TS_FIXTURES/system.json"
  run tailnet route homebox
  [ "$output" = personal ]
}

@test "tailnet status/system: report each daemon and the system tailnet" {
  run tailnet status
  [ "$status" -eq 0 ]
  [[ "$output" == *"personal:"* ]]
  [[ "$output" == *"port:       1055 (socks5h://localhost:1055, also http)"* ]]
  [[ "$output" == *"service:    running (pid 4242)"* ]]
  [[ "$output" == *"backend:    Running"* ]]
  [[ "$output" == *"tailnet:    work-net.ts.net"* ]]
  [[ "$output" == *"hostname:   testbox-work.work-net.ts.net."* ]]
  [[ "$output" == *"key expiry: 2030-01-01T00:00:00Z"* ]]
  rm "$STATE/work/tailscaled.sock"
  run tailnet status work
  [[ "$output" == *"socket:     MISSING"* ]]
  run tailnet system
  [ "$status" -eq 0 ]
  [[ "$output" == *"system: Running, tailnet personal-net.ts.net"* ]]
  [[ "$output" == *"personal-net     someone@example.com*"* ]]
}

@test "tailnet nc: execs the daemon CLI's nc on that socket" {
  run tailnet nc work workbox 22
  [ "$status" -eq 0 ]
  [ "$output" = "NC: --socket=$STATE/work/tailscaled.sock nc workbox 22" ]
}

# --- functions: cwd preference ---------------------------------------------

@test "dot_functions defines the tailnet helpers and wrappers" {
  run zsh -c "source '$DOTFUNCTIONS'; whence -w tailnet_for_cwd tailnet_route tailnet_hostish tailnet_ssh_host tailnet_scp_host tailnet_curl_host tailnet_for_cmd tailnet_exec ssh scp sftp curl tailnet-as tailnet-doctor defined_trace shell_trace"
  [ "$status" -eq 0 ]
  for f in tailnet_for_cwd tailnet_route tailnet_hostish tailnet_ssh_host tailnet_scp_host tailnet_curl_host tailnet_for_cmd tailnet_exec ssh scp sftp curl tailnet-as tailnet-doctor defined_trace shell_trace; do
    [[ "$output" == *"$f: function"* ]]
  done
}

@test "tailnet_for_cwd: work repo -> work, personal -> personal, repo pin outranks, unmapped -> nothing" {
  repo=$(make_repo 'git@github.com:octo-work-org/some-repo.git')
  in_repo "$repo" tailnet_for_cwd
  [ "$output" = work ]
  repo=$(make_repo 'https://github.com/octo-personal/some-repo.git')
  in_repo "$repo" tailnet_for_cwd
  [ "$output" = personal ]
  repo=$(make_repo 'git@github.com:octo-personal/side-project.git')
  in_repo "$repo" tailnet_for_cwd
  [ "$output" = work ]
  repo=$(make_repo 'git@github.com:someone-else/repo.git')
  in_repo "$repo" tailnet_for_cwd
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
}

@test "tailnet_for_cwd: TAILNET takes an installed name or a mapped account, rejects the rest" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  in_repo "$repo" "TAILNET=work tailnet_for_cwd"
  [ "$output" = work ]
  in_repo "$repo" "TAILNET=work-account tailnet_for_cwd"
  [ "$output" = work ]
  in_repo "$repo" "TAILNET=newbie-account tailnet_for_cwd"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TAILNET='newbie-account' is neither an installed tailnet nor a mapped account"* ]]
}

@test "tailnet_hostish: only shapes that can be a tailnet node" {
  run zsh -c "source '$DOTFUNCTIONS'; for h in workbox WorkBox box.work-net.ts.net 100.102.3.4 100.64.0.1 100.127.255.255 fd7a:115c:a1e0::1; do tailnet_hostish \$h && echo \"yes \$h\"; done; for h in github.com localhost 10.0.0.1 100.128.0.1 192.168.1.1 printer.local 2001:db8::1 ''; do tailnet_hostish \"\$h\" || echo \"no \$h\"; done"
  [ "$status" -eq 0 ]
  [ "$output" = $'yes workbox\nyes WorkBox\nyes box.work-net.ts.net\nyes 100.102.3.4\nyes 100.64.0.1\nyes 100.127.255.255\nyes fd7a:115c:a1e0::1\nno github.com\nno localhost\nno 10.0.0.1\nno 100.128.0.1\nno 192.168.1.1\nno printer.local\nno 2001:db8::1\nno ' ]
}

# --- functions: ssh / scp / sftp -------------------------------------------

@test "ssh: from a personal repo, a work host gets a ProxyCommand through the work daemon, args untouched" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  in_repo "$repo" ssh -p 2222 admin@workbox uptime --now
  [ "$status" -eq 0 ]
  [ "$output" = "RAN ssh: -o ProxyCommand=$TAILNET_BIN nc work %h %p -p 2222 admin@workbox uptime --now" ]
}

@test "ssh: a host on the tailnet the app is on runs direct" {
  repo=$(make_repo 'git@github.com:octo-work-org/some-repo.git')
  in_repo "$repo" ssh homebox
  [ "$output" = "RAN ssh: homebox" ]
}

@test "ssh: a name in both tailnets follows the cwd's preference" {
  repo=$(make_repo 'git@github.com:octo-work-org/some-repo.git')
  in_repo "$repo" ssh shared
  [ "$output" = "RAN ssh: -o ProxyCommand=$TAILNET_BIN nc work %h %p shared" ]
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  in_repo "$repo" ssh shared
  [ "$output" = "RAN ssh: shared" ]
  # Unmapped cwd: still reachable, installed order decides (personal first -> direct).
  in_repo "$BATS_TEST_TMPDIR" ssh shared
  [ "$output" = "RAN ssh: shared" ]
  in_repo "$BATS_TEST_TMPDIR" ssh workbox
  [ "$output" = "RAN ssh: -o ProxyCommand=$TAILNET_BIN nc work %h %p workbox" ]
}

@test "ssh: an existing ProxyJump/ProxyCommand, or arguments ssh cannot parse, are left alone" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  in_repo "$repo" ssh -J jumphost workbox
  [ "$output" = "RAN ssh: -J jumphost workbox" ]
  in_repo "$repo" ssh -o ProxyCommand=mything workbox
  [ "$output" = "RAN ssh: -o ProxyCommand=mything workbox" ]
  in_repo "$repo" ssh nohost.invalid
  [ "$output" = "RAN ssh: nohost.invalid" ]
  in_repo "$repo" ssh
  [ "$output" = "RAN ssh: " ]
}

@test "ssh: a public host costs no tailscale call at all" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  in_repo "$repo" ssh git@github.com
  [ "$output" = "RAN ssh: git@github.com" ]
  [ ! -s "$TS_LOG" ]
  in_repo "$repo" ssh localhost
  [ "$output" = "RAN ssh: localhost" ]
  [ ! -s "$TS_LOG" ]
}

@test "ssh: TAILNET forces a tailnet, node check skipped (subnet-router destinations)" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  in_repo "$repo" "TAILNET=work ssh 10.9.8.7"
  [ "$output" = "RAN ssh: -o ProxyCommand=$TAILNET_BIN nc work %h %p 10.9.8.7" ]
  in_repo "$repo" "TAILNET=personal ssh 10.9.8.7"
  [ "$output" = "RAN ssh: 10.9.8.7" ]
}

# --- open-as: auth URLs to the right browser profile ------------------------
# Some URLs are identical no matter which account they authenticate
# (Tailscale auth/check links), so the tool that knows whose they are tags
# them with an opaque #token (browser.tag.<alias> in git config) for the
# link router. The `open` stub records instead of opening.

@test "open-as: appends the pinned opaque token as a fragment and opens" {
  run open-as work https://device.oauth.example/activate
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$(cat "$OPEN_LOG")" = "https://device.oauth.example/activate#wk94fjq2x" ]
}

@test "open-as: an alias with no pin opens untagged and says so; bad usage errors out" {
  run open-as personal https://device.oauth.example/activate
  [ "$status" -eq 0 ]
  [[ "$output" == *"no browser.tag.personal pin"* ]]
  [ "$(cat "$OPEN_LOG")" = "https://device.oauth.example/activate" ]
  run open-as 'bad alias' https://x.example/
  [ "$status" -eq 2 ]
  run open-as lonely-alias
  [ "$status" -eq 2 ]
  # Neither error opened anything beyond the first (untagged) open.
  [ "$(wc -l < "$OPEN_LOG")" -eq 1 ]
}

@test "ssh: a Tailscale SSH check-mode URL on stderr is auto-opened, tagged for the tailnet's profile" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  FAKE_SSH_CHECK_URL=https://login.tailscale.com/a/def456 in_repo "$repo" ssh workbox hostname
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN ssh: -o ProxyCommand=$TAILNET_BIN nc work %h %p workbox hostname"* ]]
  [[ "$output" == *"additional check"* ]]
  [ "$(cat "$OPEN_LOG")" = "https://login.tailscale.com/a/def456#wk94fjq2x" ]
}

@test "ssh: the check watcher failing to set up never blocks the command" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  TMPDIR=/nonexistent-tailnet-test in_repo "$repo" ssh workbox hostname
  [ "$status" -eq 0 ]
  [ "$output" = "RAN ssh: -o ProxyCommand=$TAILNET_BIN nc work %h %p workbox hostname" ]
  [ ! -s "$OPEN_LOG" ]
}

@test "tailnet up: an auth URL in the output is auto-opened, tagged; output and status untouched" {
  FAKE_UP_URL=https://login.tailscale.com/a/ghi789 run tailnet up work
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "UP: --socket=$STATE/work/tailscaled.sock up --hostname=testbox-work --accept-routes" ]
  [[ "$output" == *"To authenticate, visit:"* ]]
  [ "$(cat "$OPEN_LOG")" = "https://login.tailscale.com/a/ghi789#wk94fjq2x" ]
}

@test "scp/sftp: the remote operand is found (user@host:path, -P, URLs); local colons are not remote" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  in_repo "$repo" scp -P 2222 ./file.txt admin@workbox:/tmp/
  [ "$output" = "RAN scp: -o ProxyCommand=$TAILNET_BIN nc work %h %p -P 2222 ./file.txt admin@workbox:/tmp/" ]
  in_repo "$repo" scp -r workbox:src ./dst
  [ "$output" = "RAN scp: -o ProxyCommand=$TAILNET_BIN nc work %h %p -r workbox:src ./dst" ]
  in_repo "$repo" scp scp://workbox:2222/etc/hosts .
  [ "$output" = "RAN scp: -o ProxyCommand=$TAILNET_BIN nc work %h %p scp://workbox:2222/etc/hosts ." ]
  in_repo "$repo" scp ./a:b ./c
  [ "$output" = "RAN scp: ./a:b ./c" ]
  in_repo "$repo" scp -o User=x homebox:f .
  [ "$output" = "RAN scp: -o User=x homebox:f ." ]
  in_repo "$repo" sftp -P 2222 workbox
  [ "$output" = "RAN sftp: -o ProxyCommand=$TAILNET_BIN nc work %h %p -P 2222 workbox" ]
  in_repo "$repo" sftp admin@workbox:/srv
  [ "$output" = "RAN sftp: -o ProxyCommand=$TAILNET_BIN nc work %h %p admin@workbox:/srv" ]
}

# --- functions: curl -------------------------------------------------------

@test "curl: a work URL gets --proxy socks5h on the work port; personal and public URLs run direct" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  in_repo "$repo" curl -sS -H "'Accept: application/json'" http://workbox:8080/api/x
  [ "$output" = "RAN curl: --proxy socks5h://localhost:1056 -sS -H Accept: application/json http://workbox:8080/api/x" ]
  in_repo "$repo" curl https://WorkBox.work-net.ts.net/
  [ "$output" = "RAN curl: --proxy socks5h://localhost:1056 https://WorkBox.work-net.ts.net/" ]
  in_repo "$repo" curl http://admin@workbox/
  [ "$output" = "RAN curl: --proxy socks5h://localhost:1056 http://admin@workbox/" ]
  in_repo "$repo" curl workbox:9000/health
  [ "$output" = "RAN curl: --proxy socks5h://localhost:1056 workbox:9000/health" ]
  in_repo "$repo" curl http://homebox/
  [ "$output" = "RAN curl: http://homebox/" ]
  : > "$TS_LOG"
  in_repo "$repo" curl -sSL https://api.github.com/user
  [ "$output" = "RAN curl: -sSL https://api.github.com/user" ]
  [ ! -s "$TS_LOG" ]
  in_repo "$repo" curl localhost:3000
  [ "$output" = "RAN curl: localhost:3000" ]
  [ ! -s "$TS_LOG" ]
}

@test "curl: the user's own proxy (flag or environment) wins" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  in_repo "$repo" curl -x http://other:3128 http://workbox/
  [ "$output" = "RAN curl: -x http://other:3128 http://workbox/" ]
  in_repo "$repo" curl --noproxy "'*'" http://workbox/
  [ "$output" = "RAN curl: --noproxy * http://workbox/" ]
  in_repo "$repo" "ALL_PROXY=socks5h://localhost:9 curl http://workbox/"
  [ "$output" = "RAN curl: http://workbox/" ]
  [ ! -s "$TS_LOG" ]
}

# --- functions: tailnet-as / passthrough ------------------------------------

@test "tailnet-as: runs one command with TAILNET and the proxy environment set; unknown names error out" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  in_repo "$repo" "tailnet-as work sh -c 'echo T=\$TAILNET A=\$ALL_PROXY H=\$HTTPS_PROXY h=\$http_proxy N=\$NO_PROXY'"
  [ "$status" -eq 0 ]
  [ "$output" = "T=work A=socks5h://localhost:1056 H=socks5h://localhost:1056 h=socks5h://localhost:1056 N=localhost,127.0.0.1,::1" ]
  # The wrappers still apply inside, forced to that tailnet; the environment
  # does not leak out afterwards.
  in_repo "$repo" "tailnet-as work ssh 10.9.8.7; echo after=\${TAILNET-unset}"
  [ "$output" = $'RAN ssh: -o ProxyCommand='"$TAILNET_BIN"$' nc work %h %p 10.9.8.7\nafter=unset' ]
  # A mapped account name works too.
  in_repo "$repo" "tailnet-as work-account sh -c 'echo \$TAILNET'"
  [ "$output" = work ]
  in_repo "$repo" tailnet-as nonesuch true
  [ "$status" -eq 1 ]
  [[ "$output" == *"tailnet-as: unknown tailnet 'nonesuch'"* ]]
  [[ "$output" == *$'installed tailnets:\npersonal\nwork'* ]]
  in_repo "$repo" tailnet-as work
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage: tailnet-as <name> <command> [args...]"* ]]
}

@test "wrappers: with nothing installed they are plain passthroughs and never call tailscale" {
  rm -rf "$STATE"
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  in_repo "$repo" ssh workbox
  [ "$output" = "RAN ssh: workbox" ]
  in_repo "$repo" curl http://workbox/
  [ "$output" = "RAN curl: http://workbox/" ]
  in_repo "$repo" scp workbox:x .
  [ "$output" = "RAN scp: workbox:x ." ]
  [ ! -s "$TS_LOG" ]
  # Same without the script on PATH.
  rm "$TAILNET_BIN"
  in_repo "$repo" ssh workbox
  [ "$output" = "RAN ssh: workbox" ]
}

# --- functions: option independence -------------------------------------------

@test "wrappers: behave the same under Claude Code's zsh options (no bare glob qualifiers, no extendedglob)" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  # The crash: with tailnets installed, tailnet_active's `*/port(N)` glob
  # aborted every wrapper under NO_BARE_GLOB_QUAL — a curl to loopback died
  # with "no matches found" and never ran.
  ZOPTS=$CLAUDE_CODE_OPTS in_repo "$repo" tailnet_active
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  ZOPTS=$CLAUDE_CODE_OPTS in_repo "$repo" curl -s http://127.0.0.1:8321/
  [ "$status" -eq 0 ]
  [ "$output" = "RAN curl: -s http://127.0.0.1:8321/" ]
  [ ! -s "$TS_LOG" ]
  # And routing still works there — the same verdicts as the default shell.
  ZOPTS=$CLAUDE_CODE_OPTS in_repo "$repo" ssh -p 2222 admin@workbox uptime
  [ "$output" = "RAN ssh: -o ProxyCommand=$TAILNET_BIN nc work %h %p -p 2222 admin@workbox uptime" ]
  ZOPTS=$CLAUDE_CODE_OPTS in_repo "$repo" ssh homebox
  [ "$output" = "RAN ssh: homebox" ]
  ZOPTS=$CLAUDE_CODE_OPTS in_repo "$repo" curl workbox:9000/health
  [ "$output" = "RAN curl: --proxy socks5h://localhost:1056 workbox:9000/health" ]
  ZOPTS=$CLAUDE_CODE_OPTS in_repo "$repo" scp -P 2222 ./file.txt admin@workbox:/tmp/
  [ "$output" = "RAN scp: -o ProxyCommand=$TAILNET_BIN nc work %h %p -P 2222 ./file.txt admin@workbox:/tmp/" ]
  ZOPTS=$CLAUDE_CODE_OPTS in_repo "$repo" sftp admin@workbox:/srv
  [ "$output" = "RAN sftp: -o ProxyCommand=$TAILNET_BIN nc work %h %p admin@workbox:/srv" ]
  ZOPTS=$CLAUDE_CODE_OPTS in_repo "$repo" "TAILNET=work ssh 10.9.8.7"
  [ "$output" = "RAN ssh: -o ProxyCommand=$TAILNET_BIN nc work %h %p 10.9.8.7" ]
  ZOPTS=$CLAUDE_CODE_OPTS in_repo "$repo" "tailnet-as work sh -c 'echo T=\$TAILNET A=\$ALL_PROXY'"
  [ "$output" = "T=work A=socks5h://localhost:1056" ]
  ZOPTS=$CLAUDE_CODE_OPTS in_repo "$repo" tailnet-doctor workbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"route:   workbox -> via work (ProxyCommand=$TAILNET_BIN nc work %h %p; curl --proxy socks5h://localhost:1056)"* ]]
  ZOPTS=$CLAUDE_CODE_OPTS in_repo "$repo" tailnet_hostish 100.102.3.4
  [ "$status" -eq 0 ]
  ZOPTS=$CLAUDE_CODE_OPTS in_repo "$repo" tailnet_hostish github.com
  [ "$status" -eq 1 ]
}

# --- functions: fail open ------------------------------------------------------

# A function body that aborts the shell running it: NOMATCH on a glob that
# matches nothing — the exact failure mode of the original crash. Redefined
# over a helper, it stands in for "something unexpected broke in here".
CRASH='local d; for d in /nonexistent-tailnet-test/*/port; do :; done; print -ru2 -- "SHOULD NOT GET HERE"'

# What the stub for the command line $1 prints when it runs it untouched.
ran() { echo "RAN ${1%% *}: ${1#* }"; }

@test "wrappers: a destination whose shape cannot be a node runs direct before any state or daemon lookup" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  # tailnet_active is the state lookup; crashing it proves it is never
  # reached for these destinations. The real script/state are all present.
  for shell_opts in "" "$CLAUDE_CODE_OPTS"; do
    for cmd in "curl -s http://127.0.0.1:8321/" "curl localhost:3000" "curl -sSL https://api.github.com/user" \
               "curl http://10.0.0.5/" "ssh localhost" "ssh git@github.com" "ssh -p 22 admin@192.168.1.9" \
               "scp ./file.txt git@github.com:/srv/" "sftp user@example.org"; do
      : > "$TS_LOG"
      ZOPTS=$shell_opts in_repo "$repo" "tailnet_active() { $CRASH; }; $cmd"
      [ "$status" -eq 0 ]
      # Exact: no crash output either, since the crashing helper never ran.
      [ "$output" = "$(ran "$cmd")" ]
      [ ! -s "$TS_LOG" ]
    done
  done
}

@test "wrappers: any helper breaking degrades to running the command direct, never to blocking it" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  for helper in tailnet_state_root tailnet_installed tailnet_active tailnet_hostish tailnet_for_cwd \
                tailnet_route tailnet_ssh_host tailnet_scp_host tailnet_curl_host tailnet_for_cmd; do
    for shell_opts in "" "$CLAUDE_CODE_OPTS"; do
      # Non-node destinations: direct, and still no tailscale call.
      for cmd in "curl -s http://127.0.0.1:8321/" "ssh localhost" "curl https://api.github.com/user" "ssh git@github.com"; do
        : > "$TS_LOG"
        ZOPTS=$shell_opts in_repo "$repo" "$helper() { $CRASH; }; $cmd"
        [ "$status" -eq 0 ]
        # `run` merges stderr: the crash message may precede the run line.
        [[ "$output" == *"$(ran "$cmd")" ]]
        [ ! -s "$TS_LOG" ]
      done
      # A destination that would have been routed: the command still runs —
      # direct when a helper on its path broke, routed (without a
      # preference) when only tailnet_for_cwd did or the helper is not on
      # this command's path at all — never dead. Blocking is the one outcome
      # that must not happen.
      for cmd in "ssh workbox" "curl http://workbox:8080/" "scp ./f workbox:/tmp/" "sftp workbox"; do
        ZOPTS=$shell_opts in_repo "$repo" "$helper() { $CRASH; }; $cmd"
        [ "$status" -eq 0 ]
        [[ "$output" == *"RAN ${cmd%% *}: "*"${cmd#* }" ]]
      done
    done
  done
}

@test "wrappers: a misbehaving script (garbage verdict, failing proxy-url) means direct" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  # A verdict that names no installed tailnet is not acted on.
  cat > "$TAILNET_BIN" <<'STUB'
#!/bin/sh
case $1 in route) echo "oops: something went wrong";; *) exit 3;; esac
STUB
  in_repo "$repo" ssh workbox
  [ "$status" -eq 0 ]
  [ "$output" = "RAN ssh: workbox" ]
  in_repo "$repo" curl http://workbox/
  [ "$output" = "RAN curl: http://workbox/" ]
  # A good verdict whose proxy-url cannot be produced: curl runs direct.
  cat > "$TAILNET_BIN" <<'STUB'
#!/bin/sh
case $1 in route) echo work;; *) exit 3;; esac
STUB
  in_repo "$repo" curl http://workbox/
  [ "$status" -eq 0 ]
  [ "$output" = "RAN curl: http://workbox/" ]
  # The script exiting non-zero with no output: direct.
  printf '#!/bin/sh\nexit 7\n' > "$TAILNET_BIN"
  in_repo "$repo" ssh workbox
  [ "$output" = "RAN ssh: workbox" ]
  in_repo "$repo" curl workbox:9000/health
  [ "$output" = "RAN curl: workbox:9000/health" ]
}

# --- doctor ------------------------------------------------------------------

@test "tailnet-doctor: traces the machinery, the cwd's preference, and a host's route" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  in_repo "$repo" tailnet-doctor workbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrapper: ssh: function / curl: function"* ]]
  [[ "$output" == *"defined: ok (14 helpers)"* ]]
  [[ "$output" == *"helpers: ok"* ]]
  [[ "$output" == *"script:  $TAILNET_BIN"* ]]
  [[ "$output" == *"binary:  $BIN/tailscaled"* ]]
  [[ "$output" == *"cli:     $BIN/tailscale"* ]]
  [[ "$output" == *"system: Running, tailnet personal-net.ts.net"* ]]
  [[ "$output" == *"state:   $STATE"* ]]
  [[ "$output" == *"  work:"* ]]
  [[ "$output" == *"account: personal-account"* ]]
  [[ "$output" == *"repo pin: <none>"* ]]
  [[ "$output" == *"mapping: tailnet.profile.personal-account = personal"* ]]
  [[ "$output" == *"env:     TAILNET=<unset>"* ]]
  [[ "$output" == *"wants:   personal first, then the other installed tailnets"* ]]
  [[ "$output" == *"route:   workbox -> via work (ProxyCommand=$TAILNET_BIN nc work %h %p; curl --proxy socks5h://localhost:1056)"* ]]
  in_repo "$repo" tailnet-doctor homebox
  [[ "$output" == *"route:   homebox -> direct (a node of the tailnet the app is on)"* ]]
  in_repo "$repo" tailnet-doctor github.com
  [[ "$output" == *"route:   github.com -> direct (shape cannot be a tailnet node; no daemon asked)"* ]]
  in_repo "$repo" tailnet-doctor nobody
  [[ "$output" == *"route:   nobody -> direct (a node of no installed tailnet)"* ]]
  # A dropped helper (Claude Code's shell snapshot has done this) is named
  # first, before any line that would silently misreport without it.
  in_repo "$repo" "unfunction tailnet_for_cmd; tailnet-doctor 2>/dev/null"
  [[ "$output" == *"defined: MISSING tailnet_for_cmd — a shell snapshot or partial source dropped them; source ~/.functions again"* ]]
  [[ "$output" == *"helpers: BROKEN — tailnet-doctor:"*"command not found: tailnet_for_cmd (the wrappers run every command direct until this is fixed)"* ]]
}

@test "tailnet-doctor: helpers: runs the real decision path and reports the first thing that breaks" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  # The wrappers fail open, so a crashed helper is silent there; the doctor
  # names it — in the default shell and under Claude Code's options.
  for shell_opts in "" "$CLAUDE_CODE_OPTS"; do
    ZOPTS=$shell_opts in_repo "$repo" "tailnet_ssh_host() { $CRASH; }; tailnet-doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"helpers: BROKEN — tailnet_ssh_host: no matches found: /nonexistent-tailnet-test/*/port (the wrappers run every command direct until this is fixed)"* ]]
    ZOPTS=$shell_opts in_repo "$repo" "tailnet_curl_host() { $CRASH; }; tailnet-doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"helpers: BROKEN — tailnet_curl_host: no matches found:"* ]]
  done
  # A crash in a helper the doctor itself later calls bare (tailnet_active)
  # kills a non-interactive shell mid-doctor — which is exactly why helpers:
  # is printed first: the diagnosis is on screen before that happens.
  in_repo "$repo" "tailnet_active() { $CRASH; }; tailnet-doctor"
  [[ "$output" == *"helpers: BROKEN — tailnet_active: no matches found:"* ]]
  # A verdict for a host no tailnet has means misrouting, the opposite of
  # direct — its own wording.
  cat > "$TAILNET_BIN" <<'STUB'
#!/bin/sh
case $1 in route) echo work;; names) printf 'personal\nwork\n';; *) exit 0;; esac
STUB
  in_repo "$repo" tailnet-doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"helpers: BROKEN — verdict 'work' for tailnet-doctor-probe, a host no tailnet has (the wrappers would proxy hosts that are nodes nowhere)"* ]]
  # Under tailnet-as, TAILNET is set: the probe must not read the forced
  # verdict as breakage.
  cp "$BATS_TEST_DIRNAME/../bin/executable_tailnet" "$TAILNET_BIN"
  in_repo "$repo" "TAILNET=work tailnet-doctor"
  [[ "$output" == *"helpers: ok"* ]]
  # No machinery at all: the decision path exits early, and that is fine.
  rm -rf "$STATE"
  in_repo "$repo" tailnet-doctor
  [[ "$output" == *"helpers: ok"* ]]
}

@test "tailnet-doctor: mapped but not installed, repo pin, forced TAILNET" {
  repo=$(make_repo 'git@github.com:octo-newbie/some-repo.git')
  in_repo "$repo" tailnet-doctor
  [[ "$output" == *"mapping: tailnet.profile.newbie-account = never-installed"* ]]
  [[ "$output" == *"wants:   never-installed — NOT INSTALLED — run: tailnet install never-installed && tailnet up never-installed"* ]]
  repo=$(make_repo 'git@github.com:octo-personal/side-project.git')
  in_repo "$repo" tailnet-doctor
  [[ "$output" == *"repo pin: tailnet.octo-personal/side-project.profile = work"* ]]
  [[ "$output" == *"wants:   work first, then the other installed tailnets"* ]]
  in_repo "$repo" "TAILNET=personal tailnet-doctor 10.9.8.7"
  [[ "$output" == *"wants:   personal (forced via TAILNET — node check skipped)"* ]]
  [[ "$output" == *"route:   10.9.8.7 -> direct (a node of the tailnet the app is on)"* ]]
  rm -rf "$STATE"
  in_repo "$repo" tailnet-doctor
  [[ "$output" == *"<no tailnet installed — tailnet install <name> && tailnet up <name>>"* ]]
}

@test "doctor: runs the tailnet doctor after the others" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  in_repo "$repo" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"== wrangler-doctor"*"== tailnet-doctor"*"wants:   personal first"* ]]
}

@test "doctor: opens with the calling shell's version and pattern options, read before any emulate" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  ver=$(zsh -c 'print -r -- $ZSH_VERSION')
  # A plain non-interactive zsh with no rc files: nothing off default.
  in_repo "$repo" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == "shell:   zsh $ver, options: none"$'\n'* ]]
  # Claude Code's Bash tool: its marker and its option set, in setopt's order.
  ZOPTS=$CLAUDE_CODE_OPTS in_repo "$repo" "CLAUDECODE=1 doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == "shell:   zsh $ver, under Claude Code, options: nobareglobqual nocaseglob globstarshort (the tailnet wrappers reset these with emulate -L zsh)"$'\n'* ]]
  # The marker alone, options alone.
  in_repo "$repo" "CLAUDECODE=1 doctor"
  [[ "$output" == "shell:   zsh $ver, under Claude Code, options: none"$'\n'* ]]
  ZOPTS="extendedglob nomatch" in_repo "$repo" doctor
  [[ "$output" == "shell:   zsh $ver, options: extendedglob (the tailnet wrappers reset these with emulate -L zsh)"$'\n'* ]]
  # The line comes from the caller's options even though the doctors that
  # follow emulate their own: the tailnet doctor still works underneath.
  ZOPTS=$CLAUDE_CODE_OPTS in_repo "$repo" doctor
  [[ "$output" == *"== tailnet-doctor"*"helpers: ok"* ]]
}
