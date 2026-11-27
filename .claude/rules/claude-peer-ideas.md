---
paths:
  - "**/bin/executable_claude-peer"
  - "**/dot_config/claude-peer/**"
  - "**/tests/claude-peer.bats"
  - "**/tests/claude-peer-screen.bats"
---

# Claude peers: the ideas list, the idea cards and the Ideas pane

What the Ideas pane (slot `ideas`) shows and what a pick starts. The reader is
`claude-peer ideas [--all] [--width N] [<dir>]`, `queue shape` links a session to an idea
file, and `ideas similar` finds an earlier idea. The pane's launch, cap, seat note and clock
are in `claude-peer-bar.md`, the generic pane in `claude-peer.md`.

## The idea cards

- `queue shape [--session SID] [--as NAME] -- <idea file>` records an idea before it has a
  verdict: the session runs it once the idea file has its Goal, and it writes a `shape`
  line, `<value>` being `session=<SID or ->:by=session:similar=<n or ->`, the text the
  idea's title, the file the idea file (absolute; it must be a readable regular file, else
  exit 1). The title is the first line of the file that starts `# `, else the first
  non-empty line under `## Goal`, else the file's name without `idea-` and `.md` with each
  `-` read as a space, cut to 80 characters. The session is `--session`, else
  `$CLAUDE_CODE_SESSION_ID`, else `-`. It finds the card only by the card's `idea` field
  (`cardof`), which a `shape` line sets, and an `add` that reused a `shaping` card keeps. A
  card made by a plain `queue add ... <file>` with no earlier `shape` has no `idea` field, so
  `queue shape` on that file makes a second card and the list shows the file twice. A file
  no card's `idea` names creates a card (kind `idea`, state `shaping`, the next `Q<n>`); a
  file one does name writes a line only when the session or title changed, and then with
  that card's id. It prints the id; on a creation it then prints up to three `similar<TAB>`
  lines, each an `ideas similar` row (below), and `similar=<n>` counts them. It wakes nobody,
  escalates nothing and writes nothing to the log. `/clear` inside a session gives it a new
  id, and the card keeps the old one until `queue shape` is run again.
- A `shaping` card is no reading of Lead's: `list`, `next`, `take`, the hook and the wake
  start from `waiting` cards, so it shows only in `queue list --all` (`shaping` in the first
  column), `queue show` and `queue set`. A reader for Lead or the work board uses `queue
  list`, never `--all`. `take` refuses it; `drop` and `park` accept it; `reopen` puts a card
  that was never added (shaped, then parked or dropped) back to `shaping`, any other to
  `waiting`.
- **One idea is one card.** For an `idea` or `plan`, a `queue add` that names the card's
  session (`--session`, else `$CLAUDE_CODE_SESSION_ID`) or its file, where that card is
  `shaping`, `parked` or `dropped`, **reuses that card's id** and promotes it to `waiting`,
  keeping the earlier idea file and, when the `add` names none, the earlier session. The
  environment's session id only finds the card; it is not written into the `add` line.
  Kinds `ask` and `unfinished` never reuse.

## The ideas list

A session the pane's clock ends is also a row, which brings it back; the list shows the
`unfinished` reminder once, not beside the idea's own row.

The Ideas pane shows its ideas, not the generic picker's contexts.

- **Rows.** One row per idea of the repository holding `<dir>` (default `$PWD`; from a slot
  worktree, the main checkout's), seven tab-separated columns: `state<TAB>id<TAB>age<TAB>session<TAB>live<TAB>title<TAB>file`.
  `state` is `shaping`, `waiting`, `taken`, `unfinished` (a waiting card of kind
  `unfinished`), `parked`, `done` or `dropped`. `id` is `Q<n>`, or `-` for an idea file no
  card names; `session` and `file` are `-` for none. `age` is `dur_of` form since the newer
  of the card's last event and the file's modification time. `live` is the `name` of a live
  registry record whose `sessionId` is the row's session (the pid passing `session_same`,
  every `profile_dirs` directory), else `-`. `title` is the title rule of `queue shape` when
  the row has a readable idea file, else the card's text.
- **Which are rows.** Every card of kind `idea` or `plan`, or with an idea file or a
  session, except an `unfinished` card whose session is another row's; and every
  `idea-*.md` of `${XDG_STATE_HOME:-$HOME/.local/state}/claude-reports/<rname>/` that no
  card names (state `shaping`). Order: one list, newest first, for `shaping`, `waiting`,
  `taken` and `unfinished` together (the state does not order it), then `parked`, newest
  first; `--all` adds `done` and `dropped`. `--width N` (N at least 30) adds an eighth
  column, `display`: `<title> · <state word> · <age>`, the title padded and cut with `…` so
  that no display is wider than N characters. The state word is `open` when `live` is set,
  `with Lead` for `waiting` and `taken`, else the state. Without python3 it prints no rows,
  one stderr line, exit 0; outside a repository exit 1.
