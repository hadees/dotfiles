#!/usr/bin/env bats

# bin/executable_git-ssh-pinned deploys to ~/bin/git-ssh-pinned, the
# core.sshCommand the overlays set: for a plain github.com ssh remote it
# resolves the owner to an account through the credential pins, looks up
# identity.<account>.sshkey, and runs ssh with that key alone
# (-o IdentitiesOnly=yes -i <key>). In every other case — an alias host, an
# unpinned owner, no key declared, git's -G variant probe, a non-GitHub host
# — it must hand the arguments to ssh *untouched*, so a remote the pins know
# nothing about behaves exactly as before. These tests run the source copy
# under sh against a stub ssh that records its argv; the last one drives it
# through real git. All names here are fixtures — no real account, key, or
# org may appear (see CLAUDE.md).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.ssh" "$HOME/bin" "$BATS_TEST_TMPDIR/bin"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  unset GIT_SSH GIT_SSH_COMMAND GIT_SSH_VARIANT

  HELPER="$BATS_TEST_DIRNAME/../bin/executable_git-ssh-pinned"
  cp "$HELPER" "$HOME/bin/git-ssh-pinned"; chmod +x "$HOME/bin/git-ssh-pinned"

  # Stub ssh: appends its argv, one per line, then a blank line per call.
  export SSH_LOG="$BATS_TEST_TMPDIR/ssh-args"
  cat > "$BATS_TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/sh
{ printf '%s\n' "$@"; echo; } >> "$SSH_LOG"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/ssh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-personal.username personal-acct
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-org.username work-acct
  git config --file "$GIT_CONFIG_GLOBAL" identity.personal-acct.sshkey '~/.ssh/id_personal.pub'
  git config --file "$GIT_CONFIG_GLOBAL" identity.work-acct.sshkey "$HOME/.ssh/id_work.pub"
  # A repo under the personal owner that authenticates with its own key.
  git config --file "$GIT_CONFIG_GLOBAL" identity.octo-personal/side-project.sshkey "$HOME/.ssh/id_side.pub"
}

# Run the helper the way git does for an upload-pack of $1, with git's usual
# leading option. Extra args go before the host.
pull() {
  run sh "$HELPER" -o SendEnv=GIT_PROTOCOL "${@:2}" git@github.com "git-upload-pack '$1'"
}

# Argv the stub ssh recorded, joined by spaces (last call only).
recorded() {
  awk 'BEGIN{RS=""} {gsub(/\n/, " "); line=$0} END{print line}' "$SSH_LOG"
}

@test "pinned owner: ssh gets that account's key alone, git's own args intact" {
  pull 'octo-personal/some-repo.git'
  [ "$status" -eq 0 ]
  [ "$(recorded)" = "-o IdentitiesOnly=yes -i $HOME/.ssh/id_personal.pub -o SendEnv=GIT_PROTOCOL git@github.com git-upload-pack 'octo-personal/some-repo.git'" ]
}

@test "the owner decides, not the account that happens to be active: a work org gets the work key" {
  pull 'octo-org/tooling.git'
  [ "$(recorded)" = "-o IdentitiesOnly=yes -i $HOME/.ssh/id_work.pub -o SendEnv=GIT_PROTOCOL git@github.com git-upload-pack 'octo-org/tooling.git'" ]
}

@test "a per-repo sshkey pin outranks the account's key" {
  pull 'octo-personal/side-project.git'
  [ "$(recorded)" = "-o IdentitiesOnly=yes -i $HOME/.ssh/id_side.pub -o SendEnv=GIT_PROTOCOL git@github.com git-upload-pack 'octo-personal/side-project.git'" ]
  # ...and only for that exact slug — case-insensitively, like GitHub.
  pull 'Octo-Personal/Side-Project.git'
  [ "$(recorded)" = "-o IdentitiesOnly=yes -i $HOME/.ssh/id_side.pub -o SendEnv=GIT_PROTOCOL git@github.com git-upload-pack 'Octo-Personal/Side-Project.git'" ]
}

