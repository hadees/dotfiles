#!/usr/bin/env bats

# bin/executable_issue-practice: the issue core's command, and the core it reads
# (dot_local/share/issue-practice: version, forms/, labels.tsv). The script is plain
# sh with no network, so these run on every OS. Every tree lives under BATS_TEST_TMPDIR,
# and every fixture name is made up.

# The digest of the four forms in name order, joined, kept beside the version it
# belongs to: a form changes, the version and every marker rise, then this does.
CORE_VERSION=1
CORE_DIGEST=d506bc699ec87dbf4d100601bd1d0d9dd5bd680f320fd631b208ac2d1f0de8f7

setup() {
  # An asdf shim cannot resolve a version under a fake HOME: pin python3 first.
  PY="$(python3 -c 'import sys; print(sys.executable)')"
  IP="$BATS_TEST_DIRNAME/../bin/executable_issue-practice"
  SRC="$BATS_TEST_DIRNAME/../dot_local/share/issue-practice"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export ISSUE_PRACTICE_HOME="$SRC"
  TAB="$(printf '\t')"
  T="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$T"
}

ip() { run sh "$IP" "$@"; }

# absent <command>: fails when the command succeeds. A bare "! cmd" does not
# fail a test unless it is the last line.
absent() { ! "$@"; }

# A copy of the core to break in a test.
core_copy() {
  cp -R "$SRC" "$BATS_TEST_TMPDIR/core"
  export ISSUE_PRACTICE_HOME="$BATS_TEST_TMPDIR/core"
}

templates() { printf '%s' "$1/.github/ISSUE_TEMPLATE"; }

installed_tree() {
  sh "$IP" install "$1" >/dev/null
}

snapshot() { (cd "$1" && find . -type f -exec cksum {} + | sort); }

# first_line <file> <text>: the file with its first line replaced.
first_line() {
  { printf '%s\n' "$2"; sed 1d "$1"; } > "$1.new" && mv "$1.new" "$1"
}

@test "version and forms" {
  ip version
  [ "$status" -eq 0 ]
  [ "$output" = "issue-practice $CORE_VERSION" ]
  [ "$(cat "$SRC/version")" = "$CORE_VERSION" ]
  ip forms
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'bug.yml\nconfig.yml\nfeature.yml\ntask.yml')" ]
}

@test "core forms: marker, keys, ids, labels, min_length" {
  marker="# issue-practice $CORE_VERSION: installed from the issue core; change it there, never here."
  for f in bug config feature task; do
    [ "$(sed -n 1p "$SRC/forms/$f.yml")" = "$marker" ]
  done
  for f in bug feature task; do
    for k in name description type body; do grep -q "^$k:" "$SRC/forms/$f.yml"; done
    absent grep -Eq '^(labels|assignees|projects|title):' "$SRC/forms/$f.yml"
    [ "$(grep -c 'min_length:' "$SRC/forms/$f.yml")" -eq 1 ]
    grep -q 'min_length: 20$' "$SRC/forms/$f.yml"
    ids="$(sed -n 's/^ *id: //p' "$SRC/forms/$f.yml")"
    [ -z "$(printf '%s\n' "$ids" | sort | uniq -d)" ]
  done
  [ "$(sed -n 's/^ *label: //p' "$SRC/forms/feature.yml")" = "$(sed -n 's/^ *label: //p' "$SRC/forms/task.yml")" ]
  grep -qx 'blank_issues_enabled: false' "$SRC/forms/config.yml"
  # A '#' in a markdown value would start a YAML comment.
  run grep -h -A1 'value: |' "$SRC"/forms/task.yml "$SRC"/forms/feature.yml "$SRC"/forms/bug.yml
  [ "$status" -eq 0 ]
  absent grep -q '#' <<< "$(printf '%s\n' "$output" | grep -v -e 'value: |' -e '^--$')"
}

@test "digest: a form changed means a new version and a new digest" {
  run "$PY" -I -c '
import hashlib, sys
h = hashlib.sha256()
for n in ("bug.yml", "config.yml", "feature.yml", "task.yml"):
    h.update(open(sys.argv[1] + "/forms/" + n, "rb").read())
print(h.hexdigest())' "$SRC"
  [ "$status" -eq 0 ]
  if [ "$output" != "$CORE_DIGEST" ]; then
    echo "a form changed: raise version, raise the number in every marker, then put the new digest here ($output)" >&2
    return 1
  fi
}

