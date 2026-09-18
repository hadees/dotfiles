#!/usr/bin/env bats

# denyguard is the PreToolUse hook that reads a profile's permissions.deny
# and refuses any Bash command whose literal path tokens, glob prefixes, or
# cwd land inside a denied tree — Claude Code's own Read/Edit deny rules
# never reach Bash. These tests drive the real script under a sandboxed
# HOME with fixture repos and a fixture profile; no real path, repo,
# profile or account name appears (see CLAUDE.md). `gizmo` stands in for a
# bare-word grep target so the test never types a real one.
#
# python3 itself is resolved to its real interpreter binary before HOME is
# sandboxed and re-exposed under a stub on PATH: an asdf shim (as on this
# machine) resolves relative to $HOME and breaks the moment these tests
# override it, which has nothing to do with denyguard.

setup() {
  command -v python3 >/dev/null || skip "python3 not installed"
  REAL_PYTHON3="$(python3 -c 'import sys; print(sys.executable)')"

  # Resolved to its physical path: on macOS $BATS_TEST_TMPDIR sits under
  # /var, itself a symlink to /private/var, and denyguard's realpath-based
  # symlink handling would otherwise compare an unresolved rule prefix
  # against a fully-resolved candidate and never agree (same reason
  # tests/git-hooks.bats and tests/tailnet.bats resolve their fixtures).
  mkdir -p "$BATS_TEST_TMPDIR/home"
  export HOME
  HOME="$(cd "$BATS_TEST_TMPDIR/home" && pwd -P)"
  mkdir -p "$HOME/code/octo-alpha" "$HOME/code/octo-secret" "$HOME/.claude-fixture"

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  cat > "$BIN/python3" <<STUB
#!/bin/sh
exec "$REAL_PYTHON3" "\$@"
STUB
  chmod +x "$BIN/python3"
  export PATH="$BIN:$PATH"

  echo secret > "$HOME/code/octo-secret/x"
  echo secret > "$HOME/code/octo-secret/CLAUDE.md"
  ln -s "$HOME/code/octo-secret" "$HOME/link"

  export CLAUDE_CONFIG_DIR="$HOME/.claude-fixture"
  export DENYGUARD_LOG="$BATS_TEST_TMPDIR/denied.log"
  unset XDG_STATE_HOME

  DG="$BATS_TEST_DIRNAME/../bin/executable_denyguard"

  # The standard fixture rule set: a tree, a single file, and an
  # already-anchored-from-root rule, each of a shape the docs allow but
  # naming nothing real.
  fixture_rules '["Read(~/code/octo-secret/**)","Edit(~/code/octo-secret/**)","Read(~/.hushfile)","Read(//srv/vault/**)"]'
}

fixture_rules() { # json array literal
  printf '{"permissions":{"deny":%s}}\n' "$1" > "$HOME/.claude-fixture/settings.json"
}

# A PreToolUse Bash event with the given cwd and command.
evt() { # cwd command
  printf '{"session_id":"s1","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" "$2"
}

# A PreToolUse event for a non-Bash tool with one string field.
evt_field() { # cwd tool field value
  printf '{"session_id":"s1","cwd":"%s","tool_name":"%s","tool_input":{"%s":"%s"}}' "$1" "$2" "$3" "$4"
}

hook() { printf '%s' "$1" | "$DG" hook; } # $1: event JSON

@test "cat on a denied file is refused, naming the rule" {
  run hook "$(evt "$HOME/code" "cat $HOME/code/octo-secret/x")"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
  [[ "$output" == *"Read(~/code/octo-secret/**)"* ]]
}

