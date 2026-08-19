#!/usr/bin/env bats

# The wrangler() wrapper in dot_functions keeps each repo bound to the
# Cloudflare auth profile mapped for its GitHub account: cwd origin ->
# credential.<url>.username pin -> wrangler.profile.<account> -> wrangler's
# own `auth activate <profile> <repo root>` directory binding. These tests
# source the real functions under zsh against a sandboxed git config, fake
# repos, and a stub `wrangler` binary that records its argv and emulates
# `auth activate` against a fake bindings file. All pins here are test
# fixtures — no real account, org, or profile names may appear (see CLAUDE.md).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  unset WRANGLER_PROFILE CLOUDFLARE_API_TOKEN
  # Pin wrangler's config dir so the wrapper's path guess is the same on
  # every platform: $XDG_CONFIG_HOME/.wrangler.
  export XDG_CONFIG_HOME="$HOME/xdg"
  WRANGLER_CFG="$XDG_CONFIG_HOME/.wrangler"
  mkdir -p "$WRANGLER_CFG/config" "$WRANGLER_CFG/profiles"

  # Fixture pins: work maps to wrangler's default login, personal to a named
  # profile that exists; a third account maps to a profile never created.
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-work-org.username work-account
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-personal.username personal-account
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-newbie.username newbie-account
  git config --file "$GIT_CONFIG_GLOBAL" wrangler.profile.work-account default
  git config --file "$GIT_CONFIG_GLOBAL" wrangler.profile.personal-account personal-profile
  git config --file "$GIT_CONFIG_GLOBAL" wrangler.profile.newbie-account never-created
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  : > "$WRANGLER_CFG/config/personal-profile.toml"

  # Stub wrangler: log every invocation's argv; emulate `auth activate
  # <profile> <dir>` (succeeds and records the binding when the profile's
  # config file exists, fails like wrangler otherwise).
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  WRANGLER_LOG="$BATS_TEST_TMPDIR/wrangler.log"
  : > "$WRANGLER_LOG"
  cat > "$BATS_TEST_TMPDIR/bin/wrangler" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/wrangler.log"
cfg="$XDG_CONFIG_HOME/.wrangler"
if [ "$1" = auth ] && [ "$2" = activate ]; then
  if [ -e "$cfg/config/$3.toml" ]; then
    b="$cfg/profiles/directory-bindings.json"
    [ -e "$b" ] || printf '{\n}\n' > "$b"
    printf '{\n\t"%s": "%s"\n}\n' "$4" "$3" > "$b"
    echo "Profile \"$3\" activated for \"$4\"."
    exit 0
  fi
  echo "Profile \"$3\" does not exist. Run \`wrangler auth create $3\` first." >&2
  exit 1
fi
echo "RAN: $*"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/wrangler"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  DOTFUNCTIONS="$BATS_TEST_DIRNAME/../dot_functions"
}

# Make a bare-bones repo whose origin is $1; prints its real path (git
# reports the toplevel with symlinks resolved, so compare against that).
make_repo() {
  local repo="$BATS_TEST_TMPDIR/repo"
  rm -rf "$repo"
  git init -q "$repo"
  git -C "$repo" remote add origin "$1"
  cd "$repo" && pwd -P
}

wrangler_in() {
  local dir=$1; shift
  run zsh -c "source '$DOTFUNCTIONS'; cd '$dir'; wrangler $*"
}

@test "dot_functions defines the wrangler wrapper and its helpers" {
  run zsh -c "source '$DOTFUNCTIONS'; whence -w wrangler wrangler-as wrangler_profile wrangler_bin wrangler_bind wrangler_config_dir wrangler_profile_exists bin_trace"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrangler: function"* ]]
  [[ "$output" == *"wrangler-as: function"* ]]
  [[ "$output" == *"wrangler_profile: function"* ]]
  [[ "$output" == *"wrangler_bind: function"* ]]
  [[ "$output" == *"wrangler_bin: function"* ]]
  [[ "$output" == *"bin_trace: function"* ]]
}

