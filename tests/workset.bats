#!/usr/bin/env bats

# workset is a set of repos one Claude Code session works as one codebase:
# `bin/executable_workset` manages config, worktrees and two convenience
# hooks; `workset()`/`workset_profile()`/`workset-doctor()` in dot_functions
# decide which Claude profile a set runs under and refuse a member that
# profile's `denyguard` denies — one definition of that boundary, consumed
# here rather than re-scanned. These tests drive the real scripts (workset
# AND denyguard, never a stub of either) under a sandboxed HOME with fixture
# repos `octo-alpha`/`octo-beta`/`octo-secret`; no real path, repo, profile
# or account name appears (see CLAUDE.md).
#
# python3 is resolved to its real interpreter before HOME is sandboxed and
# re-exposed under a stub on PATH: an asdf shim resolves relative to $HOME
# and breaks the moment these tests override it (see tests/denyguard.bats).

setup() {
  REAL_PYTHON3="$(python3 -c 'import sys; print(sys.executable)')"

  # Resolved to its physical path: $BATS_TEST_TMPDIR sits under /var, itself
  # a symlink to /private/var on macOS, and both workset's own realpath
  # dedupe and denyguard's rule matching would otherwise compare an
  # unresolved path against a fully-resolved one and never agree (same
  # reason tests/denyguard.bats resolves HOME up front).
  mkdir -p "$BATS_TEST_TMPDIR/home"
  export HOME
  HOME="$(cd "$BATS_TEST_TMPDIR/home" && pwd -P)"
  mkdir -p "$HOME/code"

  export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  unset CLAUDE_PROFILE CLAUDE_CONFIG_DIR WORKSET WORKSET_BRANCH XDG_STATE_HOME

  gc() { git config --file "$GIT_CONFIG_GLOBAL" "$@"; }
  gc init.defaultBranch main
  gc user.email t@example.com
  gc user.name Test

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  cat > "$BIN/python3" <<STUB
#!/bin/sh
exec "$REAL_PYTHON3" "\$@"
STUB
  chmod +x "$BIN/python3"
  ln -sf "$(command -v git)" "$BIN/git"
  ln -sf "$BATS_TEST_DIRNAME/../bin/executable_workset" "$BIN/workset"
  ln -sf "$BATS_TEST_DIRNAME/../bin/executable_denyguard" "$BIN/denyguard"
  export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"

  DOTFUNCTIONS="$BATS_TEST_DIRNAME/../dot_functions"
  WS="$BATS_TEST_DIRNAME/../bin/executable_workset"
}

mk_repo() { # name
  local r="$HOME/code/$1"
  mkdir -p "$r"
  git -C "$r" init -q -b main
  git -C "$r" config user.email t@example.com
  git -C "$r" config user.name Test
  echo hi > "$r/README.md"
  git -C "$r" add -A
  git -C "$r" commit -q -m init >/dev/null
}

# A fixture profile directory with the given permissions.deny array literal
# (or no block at all when omitted), mapped as `workset.<set>.profile`.
fixture_profile() { # dir-name [deny-json-array]
  mkdir -p "$HOME/$1"
  if [ -n "${2-}" ]; then
    printf '{"permissions":{"deny":%s}}\n' "$2" > "$HOME/$1/settings.json"
  else
    printf '{}\n' > "$HOME/$1/settings.json"
  fi
}

workset_fn() { # subcommand...
  run zsh -c "source '$DOTFUNCTIONS'; workset \"\$@\"" zsh "$@"
}

# --- bin/executable_workset: config, worktrees -------------------------------

@test "list: config-order names, invalid names warned not dropped" {
  git config --file "$GIT_CONFIG_GLOBAL" --add 'workset.demo.member' '~/code/octo-alpha'
  git config --file "$GIT_CONFIG_GLOBAL" --add 'workset.bad name.member' '~/code/octo-alpha'
  run "$WS" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"demo"* ]]
  # never LISTED as a set name (the warning naming it, on the other hand,
  # is expected — worktabs' own stance: complained about, never dropped
  # silently)
  ! printf '%s\n' "$output" | grep -qx "bad name"
  [[ "$output" == *"a name may only hold letters, digits, - and _"* ]]
}