- **The match.** `claude-peer ideas similar (--file <idea file> | -- <words...>)` prints up
  to three rows (`score<TAB>` and the seven columns), most words in common first, then the
  newer idea, for ideas in every state, and exits 3 with none. A word is a lower-case run of
  letters and digits of at least three characters, not in a fixed stop list, with one
  trailing `ing`, `ed`, `es` or `s` removed when four characters remain. Both sides are
  short: the query is the given words or, for `--file`, that file's title and the first
  sentence of its Goal; an idea's text is its title and the first sentence of its Goal (up to
  the first `.`, `?` or `!` that ends a line or is followed by a space, else its first
  paragraph, at most 300 characters), nothing else. A row needs
  `git config claude-peer.idea-match` words in common (default 3; not a number is 3; 1 and 2
  are read as 3; 0 means no row ever). No model is involved, and it never refuses a new idea.

## The Ideas pane

Its rows are `New idea`, then the active ideas newest first, then the parked ones; `done` and
`dropped` are not listed (they still feed the match). The prompt, the title line and the
quiet line read `Ideas`, as do the slot, the log's label and the session name `<repo>-ideas`. The hint is `↵ open · ^T new idea from what you typed ·
esc hide`. The sleeper, Esc, `q`, a `start` request, the cap, the clock and the drift note
are the generic pane's, because the row file keeps its `id<TAB>display` shape. It differs
from the generic pane in four places:

- `^S` (save the typed task) is gone, and the hint drops it; `^T` is the only typed-line key.
- At the quiet line a typed context key no longer runs a named context; it opens the list.
  The quiet line reads `Ideas: Return lists the ideas, c continues the last session, q
  leaves a shell`.
- With `claude-peer.picker off` there is no Ideas pane: `pane_mode` returns early and the
  pane is the generic one, since an `off` picker has no list to fill.
- `git config claude-peer.ideas false` gives the generic picker again. `pane_mode` runs once
  when the pane starts, so this takes effect at the pane's next start (the tab closed and
  reopened); an Ideas pane already open keeps its list.

With fzf the list is the picker; without it the pane prints a numbered list of the first rows
that fit (`New idea` is 1, at most 12), then `… N more: claude-peer ideas` for the rest, which
cannot be picked there, and `n new idea, typed · q shell`. Return in it is `New idea`.

- **A pick.** A row whose session is live in another pane prints that it is open there and
  starts nothing (two terminals on one transcript lose messages). A row with a session whose
  transcript is on disk (`idea_transcript`: `<profile dir>/projects/*/<SID>.jsonl` in some
  `profile_dirs` directory) starts `claude --resume <id>`, with the seat's arguments and no
  `--model`. A resume passes the seat note again, so a resumed old idea gets the current note;
  only a session still open when the note changed keeps the old one. Any other row starts a
  fresh session with one of two first prompts: a row with an idea file names it and tells the
  session to read it and run `claude-peer queue shape` on it; a row with no file (a card only)
  says "Continue this idea from the queue (card <id>) ... Start its idea file as the seat note
  says." A resume that exits non-zero within 15 seconds (a Ctrl-C included) is remembered for
  that pane (`pn_nores`), says so once, and the next pick of the row starts fresh. Resuming
  rests on Claude Code keeping the transcript (30 days unless a profile sets
  `cleanupPeriodDays`) and on its search across the repository's worktrees (2.1.223 or
  newer). `idea_transcript` looks in every profile directory, so a transcript in a profile
  the pane will not launch under is a false yes, caught once per pane by the failed resume.
  New idea and a fresh start from a file or a card are `fresh` starts, which get the fresh-tree
  move of `claude-peer-bar.md`; a resume does not, and its worktree is left as it is.
  At the cap the pane says `pick again to open another`.
- **A typed line** (`^T` with a query, Return on no match, the list's `n`) starts a new idea
  with the line as its first prompt, after the match: when an earlier idea shares enough words
  with it, the pane prints `You had this already: <title> (<state word> <age>)` (a second and
  third row numbered) and asks. Return starts the new idea (a reflex key must never resume a
  long conversation), `1` or `r` resumes the first, a number that row, anything else goes back
  to the list; a `start` request still cuts in. The new idea's first prompt then ends with one
  sentence naming the earlier ideas the operator passed over, so the session does not ask again.
- **Corners.** In a state column `open` hides `shaping` and `with Lead` on purpose: what
  matters about that row is that it cannot be opened. Alignment counts characters, so a title
  with double-width characters (CJK, emoji) is out of line.

## The seat note's idea part

The operator signed this wording with the ideas-picker go (2026-11-26); it is in
`ideas_note` (`claude-peer-bar.md`). It tells the session that its idea file's first
line is `# ` and the idea in a few words (the name the list shows), to run `claude-peer queue
shape <idea file>` once the file has its Goal, and, for a line that starts `similar`, to ask
the operator "You had this already: <title> (<state> <age>). Resume it?" (on yes: add what is
new under Open in that idea's file, `queue drop` its own card as a duplicate, tell them to
type /exit and pick the earlier idea in the list, and stop). It says the session is for this
one idea and the pane lists the others, each with a session of its own.

Tests: `tests/claude-peer.bats` ("queue shape: ...", "ideas: ...", "ideas similar: ...",
"ideas pane: ...") and `tests/claude-peer-screen.bats` ("ideas: ..."). `ideafile`, `qshape`
and `idea_live` write the fixtures; `chars` counts characters the way the screen file's `flat`
does, so a width is measured the same under every locale.