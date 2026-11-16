# Helpers for the tests that read the shared Claude memory. The memory is an
# index (dot_claude-shared/CLAUDE.md) that `@topics/<slug>.md` imports, one per
# line, so anything that wants the whole text reads the expansion.

SHARED_MEMORY="$BATS_TEST_DIRNAME/../dot_claude-shared/CLAUDE.md"

# The index with each import line replaced by the file it names (paths resolve
# against the importing file, as Claude Code resolves them). Expands one level:
# a topic that imported another file would stay unexpanded and fail the
# claude-shared-memory test that forbids it.
shared_memory_expanded() {
  python3 -I - "$SHARED_MEMORY" <<'PY'
import os, re, sys
index = sys.argv[1]
out = []
for line in open(index, encoding="utf-8").read().split("\n"):
    m = re.fullmatch(r"@(\S+)", line)
    if m:
        out.append(open(os.path.join(os.path.dirname(index), m.group(1)), encoding="utf-8").read().rstrip("\n"))
    else:
        out.append(line)
sys.stdout.write("\n".join(out))
PY
}

# The expansion, then each topic the index does not import (sorted) after a
# blank line: the text of the whole memory, whether a session loads it at
# start, a hook adds it, or Claude reads it when the task comes up.
shared_memory_all() {
  shared_memory_expanded
  python3 -I - "$SHARED_MEMORY" <<'PY'
import glob, os, re, sys
index = sys.argv[1]
imported = set(re.findall(r"^@(\S+)$", open(index, encoding="utf-8").read(), re.M))
here = os.path.dirname(index)
for f in sorted(glob.glob(os.path.join(here, "topics", "*.md"))):
    if os.path.relpath(f, here) not in imported:
        sys.stdout.write("\n\n" + open(f, encoding="utf-8").read().rstrip("\n"))
PY
}