@test "check: none for no .github, and for a directory with only a README" {
  ip check "$T"
  [ "$status" -eq 0 ]
  [ "$output" = "forms: none" ]
  mkdir -p "$(templates "$T")"
  printf 'x\n' > "$(templates "$T")/README.txt"
  ip check "$T"
  [ "$status" -eq 0 ]
  [ "$output" = "forms: none" ]
}

@test "check: current after install" {
  installed_tree "$T"
  ip check "$T"
  [ "$status" -eq 0 ]
  [ "$output" = "forms: current issue-practice 1" ]
}

@test "check: an unmarked config.yml alone is own, exit 1" {
  mkdir -p "$(templates "$T")"
  printf 'blank_issues_enabled: true\n' > "$(templates "$T")/config.yml"
  ip check "$T"
  [ "$status" -eq 1 ]
  [ "$output" = "forms: own config.yml" ]
}

@test "check: an unmarked extra file next to the installed four is own" {
  installed_tree "$T"
  printf 'hello\n' > "$(templates "$T")/extra.md"
  ip check "$T"
  [ "$status" -eq 1 ]
  [ "$output" = "forms: own extra.md" ]
}

@test "check: a marker comment pasted below line 1 is not a marker" {
  mkdir -p "$(templates "$T")"
  printf 'name: Own\n# issue-practice 1: installed from the issue core; change it there, never here.\n' > "$(templates "$T")/task.yml"
  ip check "$T"
  [ "$status" -eq 1 ]
  [ "$output" = "forms: own task.yml" ]
}

@test "check: behind and ahead" {
  installed_tree "$T"
  first_line "$(templates "$T")/task.yml" "# issue-practice 0: installed from the issue core; change it there, never here."
  ip check "$T"
  [ "$status" -eq 1 ]
  [ "$output" = "forms: behind issue-practice 0 here, 1 in the core" ]
  first_line "$(templates "$T")/task.yml" "# issue-practice 2: installed from the issue core; change it there, never here."
  ip check "$T"
  [ "$status" -eq 1 ]
  [ "$output" = "forms: ahead issue-practice 2 here, 1 in the core" ]
}

@test "check: edited below an intact marker, a form deleted, one more marked file" {
  installed_tree "$T"
  printf '# one more line\n' >> "$(templates "$T")/task.yml"
  ip check "$T"
  [ "$status" -eq 1 ]
  [ "$output" = "forms: edited task.yml" ]
  rm "$(templates "$T")/bug.yml"
  cp "$SRC/forms/task.yml" "$(templates "$T")/task.yml"
  ip check "$T"
  [ "$status" -eq 1 ]
  [ "$output" = "forms: edited bug.yml" ]
  cp "$SRC/forms/bug.yml" "$(templates "$T")/bug.yml"
  cp "$SRC/forms/bug.yml" "$(templates "$T")/spare.yml"
  ip check "$T"
  [ "$status" -eq 1 ]
  [ "$output" = "forms: edited spare.yml" ]
}

@test "install: into an empty tree" {
  ip install "$T" --dry-run
  [ "$status" -eq 0 ]
  [ "$output" = "would install: issue-practice 1, 4 files" ]
  [ ! -e "$T/.github" ]
  ip install "$T"
  [ "$status" -eq 0 ]
  [ "$output" = "installed: issue-practice 1, 4 files" ]
  for f in bug config feature task; do cmp "$SRC/forms/$f.yml" "$(templates "$T")/$f.yml"; done
  [ "$(ls -A "$(templates "$T")" | wc -l | tr -d ' ')" = 4 ]
}

@test "install: on current there is nothing to do" {
  installed_tree "$T"
  ip install "$T"
  [ "$status" -eq 0 ]
  [ "$output" = "nothing to do: forms: current issue-practice 1" ]
}