@test "grep -c on a denied file is refused — the shape auto mode prefers" {
  run hook "$(evt "$HOME/code" "grep -c foo $HOME/code/octo-secret/CLAUDE.md")"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "a glob that could expand into a denied tree is refused" {
  run hook "$(evt "$HOME/code" "ls $HOME/code/octo-secret/*")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"may expand into"* ]]
}

@test "git -C into an allowed repo is silent" {
  run hook "$(evt "$HOME/code" "git -C $HOME/code/octo-alpha status")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a session cwd already inside a denied tree denies everything" {
  run hook "$(evt "$HOME/code/octo-secret" "pwd")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"session cwd"* ]]
  [[ "$output" == *"is inside Read(~/code/octo-secret/**)"* ]]
}

@test "a relative path under the denied repo, resolved against cwd, is refused" {
  run hook "$(evt "$HOME/code" "cat octo-secret/x")"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "cd into the denied repo's bare name is refused (the fragment exists)" {
  run hook "$(evt "$HOME/code" "cd octo-secret")"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "a bare word matching no file in the cwd is left alone" {
  run hook "$(evt "$HOME/code/octo-alpha" "grep gizmo README")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a symlink into the denied tree is refused via its realpath" {
  run hook "$(evt "$HOME/code" "cat $HOME/link/x")"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "find over an ancestor of a denied tree is refused as recursive" {
  run hook "$(evt "$HOME/code" "find $HOME/code -name x")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"looks recursive"* ]]
}

@test "ls over the same ancestor, with no recursive tell, is allowed" {
  run hook "$(evt "$HOME/code" "ls $HOME/code")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sourcing a denied single file is refused, both spellings" {
  run hook "$(evt "$HOME/code" "source $HOME/.hushfile")"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
  run hook "$(evt "$HOME/code" ". $HOME/.hushfile")"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "a //-anchored rule denies the absolute path from filesystem root" {
  run hook "$(evt "$HOME/code" "cat /srv/vault/k")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Read(//srv/vault/**)"* ]]
}

@test "a non-Bash tool is scanned on every string leaf of tool_input" {
  run hook "$(evt_field "$HOME/code" "SomeOtherTool" "path" "$HOME/code/octo-secret/x")"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "Bash's description field is never examined, only command" {
  run hook "$(printf '{"session_id":"s1","cwd":"%s","tool_name":"Bash","tool_input":{"command":"true","description":"reads %s/code/octo-secret/x"}}' "$HOME/code" "$HOME")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a profile with no permissions.deny at all is a silent allow" {
  fixture_rules '[]'
  run hook "$(evt "$HOME/code" "cat $HOME/code/octo-secret/x")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unparsable settings.json blocks Bash with a message" {
  printf '{not json' > "$HOME/.claude-fixture/settings.json"
  run hook "$(evt "$HOME/code" "true")"
  [ "$status" -eq 2 ]
  [[ "$output" == *"denyguard: cannot read"* ]]
}

@test "no python3 on PATH blocks Bash with a message" {
  EMPTYBIN="$BATS_TEST_TMPDIR/emptybin"
  mkdir -p "$EMPTYBIN"
  run bash -c 'printf "%s" "$1" | PATH="$2" "$3" hook' _ \
    "$(evt "$HOME/code" "true")" "$EMPTYBIN" "$DG"
  [ "$status" -eq 2 ]
  [[ "$output" == *"python3 not found"* ]]
}

@test "check: a path inside a denied tree exits 1, naming it" {
  run "$DG" check --profile "$HOME/.claude-fixture" "$HOME/code/octo-secret/sub"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is inside Read(~/code/octo-secret/**)"* ]]
}

@test "check: a path that contains a denied tree exits 1, naming it" {
  run "$DG" check --profile "$HOME/.claude-fixture" "$HOME/code"
  [ "$status" -eq 1 ]
  [[ "$output" == *"contains Read(~/code/octo-secret/**)'s region"* ]]
}

@test "check: an unrelated allowed repo exits 0" {
  run "$DG" check --profile "$HOME/.claude-fixture" "$HOME/code/octo-alpha"
  [ "$status" -eq 0 ]
}

@test "check: a project-relative rule cannot be evaluated, exit 2" {
  fixture_rules '["Read(/rel/**)"]'
  run "$DG" check --profile "$HOME/.claude-fixture" "$HOME/code/octo-alpha"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot be evaluated"* ]]
}

@test "rules: prints tool, rule, absolute prefix and kind, one per line" {
  run "$DG" rules --profile "$HOME/.claude-fixture"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'Read\tRead(~/code/octo-secret/**)\t'"$HOME"$'/code/octo-secret\tprefix'* ]]
  [[ "$output" == *$'Edit\tEdit(~/code/octo-secret/**)\t'"$HOME"$'/code/octo-secret\tprefix'* ]]
  [[ "$output" == *$'Read\tRead(~/.hushfile)\t'"$HOME"$'/.hushfile\tprefix'* ]]
  [[ "$output" == *$'Read\tRead(//srv/vault/**)\t/srv/vault\tprefix'* ]]
}

@test "settings: prints valid JSON, fails closed, never || true" {
  run "$DG" settings
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -m json.tool >/dev/null
  [[ "$output" == *"exit 2"* ]]
  [[ "$output" != *'|| true'* ]]
  [[ "$output" == *'"matcher": "Bash"'* ]]
}

@test "a deny appends exactly one line to DENYGUARD_LOG" {
  [ ! -e "$DENYGUARD_LOG" ]
  run hook "$(evt "$HOME/code" "cat $HOME/code/octo-secret/x")"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$DENYGUARD_LOG" | tr -d ' ')" = 1 ]
  [[ "$(cat "$DENYGUARD_LOG")" == *$'\t'"Read(~/code/octo-secret/**)"$'\t'* ]]
}

@test "dir: reports the profile directory this invocation reads" {
  run "$DG" dir
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.claude-fixture" ]
  unset CLAUDE_CONFIG_DIR
  run "$DG" dir
  [ "$output" = "$HOME/.claude" ]
}

@test "an absent settings.json is zero rules, not a refusal" {
  # The public repo ships no settings.json — every profile's is overlay-owned —
  # so a stranger wiring this hook through a project-level .claude/settings.json
  # has no profile settings file at all. Refusing there would deny every Bash
  # call in that project and name `dotfiles` as the remedy, which cannot help
  # them. Unreadable is still a refusal; absent is not (advocate, 2026-09-18).
  run env CLAUDE_CONFIG_DIR="$HOME/.claude-absent" sh -c "printf '%s' '$(evt "$HOME/code" "echo hi")' | '$DG' hook"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run env CLAUDE_CONFIG_DIR="$HOME/.claude-absent" "$DG" rules
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an unparsable settings.json still refuses, naming the file not the deploy" {
  mkdir -p "$HOME/.claude-broken"
  printf '{ "permissions": { "deny": [ ' > "$HOME/.claude-broken/settings.json"
  run env CLAUDE_CONFIG_DIR="$HOME/.claude-broken" sh -c "printf '%s' '$(evt "$HOME/code" "echo hi")' | '$DG' hook"
  [ "$status" -eq 2 ]
  [[ "$output" == *"settings.json"* ]]
  [[ "$output" != *dotfiles* ]]
}
