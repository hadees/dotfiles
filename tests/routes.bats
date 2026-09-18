#!/usr/bin/env bats

# `routes` in dot_functions is the fleet-wide counterpart to the per-cwd
# doctors: one row per project, one column per wrapper, every cell resolved by
# calling the wrapper's own resolver in a subshell cd'd into the repo. These
# tests source the real functions under zsh against a sandboxed HOME and git
# config, with fixture repos, fixture pins and stub state (a wrangler profile
# file, a tailnet port file, a hermes config, a `worktabs` that prints a plan)
# standing in for the machinery the columns report on. Every account, owner and
# profile name here is a fixture — no real ones may appear (see CLAUDE.md).
#
# What is worth pinning here, beyond "it prints rows": the markers (`*` a
# per-repo pin outranking the account mapping, `!` mapped but never created on
# this machine), that an all-empty column is dropped from the table but never
# from --tsv, that the override variables are ignored, and that the walk stops
# at the first repo — a vendored checkout inside a project must not appear
# beside it.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/code"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  unset CLAUDE_PROFILE CLAUDE_CONFIG_DIR WRANGLER_PROFILE TAILNET

  gc() { git config --file "$GIT_CONFIG_GLOBAL" "$@"; }
  gc init.defaultBranch main
  gc credential.https://github.com/octo-work-org.username work-account
  gc credential.https://github.com/octo-personal.username personal-account

  # A machine with two accounts mapped across the wrappers.
  gc claude.profile.work-account '~/.claude'
  gc claude.profile.personal-account '~/.claude-personal'
  gc wrangler.profile.work-account work-cf
  gc wrangler.profile.personal-account personal-cf
  gc tailnet.profile.work-account work-net
  gc tailnet.profile.personal-account personal-net
  mkdir -p "$HOME/.claude" "$HOME/.claude-personal"
  mkdir -p "$HOME/.wrangler/config"
  : > "$HOME/.wrangler/config/work-cf.toml"
  : > "$HOME/.wrangler/config/personal-cf.toml"
  mkdir -p "$HOME/.local/state/tailnet/work-net" "$HOME/.local/state/tailnet/personal-net"
  : > "$HOME/.local/state/tailnet/work-net/port"
  : > "$HOME/.local/state/tailnet/personal-net/port"

  # PATH without a real worktabs/wrangler/tailnet: the TABS column is opt-in
  # per test, and nothing here may consult a real installation.
  export PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # git itself must stay reachable wherever bats found it.
  ln -sf "$(command -v git)" "$BATS_TEST_TMPDIR/bin/git"

  DOTFUNCTIONS="$BATS_TEST_DIRNAME/../dot_functions"
}