@test "list: a value containing a dot does not swallow the set name" {
  # git prints `workset.<name>.<key> <value>` on one line, so a greedy
  # capture of the name runs past the space and into the value. A note
  # mentioning a filename is the ordinary case, and it warned the whole set
  # away as a bad name — the set vanished from `list` and its brief was
  # never printed, with only a warning naming the note as the "name".
  git config --file "$GIT_CONFIG_GLOBAL" --add 'workset.demo.member' '~/code/octo-alpha'
  git config --file "$GIT_CONFIG_GLOBAL" --add 'workset.demo.note' 'tag first; the coupling is src/pkg/_thing.py and tests/_runner.*'
  run "$WS" list
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx demo
  ! [[ "$output" == *"a name may only hold"* ]]
}

@test "members: ok/missing/not-a-repo/duplicate, exit 2 if any is not ok" {
  mk_repo octo-alpha
  mkdir -p "$HOME/code/octo-plain"
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.mix.member '~/code/octo-alpha'
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.mix.member '~/code/octo-alpha'
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.mix.member '~/code/octo-missing'
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.mix.member '~/code/octo-plain'
  run "$WS" members mix
  [ "$status" -eq 2 ]
  [[ "$output" == *$'\tok'* ]]
  [[ "$output" == *$'\tduplicate'* ]]
  [[ "$output" == *$'\tmissing'* ]]
  [[ "$output" == *$'\tnot-a-repo'* ]]
}

@test "plan: create for an absent worktree, reuse for a matching one, conflict for a mismatched one" {
  mk_repo octo-alpha
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.demo.member '~/code/octo-alpha'
  run "$WS" plan demo feat/probe
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\tcreate'* ]]
  "$WS" checkout demo feat/probe >/dev/null
  run "$WS" plan demo feat/probe
  [[ "$output" == *$'\treuse'* ]]
  git -C "$HOME/code/octo-alpha/.claude/worktrees/feat-probe" checkout -q -b other-branch
  run "$WS" plan demo feat/probe
  [[ "$output" == *$'\tconflict'* ]]
}

@test "plan: a missing member reports missing-member rather than aborting" {
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.ghost.member '~/code/nope'
  run "$WS" plan ghost feat/x
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\tmissing-member'* ]]
}

@test "checkout: creates worktrees on origin/HEAD when it resolves, and adds the exclude line once" {
  mk_repo octo-alpha
  mkdir -p "$HOME/remote"
  git -C "$HOME/remote" init -q --bare -b main
  git -C "$HOME/code/octo-alpha" remote add origin "$HOME/remote"
  git -C "$HOME/code/octo-alpha" push -q origin main
  git -C "$HOME/code/octo-alpha" fetch -q origin
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.demo.member '~/code/octo-alpha'
  run "$WS" checkout demo feat/probe
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\tcreated'* ]]
  [ -d "$HOME/code/octo-alpha/.claude/worktrees/feat-probe" ]
  # no git progress text leaked into the TSV
  [[ "$output" != *"HEAD is now at"* ]]
  [ "$(git -C "$HOME/code/octo-alpha/.claude/worktrees/feat-probe" rev-parse HEAD)" \
    = "$(git -C "$HOME/code/octo-alpha" rev-parse origin/HEAD)" ]
  [ "$(grep -c '\*\*/.claude/worktrees/' "$HOME/code/octo-alpha/.git/info/exclude")" -eq 1 ]
  run "$WS" checkout demo feat/probe
  [ "$(grep -c '\*\*/.claude/worktrees/' "$HOME/code/octo-alpha/.git/info/exclude")" -eq 1 ]
}

