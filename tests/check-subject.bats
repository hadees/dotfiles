#!/usr/bin/env bats

# The personal git-conventions skill ships check-subject.sh, which validates a
# commit subject against the emoji + Conventional Commits shape. The last two
# tests are the drift guards: the script embeds its own emoji tables (a git
# hook installed as .git/hooks/commit-msg has no access to the skill's
# references/), so the copies are diffed against the documents they came from.

setup() {
  SKILL="$BATS_TEST_DIRNAME/../private_dot_claude-hadees/skills/git-conventions"
  SCRIPT="$SKILL/scripts/executable_check-subject.sh"
}

check() { printf '%s\n' "$1" | sh "$SCRIPT" -; }

@test "minimal valid subject passes" {
  run check '✨ feat: add the workspace launcher'
  [ "$status" -eq 0 ]
}

@test "every type anchor pair passes" {
  while read -r emoji type; do
    run check "$emoji $type: do the thing"
    [ "$status" -eq 0 ]
  done < <(sh "$SCRIPT" --list-anchors)
}

@test "flavor and breaking-change forms pass" {
  run check '🧰 chore: ⬆️ bump the pinned bats version'
  [ "$status" -eq 0 ]
  run check '✨ feat!: drop the bash 3.2 fallback'
  [ "$status" -eq 0 ]
}

@test "git-generated subjects are exempt" {
  run check 'Merge branch feat/x into main'
  [ "$status" -eq 0 ]
  run check 'fixup! ✨ feat: add the workspace launcher'
  [ "$status" -eq 0 ]
}

@test "a mispaired anchor names the right one" {
  run check '🐛 feat: anchor belongs to fix'
  [ "$status" -eq 1 ]
  [[ $output == *"takes the anchor"* ]]
}

@test "a bare subject with no anchor fails" {
  run check 'add the workspace launcher'
  [ "$status" -eq 1 ]
}

@test "a type anchor in the flavor slot is rejected" {
  run check '✨ feat: 🐛 two kinds of change in one commit'
  [ "$status" -eq 1 ]
  [[ $output == *"not a flavor"* ]]
}

@test "drift guard: script flavor table matches references/flavors.md" {
  md=$(awk -F'|' '/^\| .+ \| `:.+:` \|/ {gsub(/^ +| +$/, "", $2); print $2}' \
    "$SKILL/references/flavors.md")
  script=$(sh "$SCRIPT" --list-flavors)
  diff <(printf '%s\n' "$md") <(printf '%s\n' "$script")
}

@test "drift guard: script anchors match the SKILL.md anchor table" {
  md=$(awk -F'|' '/^\| .+ \| `[a-z]+:` +\|/ {
    gsub(/^ +| +$/, "", $2); gsub(/[` ]/, "", $3); sub(/:$/, "", $3);
    print $2 " " $3}' "$SKILL/SKILL.md")
  script=$(sh "$SCRIPT" --list-anchors)
  diff <(printf '%s\n' "$md") <(printf '%s\n' "$script")
}

@test "no work-domain flavors survive in either copy" {
  ! grep -qE 'SPICE|netlist|Monte Carlo|semiconductor' \
    "$SKILL/references/flavors.md" "$SCRIPT" "$SKILL/SKILL.md"
}
