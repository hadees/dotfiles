#!/usr/bin/env bats

# The claude() wrapper in dot_functions picks a Claude Code config directory
# from the cwd's origin remote, via the credential.<url>.username pins and
# claude.profile.<account> mappings in git config. These tests source the
# real functions under zsh against a sandboxed git config, fake repos with
# every supported origin-URL shape, and a stub `claude` binary that reports
# the CLAUDE_CONFIG_DIR it was launched with. All pins here are test
# fixtures — no real account or org names may appear (see CLAUDE.md).
#
# CI can only guard the source copy: a machine that hasn't run
# `chezmoi apply` still runs whatever ~/.functions it last deployed.
# tests/chezmoi.bats guards that the file renders at all.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  unset CLAUDE_PROFILE CLAUDE_CONFIG_DIR

  # Fixture pins: one "work" org and one "personal" owner, mapped to two
  # accounts; work maps to the default dir, personal to a separate profile.
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-work-org.username work-account
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-personal.username personal-account
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.work-account '~/.claude'
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.personal-account '~/.claude-personal'
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

  # Stub claude: prove which config dir (if any) the wrapper handed it.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR-UNSET}"\n' \
    > "$BATS_TEST_TMPDIR/bin/claude"
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  DOTFUNCTIONS="$BATS_TEST_DIRNAME/../dot_functions"
}

# Make a bare-bones repo whose origin is $1; prints its path.
make_repo() {
  local repo="$BATS_TEST_TMPDIR/repo"
  rm -rf "$repo"
  git init -q "$repo"
  git -C "$repo" remote add origin "$1"
  echo "$repo"
}

account_in() {
  run zsh -c "source '$DOTFUNCTIONS'; cd '$1'; gh_account_for_cwd"
}

claude_in() {
  run zsh -c "source '$DOTFUNCTIONS'; cd '$1'; claude"
}

@test "dot_functions defines the claude wrapper and account resolver" {
  run zsh -c "source '$DOTFUNCTIONS'; whence -w claude gh_account_for_cwd gh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude: function"* ]]
  [[ "$output" == *"gh_account_for_cwd: function"* ]]
  [[ "$output" == *"gh: function"* ]]
}

@test "resolver: SSH host-alias origin resolves through the owner segment" {
  repo=$(make_repo 'git@github-workalias:octo-work-org/some-repo.git')
  account_in "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "work-account" ]
}

@test "resolver: plain github.com SSH origin resolves" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  account_in "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "personal-account" ]
}

@test "resolver: HTTPS origin resolves" {
  repo=$(make_repo 'https://github.com/octo-work-org/some-repo.git')
  account_in "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "work-account" ]
}

@test "resolver: unpinned owner fails silently" {
  repo=$(make_repo 'git@github.com:someone-else/some-repo.git')
  account_in "$repo"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "resolver: outside any git repo fails silently" {
  account_in "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "claude: repo mapped to the default dir runs with CLAUDE_CONFIG_DIR unset" {
  # Keychain regression guard: setting CLAUDE_CONFIG_DIR at all — even to
  # ~/.claude itself — switches Claude Code off Keychain auth.
  repo=$(make_repo 'git@github-workalias:octo-work-org/some-repo.git')
  claude_in "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "CLAUDE_CONFIG_DIR=UNSET" ]
}

@test "claude: repo mapped to a non-default profile exports its expanded dir" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  claude_in "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "CLAUDE_CONFIG_DIR=$HOME/.claude-personal" ]
}

@test "claude: unpinned repo falls back to plain claude" {
  repo=$(make_repo 'git@github.com:someone-else/some-repo.git')
  claude_in "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "CLAUDE_CONFIG_DIR=UNSET" ]
}