@test "checkout: refuses and creates nothing when a member conflicts" {
  mk_repo octo-alpha
  mk_repo octo-beta
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.demo.member '~/code/octo-alpha'
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.demo.member '~/code/octo-beta'
  "$WS" checkout demo feat/probe >/dev/null
  git -C "$HOME/code/octo-beta/.claude/worktrees/feat-probe" checkout -q -b elsewhere
  run "$WS" checkout demo feat/probe
  [ "$status" -eq 1 ]
  [[ "$output" == *"conflicting or missing"* ]]
}

@test "close: refuses dirty, refuses unpushed, removes merged and deletes the branch" {
  mk_repo octo-alpha
  mkdir -p "$HOME/remote"
  git -C "$HOME/remote" init -q --bare -b main
  git -C "$HOME/code/octo-alpha" remote add origin "$HOME/remote"
  git -C "$HOME/code/octo-alpha" push -q origin main
  git -C "$HOME/code/octo-alpha" fetch -q origin
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.demo.member '~/code/octo-alpha'
  "$WS" checkout demo feat/probe >/dev/null
  WT="$HOME/code/octo-alpha/.claude/worktrees/feat-probe"

  echo dirty >> "$WT/README.md"
  run "$WS" close demo feat/probe
  [[ "$output" == *"dirty"* ]]
  [ -d "$WT" ]
  git -C "$WT" checkout -q -- README.md

  # A commit unique to the branch, not yet on the remote at all.
  echo unpushed >> "$WT/README.md"
  git -C "$WT" commit -q -am unpushed
  run "$WS" close demo feat/probe
  [[ "$output" == *"not on the remote"* ]]
  [ -d "$WT" ]

  git -C "$WT" push -q -u origin feat/probe

  # Land it: merged into main and pushed, the way the brief's remedy
  # (revert-forward, never rewrite) assumes a landed member looks.
  git -C "$HOME/code/octo-alpha" checkout -q main
  git -C "$HOME/code/octo-alpha" merge -q --no-ff feat/probe -m merge
  git -C "$HOME/code/octo-alpha" push -q origin main
  git -C "$HOME/code/octo-alpha" fetch -q origin

  run "$WS" close demo feat/probe
  [[ "$output" == *"closed"* ]]
  [ ! -d "$WT" ]
  ! git -C "$HOME/code/octo-alpha" show-ref --verify -q refs/heads/feat/probe
}

@test "guard: denies a live path, allows the worktree path, and is silent without WORKSET" {
  mk_repo octo-alpha
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.demo.member '~/code/octo-alpha'
  run env WORKSET=demo "$WS" guard <<< "$(printf '{"tool_input":{"file_path":"%s/code/octo-alpha/README.md"}}' "$HOME")"
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
  [[ "$output" == *"live checkout"* ]]

  run env WORKSET=demo "$WS" guard <<< "$(printf '{"tool_input":{"file_path":"%s/code/octo-alpha/.claude/worktrees/feat-probe/README.md"}}' "$HOME")"
  [ -z "$output" ]

  run "$WS" guard <<< "$(printf '{"tool_input":{"file_path":"%s/code/octo-alpha/README.md"}}' "$HOME")"
  [ -z "$output" ]
}

@test "hook start: prints the brief and notes when WORKSET is set, nothing otherwise" {
  mk_repo octo-alpha
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.demo.member '~/code/octo-alpha'
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.demo.note 'grovel lands first'
  "$WS" checkout demo feat/probe >/dev/null

  run "$WS" hook start <<< '{}'
  [ -z "$output" ]

  run env WORKSET=demo WORKSET_BRANCH=feat/probe "$WS" hook start <<< '{}'
  [[ "$output" == *"demo on feat/probe"* ]]
  [[ "$output" == *"primary"* ]]
  [[ "$output" == *"feat-probe -> "*"octo-alpha"* ]]
  [[ "$output" == *"grovel lands first"* ]]
}

@test "settings: prints valid-looking JSON with the fail-open guard, never denyguard's fail-closed one" {
  run "$WS" settings
  [ "$status" -eq 0 ]
  [[ "$output" == *"workset hook start"* ]]
  [[ "$output" == *"workset guard"* ]]
  [[ "$output" == *"Edit|Write|NotebookEdit"* ]]
  [[ "$output" == *"|| true"* ]]
}