@test "wrangler: personal repo binds the repo root to its profile once, then runs" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  wrangler_in "$repo" deploy --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrangler: bound $repo to profile 'personal-profile'"* ]]
  [[ "$output" == *"RAN: deploy --dry-run"* ]]
  # Bind happened before the command, exactly once, against the repo root.
  [ "$(sed -n 1p "$WRANGLER_LOG")" = "auth activate personal-profile $repo" ]
  [ "$(sed -n 2p "$WRANGLER_LOG")" = "deploy --dry-run" ]
  grep -Fq "\"$repo\": \"personal-profile\"" "$WRANGLER_CFG/profiles/directory-bindings.json"

  # Second run: binding already present, no activate, no notice.
  : > "$WRANGLER_LOG"
  wrangler_in "$repo" whoami
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: whoami" ]
  [ "$(cat "$WRANGLER_LOG")" = "whoami" ]
}

@test "wrangler: a per-repo pin outranks the owner's account mapping" {
  # A side project hosted under the personal GitHub account but deploying to
  # its own Cloudflare login: `wrangler.<owner>/<repo>.profile` wins.
  git config --file "$GIT_CONFIG_GLOBAL" wrangler.octo-personal/side-project.profile side-profile
  : > "$WRANGLER_CFG/config/side-profile.toml"
  repo=$(make_repo 'git@github.com:octo-personal/side-project.git')
  wrangler_in "$repo" deploy
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$WRANGLER_LOG")" = "auth activate side-profile $repo" ]
  # Sibling repos of the same owner are unaffected.
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  : > "$WRANGLER_LOG"
  wrangler_in "$repo" deploy
  [ "$(sed -n 1p "$WRANGLER_LOG")" = "auth activate personal-profile $repo" ]
}

@test "wrangler: the per-repo pin matches https and mixed-case origins too" {
  git config --file "$GIT_CONFIG_GLOBAL" wrangler.octo-personal/side-project.profile side-profile
  : > "$WRANGLER_CFG/config/side-profile.toml"
  repo=$(make_repo 'https://github.com/Octo-Personal/Side-Project.git')
  wrangler_in "$repo" deploy
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$WRANGLER_LOG")" = "auth activate side-profile $repo" ]
}

@test "git_origin_slug: owner/repo from every origin shape, lowercased, .git stripped" {
  for origin in 'git@github.com:Octo-Personal/Some-Repo.git' 'github-alias:octo-personal/some-repo' 'https://github.com/octo-personal/some-repo.git' 'ssh://git@github.com/octo-personal/some-repo.git'; do
    repo=$(make_repo "$origin")
    run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; git_origin_slug"
    [ "$status" -eq 0 ]
    [ "$output" = "octo-personal/some-repo" ]
  done
  repo=$(make_repo '/some/local/path.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; git_origin_slug"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "wrangler: a subdirectory of the repo still binds the repo root" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  mkdir -p "$repo/packages/worker"
  wrangler_in "$repo/packages/worker" deploy
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$WRANGLER_LOG")" = "auth activate personal-profile $repo" ]
}

@test "wrangler-doctor: a stale binding is shown once, with the rebind note" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  printf '{\n\t"%s": "%s"\n}' "$repo" "other-profile" > "$WRANGLER_CFG/profiles/directory-bindings.json"
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; wrangler-doctor"
  [[ "$output" == *"binding: $repo -> other-profile  (wrapper will rebind it to 'personal-profile' on the next run)"* ]]
  [[ "$output" != *"other-profileother-profile"* ]]
}

@test "wrangler: a stale binding to another profile is rebound to the pinned one" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  printf '{\n\t"%s": "%s"\n}\n' "$repo" "somebody-else" > "$WRANGLER_CFG/profiles/directory-bindings.json"
  wrangler_in "$repo" deploy
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$WRANGLER_LOG")" = "auth activate personal-profile $repo" ]
  grep -Fq "\"$repo\": \"personal-profile\"" "$WRANGLER_CFG/profiles/directory-bindings.json"
}

@test "wrangler: mapped profile that was never created refuses to run the command" {
  # Running on would silently use whatever profile wrangler falls back to.
  repo=$(make_repo 'git@github.com:octo-newbie/some-repo.git')
  wrangler_in "$repo" deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
  [[ "$output" == *"wrangler auth create never-created"* ]]
  [[ "$output" != *"RAN:"* ]]
  ! grep -q '^deploy' "$WRANGLER_LOG"
}