# A repo at $HOME/code/$1 with origin owner/repo $2; extra args are
# `git config` key/value pairs set in its local config.
make_repo() {
  local name=$1 slug=$2; shift 2
  local repo="$HOME/code/$name"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" remote add origin "git@github.com:$slug.git"
  while (( $# >= 2 )); do
    git -C "$repo" config "$1" "$2"
    shift 2
  done
  printf '%s\n' "$repo"
}

routes() {
  run zsh -c "source '$DOTFUNCTIONS'; routes \"\$@\"" zsh "$@"
}

# The row for project $1 in the captured output, column padding squeezed to
# one space and one added back at the end. The trailing space is what lets a
# `*" value "*` assertion mean "this whole cell" for the last column too — the
# table itself never pads the last one, so patterns would otherwise have to
# know which column happens to be last in that test.
row_for() {
  printf '%s\n' "$output" | awk -v p="$1" '$1 == p' | tr -s ' ' | sed 's/$/ /'
}

@test "dot_functions defines routes and the helpers it drives" {
  run zsh -c "source '$DOTFUNCTIONS'; whence -w routes routes_scan routes_probe identity_expected"
  [ "$status" -eq 0 ]
  [[ "$output" == *"routes: function"* ]]
  [[ "$output" == *"routes_scan: function"* ]]
  [[ "$output" == *"routes_probe: function"* ]]
  [[ "$output" == *"identity_expected: function"* ]]
}

@test "table: each column is the wrapper's own answer for that repo" {
  make_repo work-thing octo-work-org/work-thing
  make_repo personal-thing octo-personal/personal-thing
  routes
  [ "$status" -eq 0 ]
  [[ "$output" == "PROJECT"*"ACCOUNT"*"CLAUDE"*"WRANGLER"*"TAILNET"* ]]
  # No hermes pin and no worktabs on this fixture machine, so those two
  # columns are absent — a full-row equality is the assertion that proves it.
  [ "$(row_for work-thing)" = "work-thing work-account .claude work-cf work-net " ]
  [ "$(row_for personal-thing)" = "personal-thing personal-account .claude-personal personal-cf personal-net " ]
}

@test "table: rows group by account, and unpinned repos sort last" {
  make_repo zed-work octo-work-org/zed-work
  make_repo alpha-personal octo-personal/alpha-personal
  make_repo unpinned other-owner/unpinned
  routes
  [ "$status" -eq 0 ]
  local order
  order=$(printf '%s\n' "$output" | awk 'NR>1 && NF && $1 != "PROJECT" {print $1}' | head -3 | paste -sd, -)
  [ "$order" = "alpha-personal,zed-work,unpinned" ]
}

@test "table: an unpinned repo still reports the default Claude profile it would get" {
  gc claude.profile.default '~/.claude-personal'
  make_repo unpinned other-owner/unpinned
  routes
  [ "$status" -eq 0 ]
  [[ "$(row_for unpinned)" == "unpinned - .claude-personal "* ]]
}

@test "marker *: a per-repo pin outranks the account mapping" {
  make_repo side-project octo-personal/side-project
  gc wrangler.octo-personal/side-project.profile other-cf
  : > "$HOME/.wrangler/config/other-cf.toml"
  routes
  [ "$status" -eq 0 ]
  [[ "$(row_for side-project)" == *" other-cf* "* ]]
  [[ "$output" == *"* per-repo pin, outranking the account mapping"* ]]
}

@test "marker *: a per-repo Claude pin shows in the CLAUDE column too" {
  make_repo moved-repo octo-work-org/moved-repo
  gc 'claude.octo-work-org/moved-repo.profile' personal-account
  routes
  [ "$status" -eq 0 ]
  # Routed to the personal profile despite the work owner, and marked as a pin.
  [[ "$(row_for moved-repo)" == *" .claude-personal* "* ]]
}

@test "marker !: mapped on this machine but never created" {
  rm "$HOME/.wrangler/config/work-cf.toml"
  rm "$HOME/.local/state/tailnet/work-net/port"
  rm -rf "$HOME/.claude"
  make_repo work-thing octo-work-org/work-thing
  routes
  [ "$status" -eq 0 ]
  [[ "$(row_for work-thing)" == "work-thing work-account .claude! work-cf! work-net! "* ]]
  [[ "$output" == *"! mapped but not created on this machine"* ]]
}

@test "hermes: a per-repo pin is reported, and marked when its profile is absent" {
  make_repo agent-repo octo-personal/agent-repo hermes.profile fixture-agent
  make_repo other-agent octo-personal/other-agent hermes.profile missing-agent
  mkdir -p "$HOME/.hermes/profiles/fixture-agent"
  : > "$HOME/.hermes/profiles/fixture-agent/config.yaml"
  routes
  [ "$status" -eq 0 ]
  [[ "$(row_for agent-repo)" == *" fixture-agent "* ]]
  [[ "$(row_for other-agent)" == *" missing-agent! "* ]]
}

@test "columns: one nothing uses is dropped from the table and named in the footer" {
  make_repo work-thing octo-work-org/work-thing
  routes
  [ "$status" -eq 0 ]
  [[ "$output" != *"HERMES"* ]]
  [[ "$output" != *"TABS"* ]]
  [[ "$output" != *"MAIL"* ]]
  [[ "$output" == *"nothing configured anywhere, columns dropped: hermes, tabs, mail"* ]]
}

# The MAIL column is postbox's own answer for the directory (name, then its
# source), so the table cannot disagree with what a session registers as.
# A stub stands in for the script: no daemon, no vocabulary, no real names.
stub_postbox() {
  cat > "$BATS_TEST_TMPDIR/bin/postbox" <<'STUB'
#!/bin/sh
[ "$1" = name ] && [ "$2" = --source ] || exit 1
case ${PWD##*/} in
  work-thing) printf 'AmberLake\tpin\n' ;;
  personal-thing) printf 'NavyHawk\tpin-invalid\n' ;;
  *) printf 'TealHeron\thash\n' ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/postbox"
}

