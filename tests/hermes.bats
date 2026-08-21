#!/usr/bin/env bats

# The hermes() wrapper in dot_functions routes the Hermes harness through a
# per-repo profile pin (hermes.profile), refuses a foreign -p/--profile in a
# pinned repo, optionally appends a pinned --model (hermes.model), and — when
# the effective profile's config.yaml points at a local ollama endpoint —
# probes the port and starts `ollama serve` when nothing answers. These tests
# source the real functions under zsh against sandboxed git config, a fake
# $HOME/.hermes profile store, and stub hermes/ollama/curl binaries. All pins
# are test fixtures — no real profile or model names (see CLAUDE.md).
#
# CI can only guard the source copy: a machine that hasn't run
# `chezmoi apply` still runs whatever ~/.functions it last deployed.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  unset HERMES_HOME

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # Stub hermes: prove the argv the wrapper handed it, and that it ran at all.
  cat > "$BATS_TEST_TMPDIR/bin/hermes" <<'STUB'
#!/bin/sh
touch "$BATS_TEST_TMPDIR/hermes-invoked"
echo "ARGS=$*"
STUB
  # Stub ollama: log the invocation (with OLLAMA_HOST) and bring the fake
  # server "up" so the wrapper's readiness wait succeeds immediately.
  cat > "$BATS_TEST_TMPDIR/bin/ollama" <<'STUB'
#!/bin/sh
printf '%s\n' "OLLAMA_HOST=${OLLAMA_HOST-UNSET} $*" >> "$BATS_TEST_TMPDIR/ollama.log"
touch "$BATS_TEST_TMPDIR/ollama-up"
STUB
  # Stub curl: the wrapper's port probe. Up iff the flag file exists.
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/curl.log"
[ -e "$BATS_TEST_TMPDIR/ollama-up" ] && exit 0
exit 7
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  DOTFUNCTIONS="$BATS_TEST_DIRNAME/../dot_functions"
}

# Make a bare-bones repo (optionally pinned to profile $1); prints its path.
make_repo() {
  local repo="$BATS_TEST_TMPDIR/repo"
  rm -rf "$repo"
  git init -q "$repo"
  [ -n "${1-}" ] && git -C "$repo" config hermes.profile "$1"
  echo "$repo"
}

# Write a profile config.yaml: make_profile <name> <provider> [base_url].
# A trailing top-level key proves the model: block parse stops where it should.
make_profile() {
  local dir="$HOME/.hermes/profiles/$1"
  [ "$1" = default ] && dir="$HOME/.hermes"
  mkdir -p "$dir"
  {
    echo "model:"
    echo "    api_key: x"
    [ -n "${3-}" ] && echo "    base_url: $3"
    echo "    default: some-model"
    echo "    provider: $2"
    echo "providers:"
    echo "    other: {}"
  } > "$dir/config.yaml"
}

hermes_in() {
  local dir="$1"; shift
  run zsh -c "source '$DOTFUNCTIONS'; cd '$dir'; hermes $*"
}

@test "dot_functions defines the hermes wrapper and its ollama helper" {
  run zsh -c "source '$DOTFUNCTIONS'; whence -w hermes hermes_ensure_ollama"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hermes: function"* ]]
  [[ "$output" == *"hermes_ensure_ollama: function"* ]]
}

@test "unpinned directory passes through untouched" {
  hermes_in "$BATS_TEST_TMPDIR" chat --foo
  [ "$status" -eq 0 ]
  [ "$output" = "ARGS=chat --foo" ]
  [ ! -e "$BATS_TEST_TMPDIR/ollama.log" ]
}

@test "pinned repo injects -p <profile> first" {
  repo=$(make_repo hardened)
  hermes_in "$repo" chat
  [ "$status" -eq 0 ]
  [ "$output" = "ARGS=-p hardened chat" ]
}

@test "pinned repo refuses a foreign -p and never launches hermes" {
  repo=$(make_repo hardened)
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; hermes -p other 2>'$BATS_TEST_TMPDIR/stderr'"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$BATS_TEST_TMPDIR/hermes-invoked" ]
  grep -q "pinned to profile 'hardened'" "$BATS_TEST_TMPDIR/stderr"
  grep -q "refusing explicit '-p other'" "$BATS_TEST_TMPDIR/stderr"
}

@test "pinned repo refuses a foreign --profile=<name> too" {
  repo=$(make_repo hardened)
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; hermes --profile=other 2>'$BATS_TEST_TMPDIR/stderr'"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/hermes-invoked" ]
  grep -q "refusing explicit '--profile other'" "$BATS_TEST_TMPDIR/stderr"
}

@test "explicitly naming the pinned profile is a no-op, not a duplicate flag" {
  repo=$(make_repo hardened)
  hermes_in "$repo" -p hardened chat
  [ "$status" -eq 0 ]
  [ "$output" = "ARGS=-p hardened chat" ]
}