@test "wrangler: repo mapped to default manages no binding and runs plainly" {
  repo=$(make_repo 'git@github-workalias:octo-work-org/some-repo.git')
  wrangler_in "$repo" deploy
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: deploy" ]
  [ "$(cat "$WRANGLER_LOG")" = "deploy" ]
}

@test "wrangler: unpinned repo and non-repo cwd fall back to plain wrangler" {
  repo=$(make_repo 'git@github.com:someone-else/some-repo.git')
  wrangler_in "$repo" deploy
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: deploy" ]
  wrangler_in "$BATS_TEST_TMPDIR" whoami
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: whoami" ]
  ! grep -q '^auth activate' "$WRANGLER_LOG"
}

# --- which wrangler runs -----------------------------------------------------
#
# A project that vendors wrangler (a devDependency, as Cloudflare projects do)
# must get its own node_modules/.bin/wrangler — the version it pinned, on the
# node it was installed under — exactly as `npx wrangler` and its package.json
# scripts would. Everything else gets whatever `wrangler` is on PATH, which is
# where a version manager's shim (asdf, nodenv) or `npm -g` lives.

# A fake vendored wrangler laid out as npm lays it out: node_modules/.bin/
# wrangler is a symlink into node_modules/wrangler/, whose package.json
# carries the version — bin_trace reads that instead of running anything.
vendor_wrangler() {
  local root=$1 ver=$2
  mkdir -p "$root/node_modules/.bin" "$root/node_modules/wrangler/bin"
  printf '{\n  "name": "wrangler",\n  "version": "%s"\n}\n' "$ver" > "$root/node_modules/wrangler/package.json"
  cat > "$root/node_modules/wrangler/bin/wrangler.js" <<'STUB'
#!/bin/sh
printf 'LOCAL %s\n' "$*" >> "$BATS_TEST_TMPDIR/wrangler.log"
if [ "$1" = auth ] && [ "$2" = activate ]; then
  cfg="$XDG_CONFIG_HOME/.wrangler"
  printf '{\n\t"%s": "%s"\n}\n' "$4" "$3" > "$cfg/profiles/directory-bindings.json"
  exit 0
fi
echo "LOCAL RAN: $*"
STUB
  chmod +x "$root/node_modules/wrangler/bin/wrangler.js"
  ln -s ../wrangler/bin/wrangler.js "$root/node_modules/.bin/wrangler"
}

@test "wrangler: a repo that vendors wrangler runs node_modules/.bin/wrangler, binding included" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  vendor_wrangler "$repo" 4.999.0
  wrangler_in "$repo" deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrangler: bound $repo to profile 'personal-profile'"* ]]
  [[ "$output" == *"LOCAL RAN: deploy"* ]]
  # Both the activate and the command went to the vendored copy; the PATH
  # stub (asdf shim stand-in) was never touched.
  [ "$(sed -n 1p "$WRANGLER_LOG")" = "LOCAL auth activate personal-profile $repo" ]
  [ "$(sed -n 2p "$WRANGLER_LOG")" = "LOCAL deploy" ]
  ! grep -qv '^LOCAL ' "$WRANGLER_LOG"
}

@test "wrangler: the vendored wrangler is found from a subdirectory and hoisted monorepo roots" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  vendor_wrangler "$repo" 4.999.0
  mkdir -p "$repo/packages/worker/src"
  wrangler_in "$repo/packages/worker/src" whoami
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOCAL RAN: whoami"* ]]
  # PATH lookup is only the fallback: an unpinned non-repo cwd with no
  # node_modules anywhere above it gets the PATH wrangler.
  wrangler_in "$BATS_TEST_TMPDIR" whoami
  [ "$output" = "RAN: whoami" ]
  # wrangler_bin itself resolves the same way, and the passthrough commands
  # use it too.
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo/packages/worker'; wrangler_bin"
  [ "$output" = "$repo/node_modules/.bin/wrangler" ]
  wrangler_in "$repo" login
  [ "$output" = "LOCAL RAN: login" ]
}

@test "wrangler: no wrangler anywhere errors clearly and touches nothing" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  # (exit 127, checked inside the shell so old bats releases don't warn.)
  run zsh -c "PATH=/usr/bin:/bin; source '$DOTFUNCTIONS'; cd '$repo'; wrangler deploy 2>'$BATS_TEST_TMPDIR/stderr'; [ \$? -eq 127 ]"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q "wrangler: not found — no node_modules/.bin/wrangler at or above $repo and none on PATH" "$BATS_TEST_TMPDIR/stderr"
  [ ! -e "$WRANGLER_CFG/profiles/directory-bindings.json" ]
}

