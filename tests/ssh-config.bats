#!/usr/bin/env bats

# ~/.ssh/config is a skeleton that includes per-overlay fragments. Two kinds
# of assertion here: what chezmoi renders per machine class, and what ssh
# itself then DOES with it — the second matters because ssh_config's
# precedence rule is the opposite of git's and is easy to encode backwards.
#
# Fixture fragments only. A real alias, host, or account in this file would
# itself be the leak the split exists to prevent.

chez() {
  HOME="$TMPHOME" \
  XDG_CONFIG_HOME="$TMPHOME/.config" \
  XDG_DATA_HOME="$TMPHOME/.local/share" \
  XDG_STATE_HOME="$TMPHOME/.local/state" \
  XDG_CACHE_HOME="$TMPHOME/.cache" \
    chezmoi "$@"
}

setup() {
  command -v chezmoi > /dev/null 2>&1 || skip "chezmoi not installed"
  TMPHOME="$(mktemp -d)"
}

teardown() { rm -rf "$TMPHOME"; }

apply_class() {
  cd "$BATS_TEST_DIRNAME/.."
  chez init --source "$PWD" --promptString machineClass="$1" --apply --exclude scripts
}

@test "mac renders the include above the catch-all, with the 1Password agent" {
  apply_class mac
  [ -f "$TMPHOME/.ssh/config" ]
  grep -q '^Include ~/.ssh/config.d/\*.conf$' "$TMPHOME/.ssh/config"
  grep -q 'IdentityAgent' "$TMPHOME/.ssh/config"
  # First-wins: a Host * read before the fragments would shadow all of them.
  inc=$(grep -n '^Include' "$TMPHOME/.ssh/config" | cut -d: -f1)
  star=$(grep -n '^Host \*' "$TMPHOME/.ssh/config" | cut -d: -f1)
  [ "$inc" -lt "$star" ]
}

@test "linux renders the include but NEVER IdentityAgent" {
  apply_class linux
  grep -q '^Include ~/.ssh/config.d/\*.conf$' "$TMPHOME/.ssh/config"
  # IdentityAgent overrides $SSH_AUTH_SOCK. Pointing it at 1Password's macOS
  # path here would make ssh ignore a FORWARDED agent, which is the only way
  # a Linux box has a key at all.
  ! grep -q 'IdentityAgent' "$TMPHOME/.ssh/config"
  ! grep -q '1password' "$TMPHOME/.ssh/config"
}

@test "wsl gets no POSIX ssh config at all" {
  apply_class wsl
  [ ! -e "$TMPHOME/.ssh/config" ]
}

@test "the skeleton names no host, alias, key, or account" {
  apply_class mac
  # Only two directives may appear: the include and the agent fallback.
  run grep -cE '^[[:space:]]*(Host|Match|IdentityFile|User|HostName|ForwardAgent)' \
    "$TMPHOME/.ssh/config"
  [ "$output" = "1" ]   # the lone `Host *`
  ! grep -qE '^[[:space:]]*IdentityFile' "$TMPHOME/.ssh/config"
}

@test "modes are ssh-safe: 0700 dir, 0600 file" {
  apply_class mac
  m() { stat -f '%Lp' "$1" 2> /dev/null || stat -c '%a' "$1"; }
  [ "$(m "$TMPHOME/.ssh")" = "700" ]
  [ "$(m "$TMPHOME/.ssh/config")" = "600" ]
}

@test "with no overlay fragments ssh still parses the skeleton" {
  apply_class mac
  # The property the whole design rests on: an unmatched Include glob is not
  # an error, so a machine missing an overlay needs no conditional anywhere.
  run ssh -F "$TMPHOME/.ssh/config" -G example.invalid
  [ "$status" -eq 0 ]
}

# ssh expands `~` in an Include from the passwd entry, NOT $HOME, so a
# sandboxed home cannot relocate it. These two derive a fixture FROM the
# rendered skeleton — same structure, same Include position, absolute path —
# so what is exercised is still the file chezmoi produces, not a hand-written
# stand-in. The literal `~/.ssh/config.d/*.conf` path is pinned above.
rendered_with_absolute_include() {
  mkdir -p "$TMPHOME/.ssh/config.d"
  sed "s|~/|$TMPHOME/|g" "$TMPHOME/.ssh/config" > "$TMPHOME/.ssh/config.abs"
}

@test "an earlier fragment wins — 10-personal outranks 20-work" {
  apply_class mac
  rendered_with_absolute_include
  printf 'Host shared.invalid\n  User first\n'  > "$TMPHOME/.ssh/config.d/10-personal.conf"
  printf 'Host shared.invalid\n  User second\n' > "$TMPHOME/.ssh/config.d/20-work.conf"
  run ssh -F "$TMPHOME/.ssh/config.abs" -G shared.invalid
  echo "$output" | grep -q '^user first$'
  # Renaming alone must flip it — proof the numbering IS the precedence and
  # not decoration, and that this is backwards from ~/.gitconfig, where the
  # LAST include wins.
  mv "$TMPHOME/.ssh/config.d/10-personal.conf" "$TMPHOME/.ssh/config.d/30-personal.conf"
  run ssh -F "$TMPHOME/.ssh/config.abs" -G shared.invalid
  echo "$output" | grep -q '^user second$'
}

@test "a fragment outranks the catch-all it is included above" {
  apply_class mac
  rendered_with_absolute_include
  printf 'Host pinned.invalid\n  IdentityAgent none\n' > "$TMPHOME/.ssh/config.d/10-personal.conf"
  run ssh -F "$TMPHOME/.ssh/config.abs" -G pinned.invalid
  echo "$output" | grep -q '^identityagent none$'
}