@test "mail: the column comes from postbox name --source, marking pins and rejected pins" {
  make_repo work-thing octo-work-org/work-thing
  make_repo personal-thing octo-personal/personal-thing
  make_repo unpinned other-owner/unpinned
  stub_postbox
  routes
  [ "$status" -eq 0 ]
  [[ "$output" == *"MAIL"* ]]
  [[ "$(row_for work-thing)" == *" AmberLake* "* ]]
  [[ "$(row_for personal-thing)" == *" NavyHawk! "* ]]
  [[ "$(row_for unpinned)" == *" TealHeron "* ]]
}

@test "mail: --tsv carries the name as the tenth field, after gate" {
  make_repo work-thing octo-work-org/work-thing
  stub_postbox
  routes --tsv
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f10)" = "AmberLake*" ]
}

@test "tabs: the column comes from worktabs' own plan, including its group" {
  local repo
  repo=$(make_repo work-thing octo-work-org/work-thing)
  printf '#!/bin/sh\nprintf "%%s\\t%%s\\t%%s\\t%%s\\t%%s\\t%%s\\n" fixture-group work-thing ok work-thing "%s" "cd"\n' \
    "$repo" > "$BATS_TEST_TMPDIR/bin/worktabs"
  chmod +x "$BATS_TEST_TMPDIR/bin/worktabs"
  routes
  [ "$status" -eq 0 ]
  [[ "$output" == *"TABS"* ]]
  [[ "$(row_for work-thing)" == *" fixture-group "* ]]
}

@test "tabs: an entry worktabs cannot open is marked, not reported as open" {
  local repo
  repo=$(make_repo work-thing octo-work-org/work-thing)
  printf '#!/bin/sh\nprintf "%%s\\t%%s\\t%%s\\t%%s\\t%%s\\t%%s\\n" fixture-group work-thing disabled work-thing "%s" "cd"\n' \
    "$repo" > "$BATS_TEST_TMPDIR/bin/worktabs"
  chmod +x "$BATS_TEST_TMPDIR/bin/worktabs"
  routes
  [ "$status" -eq 0 ]
  [[ "$(row_for work-thing)" == *" fixture-group! "* ]]
}

@test "--long: adds the commit identity and the gate's verdict on it" {
  gc identity.work-account.email dev@example.com
  make_repo good octo-work-org/good user.email dev@example.com
  make_repo bad octo-work-org/bad user.email someone-else@example.com
  routes --long
  [ "$status" -eq 0 ]
  [[ "$output" == *"IDENTITY"*"GATE"* ]]
  [[ "$(row_for good)" == *" dev@example.com ok " ]]
  [[ "$(row_for bad)" == *" someone-else@example.com REFUSE " ]]
}

@test "--long: an unpinned owner gets no verdict rather than a passing one" {
  gc identity.work-account.email dev@example.com
  # A second, pinned repo keeps the GATE column in the table: a column every
  # row leaves empty is dropped, and "-" for one repo is the point here.
  make_repo pinned octo-work-org/pinned user.email dev@example.com
  make_repo unpinned other-owner/unpinned user.email dev@example.com
  routes --long
  [ "$status" -eq 0 ]
  [[ "$(row_for pinned)" == *" dev@example.com ok " ]]
  [[ "$(row_for unpinned)" == *" dev@example.com - " ]]
}

@test "--long: the per-repo email pin outranks the account's, via identity_expected" {
  gc identity.work-account.email dev@example.com
  gc identity.octo-work-org/side.email side@example.com
  make_repo side octo-work-org/side user.email side@example.com
  routes --long
  [ "$status" -eq 0 ]
  [[ "$(row_for side)" == *" side@example.com ok " ]]
}

@test "--tsv: keeps every column whether or not it is empty, with no header or footer" {
  make_repo work-thing octo-work-org/work-thing
  routes --tsv
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" != *"PROJECT"* ]]
  [[ "$output" != *"projects under"* ]]
  local n
  n=$(printf '%s\n' "$output" | awk -F'\t' '{print NF}')
  [ "$n" -eq 11 ]
  [ "$(printf '%s\n' "$output" | cut -f1,2,6,7,11)" = "$(printf 'work-thing\twork-account\t-\t-\t-')" ]
}