@test "wrangler: a bind failure for a profile that exists does not send you to auth create" {
  # The stub only knows the profile from its config file; make activate fail
  # for a profile that does exist (an old wrangler, a shim with no wrangler
  # under the selected node, ...) — the hint must point at the error and the
  # doctor, not at creating a profile that is already there.
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  cat > "$BATS_TEST_TMPDIR/bin/wrangler" <<'STUB'
#!/bin/sh
echo "No version is set for command wrangler" >&2
exit 126
STUB
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; wrangler deploy 2>'$BATS_TEST_TMPDIR/stderr'"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  grep -q "No version is set for command wrangler" "$BATS_TEST_TMPDIR/stderr"
  grep -qF "cannot bind $repo to profile 'personal-profile' (see above; \`wrangler-doctor\` shows which wrangler ran)" "$BATS_TEST_TMPDIR/stderr"
  ! grep -q "auth create" "$BATS_TEST_TMPDIR/stderr"
}

@test "wrangler: auth, login, and logout pass straight through, even in a pinned repo" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  for cmd in "auth list" "auth deactivate" login logout; do
    : > "$WRANGLER_LOG"
    wrangler_in "$repo" $cmd
    [ "$status" -eq 0 ]
    [ "$(cat "$WRANGLER_LOG")" = "$cmd" ]
  done
}

@test "wrangler: CLOUDFLARE_API_TOKEN in the environment disables profile management" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; CLOUDFLARE_API_TOKEN=x wrangler deploy"
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: deploy" ]
  [ "$(cat "$WRANGLER_LOG")" = "deploy" ]
}

@test "wrangler: WRANGLER_PROFILE mapped account injects --profile= and skips binding" {
  git config --file "$GIT_CONFIG_GLOBAL" wrangler.profile.octo-alias personal-profile
  repo=$(make_repo 'git@github-workalias:octo-work-org/some-repo.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; WRANGLER_PROFILE=octo-alias wrangler deploy --env prod"
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: --profile=personal-profile deploy --env prod" ]
  ! grep -q '^auth activate' "$WRANGLER_LOG"
}

@test "wrangler: WRANGLER_PROFILE accepts an existing literal profile and default" {
  run zsh -c "source '$DOTFUNCTIONS'; WRANGLER_PROFILE=personal-profile wrangler deploy"
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: --profile=personal-profile deploy" ]
  run zsh -c "source '$DOTFUNCTIONS'; WRANGLER_PROFILE=default wrangler deploy"
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: --profile=default deploy" ]
}

@test "wrangler: WRANGLER_PROFILE typo warns and falls back to the cwd's profile" {
  # A misspelling must never become a fresh OAuth login under that name.
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; WRANGLER_PROFILE=persnal-profile wrangler deploy 2>'$BATS_TEST_TMPDIR/stderr'"
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: deploy" ]
  grep -q "WRANGLER_PROFILE='persnal-profile' is neither a mapped account nor an existing wrangler profile" "$BATS_TEST_TMPDIR/stderr"
  [ "$(sed -n 1p "$WRANGLER_LOG")" = "auth activate personal-profile $repo" ]
}

@test "wrangler: an explicit --profile in the arguments is not duplicated by the override" {
  run zsh -c "source '$DOTFUNCTIONS'; WRANGLER_PROFILE=personal-profile wrangler deploy --profile default"
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: deploy --profile default" ]
  run zsh -c "source '$DOTFUNCTIONS'; WRANGLER_PROFILE=personal-profile wrangler --profile=default deploy"
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: --profile=default deploy" ]
}

@test "wrangler-as: mapped alias pins the profile and forwards args intact" {
  git config --file "$GIT_CONFIG_GLOBAL" wrangler.profile.octo-alias personal-profile
  run zsh -c "source '$DOTFUNCTIONS'; wrangler-as octo-alias d1 execute mydb --command 'select 1'"
  [ "$status" -eq 0 ]
  [ "$output" = "RAN: --profile=personal-profile d1 execute mydb --command select 1" ]
}

@test "wrangler-as: unknown profile errors, lists profiles, never launches wrangler" {
  run zsh -c "source '$DOTFUNCTIONS'; wrangler-as no-such-profile deploy 2>'$BATS_TEST_TMPDIR/stderr'"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -s "$WRANGLER_LOG" ]
  grep -q "unknown profile 'no-such-profile'" "$BATS_TEST_TMPDIR/stderr"
  grep -q '^work-account$' "$BATS_TEST_TMPDIR/stderr"
  grep -q '^personal-account$' "$BATS_TEST_TMPDIR/stderr"
}