# --- dot_functions: workset_profile / workset / workset-doctor --------------

@test "workset_profile: an explicit profile is used as-is when it resolves" {
  mk_repo octo-alpha
  fixture_profile .claude-fixture
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.fixture "$HOME/.claude-fixture"
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.demo.member '~/code/octo-alpha'
  git config --file "$GIT_CONFIG_GLOBAL" workset.demo.profile fixture
  workset_fn profile demo
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.claude-fixture" ]
}

@test "workset_profile: workset.<name>.profile disagreeing across includes is a config error" {
  mk_repo octo-alpha
  fixture_profile .claude-fixture
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.fixture "$HOME/.claude-fixture"
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.demo.member '~/code/octo-alpha'
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.demo.profile fixture
  # A second, differently-named config file included after the first, the
  # way a work overlay's file is included after a personal one.
  local other="$BATS_TEST_TMPDIR/gitconfig-work"
  git config --file "$other" workset.demo.profile fixture-two
  {
    echo "[include]"
    echo "	path = $other"
  } >> "$GIT_CONFIG_GLOBAL"
  workset_fn profile demo
  [ "$status" -eq 2 ]
  [[ "$output" == *"disagrees across includes"* ]]
}

@test "workset_profile: heterogeneous members print each member's resolution and refuse" {
  mk_repo octo-alpha
  mk_repo octo-beta
  fixture_profile .claude-a
  fixture_profile .claude-b
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.acct-a "$HOME/.claude-a"
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.acct-b "$HOME/.claude-b"
  git -C "$HOME/code/octo-alpha" remote add origin git@github.com:owner-a/octo-alpha.git
  git -C "$HOME/code/octo-beta" remote add origin git@github.com:owner-b/octo-beta.git
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/owner-a.username acct-a
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/owner-b.username acct-b
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.mixed.member '~/code/octo-alpha'
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.mixed.member '~/code/octo-beta'
  workset_fn profile mixed
  [ "$status" -eq 3 ]
  [[ "$output" == *"different Claude profiles"* ]]
  [[ "$output" == *"octo-alpha ->"* ]]
  [[ "$output" == *"octo-beta ->"* ]]
}

@test "workset_profile: a denied member refuses (4) with denyguard's own message" {
  mk_repo octo-alpha
  mk_repo octo-secret
  fixture_profile .claude-fixture '["Read(~/code/octo-secret/**)"]'
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.fixture "$HOME/.claude-fixture"
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.bad.member '~/code/octo-alpha'
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.bad.member '~/code/octo-secret'
  git config --file "$GIT_CONFIG_GLOBAL" workset.bad.profile fixture
  workset_fn profile bad
  [ "$status" -eq 4 ]
  [[ "$output" == *"octo-secret"* ]]
  [[ "$output" == *"Read(~/code/octo-secret/**)"* ]]
}

@test "workset_profile: a rule denyguard cannot evaluate refuses (4), not silently" {
  mk_repo octo-alpha
  fixture_profile .claude-fixture '["Read(/rel/**)"]'
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.fixture "$HOME/.claude-fixture"
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.demo.member '~/code/octo-alpha'
  git config --file "$GIT_CONFIG_GLOBAL" workset.demo.profile fixture
  workset_fn profile demo
  [ "$status" -eq 4 ]
  [[ "$output" == *"cannot be evaluated"* || "$output" == *"cannot evaluate"* ]]
}