@test "install: on behind it overwrites, removes a marked file the core lacks, keeps a README" {
  installed_tree "$T"
  first_line "$(templates "$T")/task.yml" "# issue-practice 0: installed from the issue core; change it there, never here."
  printf '# issue-practice 0: installed from the issue core; change it there, never here.\nname: Old\n' > "$(templates "$T")/old.yml"
  printf 'note\n' > "$(templates "$T")/README.txt"
  ip install "$T"
  [ "$status" -eq 0 ]
  [ "$output" = "installed: issue-practice 1, 4 files" ]
  cmp "$SRC/forms/task.yml" "$(templates "$T")/task.yml"
  [ ! -e "$(templates "$T")/old.yml" ]
  [ -f "$(templates "$T")/README.txt" ]
}

@test "install: declines own, edited and ahead, with the tree untouched" {
  mkdir -p "$(templates "$T")"
  printf 'blank_issues_enabled: true\n' > "$(templates "$T")/config.yml"
  before="$(snapshot "$T")"
  ip install "$T"
  [ "$status" -eq 3 ]
  [ "$output" = "issue-practice: not installed: forms: own config.yml" ]
  [ "$(snapshot "$T")" = "$before" ]

  rm -r "${T:?}/.github"
  installed_tree "$T"
  printf '# edit\n' >> "$(templates "$T")/bug.yml"
  before="$(snapshot "$T")"
  ip install "$T"
  [ "$status" -eq 3 ]
  [ "$output" = "issue-practice: not installed: forms: edited bug.yml" ]
  [ "$(snapshot "$T")" = "$before" ]

  rm -r "${T:?}/.github"
  installed_tree "$T"
  first_line "$(templates "$T")/bug.yml" "# issue-practice 2: installed from the issue core; change it there, never here."
  before="$(snapshot "$T")"
  ip install "$T"
  [ "$status" -eq 3 ]
  [ "$output" = "issue-practice: not installed: forms: ahead issue-practice 2 here, 1 in the core" ]
  [ "$(snapshot "$T")" = "$before" ]
}

@test "a tree whose path holds a space works for check and install" {
  S="$BATS_TEST_TMPDIR/a tree"
  mkdir -p "$S"
  ip install "$S"
  [ "$status" -eq 0 ]
  ip check "$S"
  [ "$status" -eq 0 ]
  [ "$output" = "forms: current issue-practice 1" ]
}

@test "labels: seven lines, three fields each, the signed names" {
  ip labels
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 7 ]
  absent grep -q '^#' <<< "$output"
  names=
  while IFS="$TAB" read -r name colour desc rest; do
    [ -z "$rest" ]
    [[ "$name" =~ ^[a-z0-9][a-z0-9:-]*$ ]]
    [[ "$colour" =~ ^[0-9a-fA-F]{6}$ ]]
    [ -n "$desc" ]
    [ "${#desc}" -le 100 ]
    case " $names " in *" $name "*) false ;; esac
    names="$names $name"
  done <<EOF
$output
EOF
  [ "$names" = " agent-ready needs-human blocked idea ai:claude ai:gpt ai:gemini" ]
  [ "$(grep -c "$TAB" "$SRC/labels.tsv")" -eq 7 ]
}

@test "labels check: its own output is current, with the allowed variations" {
  sh "$IP" labels > "$BATS_TEST_TMPDIR/l"
  ip labels check < "$BATS_TEST_TMPDIR/l"
  [ "$status" -eq 0 ]
  [ "$output" = "labels: current" ]
  # upper-case colour, a '#' on another, a name in another case, extra labels
  sed -e 's/0e8a16/0E8A16/' -e 's/d93f0b/#d93f0b/' -e 's/^blocked/Blocked/' "$BATS_TEST_TMPDIR/l" > "$BATS_TEST_TMPDIR/l2"
  printf 'my-own\t123456\tmine\n' >> "$BATS_TEST_TMPDIR/l2"
  ip labels check < "$BATS_TEST_TMPDIR/l2"
  [ "$status" -eq 0 ]
  [ "$output" = "labels: current" ]
}