@test "wrangler-as: no arguments prints usage and the profile list on stderr" {
  run zsh -c "source '$DOTFUNCTIONS'; wrangler-as 2>'$BATS_TEST_TMPDIR/stderr'"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  grep -q 'usage: wrangler-as <profile>' "$BATS_TEST_TMPDIR/stderr"
  grep -q '^personal-account$' "$BATS_TEST_TMPDIR/stderr"
}

@test "wrangler_config_dir: legacy ~/.wrangler wins, else XDG_CONFIG_HOME, else the platform default" {
  run zsh -c "source '$DOTFUNCTIONS'; wrangler_config_dir"
  [ "$output" = "$XDG_CONFIG_HOME/.wrangler" ]
  run zsh -c "source '$DOTFUNCTIONS'; unset XDG_CONFIG_HOME; wrangler_config_dir"
  if [ "$(uname)" = Darwin ]; then
    [ "$output" = "$HOME/Library/Preferences/.wrangler" ]
  else
    [ "$output" = "$HOME/.config/.wrangler" ]
  fi
  mkdir -p "$HOME/.wrangler"
  run zsh -c "source '$DOTFUNCTIONS'; wrangler_config_dir"
  [ "$output" = "$HOME/.wrangler" ]
}

@test "wrangler-doctor: traces a repo pin, missing profile, and pending binding" {
  git config --file "$GIT_CONFIG_GLOBAL" wrangler.octo-personal/side-project.profile side-profile
  repo=$(make_repo 'git@github.com:octo-personal/side-project.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; wrangler-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrapper: wrangler: function"* ]]
  [[ "$output" == *"defined: ok (8 helpers)"* ]]
  [[ "$output" == *"binary:  $BATS_TEST_TMPDIR/bin/wrangler"* ]]
  [[ "$output" != *"repo-local"* ]]
  [[ "$output" == *"account: personal-account"* ]]
  [[ "$output" == *"repo pin: wrangler.octo-personal/side-project.profile = side-profile"* ]]
  [[ "$output" == *"mapping: wrangler.profile.personal-account = personal-profile"* ]]
  [[ "$output" == *"wants:   side-profile"* ]]
  [[ "$output" == *"profile: 'side-profile' NOT CREATED — run: wrangler auth create side-profile"* ]]
  [[ "$output" == *"binding: <repo root not bound>  (wrapper will bind it to 'side-profile' on the next run)"* ]]
  [[ "$output" == *"uses:    default (no binding covers this directory)"* ]]
  # The doctor only reads; it must never invoke wrangler.
  [ ! -s "$WRANGLER_LOG" ]
  # A dropped helper is named up front.
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; unfunction wrangler_bind; wrangler-doctor 2>/dev/null"
  [[ "$output" == *"defined: MISSING wrangler_bind — "* ]]
}

@test "wrangler-doctor: reports an existing binding, incl. from a subdirectory, and never prints tokens" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  printf '{\n\t"%s": "%s"\n}\n' "$repo" "personal-profile" > "$WRANGLER_CFG/profiles/directory-bindings.json"
  mkdir -p "$repo/sub/dir"
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo/sub/dir'; CLOUDFLARE_API_TOKEN=sekrit-token wrangler-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"profile: 'personal-profile' exists"* ]]
  [[ "$output" == *"binding: $repo -> personal-profile"$'\n'* ]]
  [[ "$output" != *"will bind"* ]]
  [[ "$output" == *"CLOUDFLARE_API_TOKEN=<set"* ]]
  [[ "$output" == *"uses:    CLOUDFLARE_API_TOKEN"* ]]
  [[ "$output" != *"sekrit"* ]]
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo/sub/dir'; wrangler-doctor"
  [[ "$output" == *"uses:    personal-profile (bound at $repo)"* ]]
}

