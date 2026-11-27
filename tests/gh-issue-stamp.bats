#!/usr/bin/env bats

# gh()'s two guards on a session's create (dot_functions): the stamp guard on
# `issue create` (opt-in per owner by gh.<owner>.issue-stamp) and the check for
# private details on `issue|pr create` (gh.<owner>.private-issues, refused once
# per session and public repository). Same sandbox as tests/gh-wrapper.bats: a
# fixture gitconfig with credential pins, fixture repos, and a stub `gh` that
# logs every call. The stub also answers `gh api repos/... --jq .visibility`.
# All names are fixtures: no real account, organisation or repository.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  unset GH_TOKEN GH_REPO GH_ISSUE_STAMP GH_PRIVATE_CHECK
  export CLAUDECODE=1
  export CLAUDE_CODE_SESSION_ID=test-session
  TALLY="$XDG_STATE_HOME/gh-issue-stamp"

  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-work-org.username work-acct
  git config --file "$GIT_CONFIG_GLOBAL" credential.https://github.com/octo-personal.username personal-acct
  git config --file "$GIT_CONFIG_GLOBAL" gh.octo-personal.issue-stamp true
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

  export GH_STUB_LOG="$BATS_TEST_TMPDIR/calls"
  export GH_STUB_STDIN="$BATS_TEST_TMPDIR/stdin"
  : > "$GH_STUB_LOG"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/bin/sh
if [ "$1" = auth ] && [ "$2" = token ] && [ "$3" = --user ]; then
  echo "tok-$4"
  exit 0
fi
echo "TOKEN=${GH_TOKEN-UNSET} $*" | tr '\n' ' ' >> "$GH_STUB_LOG"
echo >> "$GH_STUB_LOG"
if [ "$1" = api ]; then
  [ -n "${GH_STUB_API_FAIL-}" ] && exit 1
  echo "${GH_STUB_VISIBILITY-public}"
  exit 0
fi
case " $* " in *" -F - "*) cat > "$GH_STUB_STDIN" ;; esac
echo created
exit "${GH_STUB_STATUS-0}"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  DOTFUNCTIONS="$BATS_TEST_DIRNAME/../dot_functions"
  PERSONAL=$(make_repo 'git@github.com:octo-personal/proj-one.git')
  CLOSED=$'a body\n\n_Filed by a Claude session._\n<!-- workboard:filed-by-session v1 -->'
}

make_repo() {
  local repo="$BATS_TEST_TMPDIR/repo-$(echo "$1" | tr -c 'A-Za-z0-9\n' _)"
  rm -rf "$repo"
  git init -q "$repo"
  git -C "$repo" remote add origin "$1"
  echo "$repo"
}

# Run `gh <args...>` through the sourced wrapper from inside repo $1.
gh_in() {
  local repo="$1"
  shift
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; gh \"\$@\"" zsh "$@"
}

# Same, with standard input $1.
gh_in_stdin() {
  local repo="$1" input="$2"
  shift 2
  run zsh -c "source '$DOTFUNCTIONS'; cd '$repo'; gh \"\$@\"" zsh "$@" <<<"$input"
}

# Bytes in the tally file $1 (0 when there is none).
count() {
  if [ -f "$TALLY/$1.count" ]; then wc -c < "$TALLY/$1.count" | tr -d ' '; else echo 0; fi
}

# Calls the stub saw that were not `gh api`.
creates() { grep -vc ' api ' "$GH_STUB_LOG" || true; }
apis() { grep -c ' api ' "$GH_STUB_LOG" || true; }

REFUSAL_1="gh: not created. In this repository a session's issue ends with these two lines, last in its body:"

# --- the stamp guard ---------------------------------------------------------

@test "guard: an unstamped body is refused in each of five spellings" {
  echo "no lines here" > "$BATS_TEST_TMPDIR/body.md"
  gh_in "$PERSONAL" issue create --title t --body "x"
  [ "$status" -eq 64 ]
  gh_in "$PERSONAL" issue create --title t --body=x
  [ "$status" -eq 64 ]
  gh_in "$PERSONAL" issue create --title t -b x
  [ "$status" -eq 64 ]
  gh_in "$PERSONAL" issue create --title t --body-file "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 64 ]
  gh_in_stdin "$PERSONAL" "no lines here" issue create --title t -F -
  [ "$status" -eq 64 ]
  [[ "$output" == *"$REFUSAL_1"* ]]
  [[ "$output" == *$'\n_Filed by a Claude session._\n<!-- workboard:filed-by-session v1 -->'* ]]
  [ "$(creates)" -eq 0 ]
  [ "$(count refused)" -eq 5 ]
}

