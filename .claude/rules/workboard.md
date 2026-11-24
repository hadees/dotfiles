---
paths:
  - "**/bin/executable_workboard"
  - "**/dot_local/libexec/workboard/**"
  - "**/dot_local/share/workboard/**"
  - "**/tests/workboard-*.bats"
  - "**/tests/workboard-stubs/**"
  - "**/tests/helpers/workboard*"
  - "**/tests/fixtures/workboard/**"
---

# The work board

`workboard` is a page of cards over GitHub issues and pull requests, with the
sessions on the cards. It stores nothing about the work: every card and stage
is computed from what GitHub, git, the claim files and the panel already say.
One standard-library python process
(`dot_local/libexec/workboard/board.py`, run as `python3 -I -B`, clean on 3.9)
serves one HTML page (`dot_local/share/workboard/board.html`) on
`127.0.0.1:47601`; `bin/executable_workboard` (POSIX `sh`) starts it.

**What exists today.** The model, the three readers, the page, the server and
the entry script, tested alone against fixtures and together in
`tests/workboard-e2e.bats`. **None of it has run
against the live machine yet**: no live GitHub pass, no deploy, no look at the
real board. The optional plug-in modules (below) do not exist, so there is no verb
that writes, no MCP endpoint and no LaunchAgent, and `workboard list` is exit 2.

## What a card is

**A card is one deliverable: a thing that ends in a merged pull request or a
closed issue.** It is not a session, a claim or a job. Four forms:

| Form | Key | Exists because |
| --- | --- | --- |
| `issue` | `<owner>/<repo>#<n>` | an open issue passes the repository's `intake` |
| `pr` | `<owner>/<repo>#<n>` | the account's own open pull request, or one merged inside the trial window, closes no issue on the board |
| `local` | `<owner>/<repo>@<worktree name>` | a worktree holds a session and is on a task, and nothing else claims it |
| `queue` | `<owner>/<repo>~<id>` | an inbox row in state `waiting` or `taken` is linked to no issue card |

Folding, in this order: an own pull request whose `closes` names an issue card
is drawn inside it; an inbox row linked to an issue card sets that card's
`queue` (the first wins); a worktree whose branch heads a card's open pull
request holds that card; a worktree a `links.tsv` line ties to an issue holds it
(the newest line wins); any other qualifying worktree is a `local` card. A
worktree qualifies when a who row stands in it and it has a claim task, an open
`log claim`, or a branch other than the repository's default. A merged pull
request that closed an issue not on the board takes that issue's key and title.

**Stage, flags and order** are `_stage`, `_sort_key` and the `takeable` branch of
`build_board` in `dot_local/libexec/workboard/model.py`; read them there.

## Nothing is stored

**No document is ever written to disk.** The four input documents and the
board live in the server's memory and are rebuilt after a restart. The state
directory, `${XDG_STATE_HOME:-$HOME/.local/state}/workboard/` (mode 0700, files
0600, every write through a temporary file and a rename), holds `secret`,
`tally.json` (counters), `links.tsv` (slug, issue number, worktree path, time;
read by the server, written by nothing yet), and from the entry script `pid`,
`log` and `log.prev`. No title, body, label or claim text reaches any of them.
A pass that raises is one log line with the pass's name and the exception's
**class**, never its message (a message can quote a response), and a counter.

## The clocks

| Input | Read by | Runs |
| --- | --- | --- |
| GitHub | `github.poll` | per account at its `next_interval`, and at once on `ctx.poll_now` |
| Local | `local.read`, then `inbox.read` | every 60 s |
| Who | `who.read`, then `inbox.read` when `inbox.changed` says so | every 2 s, **only while a page asked within the last 10 s** |

`build_board` is a pure function of the four documents, the trial length, the
time and an optional scope, and the only place cards are joined. It reruns when
a pass changed an input, and `rev` goes up when the unscoped document differs
ignoring `generated_at` and `health.panel_age`. **At rest**: after 15 minutes
with no request (`WORKBOARD_REST` seconds) the GitHub passes stop and `paused`
is counted; the next request answers from what is held and starts a pass. A
failed GitHub pass retries in 60 s. **The server follows its own code**: when
the mtime of a `.py` file beside it or of the entry script changes it writes the
tally and replaces itself with the same arguments; `build` is the newest mtime.

