#!/usr/bin/env bats

# CLAUDE.md is the always-loaded memory; the per-tool design notes live in
# path-scoped rule files under .claude/rules/ and load only when a file they
# cover is opened. That mechanism declines to act without a trace: a rule whose
# glob no longer matches anything (its script was renamed) simply never loads,
# and a file that grows past the limits costs every session again. These tests
# are the countable part. Fixture rules only — no real names (see CLAUDE.md).

ROOT="$BATS_TEST_DIRNAME/.."
RULES="$ROOT/.claude/rules"
CLAUDE_MD_MAX=25000   # characters; the always-loaded file
RULE_MAX=40000        # characters; the on-demand per-file limit

# Code points, counted by python: wc -m counts bytes under the C locale of the
# Rocky CI container.
chars() { python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read()))' "$1"; }

setup() {
  # Container CI checkouts are owned by another uid and git refuses to read
  # them ("dubious ownership"). Point the global config at a per-test file
  # so marking the repo safe never touches the real machine's config.
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  git config --file "$GIT_CONFIG_GLOBAL" safe.directory '*'
}

# The `paths:` entries of a rule file, one per line, quotes stripped. Fails if
# the file does not open with a frontmatter block.
rule_paths() {
  awk '
    NR==1 { if ($0 != "---") exit 1; next }
    $0 == "---" { exit }
    /^[[:space:]]+-[[:space:]]/ { sub(/^[[:space:]]+-[[:space:]]+/, ""); gsub(/"/, ""); print }
  ' "$1"
}

# Prints every `paths` entry of the rule file $2 that matches no tracked file
# in the git repository $1.
dead_globs() {
  local pattern
  while IFS= read -r pattern; do
    [ -n "$(git -C "$1" ls-files ":(glob)$pattern")" ] || echo "$pattern"
  done < <(rule_paths "$2")
}

# Rule names listed in the map table of CLAUDE.md ("Where the detail lives").
map_names() {
  awk '/^### Where the detail lives/ {on=1; next} /^### / {on=0} on' "$ROOT/CLAUDE.md" \
    | sed -nE 's/^\| `([a-z0-9-]+)` \|.*/\1/p'
}

@test "CLAUDE.md stays under the always-loaded budget" {
  n="$(chars "$ROOT/CLAUDE.md")"
  [ "$n" -le "$CLAUDE_MD_MAX" ] || { echo "CLAUDE.md is $n characters, limit $CLAUDE_MD_MAX"; false; }
}

@test "every rule file opens with frontmatter that has a paths list, and is under the size limit" {
  for f in "$RULES"/*.md; do
    [ -n "$(rule_paths "$f")" ] || { echo "$f: no frontmatter paths"; false; }
    n="$(chars "$f")"
    [ "$n" -le "$RULE_MAX" ] || { echo "$f: $n characters, limit $RULE_MAX"; false; }
  done
}

@test "every paths entry in a rule file matches a tracked file" {
  for f in "$RULES"/*.md; do
    dead="$(dead_globs "$ROOT" "$f")"
    [ -z "$dead" ] || { echo "$f: matches no tracked file: $dead"; false; }
  done
}

@test "a rule with a glob that matches nothing is caught (fixture repo)" {
  repo="$(mktemp -d)"
  git -C "$repo" init -q
  mkdir "$repo/bin"
  : > "$repo/bin/tool"
  git -C "$repo" add bin/tool
  printf -- '---\npaths:\n  - "**/bin/tool"\n  - "**/bin/renamed-tool"\n---\n\n# Fixture\n' > "$repo/fixture.md"
  run dead_globs "$repo" "$repo/fixture.md"
  rm -rf "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "**/bin/renamed-tool" ]
}

@test "the map in CLAUDE.md and the rule files list each other" {
  map="$(map_names | sort)"
  files="$(basename -a "$RULES"/*.md | sed 's/\.md$//' | sort)"
  [ -n "$map" ] || { echo "no map rows found in CLAUDE.md"; false; }
  [ "$map" = "$files" ] || { echo "map and files differ:"; diff <(echo "$map") <(echo "$files"); false; }
}