@test "set: a fixture set over two fixture repos shows in both rows, and a heterogeneous set is marked" {
  make_repo alpha octo-personal/alpha
  make_repo beta octo-personal/beta
  gc claude.profile.other-account '~/.claude'
  gc credential.https://github.com/other-owner.username other-account
  make_repo gamma other-owner/gamma
  # Real paths, symlink-resolved: $HOME under bats' tmpdir sits under /var,
  # itself a symlink to /private/var on macOS, and the SET column matches
  # by real path exactly the way workset_profile does — an unresolved
  # $HOME here would never agree with it (same reason tests/denyguard.bats
  # resolves HOME up front).
  local rhome; rhome="$(cd "$HOME" && pwd -P)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/denyguard"
  chmod +x "$BATS_TEST_TMPDIR/bin/denyguard"
  cat > "$BATS_TEST_TMPDIR/bin/workset" <<SCRIPT
#!/bin/sh
case "\$1" in
  list) printf 'fixture-good\nfixture-bad\n' ;;
  members)
    case "\$2" in
      fixture-good) printf 'a\t%s/code/alpha\tok\nb\t%s/code/beta\tok\n' "$rhome" "$rhome" ;;
      fixture-bad) printf 'a\t%s/code/alpha\tok\nc\t%s/code/gamma\tok\n' "$rhome" "$rhome" ;;
    esac
    ;;
esac
SCRIPT
  chmod +x "$BATS_TEST_TMPDIR/bin/workset"
  routes
  [ "$status" -eq 0 ]
  [[ "$(row_for alpha)" == *" fixture-good,fixture-bad!"* ]]
  [[ "$(row_for beta)" == *" fixture-good "* ]]
  [[ "$(row_for gamma)" == *" fixture-bad!"* ]]
}

@test "overrides: a set TAILNET describes this shell, not the repos, and is called out" {
  make_repo work-thing octo-work-org/work-thing
  TAILNET=personal-net routes
  [ "$status" -eq 0 ]
  [[ "$(row_for work-thing)" == *" work-net "* ]]
  [[ "$output" == *"TAILNET=personal-net set in this shell"* ]]
}

@test "roots: an argument overrides the default, and reports the count under it" {
  mkdir -p "$HOME/elsewhere"
  git init -q "$HOME/elsewhere/outlier"
  git -C "$HOME/elsewhere/outlier" remote add origin git@github.com:octo-personal/outlier.git
  make_repo ignored octo-work-org/ignored
  routes "$HOME/elsewhere"
  [ "$status" -eq 0 ]
  [[ "$output" == *"outlier"* ]]
  [[ "$output" != *"ignored"* ]]
  [[ "$output" == *"1 projects under ~/elsewhere"* ]]
}

@test "roots: routes.root in git config is used when no argument is given" {
  mkdir -p "$HOME/elsewhere"
  git init -q "$HOME/elsewhere/outlier"
  git -C "$HOME/elsewhere/outlier" remote add origin git@github.com:octo-personal/outlier.git
  make_repo ignored octo-work-org/ignored
  gc routes.root '~/elsewhere'
  routes
  [ "$status" -eq 0 ]
  [[ "$output" == *"outlier"* ]]
  [[ "$output" != *"ignored"* ]]
}

@test "scan: stops at the first repo, so a checkout inside a project is not listed beside it" {
  local repo
  repo=$(make_repo project octo-personal/project)
  git init -q "$repo/vendor/dependency"
  git -C "$repo/vendor/dependency" remote add origin git@github.com:octo-work-org/dependency.git
  routes
  [ "$status" -eq 0 ]
  [[ "$output" == *"project"* ]]
  [[ "$output" != *"dependency"* ]]
  [[ "$output" == *"1 projects under"* ]]
}

@test "scan: a nested owner/repo layout is found and named by its path" {
  mkdir -p "$HOME/code/octo-personal"
  git init -q "$HOME/code/octo-personal/nested"
  git -C "$HOME/code/octo-personal/nested" remote add origin git@github.com:octo-personal/nested.git
  routes
  [ "$status" -eq 0 ]
  [[ "$output" == *"octo-personal/nested"* ]]
}

@test "no repos: says so on stderr and fails, rather than printing an empty table" {
  routes
  [ "$status" -eq 1 ]
  [[ "$output" == *"no git repos found under ~/code"* ]]
}

@test "a missing root is reported without aborting the rest of the scan" {
  make_repo work-thing octo-work-org/work-thing
  routes "$HOME/nowhere" "$HOME/code"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no such directory"* ]]
  [[ "$output" == *"work-thing"* ]]
}

@test "rows carry no trailing whitespace" {
  make_repo work-thing octo-work-org/work-thing
  routes
  [ "$status" -eq 0 ]
  run bash -c "printf '%s\n' \"\$1\" | grep -c ' \$' || true" bash "$output"
  [ "$output" = "0" ]
}