@test "a -p after -- belongs to the child command, not the profile scan" {
  repo=$(make_repo hardened)
  hermes_in "$repo" -- -p other
  [ "$status" -eq 0 ]
  [ "$output" = "ARGS=-p hardened -- -p other" ]
}

@test "a -p value that cannot be a profile name is not a profile selection" {
  # Mirrors hermes' own guard (e.g. pytest's `-p no:xdist` passthrough).
  repo=$(make_repo hardened)
  hermes_in "$repo" -p no:xdist
  [ "$status" -eq 0 ]
  [ "$output" = "ARGS=-p hardened -p no:xdist" ]
}

@test "a lingering hermes.launcher pin is refused with the migration printed" {
  repo=$(make_repo hardened)
  git -C "$repo" config hermes.launcher bin/hermes
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; hermes 2>'$BATS_TEST_TMPDIR/stderr'"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/hermes-invoked" ]
  grep -q 'hermes.launcher pin is retired' "$BATS_TEST_TMPDIR/stderr"
  grep -q 'git config --unset hermes.launcher' "$BATS_TEST_TMPDIR/stderr"
}

@test "hermes.model pin appends --model after the profile flag" {
  repo=$(make_repo hardened)
  git -C "$repo" config hermes.model fixture-model
  hermes_in "$repo" chat
  [ "$status" -eq 0 ]
  [ "$output" = "ARGS=-p hardened --model fixture-model chat" ]
}

@test "an explicit -m outranks the hermes.model pin" {
  repo=$(make_repo hardened)
  git -C "$repo" config hermes.model fixture-model
  hermes_in "$repo" -m user-model chat
  [ "$status" -eq 0 ]
  [ "$output" = "ARGS=-p hardened -m user-model chat" ]
}

@test "local ollama profile with the server down starts ollama serve and still launches" {
  repo=$(make_repo hardened)
  make_profile hardened ollama-launch 'http://127.0.0.1:11434/v1'
  hermes_in "$repo" chat
  [ "$status" -eq 0 ]
  [ "$output" = "ARGS=-p hardened chat" ]
  grep -q '^OLLAMA_HOST=127.0.0.1:11434 serve$' "$BATS_TEST_TMPDIR/ollama.log"
}

@test "local ollama profile with the server up starts nothing" {
  repo=$(make_repo hardened)
  make_profile hardened ollama-launch 'http://127.0.0.1:11434/v1'
  touch "$BATS_TEST_TMPDIR/ollama-up"
  hermes_in "$repo" chat
  [ "$status" -eq 0 ]
  [ "$output" = "ARGS=-p hardened chat" ]
  [ ! -e "$BATS_TEST_TMPDIR/ollama.log" ]
}

@test "cloud-provider profile never probes or spawns a local server" {
  repo=$(make_repo hardened)
  make_profile hardened openrouter 'https://example.invalid/api/v1'
  hermes_in "$repo" chat
  [ "$status" -eq 0 ]
  [ "$output" = "ARGS=-p hardened chat" ]
  [ ! -e "$BATS_TEST_TMPDIR/curl.log" ]
  [ ! -e "$BATS_TEST_TMPDIR/ollama.log" ]
}

@test "ollama-named provider on a non-loopback base_url is left alone" {
  # A LAN/WireGuard ollama endpoint is not ours to start.
  repo=$(make_repo hardened)
  make_profile hardened ollama 'http://192.168.1.50:11434/v1'
  hermes_in "$repo" chat
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/ollama.log" ]
}

@test "unpinned launch still ensures ollama for the root config" {
  make_profile default ollama 'http://127.0.0.1:11434/v1'
  hermes_in "$BATS_TEST_TMPDIR" chat
  [ "$status" -eq 0 ]
  [ "$output" = "ARGS=chat" ]
  grep -q 'serve' "$BATS_TEST_TMPDIR/ollama.log"
}

@test "an explicit -p in an unpinned directory ensures that profile's server" {
  make_profile side ollama-launch 'http://127.0.0.1:11500/v1'
  hermes_in "$BATS_TEST_TMPDIR" -p side chat
  [ "$status" -eq 0 ]
  [ "$output" = "ARGS=-p side chat" ]
  grep -q '^OLLAMA_HOST=127.0.0.1:11500 serve$' "$BATS_TEST_TMPDIR/ollama.log"
}

@test "works under Claude Code's zsh options (no bare glob qualifiers)" {
  # Same non-default options as tests/tailnet.bats; emulate -L zsh in the
  # wrapper must shield the routing from them.
  repo=$(make_repo hardened)
  make_profile hardened ollama-launch 'http://127.0.0.1:11434/v1'
  opts="no_bare_glob_qual no_case_glob glob_star_short no_extended_glob nomatch"
  run zsh -c "setopt $opts; source '$DOTFUNCTIONS'; cd '$repo'; hermes chat"
  [ "$status" -eq 0 ]
  [ "$output" = "ARGS=-p hardened chat" ]
  grep -q 'serve' "$BATS_TEST_TMPDIR/ollama.log"
}