@test "guard: the same five with both closing lines reach the stub with the token" {
  printf '%s\n' "$CLOSED" > "$BATS_TEST_TMPDIR/body.md"
  gh_in "$PERSONAL" issue create --title t --body "$CLOSED"
  [ "$status" -eq 0 ]
  [ "$output" = created ]
  gh_in "$PERSONAL" issue create --title t "--body=$CLOSED"
  [ "$status" -eq 0 ]
  gh_in "$PERSONAL" issue create --title t -b "$CLOSED"
  [ "$status" -eq 0 ]
  gh_in "$PERSONAL" issue create --title t --body-file "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 0 ]
  gh_in_stdin "$PERSONAL" "$CLOSED" issue create --title t -F -
  [ "$status" -eq 0 ]
  [ "$(creates)" -eq 5 ]
  ! grep -v 'TOKEN=tok-personal-acct' "$GH_STUB_LOG"
  [ "$(cat "$GH_STUB_STDIN")" = "$CLOSED" ]
  [ "$(count stamped)" -eq 5 ]
}

@test "guard: the stamp alone and the note alone are each refused" {
  gh_in "$PERSONAL" issue create --title t --body $'x\n<!-- workboard:filed-by-session v1 -->'
  [ "$status" -eq 64 ]
  gh_in "$PERSONAL" issue create --title t --body $'x\n_Filed by a Claude session._'
  [ "$status" -eq 64 ]
  [ "$(creates)" -eq 0 ]
}

@test "guard: the fourth line is printed only when the topic is deployed" {
  gh_in "$PERSONAL" issue create --title t --body x
  [ "${#lines[@]}" -eq 3 ]
  [[ "$output" != *"issues.md"* ]]
  mkdir -p "$HOME/.claude-shared/topics"
  echo topic > "$HOME/.claude-shared/topics/issues.md"
  gh_in "$PERSONAL" issue create --title t --body x
  [ "${#lines[@]}" -eq 4 ]
  [ "${lines[3]}" = "gh: how issues are written: ~/.claude-shared/topics/issues.md" ]
}

@test "guard: indented stamp and v2 pass, a stamp inside a sentence does not" {
  gh_in "$PERSONAL" issue create --title t --body $'  _Filed by a Claude session._ \n  <!--  workboard:filed-by-session v2 extra -->  '
  [ "$status" -eq 0 ]
  gh_in "$PERSONAL" issue create --title t --body $'_Filed by a Claude session._\nsee <!-- workboard:filed-by-session v1 --> here'
  [ "$status" -eq 64 ]
}

@test "guard: issue new is checked, other commands and no body option are not" {
  gh_in "$PERSONAL" issue new --title t --body x
  [ "$status" -eq 64 ]
  gh_in "$PERSONAL" issue list
  [ "$status" -eq 0 ]
  gh_in "$PERSONAL" issue view 3
  [ "$status" -eq 0 ]
  gh_in "$PERSONAL" pr create --title t --body x
  [ "$status" -eq 0 ]
  [ "$(creates)" -eq 3 ]
  gh_in "$PERSONAL" issue create --web
  [ "$status" -eq 0 ]
  [ "$(count unchecked)" -eq 1 ]
}

@test "guard: an unreadable body file runs gh and counts unchecked" {
  gh_in "$PERSONAL" issue create --title t --body-file "$BATS_TEST_TMPDIR/missing.md"
  [ "$status" -eq 0 ]
  [ "$(count unchecked)" -eq 1 ]
}

@test "guard: GH_ISSUE_STAMP=0 runs and counts bypassed; no CLAUDECODE checks nothing" {
  GH_ISSUE_STAMP=0 gh_in "$PERSONAL" issue create --title t --body x
  [ "$status" -eq 0 ]
  [ "$(count bypassed)" -eq 1 ]
  unset CLAUDECODE
  gh_in "$PERSONAL" issue create --title t --body x
  [ "$status" -eq 0 ]
  [ ! -e "$TALLY/refused.count" ]
}