@test "labels check: missing, differ, both, empty and a bare name" {
  sh "$IP" labels > "$BATS_TEST_TMPDIR/l"
  grep -v -e '^needs-human' -e '^ai:gpt' "$BATS_TEST_TMPDIR/l" > "$BATS_TEST_TMPDIR/m"
  ip labels check < "$BATS_TEST_TMPDIR/m"
  [ "$status" -eq 1 ]
  [ "$output" = "labels: missing needs-human ai:gpt" ]
  sed 's/^idea\(.*\)$/idea\1 changed/' "$BATS_TEST_TMPDIR/l" > "$BATS_TEST_TMPDIR/d"
  ip labels check < "$BATS_TEST_TMPDIR/d"
  [ "$status" -eq 1 ]
  [ "$output" = "labels: differ idea" ]
  sed '/^blocked/d; s/^idea\(.*\)$/idea\1 changed/' "$BATS_TEST_TMPDIR/l" > "$BATS_TEST_TMPDIR/b"
  ip labels check < "$BATS_TEST_TMPDIR/b"
  [ "$status" -eq 1 ]
  [ "$output" = "labels: missing blocked" ]
  ip labels check < /dev/null
  [ "$status" -eq 1 ]
  [ "$output" = "labels: missing agent-ready needs-human blocked idea ai:claude ai:gpt ai:gemini" ]
  sed 's/^idea.*$/idea/' "$BATS_TEST_TMPDIR/l" > "$BATS_TEST_TMPDIR/n"
  ip labels check < "$BATS_TEST_TMPDIR/n"
  [ "$status" -eq 1 ]
  [ "$output" = "labels: differ idea" ]
}

@test "a core with no labels but the comment line" {
  core_copy
  head -1 "$SRC/labels.tsv" > "$ISSUE_PRACTICE_HOME/labels.tsv"
  ip labels
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ip labels check < /dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "labels: current" ]
}

@test "usage is exit 2" {
  ip
  [ "$status" -eq 2 ]
  ip frobnicate
  [ "$status" -eq 2 ]
  ip labels nonsense
  [ "$status" -eq 2 ]
  ip check
  [ "$status" -eq 2 ]
  ip install
  [ "$status" -eq 2 ]
  : > "$BATS_TEST_TMPDIR/afile"
  ip check "$BATS_TEST_TMPDIR/afile"
  [ "$status" -eq 2 ]
  [[ "$output" == "issue-practice: not a directory: "* ]]
}

@test "help is exit 0 even with no core" {
  export ISSUE_PRACTICE_HOME="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$ISSUE_PRACTICE_HOME"
  for h in help -h --help; do
    ip $h
    [ "$status" -eq 0 ]
    [[ "$output" == *"issue-practice check <tree>"* ]]
  done
}

# Every call but help is exit 4 with the one line.
no_usable() {
  for c in "version" "forms" "check $T" "install $T" "labels"; do
    # shellcheck disable=SC2086
    ip $c
    [ "$status" -eq 4 ]
    [ "$output" = "issue-practice: no usable core at $ISSUE_PRACTICE_HOME" ]
  done
  ip labels check < /dev/null
  [ "$status" -eq 4 ]
  [ "$output" = "issue-practice: no usable core at $ISSUE_PRACTICE_HOME" ]
}

@test "a broken core is exit 4: empty, an unmarked form, no labels.tsv, bad label lines" {
  export ISSUE_PRACTICE_HOME="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$ISSUE_PRACTICE_HOME"
  no_usable

  core_copy
  first_line "$ISSUE_PRACTICE_HOME/forms/bug.yml" "name: Bug"
  no_usable

  core_copy2() { rm -rf "$BATS_TEST_TMPDIR/core"; core_copy; }
  core_copy2
  rm "$ISSUE_PRACTICE_HOME/labels.tsv"
  no_usable

  core_copy2
  printf 'two\tfields\n' > "$ISSUE_PRACTICE_HOME/labels.tsv"
  no_usable

  core_copy2
  printf 'five\t12345\tdigits\n' > "$ISSUE_PRACTICE_HOME/labels.tsv"
  no_usable
}

@test "the script makes no network or repository call" {
  absent grep -Eq '(^|[^[:alnum:]_-])(git|gh)[[:space:]]|curl|wget' "$IP"
}
