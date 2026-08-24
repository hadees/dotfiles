#!/usr/bin/env bats

# onepassword-doctor in dot_functions reports the three connections 1Password
# reaches this machine over — the op CLI's session, the SSH agent ssh/git will
# use, and op-ssh-sign — plus whether ~/.extra hides a routed token and
# whether the .claude/skills/onepassword notes were written against the
# software installed here. Sandboxed HOME and PATH; op, ssh, and ssh-add are
# stubs, so no vault, agent, or network is touched.
#
# The app bundle and op-ssh-sign live at absolute paths that cannot be stubbed,
# so assertions about those lines check the label and the shape rather than a
# fixed verdict: the same tests have to pass on a mac with 1Password installed
# and on a Linux CI runner without it. All names here are fixtures — no real
# account, vault, or item may appear (see CLAUDE.md).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  unset CLAUDECODE

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  DOTFUNCTIONS="$BATS_TEST_DIRNAME/../dot_functions"

  # The stamp shipped with the skill, so the fixture and the real thing can
  # never drift apart in what they claim the format is.
  REAL_STAMP="$BATS_TEST_DIRNAME/../.claude/skills/onepassword/VERSIONS"
  STAMP="$BATS_TEST_TMPDIR/VERSIONS"
}

# Run onepassword-doctor with $BIN first on PATH and the version helpers
# pinned to $1 (op) and $2 (app), so the skill: line is exercised without
# depending on what this machine happens to have installed.
doctor_with_versions() {
  run zsh -c "
    PATH='$BIN':\$PATH
    source '$DOTFUNCTIONS'
    onepassword_cli_version() { print -r -- '$1' }
    onepassword_app_version() { print -r -- '$2' }
    ONEPASSWORD_SKILL_STAMP='$STAMP' onepassword-doctor
  "
}

stub() {
  printf '#!/bin/sh\n%s\n' "$2" > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# --- The stamp file --------------------------------------------------------

@test "the skill ships a stamp naming both components" {
  [ -r "$REAL_STAMP" ]
  run awk '$1 == "op" {print $2}' "$REAL_STAMP"
  [[ "$output" == *.*.* ]]
  run awk '$1 == "app" {print $2}' "$REAL_STAMP"
  [[ "$output" == *.*.* ]]
}

@test "onepassword_stamp_file: the override wins, then the pinned source dir" {
  printf 'op 1.2.3\napp 4.5.6\n' > "$STAMP"
  run zsh -c "source '$DOTFUNCTIONS'; ONEPASSWORD_SKILL_STAMP='$STAMP' onepassword_stamp_file"
  [ "$status" -eq 0 ]
  [ "$output" = "$STAMP" ]

  # An override pointing at nothing falls through to the next candidate.
  local pinned="$HOME/code/dotfiles/.claude/skills/onepassword"
  mkdir -p "$pinned"
  printf 'op 9.9.9\napp 9.9.9\n' > "$pinned/VERSIONS"
  run zsh -c "source '$DOTFUNCTIONS'; ONEPASSWORD_SKILL_STAMP='$BATS_TEST_TMPDIR/absent' onepassword_stamp_file"
  [ "$status" -eq 0 ]
  [ "$output" = "$pinned/VERSIONS" ]
}

@test "onepassword_stamp_file: no stamp anywhere returns 1 and prints nothing" {
  run zsh -c "PATH='$BIN'; source '$DOTFUNCTIONS'; ONEPASSWORD_SKILL_STAMP= onepassword_stamp_file"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# --- The version nudge -----------------------------------------------------

@test "skill: matching versions report no drift" {
  printf 'op 2.39.0\napp 8.12.33\n' > "$STAMP"
  doctor_with_versions 2.39.0 8.12.33
  [ "$status" -eq 0 ]
  [[ "$output" == *"skill:   written against op 2.39.0 / app 8.12.33 — matches what is installed"* ]]
  [[ "$output" != *"refresh it"* ]]
}

@test "skill: a newer op nudges and names both the stamp and the install" {
  printf 'op 2.39.0\napp 8.12.33\n' > "$STAMP"
  doctor_with_versions 2.41.0 8.12.33
  [ "$status" -eq 0 ]
  [[ "$output" == *"written against op 2.39.0 / app 8.12.33"* ]]
  [[ "$output" == *"installed is op 2.41.0 / app 8.12.33"* ]]
  [[ "$output" == *"refresh it (${STAMP%/*})"* ]]
}

@test "skill: a newer app nudges too" {
  printf 'op 2.39.0\napp 8.12.33\n' > "$STAMP"
  doctor_with_versions 2.39.0 8.13.4
  [[ "$output" == *"installed is op 2.39.0 / app 8.13.4"* ]]
  [[ "$output" == *"refresh it"* ]]
}

@test "skill: an unreadable install version is reported, not silently matched" {
  printf 'op 2.39.0\napp 8.12.33\n' > "$STAMP"
  run zsh -c "
    PATH='$BIN':\$PATH
    source '$DOTFUNCTIONS'
    onepassword_cli_version() { return 1 }
    onepassword_app_version() { return 1 }
    ONEPASSWORD_SKILL_STAMP='$STAMP' onepassword-doctor
  "
  [[ "$output" == *"installed is op unknown / app unknown"* ]]
  [[ "$output" == *"refresh it"* ]]
}

@test "skill: no stamp reachable is stated plainly and is not an error" {
  run zsh -c "
    PATH='$BIN'
    source '$DOTFUNCTIONS'
    ONEPASSWORD_SKILL_STAMP= onepassword-doctor
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"skill:   no version stamp reachable"* ]]
}