@test "guard: the exit status of a stamped create is gh's own" {
  GH_STUB_STATUS=7 gh_in "$PERSONAL" issue create --title t --body "$CLOSED"
  [ "$status" -eq 7 ]
  GH_STUB_STATUS=7 gh_in_stdin "$PERSONAL" "$CLOSED" issue create --title t -F -
  [ "$status" -eq 7 ]
}

# --- the opt-in ------------------------------------------------------------

@test "opt-in: a pinned owner that did not opt in is never checked, and writes no tally" {
  work=$(make_repo 'git@github.com:octo-work-org/proj-one.git')
  gh_in "$work" issue create --title t --body x
  [ "$status" -eq 0 ]
  [ "$output" = created ]
  grep -q 'TOKEN=tok-work-acct' "$GH_STUB_LOG"
  [ ! -e "$TALLY" ]
}

@test "opt-in: false and unset both leave the guard off" {
  git config --file "$GIT_CONFIG_GLOBAL" gh.octo-personal.issue-stamp false
  gh_in "$PERSONAL" issue create --title t --body x
  [ "$status" -eq 0 ]
  git config --file "$GIT_CONFIG_GLOBAL" --unset gh.octo-personal.issue-stamp
  gh_in "$PERSONAL" issue create --title t --body x
  [ "$status" -eq 0 ]
  [ ! -e "$TALLY" ]
}

@test "opt-in: the target's owner decides, from -R and GH_REPO, in any case" {
  work=$(make_repo 'git@github.com:octo-work-org/proj-one.git')
  gh_in "$PERSONAL" issue create --title t --body x -R octo-work-org/proj-one
  [ "$status" -eq 0 ]
  gh_in "$work" issue create --title t --body x -R octo-personal/proj-two
  [ "$status" -eq 64 ]
  gh_in "$work" issue create --title t --body x --repo=octo-personal/proj-two
  [ "$status" -eq 64 ]
  gh_in "$work" issue create --title t --body x --repo github.com/octo-personal/proj-two
  [ "$status" -eq 64 ]
  gh_in "$work" issue create --title t --body x -R Octo-Personal/proj-two
  [ "$status" -eq 64 ]
  GH_REPO=octo-personal/proj-two gh_in "$work" issue create --title t --body x
  [ "$status" -eq 64 ]
  nowhere="$BATS_TEST_TMPDIR/nowhere"
  mkdir -p "$nowhere"
  gh_in "$nowhere" issue create --title t --body x -R octo-personal/proj-two
  [ "$status" -eq 64 ]
}

@test "opt-in: a stranger's repository is not checked even with a key set" {
  git config --file "$GIT_CONFIG_GLOBAL" gh.some-stranger.issue-stamp true
  gh_in "$PERSONAL" issue create --title t --body x -R some-stranger/repo
  [ "$status" -eq 0 ]
}

@test "opt-in: with no pins at all nothing is checked" {
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig-empty"
  git config --file "$GIT_CONFIG_GLOBAL" gh.octo-personal.issue-stamp true
  gh_in "$PERSONAL" issue create --title t --body x
  [ "$status" -eq 0 ]
  [ "$output" = "TOKEN=UNSET issue create --title t --body x" ] || [ "$output" = created ]
}

# --- the private check ---------------------------------------------------------

private_on() {
  git config --file "$GIT_CONFIG_GLOBAL" gh.octo-personal.private-issues octo-personal/proj-private
  PUBLIC=$(make_repo 'git@github.com:octo-personal/proj-two.git')
}

@test "private: a closed create in a public repository is refused once, the retry passes" {
  private_on
  gh_in "$PUBLIC" issue create --title t --body "$CLOSED"
  [ "$status" -eq 65 ]
  [ "${lines[0]}" = 'gh: not run yet. octo-personal/proj-two is public. Spend, payment, identity, home-network and private-repository details do not go there: file them in octo-personal/proj-private with a "Concerns: octo-personal/proj-two" line, and leave no stub.' ]
  [ "${lines[1]}" = "gh: if this text holds none of that, run the same command again and it will go through." ]
  [ "$(creates)" -eq 0 ]
  [ "$(count asked)" -eq 1 ]
  [ -f "$TALLY/asked/test-session__octo-personal__proj-two" ]

  GH_STUB_STATUS=3 gh_in "$PUBLIC" issue create --title t --body "$CLOSED"
  [ "$status" -eq 3 ]
  [ "$output" = created ]
  grep -q 'TOKEN=tok-personal-acct issue create' "$GH_STUB_LOG"
  [ "$(count passed)" -eq 1 ]

  # one marker per session and repository, not per command
  gh_in "$PUBLIC" pr create --title t --body x
  [ "$status" -eq 0 ]
  [ "$(count passed)" -eq 2 ]
}