@test "workset open: a fixture set with one member under a fixture deny rule refuses (4) and launches no claude" {
  mk_repo octo-alpha
  mk_repo octo-secret
  fixture_profile .claude-fixture '["Read(~/code/octo-secret/**)"]'
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.fixture "$HOME/.claude-fixture"
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.bad.member '~/code/octo-alpha'
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.bad.member '~/code/octo-secret'
  git config --file "$GIT_CONFIG_GLOBAL" workset.bad.profile fixture

  CALL_LOG="$BATS_TEST_TMPDIR/claude-calls.log"
  cat > "$BIN/claude" <<EOF
#!/bin/sh
echo "CALLED: \$*" >> "$CALL_LOG"
EOF
  chmod +x "$BIN/claude"

  workset_fn open bad feat/probe
  [ "$status" -eq 4 ]
  [[ "$output" == *"Read(~/code/octo-secret/**)"* ]]
  [ ! -f "$CALL_LOG" ]
  # nothing was created either — a refused profile check runs before checkout
  [ ! -d "$HOME/code/octo-alpha/.claude/worktrees" ]
}

@test "workset open: a homogeneous, allowed set launches claude cd'd into the primary with --add-dir for the rest" {
  mk_repo octo-alpha
  mk_repo octo-beta
  fixture_profile .claude-fixture
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.fixture "$HOME/.claude-fixture"
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.good.member '~/code/octo-alpha'
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.good.member '~/code/octo-beta'
  git config --file "$GIT_CONFIG_GLOBAL" workset.good.profile fixture

  CALL_LOG="$BATS_TEST_TMPDIR/claude-calls.log"
  cat > "$BIN/claude" <<EOF
#!/bin/sh
echo "CALLED: \$*" >> "$CALL_LOG"
echo "cwd: \$PWD" >> "$CALL_LOG"
echo "CLAUDE_PROFILE=\$CLAUDE_PROFILE WORKSET=\$WORKSET WORKSET_BRANCH=\$WORKSET_BRANCH CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=\$CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD" >> "$CALL_LOG"
EOF
  chmod +x "$BIN/claude"

  workset_fn open good feat/probe
  [ "$status" -eq 0 ]
  [ -f "$CALL_LOG" ]
  grep -q -- "--add-dir $HOME/code/octo-beta/.claude/worktrees/feat-probe" "$CALL_LOG"
  ! grep -q -- "--add-dir $HOME/code/octo-alpha" "$CALL_LOG"
  grep -q "cwd: $HOME/code/octo-alpha/.claude/worktrees/feat-probe" "$CALL_LOG"
  grep -q "CLAUDE_PROFILE=$HOME/.claude-fixture WORKSET=good WORKSET_BRANCH=feat/probe CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1" "$CALL_LOG"
}

@test "workset-doctor: reports the same denied verdict workset_profile itself returns" {
  mk_repo octo-alpha
  mk_repo octo-secret
  fixture_profile .claude-fixture '["Read(~/code/octo-secret/**)"]'
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.fixture "$HOME/.claude-fixture"
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.bad.member '~/code/octo-alpha'
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.bad.member '~/code/octo-secret'
  git config --file "$GIT_CONFIG_GLOBAL" workset.bad.profile fixture
  run zsh -c "source '$DOTFUNCTIONS'; workset-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-- bad"* ]]
  [[ "$output" == *"profile: denied"* ]]
  [[ "$output" == *"Read(~/code/octo-secret/**)"* ]]
}

@test "workset-doctor: a homogeneous, allowed set reports the resolved profile directory" {
  mk_repo octo-alpha
  fixture_profile .claude-fixture
  git config --file "$GIT_CONFIG_GLOBAL" claude.profile.fixture "$HOME/.claude-fixture"
  git config --file "$GIT_CONFIG_GLOBAL" --add workset.good.member '~/code/octo-alpha'
  git config --file "$GIT_CONFIG_GLOBAL" workset.good.profile fixture
  run zsh -c "source '$DOTFUNCTIONS'; workset-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"profile: $HOME/.claude-fixture"* ]]
}

@test "dot_functions defines workset, workset_profile and workset-doctor" {
  run zsh -c "source '$DOTFUNCTIONS'; whence -w workset workset_profile workset-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"workset: function"* ]]
  [[ "$output" == *"workset_profile: function"* ]]
  [[ "$output" == *"workset-doctor: function"* ]]
}
