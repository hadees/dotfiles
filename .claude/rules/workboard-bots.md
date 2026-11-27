---
paths:
  - "**/dot_local/libexec/workboard/github.py"
  - "**/dot_local/libexec/workboard/local.py"
  - "**/dot_local/libexec/workboard/model.py"
  - "**/dot_local/share/workboard/board.html"
---

# The bots on the board

**A dependency bot is admitted by who GitHub says it is, never by a label:**
an author whose type is `Bot` and whose login a repository's `bots` key names.
Its card is `bot`, read as `issue-practice.md` ("The origin") reads a bot's
text. A bot's pull request being open, green or labelled approves
nothing, and merging one is the ordinary gate. A session never ticks a box on
a Dependency Dashboard. The code names no bot, so Renovate, Dependabot or
another is a value of the key.

**The card.** One `bot` card per repository and listed bot, key
`<owner>/<repo>+<login>`, exists while that bot has an open pull request or an
open issue there. Its pull requests and the most recently updated open issue it
created (the dashboard) fold into it; a second issue of the bot stays an issue
card. Its title is the board's words (`<login>: <n> open pull requests`, `no
open pull requests` for none, `1 open pull request` for one), never the bot's,
and it has `origin` `bot`, `mine` false, `takeable` `no`, no labels and no
body. `take` refuses it, as it refuses any card that is not an issue.

**The key and the request.** `workboard.<owner/repo>.bots`, else the owner's:
up to four logins, `[bot]` dropped, `none` for none; `local.py` reads it as
`bots`. A repository with `bots` costs two more lists: its first 30 open pull
requests (any author, no title; a row is kept only for a `Bot` author in
`bots`) and, per bot, the first 3 open issues it created. A bot's pull request
title is never asked for.

**The counts.** `health.bot_cards` and `health.bot_prs_cut`, the latter
being the repositories with more than 30 open pull requests.
