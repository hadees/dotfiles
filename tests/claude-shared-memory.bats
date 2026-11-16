#!/usr/bin/env bats

# The shared Claude memory is split into per-topic files so that no one file
# grows past what a session can read in one piece (Anthropic's guidance is
# under 200 lines per file). The index imports each topic with `@topics/...`;
# an import written inside backticks is not an import, and one written outside
# them by accident would pull a file in that nobody listed.

load shared-memory

TOPICS="$BATS_TEST_DIRNAME/../dot_claude-shared/topics"
LINES_MAX=200

@test "the index imports every topic file exactly once, and every import resolves" {
  local f imports listed
  imports="$(grep -E '^@' "$SHARED_MEMORY" | sort)"
  listed="$(cd "$TOPICS" && for f in *.md; do echo "@topics/$f"; done | sort)"
  [ -n "$listed" ]
  [ "$imports" = "$listed" ] || { echo "index imports differ from topics/:"; diff <(echo "$imports") <(echo "$listed"); false; }
  [ -z "$(echo "$imports" | uniq -d)" ] || { echo "an import appears twice"; false; }
  for f in $imports; do
    [ -f "$(dirname "$SHARED_MEMORY")/${f#@}" ] || { echo "unresolved import: $f"; false; }
  done
}

@test "each topic starts with its own ## heading and imports nothing" {
  local f
  for f in "$TOPICS"/*.md; do
    [[ "$(head -1 "$f")" == '## '* ]] || { echo "$f: first line is not a ## heading"; false; }
  done
  # A bare @path outside backticks is an import (inside a code span or a
  # code block it is not). Neither the topics nor the
  # expansion may hold one beyond the index's own lines.
  python3 -I - "$TOPICS" <<'PY' || { echo "a topic holds a bare @ import"; false; }
import glob, re, sys
bad = []
for f in sorted(glob.glob(sys.argv[1] + "/*.md")):
    fenced = False
    for n, line in enumerate(open(f, encoding="utf-8").read().split("\n"), 1):
        if line.lstrip().startswith("```"):
            fenced = not fenced
        elif not fenced and re.search(r"(^|\s)@\S", re.sub(r"`[^`]*`", "", line)):
            bad.append("%s:%d: %s" % (f, n, line))
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
}

@test "every shared-memory file is under $LINES_MAX lines" {
  local f n
  for f in "$SHARED_MEMORY" "$TOPICS"/*.md; do
    n="$(wc -l < "$f")"
    [ "$n" -lt "$LINES_MAX" ] || { echo "$f is $n lines, limit under $LINES_MAX"; false; }
  done
}

@test "the expansion keeps the index's title and intro, then the sections in import order" {
  local exp
  exp="$(shared_memory_expanded)"
  [[ "$exp" == '# Shared user memory'* ]]
  [ "$(grep -c '^## ' <<< "$exp")" -eq "$(grep -c '^@' "$SHARED_MEMORY")" ]
  ! grep -q '^@' <<< "$exp" || { echo "an import line survived the expansion"; false; }
}
