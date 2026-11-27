#!/usr/bin/env bats

# step-cost reads a profile's Claude Code transcripts and prints numbers, never
# text. These tests build a profile of invented transcripts (shaped like the
# records Claude Code 2.1.325 writes, no real text) under BATS_TEST_TMPDIR and
# drive the real script against it. Every prompt in a fixture starts with FX-
# so a leak shows up as a grep.
#
# python3 is resolved to its real interpreter before HOME is sandboxed, for
# the reason tests/denyguard.bats gives (an asdf shim breaks under a fake
# HOME).

SC="$BATS_TEST_DIRNAME/../bin/executable_step-cost"

setup() {
  command -v python3 >/dev/null || skip "python3 not installed"
  REAL_PYTHON3="$(python3 -c 'import sys; print(sys.executable)')"

  mkdir -p "$BATS_TEST_TMPDIR/home" "$BATS_TEST_TMPDIR/bin"
  export HOME
  HOME="$(cd "$BATS_TEST_TMPDIR/home" && pwd -P)"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_PYTHON3" > "$BATS_TEST_TMPDIR/bin/python3"
  chmod +x "$BATS_TEST_TMPDIR/bin/python3"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  export CLAUDE_CONFIG_DIR="$HOME/.claude-test"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  "$REAL_PYTHON3" -I - "$CLAUDE_CONFIG_DIR" <<'PY'
import json
import os
import sys
import time
from datetime import datetime, timezone

root = sys.argv[1]
T0 = int(time.time()) - 7200


def stamp(off):
    return datetime.fromtimestamp(T0 + off, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def user(off, text, **kw):
    return dict(type="user", timestamp=stamp(off), isSidechain=kw.pop("side", False),
                message={"role": "user", "content": text}, **kw)


def asst(off, req, usage, blocks=None, side=False):
    i, w, r, o = usage
    return dict(type="assistant", timestamp=stamp(off), isSidechain=side, requestId=req,
                message={"id": "msg_" + req, "model": "claude-fixture-1",
                         "content": blocks or [{"type": "text", "text": "FX-REPLY"}],
                         "usage": {"input_tokens": i, "cache_creation_input_tokens": w,
                                   "cache_read_input_tokens": r, "output_tokens": o}})


def write(path, recs, extra=""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        for rec in recs:
            fh.write(json.dumps(rec) + "\n")
        fh.write(extra)


proj = root + "/projects/-fx-proj/"
send = [{"type": "tool_use", "id": "t1", "name": "SendMessage", "input": {}}]
tool_result = [{"type": "tool_result", "tool_use_id": "t1", "content": "FX-RESULT"}]

# alpha-lead: one of everything. Four requests; the first is written twice.
write(proj + "aaaa.jsonl", [
    {"type": "agent-name", "agentName": "alpha-lead", "sessionId": "aaaa"},
    user(0, "FX-PROMPT-ONE"),
    asst(5, "q1", (1, 100, 1000, 10)),
    asst(5, "q1", (1, 100, 1000, 10), send),
    user(6, tool_result),
    user(7, "<task-notification>FX-NOTE</task-notification>"),
    user(8, "FX-META", isMeta=True),
    user(9, "FX-SIDE", side=True),
    user(150, "FX-PROMPT-BUSY"),
    asst(160, "q2", (2, 200, 2000, 20)),
    {"type": "system", "subtype": "compact_boundary", "timestamp": stamp(170), "isSidechain": False},
    asst(180, "q3", (3, 0, 3000, 30)),
    asst(190, "q4", (4, 0, 4000, 40)),
    user(300, "FX-SUMMARY", isCompactSummary=True),
], extra="{ a torn line\n")
# its one subagent: records from 100 to 200, so the prompt at 150 is inside and
# the one at 0 is not
write(proj + "aaaa/subagents/agent-x.jsonl", [
    user(100, "FX-BRIEF", side=True),
    asst(120, "s1", (5, 50, 500, 5), side=True),
    user(200, tool_result, side=True),
])
write(proj + "bbbb.jsonl", [
    {"type": "custom-title", "customTitle": "bravo-ideas", "sessionId": "bbbb"},
    user(20, "FX-IDEAS"),
    asst(30, "b1", (1, 0, 10, 1)),
])
write(root + "/projects/-fx-proj-claude-worktrees-gamma/cccc.jsonl", [
    user(40, "FX-SLOT"),
    asst(50, "c1", (1, 0, 10, 1)),
])
write(proj + "dddd.jsonl", [
    {"type": "agent-name", "agentName": "delta-plain", "sessionId": "dddd"},
    user(-30 * 86400, "FX-OLD-PROMPT"),
    user(60, "FX-NEW-PROMPT"),
    asst(70, "d1", (1, 0, 10, 1)),
])
write(proj + "eeee.jsonl", [
    user(-900 * 86400, "FX-ANCIENT"),
    asst(-900 * 86400 + 1, "e1", (1, 0, 10, 1)),
])
PY
}

# Column $2 of the tab-separated row whose second column is $1.
col() { printf '%s\n' "$output" | awk -F'\t' -v n="$1" -v c="$2" '$2 == n { print $c }'; }

@test "sessions: one row per main transcript in the window, every column from the fixture" {
  run "$SC" sessions
  [ "$status" -eq 0 ]
  # the row minus its two timestamps
  row="$(printf '%s\n' "$output" | awk -F'\t' -v OFS='\t' '$2 == "alpha-lead" { $3 = ""; $4 = ""; print }')"
  [ "$row" = "$(printf 'lead\talpha-lead\t\t\t300\t2\t1\t4\t2202\t4004\t1\t10\t300\t10000\t100\t1\t560\t1')" ]
  [[ "$(col alpha-lead 3)" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]
  [[ "$(col alpha-lead 4)" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]
}

@test "sessions: the role comes from the name suffix or the worktree project directory" {
  run "$SC" sessions
  [ "$status" -eq 0 ]
  [ "$(col alpha-lead 1)" = lead ]
  [ "$(col bravo-ideas 1)" = ideas ]
  [ "$(col delta-plain 1)" = other ]
  [ "$(printf '%s\n' "$output" | awk -F'\t' '$2 == "-" { print $1 }')" = slot ]
}

@test "sessions: a prompt inside a subagent's span is human_busy, one outside is not" {
  run "$SC" sessions
  [ "$(col alpha-lead 6)" = 2 ]
  [ "$(col alpha-lead 7)" = 1 ]
}

@test "sessions: a sidechain, meta, tool-result, notification or compaction-summary record is not human" {
  run "$SC" sessions
  # alpha-lead holds seven user records and only two are prompts a person typed
  [ "$(col alpha-lead 6)" = 2 ]
  [ "$(col bravo-ideas 6)" = 1 ]
}

@test "sessions: only records inside the window count, and a transcript with none has no row" {
  run "$SC" sessions --since 7
  [ "$(col delta-plain 6)" = 1 ]
  run "$SC" sessions --since 40
  [ "$(col delta-plain 6)" = 2 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 4 ]
  run "$SC" sessions --since 1000
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 5 ]
}

@test "sessions: --dir names the profile, else CLAUDE_CONFIG_DIR, else ~/.claude" {
  mv "$CLAUDE_CONFIG_DIR" "$HOME/.claude"
  run "$SC" sessions --dir "$HOME/.claude"
  [ "$status" -eq 0 ]
  [ "$(col alpha-lead 6)" = 2 ]
  unset CLAUDE_CONFIG_DIR
  run "$SC" sessions
  [ "$(col alpha-lead 6)" = 2 ]
}

@test "file: one row per transcript, a subagent's included" {
  run "$SC" file "$CLAUDE_CONFIG_DIR/projects/-fx-proj/aaaa.jsonl" "$CLAUDE_CONFIG_DIR/projects/-fx-proj/aaaa/subagents/agent-x.jsonl"
  [ "$status" -eq 0 ]
  main="$(printf '%s\n' "$output" | sed -n 1p | awk -F'\t' -v OFS='\t' '{ $1 = ""; $2 = ""; $3 = ""; print }')"
  sub="$(printf '%s\n' "$output" | sed -n 2p | awk -F'\t' -v OFS='\t' '{ $1 = ""; $2 = ""; $3 = ""; print }')"
  [ "$main" = "$(printf '\t\t\t300\t4\t10\t300\t10000\t100\t2')" ]
  [ "$sub" = "$(printf '\t\t\t100\t1\t5\t50\t500\t5\t0')" ]
  [ "$(printf '%s\n' "$output" | sed -n 1p | cut -f1)" = "$CLAUDE_CONFIG_DIR/projects/-fx-proj/aaaa.jsonl" ]
}

@test "no fixture text reaches any output" {
  run "$SC" sessions --since 1000
  [ "$status" -eq 0 ]
  [[ "$output" != *FX-* ]]
  run "$SC" file "$CLAUDE_CONFIG_DIR"/projects/-fx-proj/*.jsonl
  [ "$status" -eq 0 ]
  [[ "$output" != *FX-* ]]
}

@test "step-cost writes nothing into the profile" {
  before="$(find "$CLAUDE_CONFIG_DIR" -type f -exec cksum {} + | sort)"
  run "$SC" sessions --since 1000
  run "$SC" file "$CLAUDE_CONFIG_DIR/projects/-fx-proj/aaaa.jsonl"
  [ "$(find "$CLAUDE_CONFIG_DIR" -type f -exec cksum {} + | sort)" = "$before" ]
}

@test "bad arguments exit 2 with a usage line; a missing file exits 1 and still prints the rest" {
  run "$SC"
  [ "$status" -eq 2 ]
  [[ "$output" == *usage:* ]]
  run "$SC" sessions --since many
  [ "$status" -eq 2 ]
  run "$SC" file
  [ "$status" -eq 2 ]
  run "$SC" file "$CLAUDE_CONFIG_DIR/projects/-fx-proj/aaaa.jsonl" "$BATS_TEST_TMPDIR/missing.jsonl"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing.jsonl: no such file"* ]]
  [[ "$output" == *aaaa.jsonl* ]]
}

@test "a PATH without python3 exits 1 with a message" {
  mkdir -p "$BATS_TEST_TMPDIR/nopy"
  PATH="$BATS_TEST_TMPDIR/nopy" run /bin/sh "$SC" sessions
  [ "$status" -eq 1 ]
  [[ "$output" == *"python3 not found"* ]]
}
