#!/usr/bin/env bats

# Tree-level hygiene guard: this repo is public and identity-free, so no
# secret material, no email addresses (outside files that credit upstream
# authors), and no typographic "smart" quotes in executed shell positions
# may land in the source tree. Scans iterate `git ls-files` so .git and
# untracked junk are excluded; helpers take a repo directory so the seeded
# negative tests can prove the scans actually catch violations.
#
# Every pattern below is built by string concatenation so that this file,
# once tracked, can never trip its own scan.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  # Container CI checkouts are owned by another uid and git refuses to read
  # them ("dubious ownership"), which would silently EMPTY the ls-files
  # scan lists and turn every guard below vacuous. Mark repos safe via a
  # per-test global config, then prove the scan list is non-empty so a
  # future git failure loudly fails the suite instead.
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  git config --file "$GIT_CONFIG_GLOBAL" safe.directory '*'
  [ -n "$(git -C "$REPO" ls-files)" ]

  # 1Password secret references. Outside the onepassword skill the documented
  # occurrences — CLAUDE.md's onepasswordRead example and the literal grep
  # patterns in tests/chezmoi.bats' rendered-home leak guard — are asserted
  # exactly (file + count) rather than allowlisted by pattern.
  #
  # The skill is documentation *about* the syntax, so it necessarily carries
  # many references and an exact count there would be churn with no meaning.
  # It is guarded on the property that actually matters instead: every
  # reference in it must name a placeholder vault, never a real one.
  OP_PAT='op:''//'
  OP_SKILL='.claude/skills/onepassword/'

  # Token/key material: GitHub PATs, AWS access key ids, Slack bot tokens,
  # PEM private key blocks.
  SECRET_PAT='(ghp|gho)_[A-Za-z0-9]{16,}'
  SECRET_PAT+='|github_pat_[A-Za-z0-9_]{16,}'
  SECRET_PAT+='|AKIA[0-9A-Z]{16}'
  SECRET_PAT+='|xoxb-[0-9A-Za-z-]{4,}'
  SECRET_PAT+='|BEGIN [A-Z ]*PRIVATE'' KEY'

  EMAIL_PAT='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

  # U+2018 U+2019 U+201C U+201D as an alternation of full UTF-8 byte
  # sequences (a bracket expression would match stray lead bytes under
  # LC_ALL=C and misfire on other multibyte characters).
  SMART_PAT="$(printf '\342\200\230')|$(printf '\342\200\231')"
  SMART_PAT+="|$(printf '\342\200\234')|$(printf '\342\200\235')"

  # Sourced shell files whose executed lines must stay smart-quote free.
  SHELL_FILES='dot_functions dot_aliases dot_exports dot_zshrc dot_zsh_prompt dot_bash_profile'
}

# Print "file:line:content" for every tracked text file in repo $2 whose
# content matches extended regex $1.
tree_grep() {
  local pat=$1 dir=$2 f
  while IFS= read -r -d '' f; do
    [ -f "$dir/$f" ] || continue
    LC_ALL=C grep -InE "$pat" "$dir/$f" | sed "s|^|$f:|"
  done < <(git -C "$dir" ls-files -z)
}

# Secret-reference hits in repo $1 outside the onepassword skill directory.
op_refs_outside_skill() {
  tree_grep "$OP_PAT" "$1" | grep -vF "$OP_SKILL"
}

# Secret references in repo $1 whose vault segment is a literal name rather
# than a placeholder. Placeholders are an angle-bracket token (<vault>), a
# shell variable ($APP_ENV), an ellipsis, the reserved example vault "Private"
# that CLAUDE.md's onepasswordRead example already uses, or nothing at all (a
# scheme with no path, as quoted in a grep pattern, names no vault). Anything
# else names a real vault and must not land in a public repo. The vault
# segment is captured directly — matching only characters that can appear in
# one, so the match stops at the trailing slash, quote, or brace of the
# surrounding prose.
op_real_vault_refs() {
  tree_grep "$OP_PAT" "$1" \
    | grep -oE "$OP_PAT"'[A-Za-z0-9_.$<>-]*' \
    | sed -E "s|^$OP_PAT||" \
    | grep -vE '^($|<|\$|\.\.\.$|Private$)' || true
}

# Email hits in repo $1, after dropping the files allowed to credit
# upstream authors, any git@<host> ssh destination — scp-style URLs and the
# bare host git hands its ssh command (git@host is a protocol user, not an
# address; same exclusion the rendered-home guard in tests/chezmoi.bats
# uses), and addresses at the
# RFC 2606 reserved example domains used by test fixtures.
email_hits() {
  local dir=$1 f
  while IFS= read -r -d '' f; do
    [ -f "$dir/$f" ] || continue
    case $f in
      LICENSE-MIT.txt|README.md|dot_vim/syntax/json.vim) continue ;;
    esac
    LC_ALL=C sed -E \
        -e 's/git@[A-Za-z0-9.-]+//g' \
        -e 's/git@(gist\.)?github\.com//g' \
        -e 's/[A-Za-z0-9._%+-]+@example\.(com|net|org)//g' \
        "$dir/$f" \
      | LC_ALL=C grep -InE "$EMAIL_PAT" | sed "s|^|$f:|"
  done < <(git -C "$dir" ls-files -z)
}