## The two contracts

The model never asks how anyone knows who is on a card or in what order the
Inbox goes: it reads two documents, so a better source replaces a file, not the
model.

**Who** (`who/1`, `who.read(panel_url, profiles, local, now, cache)`): one row
per thing working somewhere, with `dir` (where), `label` and `seat` (who),
`pid` (the pane a click lands in: `POST /go` takes it) and `needs` (the
operator is waited on). `source` is `session` or `job`. **Today** only
`session` rows exist: `GET <panel>/snapshot.json` (no proxy, one second), the
`needs` rows first in the panel's order, then every `others[].rows` row, `id`
`s:<profile label>:<pid>`, `dir` the `cwd` of the registry record
`<profile dir>/sessions/<pid>.json` (read once per pid, null when unreadable). A silent panel is `sources.panel`
`down` with no rows; `sources.jobs` is always `off`. A row joins the worktree
with the longest path that is its `dir` or a parent of it, by components
(`/w/alpha` does not claim `/w/alpha-two`). `who.profile_dirs()` is label to
directory: `$CLAUDE_CONFIG_DIR`, `~/.claude` and every `claude.profile.*` git
value that exists; the label is `default` for `.claude`, else the part after
`.claude-`.

**Inbox** (`inbox/1`, `inbox.read(local, now, cache)`, `inbox.changed`): one
row per queued item with order, tier, score text, state and the issue it
links. **Today** `read` returns the empty document (`source` `none`) and
`changed` is false: the Inbox is GitHub's issues, newest first.

A who row joining no card is counted in `health.unjoined` (a session) or
`unjoined_jobs`; a session with `needs` is still listed in `needs` with `card:
null`. A Lead in a main checkout on the default branch has no card: it shows in
Needs you when it needs the operator, else it is counted.

## Accounts and the GitHub reader

**The account rule is `gh()`'s** (`dot_functions`,
`bin/executable_git-credential-gh-user`): git config
`credential.https://github.com/<lowercase owner>.username` names the account,
`-` when there is no pin. The token is `gh auth token --user <account>`, held in
memory, given to the one `gh api graphql` call as `GH_TOKEN` and never in argv,
asked for again only after an authentication failure. `github.account_of` and
`local.account_of` are two copies of the rule (the readers share no code), so a
change to it is four edits.

**The request**, one per account: the account's open pull requests (first 50)
and merged ones (first 30), then one aliased `repository` per repository with
the default branch and the issues its `intake` selects (`mine` is two lists,
assigned and created, `all` and `label:<name>` one, `none` none);
`github.build_query` has the field lists. Owner, name and label reach it only as
JSON string literals. Over 50 open pull requests puts `more than 50 open pull
requests; some are not shown` on the account. One measurement made before the
code existed put the account part plus one repository at 2 points; the cost over
the real repository list has not been recorded.

**The budget rule.** `next_interval(cost, remaining, budget)` is `max(60,
ceil(3600 * cost / budget))` seconds, doubled under 1,000 points remaining and
0 (do not poll) under 300; `budget` is `workboard.budget`, default 1,200 an
hour. An account at 0 is skipped with its data carried over, and the skip lifts
an hour after its last fetch.

**A failed account keeps its prior data.** No token, a failed or slow (20 s)
request or a skip leaves the account's issues and pull requests as they were,
with `error` on the account and its repositories, so one timeout does not blank
the cards. Failure words are fixed (`no token for <account>`, `authentication
failed`, `request timed out`, `rate budget low`, ...); gh's stderr never
reaches a document. `gh api graphql` prints the body and exits non-zero when
the response carries `errors`, so any body with `data` is used.

## The local reader