# --- The three connections -------------------------------------------------

@test "cli: a signed-out op is called out with the remedy" {
  printf 'op 1.2.3\napp 4.5.6\n' > "$STAMP"
  stub op 'exit 1'
  doctor_with_versions 1.2.3 4.5.6
  [[ "$output" == *"cli:     NOT signed in — run: op signin"* ]]
}

@test "cli: a signed-in op says so, and no op at all is not an error" {
  printf 'op 1.2.3\napp 4.5.6\n' > "$STAMP"
  stub op 'exit 0'
  doctor_with_versions 1.2.3 4.5.6
  [[ "$output" == *"cli:     signed in"* ]]

  # PATH without any op: the line degrades instead of the doctor dying.
  run zsh -c "PATH=/usr/bin:/bin; source '$DOTFUNCTIONS'; ONEPASSWORD_SKILL_STAMP='$STAMP' onepassword-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cli:     no op on PATH"* ]]
  [[ "$output" == *"binary:  NOT FOUND on PATH"* ]]
}

@test "agent: the IdentityAgent ssh resolves is reported, present or missing" {
  printf 'op 1.2.3\napp 4.5.6\n' > "$STAMP"
  local sock="$BATS_TEST_TMPDIR/agent.sock"
  stub ssh "echo 'identityagent $sock'"
  doctor_with_versions 1.2.3 4.5.6
  [[ "$output" == *"agent:   $sock — MISSING"* ]]

  # With a real socket there, it reports it as present. zsh can make one.
  zsh -c "zmodload zsh/net/socket && zsocket -l '$sock'" 2>/dev/null || skip "no zsh/net/socket"
  doctor_with_versions 1.2.3 4.5.6
  [[ "$output" == *"agent:   $sock (socket present)"* ]]
}

@test "agent: no IdentityAgent in ssh_config says ssh falls back to the env" {
  printf 'op 1.2.3\napp 4.5.6\n' > "$STAMP"
  stub ssh 'echo "hostname example.com"'
  doctor_with_versions 1.2.3 4.5.6
  [[ "$output" == *"agent:   no IdentityAgent in ssh_config"* ]]
}