@test "receive-pack, upload-archive, lfs, ssh:// paths, port 443 host, and -p all route" {
  run sh "$HELPER" git@github.com "git-receive-pack 'octo-org/tooling.git'"
  [[ "$(recorded)" == "-o IdentitiesOnly=yes -i $HOME/.ssh/id_work.pub git@github.com git-receive-pack"* ]]
  run sh "$HELPER" git@github.com "git-upload-archive 'octo-org/tooling.git'"
  [[ "$(recorded)" == "-o IdentitiesOnly=yes -i $HOME/.ssh/id_work.pub "* ]]
  run sh "$HELPER" git@github.com "git-lfs-authenticate octo-org/tooling.git download"
  [[ "$(recorded)" == "-o IdentitiesOnly=yes -i $HOME/.ssh/id_work.pub "* ]]
  # ssh://git@github.com/owner/repo hands the path with a leading slash.
  run sh "$HELPER" git@github.com "git-upload-pack '/octo-org/tooling.git'"
  [[ "$(recorded)" == "-o IdentitiesOnly=yes -i $HOME/.ssh/id_work.pub "* ]]
  # ssh://git@ssh.github.com:443/owner/repo — GitHub's firewall-friendly host.
  run sh "$HELPER" -p 443 git@ssh.github.com "git-upload-pack '/octo-org/tooling.git'"
  [ "$(recorded)" = "-o IdentitiesOnly=yes -i $HOME/.ssh/id_work.pub -p 443 git@ssh.github.com git-upload-pack '/octo-org/tooling.git'" ]
  # Host case does not matter either.
  run sh "$HELPER" git@GitHub.com "git-upload-pack 'octo-org/tooling.git'"
  [[ "$(recorded)" == "-o IdentitiesOnly=yes -i $HOME/.ssh/id_work.pub "* ]]
}

@test "an unpinned owner passes through untouched" {
  pull 'someone-else/some-repo.git'
  [ "$status" -eq 0 ]
  [ "$(recorded)" = "-o SendEnv=GIT_PROTOCOL git@github.com git-upload-pack 'someone-else/some-repo.git'" ]
}

@test "a pinned owner whose account declares no sshkey passes through untouched" {
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-keyless.username keyless-acct
  pull 'octo-keyless/some-repo.git'
  [ "$(recorded)" = "-o SendEnv=GIT_PROTOCOL git@github.com git-upload-pack 'octo-keyless/some-repo.git'" ]
}

@test "an ssh-config alias host is never overridden, even for a pinned owner" {
  run sh "$HELPER" -o SendEnv=GIT_PROTOCOL git@github-personal "git-upload-pack 'octo-personal/some-repo.git'"
  [ "$(recorded)" = "-o SendEnv=GIT_PROTOCOL git@github-personal git-upload-pack 'octo-personal/some-repo.git'" ]
  run sh "$HELPER" github-personal "git-upload-pack 'octo-personal/some-repo.git'"
  [ "$(recorded)" = "github-personal git-upload-pack 'octo-personal/some-repo.git'" ]
}

@test "hosts other than GitHub pass through untouched" {
  run sh "$HELPER" git@gitlab.example.com "git-upload-pack 'octo-personal/some-repo.git'"
  [ "$(recorded)" = "git@gitlab.example.com git-upload-pack 'octo-personal/some-repo.git'" ]
}

@test "git's -G variant probe and other non-remote invocations pass through untouched" {
  run sh "$HELPER" -G git@github.com
  [ "$status" -eq 0 ]
  [ "$(recorded)" = "-G git@github.com" ]
  run sh "$HELPER" git@github.com
  [ "$(recorded)" = "git@github.com" ]
  : > "$SSH_LOG"
  run sh "$HELPER"
  [ "$status" -eq 0 ]
  [ -z "$(tr -d '\n' < "$SSH_LOG")" ]
  # A remote command with no path in it — nothing to pin on.
  run sh "$HELPER" git@github.com "git-upload-pack"
  [ "$(recorded)" = "git@github.com git-upload-pack" ]
}

@test "a repo named after a pinned owner cannot hijack the lookup" {
  # The OWNER is the first path segment only.
  pull 'someone-else/octo-org.git'
  [ "$(recorded)" = "-o SendEnv=GIT_PROTOCOL git@github.com git-upload-pack 'someone-else/octo-org.git'" ]
}

@test "real git runs the helper from core.sshCommand as the overlays set it" {
  # The overlay line, verbatim: $HOME expands because git hands a command
  # containing a shell metacharacter to sh. No ssh.variant set, so git
  # probes with -G first; the helper has to survive that too.
  git config --file "$GIT_CONFIG_GLOBAL" core.sshCommand '$HOME/bin/git-ssh-pinned'
  run git ls-remote git@github.com:octo-org/tooling.git
  # The stub ssh speaks no pack protocol, so git itself fails — the point
  # is what it ran.
  [ "$(recorded)" = "-o IdentitiesOnly=yes -i $HOME/.ssh/id_work.pub -o SendEnv=GIT_PROTOCOL git@github.com git-upload-pack 'octo-org/tooling.git'" ]
  grep -q -- '^-G$' "$SSH_LOG"
  # GIT_SSH_COMMAND outranks core.sshCommand: the documented bypass.
  : > "$SSH_LOG"
  GIT_SSH_COMMAND=ssh run git ls-remote git@github.com:octo-org/tooling.git
  [[ "$(recorded)" != *IdentitiesOnly* ]]
  [[ "$(recorded)" == *"git@github.com git-upload-pack 'octo-org/tooling.git'" ]]
}