# Smart-quote hits in executed positions of the sourced shell files under
# repo $1: drop lines whose first non-blank character is #, flag the rest.
# This is exactly the shape that recently broke a function — a $'...'
# ANSI-C string whose straight quotes were replaced by curly ones.
smart_quote_hits() {
  local dir=$1 f
  for f in $SHELL_FILES "$dir"/bin/executable_*; do
    case $f in
      "$dir"/*) ;;
      *) f="$dir/$f" ;;
    esac
    [ -f "$f" ] || continue
    LC_ALL=C grep -nE "$SMART_PAT" "$f" \
      | grep -vE '^[0-9]+:[[:space:]]*#' \
      | sed "s|^|${f#"$dir"/}:|"
  done
}

# Fresh throwaway repo for seeding synthetic violations.
make_tree() {
  local dir="$BATS_TEST_TMPDIR/seeded"
  rm -rf "$dir"
  git init -q "$dir"
  echo "$dir"
}

# --- The current tree is clean ---------------------------------------------

@test "op secret references: only the documented occurrences, exactly" {
  run op_refs_outside_skill "$REPO"
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == CLAUDE.md:* ]]
  [[ "${lines[1]}" == tests/chezmoi.bats:* ]]
  [[ "${lines[2]}" == tests/chezmoi.bats:* ]]
}

@test "op secret references in the onepassword skill name no real vault" {
  # The skill must contain at least one, or this guard is vacuous and the
  # syntax documentation has gone missing.
  run tree_grep "$OP_PAT" "$REPO"
  [ -n "$(printf '%s\n' "${lines[@]}" | grep -F "$OP_SKILL")" ]
  run op_real_vault_refs "$REPO"
  [ -z "$output" ]
}

@test "no token or private-key material anywhere in the tree" {
  run tree_grep "$SECRET_PAT" "$REPO"
  [ -z "$output" ]
}

@test "no email addresses outside the upstream-credit allowlist" {
  run email_hits "$REPO"
  [ -z "$output" ]
}

@test "no smart quotes in executed positions of sourced shell files" {
  run smart_quote_hits "$REPO"
  [ -z "$output" ]
}

# --- Seeded violations are caught ------------------------------------------

@test "seeded: a GitHub token in a tracked file is caught" {
  dir=$(make_tree)
  printf 'export HOMEBREW_GITHUB_API_TOKEN=%s\n' \
    "ghp_""0123456789abcdefghij0123456789abcdef" > "$dir/dot_exports"
  git -C "$dir" add -A
  run tree_grep "$SECRET_PAT" "$dir"
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == dot_exports:1:* ]]
}

@test "seeded: a private key block in a tracked file is caught" {
  dir=$(make_tree)
  printf -- '-----BEGIN OPENSSH PRIVATE%s-----\nbase64junk\n' " KEY" \
    > "$dir/id_ed25519"
  git -C "$dir" add -A
  run tree_grep "$SECRET_PAT" "$dir"
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == id_ed25519:1:* ]]
}

@test "seeded: an op reference outside CLAUDE.md is caught" {
  dir=$(make_tree)
  printf 'export TOKEN={{ onepasswordRead "%sVault/item/field" }}\n' \
    "op:""//" > "$dir/dot_exports"
  git -C "$dir" add -A
  run tree_grep "$OP_PAT" "$dir"
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == dot_exports:1:* ]]
}

@test "seeded: an email in a non-allowlisted file is caught" {
  dir=$(make_tree)
  printf 'export EMAIL=%s@%s\n' "someone" "somewhere-real.net" \
    > "$dir/dot_exports"
  git -C "$dir" add -A
  run email_hits "$dir"
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == dot_exports:1:* ]]
}

@test "seeded: untracked junk with an email is ignored" {
  dir=$(make_tree)
  printf 'contact %s@%s\n' "someone" "somewhere-real.net" > "$dir/scratch.txt"
  run email_hits "$dir"
  [ -z "$output" ]
}

@test "seeded: a curly-quoted ANSI-C string in dot_functions is caught" {
  dir=$(make_tree)
  local rq; rq=$(printf '\342\200\231')
  printf 'alias please=$%ssudo !!%s\n' "$rq" "$rq" > "$dir/dot_functions"
  run smart_quote_hits "$dir"
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == dot_functions:1:* ]]
}

@test "seeded: smart quotes in full-line comments are tolerated" {
  dir=$(make_tree)
  local rq; rq=$(printf '\342\200\231')
  printf '\t# don%st flag comment-only lines\nalias ok="fine"\n' "$rq" \
    > "$dir/dot_functions"
  run smart_quote_hits "$dir"
  [ -z "$output" ]
}