@test "ssh-add is reported separately from the agent, since it reads neither" {
  printf 'op 1.2.3\napp 4.5.6\n' > "$STAMP"
  stub ssh 'echo "identityagent /nonexistent/agent.sock"'
  stub ssh-add 'echo "256 SHA256:aaaa key-one (ED25519)"; echo "256 SHA256:bbbb key-two (ED25519)"; exit 0'
  SSH_AUTH_SOCK=/some/other/agent.sock doctor_with_versions 1.2.3 4.5.6
  [[ "$output" == *"env:     SSH_AUTH_SOCK=/some/other/agent.sock"* ]]
  [[ "$output" == *"ssh-add: 2 key(s) offered by \$SSH_AUTH_SOCK"* ]]
  # The agent line still reports the socket ssh would use, not ssh-add's.
  [[ "$output" == *"agent:   /nonexistent/agent.sock — MISSING"* ]]

  stub ssh-add 'echo "The agent has no identities."; exit 1'
  doctor_with_versions 1.2.3 4.5.6
  [[ "$output" == *"ssh-add: none from \$SSH_AUTH_SOCK"* ]]
  [[ "$output" == *"ssh-add never reads ssh_config"* ]]
}

@test "signer: the op-ssh-sign line is always present" {
  printf 'op 1.2.3\napp 4.5.6\n' > "$STAMP"
  doctor_with_versions 1.2.3 4.5.6
  [[ "$output" == *"signer:  "*"op-ssh-sign"* ]]
}

# --- ~/.extra --------------------------------------------------------------

@test "extra: a routed token is flagged by NAME and its value never printed" {
  printf 'op 1.2.3\napp 4.5.6\n' > "$STAMP"
  printf 'export GH_TOKEN=%s\nexport SOME_OTHER=%s\n' \
    "not-a-real-token-abc123" "harmless" > "$HOME/.extra"
  doctor_with_versions 1.2.3 4.5.6
  [[ "$output" == *"extra:   ~/.extra mentions ROUTED GH_TOKEN"* ]]
  [[ "$output" == *"op run --env-file"* ]]
  # The whole point: the value must never reach the terminal.
  [[ "$output" != *"not-a-real-token-abc123"* ]]
}

@test "extra: several routed names are listed, unrouted ones are not" {
  printf 'op 1.2.3\napp 4.5.6\n' > "$STAMP"
  printf 'export CLOUDFLARE_API_TOKEN=x\nexport CLAUDE_CONFIG_DIR=y\nexport EDITOR=vim\n' \
    > "$HOME/.extra"
  doctor_with_versions 1.2.3 4.5.6
  [[ "$output" == *"ROUTED CLAUDE_CONFIG_DIR, CLOUDFLARE_API_TOKEN"* ]]
  [[ "$output" != *"EDITOR"* ]]
}

@test "extra: a clean or absent ~/.extra says so without alarm" {
  printf 'op 1.2.3\napp 4.5.6\n' > "$STAMP"
  doctor_with_versions 1.2.3 4.5.6
  [[ "$output" == *"extra:   ~/.extra absent"* ]]

  printf 'export EDITOR=vim\n' > "$HOME/.extra"
  doctor_with_versions 1.2.3 4.5.6
  [[ "$output" == *"extra:   ~/.extra present, no routed token names in it"* ]]
  [[ "$output" != *"ROUTED"* ]]
}

# --- House style -----------------------------------------------------------

@test "onepassword-doctor: labels are aligned and it opens with defined:" {
  printf 'op 1.2.3\napp 4.5.6\n' > "$STAMP"
  doctor_with_versions 1.2.3 4.5.6
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "defined: ok (4 helpers)" ]]
  # Every line is "<label>:" padded to a common column, like the other doctors.
  run zsh -c "
    PATH='$BIN':\$PATH
    source '$DOTFUNCTIONS'
    onepassword_cli_version() { print -r -- 1.2.3 }
    onepassword_app_version() { print -r -- 4.5.6 }
    ONEPASSWORD_SKILL_STAMP='$STAMP' onepassword-doctor \
      | grep -vE '^[a-z-]+:( )+[^ ]' && print BADLINE
  "
  [[ "$output" != *BADLINE* ]]
}

@test "onepassword-doctor: a dropped helper is named before anything using it" {
  printf 'op 1.2.3\napp 4.5.6\n' > "$STAMP"
  run zsh -c "
    PATH='$BIN':\$PATH
    source '$DOTFUNCTIONS'
    unfunction onepassword_stamp_file
    ONEPASSWORD_SKILL_STAMP='$STAMP' onepassword-doctor 2>/dev/null
  "
  [[ "${lines[0]}" == "defined: MISSING onepassword_stamp_file — "* ]]
}