@test "claude: CLAUDE_PROFILE account override beats the cwd" {
  repo=$(make_repo 'git@github-workalias:octo-work-org/some-repo.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; CLAUDE_PROFILE=personal-account claude"
  [ "$status" -eq 0 ]
  [ "$output" = "CLAUDE_CONFIG_DIR=$HOME/.claude-personal" ]
}

@test "claude: CLAUDE_PROFILE literal directory override is used as-is" {
  repo=$(make_repo 'git@github-workalias:octo-work-org/some-repo.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; CLAUDE_PROFILE='$BATS_TEST_TMPDIR/custom-profile' claude"
  [ "$status" -eq 0 ]
  [ "$output" = "CLAUDE_CONFIG_DIR=$BATS_TEST_TMPDIR/custom-profile" ]
}

@test "claude-doctor: traces resolution and flags a missing login" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; claude-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrapper: claude: function"* ]]
  [[ "$output" == *"defined: ok (4 helpers)"* ]]
  [[ "$output" == *"binary:  $BATS_TEST_TMPDIR/bin/claude"* ]]
  [[ "$output" == *"account: personal-account"* ]]
  [[ "$output" == *"launch:  $HOME/.claude-personal"* ]]
  [[ "$output" == *"NOT LOGGED IN"* ]]
  # A helper the wrapper needs is gone (Claude Code's shell snapshot has
  # dropped functions before): named, before any line that depends on it.
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; unfunction claude_profile_dir; claude-doctor 2>/dev/null"
  [[ "$output" == *"defined: MISSING claude_profile_dir — a shell snapshot or partial source dropped them; source ~/.functions again"* ]]
}

@test "claude-doctor: names the logged-in account from the profile's .claude.json" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  mkdir -p "$HOME/.claude-personal"
  echo '{"oauthAccount":{"emailAddress":"person@example.com"}}' \
    > "$HOME/.claude-personal/.claude.json"
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; claude-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"logged in as person@example.com"* ]]
}

@test "personal profile settings guard every cross-profile path" {
  # The statusline script is installed into ~/.claude by the work profile's
  # private marketplace. The public source must not hard-depend on it (or on
  # anything else the overlay provides): any reference to the work profile
  # dir in the personal settings must sit behind an existence check, so a
  # public-only machine gets a silent no-op instead of a dead command.
  f="$BATS_TEST_DIRNAME/../private_dot_claude-hadees/settings.json"
  while IFS= read -r line; do
    [[ "$line" == *'[ -x '* || "$line" == *'[ -f '* ]] || {
      echo "unguarded work-profile reference: $line"
      return 1
    }
  done < <(grep -F '.claude/' "$f" || true)
}