@test "private: a pull request is the first create too, and the stub saw one api call each" {
  private_on
  gh_in "$PUBLIC" pr create --title t --body x
  [ "$status" -eq 65 ]
  [ "$(apis)" -eq 1 ]
  grep -q 'TOKEN=tok-personal-acct api repos/octo-personal/proj-two --jq .visibility' "$GH_STUB_LOG"
  [ "$(creates)" -eq 0 ]
}

@test "private: another public repository, and another session, are asked again" {
  private_on
  gh_in "$PUBLIC" pr create --title t --body x
  [ "$status" -eq 65 ]
  other=$(make_repo 'git@github.com:octo-personal/proj-three.git')
  gh_in "$other" pr create --title t --body x
  [ "$status" -eq 65 ]
  CLAUDE_CODE_SESSION_ID=second-session gh_in "$PUBLIC" pr create --title t --body x
  [ "$status" -eq 65 ]
  [ "$(count asked)" -eq 3 ]
}

@test "private: GH_PRIVATE_CHECK=0 runs unasked, writes no marker, and the next create is asked" {
  private_on
  GH_PRIVATE_CHECK=0 gh_in "$PUBLIC" pr create --title t --body x
  [ "$status" -eq 0 ]
  [ "$(apis)" -eq 0 ]
  [ "$(count private-bypassed)" -eq 1 ]
  [ ! -e "$TALLY/asked" ]
  gh_in "$PUBLIC" pr create --title t --body x
  [ "$status" -eq 65 ]
}

@test "private: no session id, or a marker that cannot be written, never refuses" {
  private_on
  unset CLAUDE_CODE_SESSION_ID
  gh_in "$PUBLIC" pr create --title t --body x
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'gh: octo-personal/proj-two is public. Spend, payment, identity, home-network and private-repository details do not go there: file them in octo-personal/proj-private with a "Concerns: octo-personal/proj-two" line, and leave no stub.' ]
  [ "$(count unkeyed)" -eq 1 ]
  [ ! -e "$TALLY/asked" ]
  export CLAUDE_CODE_SESSION_ID=test-session
  : > "$TALLY/asked"
  gh_in "$PUBLIC" pr create --title t --body x
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "gh: octo-personal/proj-two is public."* ]]
  [ "$(count unkeyed)" -eq 2 ]
  [ "$(creates)" -eq 2 ]
}

@test "private: a private or failing answer runs gh, the private repository itself is not asked" {
  private_on
  GH_STUB_VISIBILITY=private gh_in "$PUBLIC" pr create --title t --body x
  [ "$status" -eq 0 ]
  [ "$output" = created ]
  GH_STUB_VISIBILITY=internal gh_in "$PUBLIC" pr create --title t --body x
  [ "$status" -eq 0 ]
  [ ! -e "$TALLY" ]
  GH_STUB_API_FAIL=1 gh_in "$PUBLIC" pr create --title t --body x
  [ "$status" -eq 0 ]
  [ "$output" = created ]
  [ "$(count unknown)" -eq 1 ]
  : > "$GH_STUB_LOG"
  priv=$(make_repo 'git@github.com:octo-personal/proj-private.git')
  gh_in "$priv" pr create --title t --body x
  [ "$status" -eq 0 ]
  [ "$(apis)" -eq 0 ]
}

@test "private: no key, no CLAUDECODE, and other commands make no api call" {
  gh_in "$PERSONAL" pr create --title t --body x
  [ "$status" -eq 0 ]
  [ "$(apis)" -eq 0 ]
  private_on
  unset CLAUDECODE
  gh_in "$PUBLIC" pr create --title t --body x
  [ "$status" -eq 0 ]
  export CLAUDECODE=1
  gh_in "$PUBLIC" issue list
  gh_in "$PUBLIC" issue comment 3 --body x
  gh_in "$PUBLIC" pr view 3
  [ "$status" -eq 0 ]
  [ "$(apis)" -eq 0 ]
}