**Where the repository list comes from**: every `worktabs plan` row whose state
is `ok` or `disabled` and whose directory exists (with its group), then the
multi-valued `workboard.repo` git config, then every distinct who `dir`, those
two with group `-`. Each resolves to its main checkout, so a linked worktree is
never a second repository, and the first group seen wins. The slug is the
lowercased origin remote (`git_origin_slug`'s rule); one with no usable origin
is counted in `skipped`. Per repository, git config
`workboard.<owner/repo>.intake` (`mine` default, `all`, `label:<name>`, `none`),
`.write`, `.take` (`ask` default, `auto`, `auto:<label>`) and `.notify-lead`;
any other value is the default.

**What it reads is git metadata, claim files through `claude-peer`, and the
peer log, never a working-tree file**: `git worktree list --porcelain`,
`claude-peer peers` and `claude-peer claim` (one call per live claim), and the
last 200 lines of `claude-peer log show --all`. `open_claim` is the text of the
label's latest `claim` entry, cleared by that label's `done` and by a `stop`,
`end` or `gone` entry naming the label. Each command has a 10 s limit; a failure
leaves its part empty.

**The profile answer is a port, pinned by a test.** `local.profile_of(slug,
account)` is `claude_profile_dir` (`dot_functions`): the repository's
`claude.<slug>.profile` pin names a `claude.profile.<name>` value or is itself a
path, else `claude.profile.<account>` (`default` when the owner has no pin),
else `~/.claude`; a pinned account with no mapping gives `~/.claude`, because
`claude()` then runs bare. `tests/workboard-local.bats` runs both side by side
over several pin shapes and fails, not skips, where zsh exists.

## The page and its guard

**Tokens.** `<state>/secret` is made on first start. The full token is the
first 32 hex digits of HMAC-SHA256 of `all` under it; a profile's is the same
of `profile:<absolute profile directory>`, for each directory of
`who.profile_dirs()`; compared in constant time. The full token serves every
repository; a profile's serves that profile's repositories and who rows.

**Endpoints.** `GET /health`; `GET /status.json` (no token; counts, ages and
fixed words); `GET /b/<token>/` (the page file, under a CSP of `default-src
'none'` with inline script and style and `connect-src 'self'`); `GET
/b/<token>/board.json` (the scoped board plus `rev` and `build`, `ETag` of the
rev); `POST /b/<token>/go` (`pid=<digits>`, relayed to the panel's `/go`, only
for a pid a row of that scope carries, else 404; a silent panel is 502); `POST
/b/<token>/open` (`key=<card key>`: the server looks the url up, so the page
never supplies one); `POST /api/url`; and `POST /api/<name>` and every plug-in
route. A wrong token is 403 and counted; anything else is 404.

**`workboard url` and `/api/url`.** With `CLAUDECODE` unset the command derives
the full token from the secret. Inside a Claude session it opens nothing in the
state directory: it posts `/api/url` with `X-Workboard-Profile`
(`CLAUDE_CONFIG_DIR`, else `~/.claude`) and the server answers the URL bound to
that profile (code 2 for a header naming no profile directory). **The full
token is never an answer to an HTTP request.** Closing the state directory to a
session is a deny row in the two personal-side profiles' settings.

**What the guard stops, and what it does not.** It binds `127.0.0.1` only;
answers 403 to a `Host` that is not `127.0.0.1:<port>` or `localhost:<port>`
(a rebinding page) and to a present `Origin` that is not its own; requires
`X-Workboard: 1` on every `POST` to `/api`, `/go` and `/open` (a form on
another page cannot set it); and caps a body at 65,536 bytes. **It does not
stop** a session that puts another profile's directory in
`X-Workboard-Profile`: the server trusts the header and returns that profile's
URL. Nor does it stop any process of the operator's user reading `/status.json`
or the state directory; the one process that holds every account's titles runs
as the operator. A lexical guard, not a sandbox, the strength of `denyguard`.

**The page.** One file, no external resource. Text reaches the DOM only through
`textContent`; a test greps for `innerHTML` and its kin. Five columns (Needs
you, Inbox, Building, In review / CI, Merged · trial), an accordion under
720 px; chips for All, each group and each repository, the choice in the URL
fragment (`#g=<group>` or `#r=<repo name>`) so a filtered view is a link. A
session is a filled dot, a job a ring (grey when stale); a click on a dot posts
`go`. It polls `board.json` every 2 s with `If-None-Match`; after 6 s of silence
the board dims, after 30 s it says "not updating since", and a changed `build`
reloads it. Needs you draws a card only through a `needs` entry and counts
`needs.length`. The trial length is **a constant of 7 in the page**: the board
document has no such field, so it is wrong when `workboard.trial-days` is set
otherwise. Looked at by hand in headless Chrome on the fixture board; not
looked at: the light scheme, a click, the silent states.

## Verbs and the plug-in interface

`serve`, `start`, `stop`, `restart` and `open` are the entry script's;
everything else is `board.py cli <verb>`: `status`, `url`, the readers (`model`,
`poll` for `github.py`, `local`, `who`, `inbox`, each running that module's
command line), then a verb a plug-in registered, else exit 2. The port is git
config `workboard.port`, else 47601; the panel is `workboard.panel-url`, else
`claude-tab.panel-port` on loopback. With `local.workboard`
loaded, `start` is `launchctl kickstart`, `restart` is `kickstart -k` and `stop`
is `bootout` (because `KeepAlive` undoes a kill); otherwise `start` detaches a server of its own and
`stop` signals the pid in `<state>/pid`. `open` is macOS-only and ends in `open-as iterm2 <url>`.

**The plug-in interface.** `board.py`, in the server and the client alike,
imports `model github local who inbox` by name and tries `verbs`,
`mcp_endpoint`, `service`, `notice`, `pane` from its own directory, in that
order. A missing module is skipped; one that raises on import or in `register`
is one log line (the class) and `plugin_errors + 1`, and **nothing it
registered reaches the app**: `register` gets a staging copy committed only if
it returns. `app` offers `api(name, fn)` (`POST /api/<name>`, `fn(ctx,
profile=..., **body)` returning `(code, text)`), `cli(name, parse)` (a client
verb posting that body; no server is exit 3), `command(name, fn)` (a client verb
run in the client), `route(method, path, fn)`, `after_github(fn)`, `status(name,
fn)` (numbers and fixed words, merged into `/status.json`) and `ctx`. A later part is a
new file.

## Counts by hand, and fixture mode

**A reader run by hand prints counts, never a document**: `github.py --local
<file>` makes one live pass and prints a line per account; `local.py`, `who.py`
and `inbox.py` print one line; `workboard status` reads `/status.json` and
prints counts, ages and fixed words (`needs: <n> (panel: <n>)` among them), with
no title, label or repository name. **`--fixture <dir>` is the only way to a
document**: the reader checks and prints `<dir>/<its document>.json` and reads
nothing live. `model.py` has no live source.

**Fixture mode** (`workboard serve --fixture <dir>`, `open --fixture <dir>`)
reads the four input documents from the directory on every request, runs no
pass, relays no click (`/go` is 409) and says `"fixture": true` on `/health`.
**It is the only thing a session points a browser or a screenshot at**: no live
title, body or label goes into a session's context or onto a disk, so a live
check reads counts. `open --fixture` starts a fixture server on the configured port unless
something already answers there, so beside a real server the port must differ.

## The tests

`tests/fixtures/workboard/demo/` holds one scenario's five documents and the
board they make. Names are invented; no real
account, organisation, repository or session name belongs in a test, fixture or
commit message. `tests/workboard-stubs/` has a stand-in for every module, each
headed `# TEST STAND-IN`. **A part is tested alone**: `wb_modules <real module
names>` builds a directory of symlinks to the
real files named and to the stubs for the rest. A test that finds the helper, a
stub or a fixture wrong says so and does not patch it. The serve tests set `WORKBOARD_LAUNCHCTL=false` so a Mac with the agent loaded
cannot be kicked by a run.

**`-I`, `-B` and the `sys.path` line.** `-I` leaves the script's directory off
`sys.path`, so a file that imports a sibling first runs
`sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))` (`abspath`, not
`realpath`, so a directory of symlinks imports from itself). `-B` keeps a
`__pycache__` out of the source directory, which chezmoi would deploy; every
test file ends with `wb_no_pycache`.

## The tells

- **An account whose `error` is `no token for <account>` while `gh auth status`
  lists it.** The pin's spelling and the keyring's differ: read `gh-doctor`'s
  `pins:` line.
- **Session rows in `health.unjoined` with no `local` card anywhere.** Worktree
  paths and the registry's `cwd` values have stopped agreeing (a symlink, a
  moved checkout); the join is by path component.
- **`needs` differing from the panel's count.** `workboard status` prints both;
  they are equal by construction (`needs` is the who rows with `needs` set, and
  `in_needs` is true exactly when a `needs` entry names the card), so a
  difference is a model or who bug.
- **`plugin_errors` above 0.** A plug-in raised on import or in `register`; the
  log line names it and the exception's class.