@test "no underscore-prefixed function names in dot_functions" {
  # Claude Code's shell snapshot (Bash tool, `!` commands) carries shell
  # functions over but silently drops underscore-prefixed ones, leaving
  # callers like claude() half-defined in those shells.
  run grep -En '^(function +_|_[A-Za-z0-9_]+ *\(\))' "$BATS_TEST_DIRNAME/../dot_functions"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "claude-doctor: unpinned repo reports the bare-claude fallback" {
  repo=$(make_repo 'git@github.com:someone-else/some-repo.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; claude-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"account: <no credential pin matched>"* ]]
  [[ "$output" == *"(bare claude fallback)"* ]]
}

@test "resolver: mixed-case origin owner resolves through the lowercase pin" {
  # GitHub owners are case-insensitive; the pins are recorded lowercase.
  repo=$(make_repo 'git@github.com:Octo-Personal/Some-Repo.git')
  account_in "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "personal-account" ]
}

@test "claude: non-repo cwd uses claude.profile.default when pinned" {
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.default '~/.claude-fallback'
  claude_in "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "CLAUDE_CONFIG_DIR=$HOME/.claude-fallback" ]
}

@test "claude: non-repo cwd without a default pin stays bare claude" {
  claude_in "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "CLAUDE_CONFIG_DIR=UNSET" ]
}

@test "claude: CLAUDE_PROFILE typo warns on stderr and falls back to the default profile" {
  # A typo'd account name must not become a relative CLAUDE_CONFIG_DIR — the
  # wrapper warns and launches the default profile instead, even in a repo
  # that would otherwise have mapped to a non-default one.
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; CLAUDE_PROFILE=presonal-account claude 2>'$BATS_TEST_TMPDIR/stderr'"
  [ "$status" -eq 0 ]
  [ "$output" = "CLAUDE_CONFIG_DIR=UNSET" ]
  grep -q "CLAUDE_PROFILE='presonal-account' is neither a mapped account nor a directory" \
    "$BATS_TEST_TMPDIR/stderr"
}

@test "typo alias: cladue routes through the same profile selection as claude" {
  # dot_aliases maps fat-fingered spellings to `claude`, which must expand to
  # the wrapper function, not a bare binary. `eval` forces alias expansion
  # after both files are sourced.
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  run zsh -c "source '$BATS_TEST_DIRNAME/../dot_aliases'; source '$DOTFUNCTIONS'; cd '$repo'; eval cladue"
  [ "$status" -eq 0 ]
  [ "$output" = "CLAUDE_CONFIG_DIR=$HOME/.claude-personal" ]
}

# --- dotfiles() sequencing -------------------------------------------------
#
# dotfiles() applies the public source, then every overlay config in
# ~/.config/chezmoi/*.toml (skipping chezmoi.toml itself) whose source clone
# exists. The stub chezmoi logs each invocation's argv to $CHEZMOI_LOG,
# answers `--config <cfg> source-path` from a companion `<cfg>.src` file
# (which never matches the *.toml glob), and fails the plain `apply` when
# $CHEZMOI_FAIL exists.

make_chezmoi_stub() {
  CHEZMOI_LOG="$BATS_TEST_TMPDIR/chezmoi.log"
  CHEZMOI_FAIL="$BATS_TEST_TMPDIR/chezmoi.fail"
  : > "$CHEZMOI_LOG"
  cat > "$BATS_TEST_TMPDIR/bin/chezmoi" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/chezmoi.log"
case " $* " in
  *" source-path "*)
    cfg=
    while [ $# -gt 0 ]; do
      [ "$1" = --config ] && cfg=$2
      shift
    done
    cat "$cfg.src" 2>/dev/null
    exit 0
    ;;
esac
if [ "$*" = apply ] && [ -e "$BATS_TEST_TMPDIR/chezmoi.fail" ]; then
  exit 1
fi
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/chezmoi"
}

# Add an overlay config named $1 whose stubbed source-path answer is $2.
make_overlay_cfg() {
  mkdir -p "$HOME/.config/chezmoi"
  touch "$HOME/.config/chezmoi/$1"
  echo "$2" > "$HOME/.config/chezmoi/$1.src"
}

@test "dotfiles: touches ~/.finicky.ts after applying, only if it exists" {
  make_chezmoi_stub
  # Finicky caches its bundled config on this file's mtime; overlay fragments
  # it imports change without touching it, so dotfiles() bumps it.
  touch -t 200001010000 "$HOME/.finicky.ts"
  run zsh -c "source '$DOTFUNCTIONS'; dotfiles"
  [ "$status" -eq 0 ]
  [ "$(date -r "$HOME/.finicky.ts" +%Y)" != 2000 ]
  # Absent, it must not be created.
  rm "$HOME/.finicky.ts"
  run zsh -c "source '$DOTFUNCTIONS'; dotfiles"
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.finicky.ts" ]
}

@test "dotfiles: works under Claude Code's zsh options (no bare glob qualifiers)" {
  make_chezmoi_stub
  # Under NO_BARE_GLOB_QUAL the overlay glob's `(N)` is literal text and
  # NOMATCH aborted the function after the public apply, so no overlay was
  # ever applied from such a shell. Same options as tests/tailnet.bats.
  opts="no_bare_glob_qual no_case_glob glob_star_short no_extended_glob nomatch"
  run zsh -c "setopt $opts; source '$DOTFUNCTIONS'; dotfiles"
  [ "$status" -eq 0 ]
  [ "$(cat "$CHEZMOI_LOG")" = "apply" ]
  mkdir -p "$BATS_TEST_TMPDIR/src1"
  make_overlay_cfg one.toml "$BATS_TEST_TMPDIR/src1"
  : > "$CHEZMOI_LOG"
  run zsh -c "setopt $opts; source '$DOTFUNCTIONS'; dotfiles"
  [ "$status" -eq 0 ]
  [ "$(cat "$CHEZMOI_LOG")" = $'apply\n--config '"$HOME"$'/.config/chezmoi/one.toml source-path\n--config '"$HOME"$'/.config/chezmoi/one.toml apply' ]
}

@test "dotfiles: no overlay configs means exactly one apply" {
  make_chezmoi_stub
  run zsh -c "source '$DOTFUNCTIONS'; dotfiles"
  [ "$status" -eq 0 ]
  run cat "$CHEZMOI_LOG"
  [ "$output" = "apply" ]
}

@test "dotfiles: applies each overlay after the public source, in order, with --config" {
  make_chezmoi_stub
  mkdir -p "$BATS_TEST_TMPDIR/src1" "$BATS_TEST_TMPDIR/src2"
  make_overlay_cfg fake1.toml "$BATS_TEST_TMPDIR/src1"
  make_overlay_cfg fake2.toml "$BATS_TEST_TMPDIR/src2"
  # The public config itself must never be re-applied as an overlay.
  touch "$HOME/.config/chezmoi/chezmoi.toml"
  run zsh -c "source '$DOTFUNCTIONS'; dotfiles"
  [ "$status" -eq 0 ]
  run grep 'apply$' "$CHEZMOI_LOG"
  [ "$output" = "apply
--config $HOME/.config/chezmoi/fake1.toml apply
--config $HOME/.config/chezmoi/fake2.toml apply" ]
  ! grep -q 'chezmoi\.toml' "$CHEZMOI_LOG"
}

@test "dotfiles: skips an overlay whose source clone is missing" {
  make_chezmoi_stub
  mkdir -p "$BATS_TEST_TMPDIR/src2"
  make_overlay_cfg fake1.toml "$BATS_TEST_TMPDIR/missing-src"
  make_overlay_cfg fake2.toml "$BATS_TEST_TMPDIR/src2"
  run zsh -c "source '$DOTFUNCTIONS'; dotfiles"
  [ "$status" -eq 0 ]
  ! grep -q 'fake1\.toml apply' "$CHEZMOI_LOG"
  run grep 'apply$' "$CHEZMOI_LOG"
  [ "$output" = "apply
--config $HOME/.config/chezmoi/fake2.toml apply" ]
}

@test "dotfiles: a failed public apply aborts before any overlay runs" {
  make_chezmoi_stub
  touch "$CHEZMOI_FAIL"
  mkdir -p "$BATS_TEST_TMPDIR/src1"
  make_overlay_cfg fake1.toml "$BATS_TEST_TMPDIR/src1"
  run zsh -c "source '$DOTFUNCTIONS'; dotfiles"
  [ "$status" -ne 0 ]
  run cat "$CHEZMOI_LOG"
  [ "$output" = "apply" ]
}

# --- claude-as: explicit per-account launcher ------------------------------
#
# `claude-as <profile> [args...]` pins one invocation to a named profile,
# routing through the claude() wrapper. Fixture mappings only — no real
# account names (see CLAUDE.md).

@test "claude-as: mapped alias pins the profile and forwards args intact" {
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.octo-alias '~/.claude-octo'
  # Extend the stub to also prove the argv it received.
  printf '#!/bin/sh\necho "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR-UNSET}"\necho "ARGS=$*"\n' \
    > "$BATS_TEST_TMPDIR/bin/claude"
  run zsh -c "source '$DOTFUNCTIONS'; claude-as octo-alias -p 'hello world' --model foo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLAUDE_CONFIG_DIR=$HOME/.claude-octo"* ]]
  [[ "$output" == *"ARGS=-p hello world --model foo"* ]]
}

@test "claude-as: stdin passes through to claude untouched" {
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.octo-alias '~/.claude-octo'
  printf '#!/bin/sh\ncat\n' > "$BATS_TEST_TMPDIR/bin/claude"
  run zsh -c "source '$DOTFUNCTIONS'; echo round-trip-marker | claude-as octo-alias"
  [ "$status" -eq 0 ]
  [ "$output" = "round-trip-marker" ]
}

@test "claude-as: unknown profile errors, lists profiles, never launches claude" {
  # An explicit request must never silently fall back to another account.
  printf '#!/bin/sh\ntouch "$BATS_TEST_TMPDIR/claude-invoked"\n' \
    > "$BATS_TEST_TMPDIR/bin/claude"
  run zsh -c "source '$DOTFUNCTIONS'; claude-as no-such-profile 2>'$BATS_TEST_TMPDIR/stderr'"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$BATS_TEST_TMPDIR/claude-invoked" ]
  grep -q "unknown profile 'no-such-profile'" "$BATS_TEST_TMPDIR/stderr"
  grep -q '^work-account$' "$BATS_TEST_TMPDIR/stderr"
  grep -q '^personal-account$' "$BATS_TEST_TMPDIR/stderr"
}

@test "claude-as: no arguments prints usage and the profile list on stderr" {
  run zsh -c "source '$DOTFUNCTIONS'; claude-as 2>'$BATS_TEST_TMPDIR/stderr'"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  grep -q 'usage: claude-as <profile>' "$BATS_TEST_TMPDIR/stderr"
  grep -q '^work-account$' "$BATS_TEST_TMPDIR/stderr"
  grep -q '^personal-account$' "$BATS_TEST_TMPDIR/stderr"
}

@test "claude-as: a literal existing directory works as the profile" {
  mkdir -p "$BATS_TEST_TMPDIR/literal-profile"
  run zsh -c "source '$DOTFUNCTIONS'; claude-as '$BATS_TEST_TMPDIR/literal-profile'"
  [ "$status" -eq 0 ]
  [ "$output" = "CLAUDE_CONFIG_DIR=$BATS_TEST_TMPDIR/literal-profile" ]
}