@test "private: an unstamped create refused by both prints both and exits 64; the retry passes" {
  private_on
  gh_in "$PUBLIC" issue create --title t --body x
  [ "$status" -eq 64 ]
  [[ "${lines[0]}" == "gh: not run yet. octo-personal/proj-two is public."* ]]
  [ "${lines[1]}" = "gh: if this text holds none of that, run the same command again and it will go through." ]
  [ "${lines[2]}" = "$REFUSAL_1" ]
  [ "$(apis)" -eq 1 ]
  [ "$(creates)" -eq 0 ]
  [ -f "$TALLY/asked/test-session__octo-personal__proj-two" ]
  gh_in "$PUBLIC" issue create --title t --body "$CLOSED"
  [ "$status" -eq 0 ]
  [ "$(creates)" -eq 1 ]
}

@test "private: a body on standard input is not read by a refusal; the retry delivers it whole" {
  private_on
  gh_in_stdin "$PUBLIC" "$CLOSED" issue create --title t -F -
  [ "$status" -eq 65 ]
  [ "$(creates)" -eq 0 ]
  gh_in_stdin "$PUBLIC" "$CLOSED" issue create --title t -F -
  [ "$status" -eq 0 ]
  [ "$(cat "$GH_STUB_STDIN")" = "$CLOSED" ]
}

@test "private: a marker older than 14 days goes when a new one is written, a newer one stays" {
  private_on
  mkdir -p "$TALLY/asked"
  : > "$TALLY/asked/old"
  : > "$TALLY/asked/recent"
  touch -t 202001010000 "$TALLY/asked/old"
  gh_in "$PUBLIC" pr create --title t --body x
  [ "$status" -eq 65 ]
  [ ! -e "$TALLY/asked/old" ]
  [ -e "$TALLY/asked/recent" ]
}

@test "private: no output and no file under the state directory holds the title or the body" {
  private_on
  gh_in "$PUBLIC" issue create --title "title 9242" --body "card 4111"
  [[ "$output" != *4111* && "$output" != *9242* ]]
  ! grep -rq -e 4111 -e 9242 "$XDG_STATE_HOME"
  [ -z "$(find "$XDG_STATE_HOME" -name '*4111*' -o -name '*9242*')" ]
}

@test "tally: a tally path that is a file changes no verdict and nothing lands in HOME" {
  mkdir -p "$XDG_STATE_HOME"
  : > "$TALLY"
  gh_in "$PERSONAL" issue create --title t --body x
  [ "$status" -eq 64 ]
  gh_in "$PERSONAL" issue create --title t --body "$CLOSED"
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.local/state" ]
}

# --- gh-doctor ---------------------------------------------------------------

@test "gh-doctor: issues: line says on, off or not here, with the counts" {
  gh_in "$PERSONAL" issue create --title t --body x
  run zsh -c "source '$DOTFUNCTIONS'; cd '$PERSONAL'; gh-doctor"
  [[ "$output" == *"issues:  stamp guard on · stamped 0 · refused 1 · unchecked 0 · bypassed 0"* ]]
  [[ "$output" != *"private:"* ]]
  work=$(make_repo 'git@github.com:octo-work-org/proj-one.git')
  run zsh -c "source '$DOTFUNCTIONS'; cd '$work'; gh-doctor"
  [[ "$output" == *"issues:  stamp guard off (this owner has not opted in: gh.<owner>.issue-stamp) · stamped"* ]]
  nowhere="$BATS_TEST_TMPDIR/nowhere"
  mkdir -p "$nowhere"
  run zsh -c "source '$DOTFUNCTIONS'; cd '$nowhere'; gh-doctor"
  [[ "$output" == *"issues:  stamp guard not here (no pinned owner) · stamped"* ]]
}

@test "gh-doctor: the private: line appears only where the key is set" {
  private_on
  gh_in "$PUBLIC" pr create --title t --body x
  run zsh -c "source '$DOTFUNCTIONS'; cd '$PUBLIC'; gh-doctor"
  [[ "$output" == *"private: this owner's private details go to octo-personal/proj-private · asked 1 · passed 0 · unkeyed 0 · unknown 0 · bypassed 0"* ]]
}
