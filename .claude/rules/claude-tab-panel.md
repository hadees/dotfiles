---
paths:
  - "**/bin/executable_claude-tab"
  - "**/tests/claude-tab-panel.bats"
---

# claude-tab panel

**The needs-you list holds events, not states.** Session Status shows the
state of every session; the list holds what is in the operator's court and may
not be known to them yet, in one flat list across every tab and profile, and
leaves everything else to a count. Every rule below is decided from the
registry record (`<profile dir>/sessions/<pid>.json`: `status`, `waitingFor`,
`statusUpdatedAt`), never from a Session Status row, which is the source that
lies. The registry is an observed layout, not an interface.

`claude-tab panel tick [--state <file>] [--now <epoch>] [--focus <tty>|-|?]`
is the model: one pass over the registry, a state file, and the snapshot as
one line of JSON on stdout. It works on every OS. `panel` with no or an
unknown verb is usage (exit 2). All of it is one python program, `panel_py` in
`bin/executable_claude-tab` (standard library, `python3 -I -`, clean on 3.9),
with the mode word as its first argument; the shell passes each profile as
`--profile <dir>=<label>` and the thresholds as `--quiet <seconds>`
(`git config tabstatus.quiet-minutes` times 60, default 900) and `--finished
<seconds>` (`git config claude-tab.finished-seconds`, default 60); anything
that is not a positive integer is the default. `--life <pid>=<epoch>` is a test
handle for the sign of life of a busy session. `--focus` says which tty is in
front: a tty, `-` for no iTerm2 session, `?` for could not be asked (default).

**The registry is read a fourth time**, beside `registry_rows`,
`registry_full` and `registry_waiting`, because the panel keeps the whole
record and runs in one long-lived process. The four must keep the same filter:
only files named `<digits>.json`, a record counts when its `pid` is a positive
int that answers `os.kill(pid, 0)`, and `PermissionError` means alive. A
record whose `kind` is present and not `interactive` is headless: counted,
never a row.

**Kinds.** The condition of a session, first match wins:

| Registry `status` | Kind | Rank | Appears after (from `cond_since`) | Leaves when |
| --- | --- | --- | --- | --- |
| `waiting` | `blocked`, reason `waitingFor` | 0 | 4 s | the registry stops saying `waiting` |
| `idle`/`shell`, turn record `error` | `failed` | 1 | 4 s | the next turn starts |
| `idle`/`shell`, turn record `question` | `asked` | 1 | 4 s | the next turn starts |
| `idle` | `finished` | 2 | `--finished` (60 s) | seen, or the next turn starts |
| `shell` | `finished-bg` | 2 | `--quiet` (15 min) | seen, or the next turn starts |
| `busy`, sign of life known and `now - max(since, life) >= quiet` | `quiet` | 3 | at once | seen, or it writes again |
| any other word | `unknown: <word>` | 3 | 60 s | seen, or the word changes |

`since` is `statusUpdatedAt / 1000`; with none, the time the session was first
seen in that status. An **instance** is one `(kind, cond_since)` of one
session, and a change of either is a new instance: seen, hits, listed and
entered reset. A `busy` session with no sign of life is never called quiet (not
knowing is not stuck) and is counted in `health.life_unknown`; the sign of life
is looked up only once `since` is `--quiet` old, and the tick takes it
from `--life` and nowhere else yet. The **turn record**
(`<state home>/tabstatus/<sessionId>.turn`, one line of JSON with `at`, `end`
of `question`, `error` or `plain`, `active`, `quiet`) is read only for a
session id of `[A-Za-z0-9_-]+` and only while idle or shell; it is valid when
`since - 15 <= at <= now + 5`, else there is none and the session reads as
finished. Nothing writes it yet. A turn end of a hand-off peer is Lead's, not
the operator's; the tick does not know peers yet and lists every one.

**Seen.** `--focus <tty>` gives the session on that tty one more look
(`hits`, capped at 2) and every other session none; `-` and `?` give none to
all. An instance with two looks and no `seen_at` is seen (`seen_focus`). A row
is listed when its delay has passed, its session has no look running (the
session in front is never listed), and it is `blocked`, `asked` or `failed`,
or unseen: those three stay listed once seen and the snapshot says
`seen: true`; the others leave. `mark_seen(pid)` is the click, for the server
to call (`seen_click`). **Starting calm**: with no usable state file (missing,
unreadable, another `v`, or `saved_at` over a day old) every `finished`,
`finished-bg`, `quiet` and `unknown` instance on the first tick counts as
seen; with one, a session not in it gets the same only when its `cond_since`
is not later than `saved_at`. The list starts quiet and lists what happens
from then on. A `blocked` instance that ends before it was ever listed is
`tally.hidden_prompts`.

**The state file** (`${XDG_STATE_HOME:-~/.local/state}/claude-tab/panel-state.json`,
mode 0600 in a 0700 directory, written through a temporary file and a rename)
holds `v`, `saved_at`, `sessions` keyed `<profile dir>|<pid>|<sessionId>` and the
tally. It is written only when something besides the tick counter changed or
`saved_at` is a minute old, so a calm list does not write every two seconds. A
write that fails is one line on stderr, and the snapshot is still printed.

**The snapshot** is `{v, generated_at, build, health, needs, others, tally}`.
`needs` is the listed rows in order of rank, then the time they entered, then
pid, and a row does not move while it lives. `others` holds every interactive
session once, grouped, each group with `needs`, `working` and `idle` counts; an
unlisted row's kind is `working`, `idle`, `idle-bg` or its condition kind. A
row is `pid, profile, label, group, role, kind, reason, since, seen, tty`;
`label` and `group` are the base name of the session's directory and `role` is
`plain` until the sessions are told apart. `health` is `profiles`, `sessions`,
`headless`, `unreadable` (`<digits>.json` files that did not parse),
`focus` (`ok`, `none`, `unknown`), `turn_records`, `life_unknown` and
`want_focus` (any instance not yet seen).

**The tell.** A snapshot whose `health.sessions` is 0 while `claude-tab list`
prints rows, or a row of kind `unknown`, means the registry's words moved.
Tests: `tests/claude-tab-panel.bats` (fixture registries, `--now`, `--focus`,
state under `BATS_TEST_TMPDIR`).
