---
paths:
  - "**/bin/executable_lsof"
  - "**/tests/lsof-guard.bats"
---

# The lsof guard (`~/bin/lsof`)

On macOS, `lsof` walks every process's mapped files (not only its
descriptors), and xnu-12377.161.14 has panicked twice in that walk
(`fill_vnodeinfoforaddr`). Network-only `lsof -i` skips the walk;
`fuser` and `proc_listpidspath` do it too. The heaviest caller seen is a
status line outside this repository that runs `lsof` about once a second per
session, so the guard exists to refuse non-interactive calls until the kernel
is fixed.

`bin/executable_lsof` deploys to `~/bin/lsof` on macOS only
(`.chezmoiignore`). `~/bin` is ahead of `/usr/sbin` on PATH, so it shadows
the system lsof for anything that resolves it by name; a caller that runs
`/usr/sbin/lsof` by path (macOS `fuser`) is not reached. It is plain `sh`.

## Order of decisions

1. `LSOF_GUARD_REAL` (tests) or `/usr/sbin/lsof` is the real binary.
2. `LSOF_GUARD=off` in the environment: run the real one.
3. Any of stdin, stdout, stderr is a terminal: run the real one. A person
   typed it, and `lsof | grep` must keep working.
4. `git config --type=bool --get lsof.guard` is not `true`: run the real one.
   This is the default, so a clone that never opts in behaves as before.
5. Otherwise refuse: one line on stderr, exit status 69.

Status 69 is what cc-status reads as "holder unknown" (anything other than 0
or 1), so a refusal never paints a task stalled.

## Switching it on

`lsof.guard true` belongs in the personal overlay's git config, beside
`claude.terminal-title`; this repository never sets it. Deploy the cc-status
change first, or a refusal on an old shim reads as "nobody holds the file".
A tool that needs lsof non-interactively fails with the stderr line and shows
in the tally; `LSOF_GUARD=off` in that tool's environment is the exit.

## The tally

Each refusal, in `${XDG_STATE_HOME:-$HOME/.local/state}/lsof-guard/` (mode
0700), per caller (basename of the parent's `comm`, characters outside
`A-Za-z0-9._-` replaced by `_`, else `unknown`):

- `<caller>.count`: one byte appended per refusal.
- `<caller>.last`: the latest refusal, one line: UTC time, the parent's
  command line (first 200 characters), lsof's arguments, tab-separated.

`ls -l` on that directory is the tally: file size is the number of refusals,
mtime the last one. A failure to write the files never changes the outcome.
