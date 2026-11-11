---
paths:
  - "**/bin/executable_open-as"
  - "**/bin/executable_chrome-pairing"
  - "**/dot_finicky.ts"
  - "**/dot_config/finicky/**"
  - "**/tests/open-as.bats"
  - "**/tests/chrome-pairing.bats"
  - "**/tests/finicky.bats"
---

# Browser routing

**Which browser window a session's links open in** is the profile's business
too. Claude Code runs `$BROWSER <url>` for every link it opens — the OAuth
login, a session or artifact link — and `open` otherwise (read off the
binary: the opener is `spawn(BROWSER ?? "open", [url])`, and a set `BROWSER`
also stops it from merely printing the URL). The login URL is identical for
every account, so no Finicky rule can route it; but the wrapper knows which
profile it is launching, and the profile is the login. So `claude()` sets
`BROWSER=~/bin/open-as OPEN_AS_ALIAS=<alias>` for the session when
`claude.<dir>.browser` (machine-local, overlay-supplied — `[claude
"~/.claude-<name>"] browser = <open-as alias>`) pins one, and `open-as` tags
every URL with that alias's `browser.tag.*` token for the router — the same
mechanism the tailnet tooling uses, with the alias carried in the environment
because the `BROWSER` convention leaves no room for a second argument. Keyed
by directory, not account name, because several names map to one directory
and the login lives in the directory. The pair is **set or cleared per
invocation, never inherited**: a nested launch of a profile with no pin would
otherwise carry its parent's tag and route its login to the parent's window.
`OPEN_AS_ALIAS` is ours outright and always cleared; `BROWSER` is cleared
only when it is open-as, so somebody's own browser choice survives an
unpinned launch (a pin outranks it — the profile is the more specific
statement). Subprocesses of the session inherit the pair, so `gh auth login`
from inside it routes the same way — intended; a URL that already carries a
`#fragment` (`gh browse file:10`) keeps its anchor and goes untagged, since a
second `#` would break both the anchor and the router's exact match. The
pair is only set where a window can appear (`claude_browser_can_open`: not
over ssh; off-mac only with a display and xdg-open), because a set `BROWSER`
also suppresses Claude Code's printed-URL fallback — on a headless box that
would make the login link appear nowhere. `claude-doctor`'s `browser:` line
traces pin, token, opener and that gate, and its `env:` line shows the
inherited pair.

**The same pin picks the browser a session automates.** The Claude in Chrome
extension pairs once per Chrome profile, and a session that wants the
browser sees only the connected pairings — device ids plus whatever name was
typed at Connect. With several profiles deliberately paired to one account,
the session would have to ask which one, every time. `bin/chrome-pairing`
answers from disk: `route <alias>` evaluates Finicky's own config under Node
(the way `tests/finicky.bats` does) against a link tagged with the alias's
`browser.tag` token, so it reports what the router would actually do rather
than a copy of its table; `for <alias|profile>` joins that with Chrome's
`Local State` (name → directory) and the extension's LevelDB storage in
that directory (`bridgeDeviceId`, plus the pairing's `displayName` —
observed layout, not an interface: the newest file holding the key wins);
`session` does it for `$OPEN_AS_ALIAS`, which the wrapper already exported,
so the answer is the pairing whose window this session's links open in.
`list` is the whole table. A session then calls `select_browser` with that
id — which does not broadcast a Connect prompt — instead of asking; the
standing instruction for that lives in the shared Claude memory
(`dot_claude-shared/CLAUDE.md`). Two refinements sit on top. A **per-repo
pin**, `claude.<owner>/<repo>.browser`, outranks the profile's — a project
whose own logins live in a Chrome profile of their own, whichever Claude
profile runs it, and it holds even under `CLAUDE_PROFILE`: which login is at
the keyboard changes, which window the project's pages live in does not.
And `route`/`for` accept a **URL or bare host**, answering where Finicky
would open that *site* (its host rules, then the default) — for a repo that
serves several sites, each with its own logins in its own Chrome profile,
the session picks per task (`chrome-pairing for https://<site>/`) and the
extension lands where the tabs do. No pin fits such a repo, so it has none. Tests: `tests/chrome-pairing.bats` (fixture
Local State, fixture LevelDB bytes, fixture Finicky fragments; no real
Chrome touched).

**The terminal is also a browser target — per page, never per profile.**
`open-as iterm2 <url>` (a reserved alias) opens the URL in an iTerm2 3.7
web-browser tab in the *calling* session's window, and reuses that tab on
the next call — for a localhost dashboard or a report beside the terminal.
AppleScript has no URL verb, so it drives the Python API (a heredoc in the
script; the `iterm2` library fetches its own cookie, and a caller inside
iTerm2 is iTerm2 automating itself, so no TCC grant). Tabs come from a
dynamic profile `open-as` with a **fixed UUID Guid**, because WebKit keys the
cookie jar by the profile's GUID: log in to a site once and it stays logged
in. There is no cookie import from Chrome, deliberately — it would decrypt
live session credentials out of Chrome's Keychain-protected store into a
second, weaker one. 1Password fills there through iTerm2's own Password
Manager (`op` backend, chosen in its window; the choice is a `NoSync` pref, so
machine-local), not the extension; passkeys do not work in iTerm2's browser
at all, which is why `claude_browser_alias` **refuses `iterm2` as a
profile's pin** — `BROWSER` takes the OAuth login too. Every missing piece
(not in iTerm2, `EnableAPIServer` off, no Python runtime, script error) falls
open to the ordinary path with one stderr line saying which, tagged with
`browser.tag.iterm2` if an overlay pins one; the runtime is checked before
anything talks to iTerm2, which would otherwise offer to install it in a
dialog nobody is watching. It is for viewing, not automation: the tab has no
Claude in Chrome pairing. Tests: `tests/open-as.bats` (a fake `iterm2`
module; no real iTerm2 touched). Unverified until the first live run: that
`ITERM_SESSION_ID`'s UUID is the API's session id (miss: the tab lands in the
current window), and that `file://` URLs render (else serve over localhost).