@test "wrangler-doctor: shows the vendored wrangler, its version from package.json, and the PATH one it outranks" {
  repo=$(make_repo 'git@github.com:octo-personal/some-repo.git')
  vendor_wrangler "$repo" 4.999.0
  mkdir -p "$repo/sub"
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo/sub'; wrangler-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"binary:  $repo/node_modules/.bin/wrangler (4.999.0) [repo-local, as npx would run; PATH has $BATS_TEST_TMPDIR/bin/wrangler]"* ]]
  # Still read-only: neither wrangler was executed.
  [ ! -s "$WRANGLER_LOG" ]
  run zsh -c "PATH=/usr/bin:/bin; source '$DOTFUNCTIONS'; cd '$BATS_TEST_TMPDIR'; wrangler-doctor"
  [[ "$output" == *"binary:  NOT FOUND — no node_modules/.bin/wrangler at or above the cwd and none on PATH"* ]]
}

@test "bin_trace: follows an asdf shim to the selected install, or says the node lacks the command" {
  # A fake asdf: its shim dir on PATH, and an `asdf which` that answers from
  # ASDF_STUB_TARGET (or fails, as asdf does when the selected node has no
  # such command). Nothing here runs the traced binary.
  export ASDF_DATA_DIR="$BATS_TEST_TMPDIR/asdf"
  mkdir -p "$ASDF_DATA_DIR/shims" "$ASDF_DATA_DIR/installs/nodejs/22.0.0/lib/node_modules/wrangler/bin" "$ASDF_DATA_DIR/installs/nodejs/22.0.0/bin"
  printf '{ "name": "wrangler", "version": "4.123.0" }\n' > "$ASDF_DATA_DIR/installs/nodejs/22.0.0/lib/node_modules/wrangler/package.json"
  : > "$ASDF_DATA_DIR/installs/nodejs/22.0.0/lib/node_modules/wrangler/bin/wrangler.js"
  ln -s ../lib/node_modules/wrangler/bin/wrangler.js "$ASDF_DATA_DIR/installs/nodejs/22.0.0/bin/wrangler"
  printf '#!/bin/sh\nexec asdf exec wrangler "$@"\n' > "$ASDF_DATA_DIR/shims/wrangler"
  chmod +x "$ASDF_DATA_DIR/shims/wrangler"
  cat > "$BATS_TEST_TMPDIR/bin/asdf" <<'STUB'
#!/bin/sh
[ "$1" = which ] || exit 1
[ -n "${ASDF_STUB_TARGET-}" ] || { echo "unexpected error: no versions set for $2"; exit 1; }
echo "$ASDF_STUB_TARGET"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/asdf"
  export ASDF_STUB_TARGET="$ASDF_DATA_DIR/installs/nodejs/22.0.0/bin/wrangler"
  run zsh -c "PATH='$ASDF_DATA_DIR/shims:$PATH'; source '$DOTFUNCTIONS'; bin_trace '$ASDF_DATA_DIR/shims/wrangler'"
  [ "$output" = "$ASDF_DATA_DIR/shims/wrangler -> $ASDF_STUB_TARGET (4.123.0)" ]
  # The node version in the path must never be mistaken for the tool's.
  [[ "$output" != *"22.0.0)"* ]]
  unset ASDF_STUB_TARGET
  run zsh -c "PATH='$ASDF_DATA_DIR/shims:$PATH'; source '$DOTFUNCTIONS'; bin_trace '$ASDF_DATA_DIR/shims/wrangler'"
  [ "$output" = "$ASDF_DATA_DIR/shims/wrangler -> <not installed under the selected node>" ]
  # A cask/native-style install: version read off the path, no execution.
  mkdir -p "$BATS_TEST_TMPDIR/Caskroom/some-tool/9.8.7"
  : > "$BATS_TEST_TMPDIR/Caskroom/some-tool/9.8.7/some-tool"
  ln -s "$BATS_TEST_TMPDIR/Caskroom/some-tool/9.8.7/some-tool" "$BATS_TEST_TMPDIR/bin/some-tool"
  run zsh -c "source '$DOTFUNCTIONS'; bin_trace '$BATS_TEST_TMPDIR/bin/some-tool'"
  [ "$output" = "$BATS_TEST_TMPDIR/bin/some-tool (9.8.7)" ]
}
