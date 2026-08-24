# Automatic Profile Switching, selection, and the Toolbelt

The features that react to where you are and to what is on screen. All are
configured per profile under **Settings > Profiles > Advanced** — the same
tab as Triggers — and most need shell integration to know anything at all.

## First: iTerm2 ships its own feature list

```bash
/Applications/iTerm.app/Contents/Resources/utilities/it2tip
```

`it2tip` is a Python script holding the app's whole feature tour, one entry
per feature with a title, a body, and often the menu path and shortcut.
**123 entries in 3.6.11.** It is first-party, it grows with the app, and it
is documented nowhere on iterm2.com.

`manifest.txt` records that count, because it is the **only check in this
skill that can notice a feature being added** — every other verb asks whether
a name still exists. When `verify.sh` says the count changed, run `it2tip`
and read what is new. Quotations marked *(it2tip)* below come from it.

## Automatic Profile Switching

<https://iterm2.com/documentation-automatic-profile-switching.html>
(`iterm2.com/automatic-profile-switching.html` 302s here.)

> iTerm2 can use information it knows about your current path, host name, user
> name, and foreground job name to change profiles.

**Rules are attached to the destination profile**, not to a central list:
"When any session satisfies a rule in a given profile, it will switch to that
profile." Settings > Profiles > Advanced > Automatic Profile Switching. The
underlying profile key is **`Bound Hosts`**, an array — which means a
**Dynamic Profile** can generate the rules from a host inventory
(`references/dynamic-profiles.md`). Neither page mentions the other.

**Shell Integration is required**, on every machine and every account you
want it to work for. Not SSH Integration — the docs never mention that as an
alternative, though anything that makes the host and path known will do.
Without it, `hostname` and `path` never change, no rule ever fires, and APS
looks broken rather than unconfigured. For hosts you cannot install on (root,
appliances), the documented workaround is the *Report User & Host* / *Report
Directory* triggers in `references/shell-integration.md`.

### Rule syntax

Four components, all optional, at least one required:

| Part | Form | Example |
| --- | --- | --- |
| user | name followed by `@` | `root@` |
| hostname | DNS name or IP, `*` wildcards | `*.example.com` |
| path | always begins `/`, separated from a hostname by `:`, `*` wildcards | `host:/users/name` |
| job | prefixed with `&` | `&vim`, `&emacs*` |
| sticky | prefix the whole rule with `!` | `!host.example.com` |

"The hostname is required only when both a user name and a path are
specified." (The page says "three optional components" and then documents the
job as a fourth — one of its own contradictions.)

**Since 3.6 the job part matches the full command line, not just the
executable name.** That is confirmed from the other side: the switcher's
internal entry point is `setHostname:username:path:job:commandLine:`.

### Precedence is a score, not a first match

Every specified part of a rule must match for the rule to be considered at
all; the matching parts then sum:

| Match | Points |
| --- | --- |
| hostname, exact | 16 |
| hostname, wildcard | 8 |
| job name (wildcard or not) | 4 |
| user name | 2 |
| path, exact | 1 |
| path, wildcard | 0 — but still counts as a match |

Highest score wins. A wildcard path scoring zero is the subtle one: it
qualifies the rule without adding weight, so `*:/users/x` and `/users/x`
tie unless something else separates them.

"The UI tries to prevent you from entering the same rule in two different
profiles, but if that does happen then **one profile is chosen arbitrarily**."

### What happens on ssh, and on cd — it is a stack

Each session keeps a **stack of profiles**, initially just the one it was
created with. When the username, hostname, or path changes:

- best-matching profile already on the stack → pop everything above it and
  switch to it;
- best-matching profile not on the stack → push and switch;
- **no rule matches anywhere → the stack is emptied down to the original
  profile and the session reverts to it.**

That last clause is automatic reversion, and it is why the profile snaps back
when an ssh session ends. The exception is a **sticky** rule (`!` prefix):
its profile stays after the rule stops applying, "so long as no other rule
matches".

The one troubleshooting affordance the docs offer is an off-site link to the
GitLab wiki's "why doesn't scp / automatic profile switching work" page.
There is **no APS logging or debug mode** documented. The binary does log
`Initialized automatic profile switcher %@`, so Console.app is the only
window into it.

## Smart Selection

<https://iterm2.com/documentation-smart-selection.html>

> A quad-click (four clicks of the left mouse button in quick succession)
> activates Smart Selection at the mouse cursor's position.

**Quad-click, not double-click** — double-click is plain word selection
unless you turn on Settings > General > Selection > **"Double-click performs
smart selection"**. (The neighbouring "Characters considered part of a word
for selection" is what makes a plain double-click grab a whole path.)

Profile key: **`Smart Selection Rules`**. Ships recognising: whitespace-bounded
words; `namespace::identifier`; filesystem paths; quoted strings;
`foo.bar.baz` include paths; URIs with the schemes **mailto, http, https,
ssh, telnet**; `@selector(foo:bar:)`; email addresses.

### Precision

Each rule has a **Precision**: *Very Low, Low, Normal, High, Very High*. It
means "how sure can we be that a match is what the user meant" — "Word" is
low precision, "HTTP URL" is very high.

The algorithm, verbatim: every regex is tried, only matches **including the
character under the cursor** count, the longest such match per regex becomes
a candidate scored by length, and "among the candidates in the highest
precision class ... with any matches, the [highest] scoring one is used."

Note the page contradicts itself here: that algorithm makes precision an
absolute filter, but a paragraph above says a lower-precision rule can win
"if the Word rule matches a much longer string", softened to "it's very rare
for a lower precision rule to take precedence". Treat precision as
near-absolute and do not rely on length beating it.

There is a **Smart Selection Playground** in the app for testing a rule
before committing to it. The docs' `smart_selection_cases.txt` test corpus is
mentioned as plain text, not a link, and is not reachable from the site.

### Actions

> When you right click in a terminal, smart selection is performed at the
> cursor's location. Any smart selection rule that matches that location will
> be searched for associated actions, and those actions will be added to the
> context menu. **A cmd-click on text matching a smart selection rule will
> invoke the first rule.**

That last sentence is the entire relationship with Semantic History: a Smart
Selection rule with an action **pre-empts** Semantic History on cmd-click.

The seven actions: **Open File** (default app), **Open URL** (default
browser), **Run Command** (`/bin/sh -c` in the background, output to the
Script Console), **Run Coprocess**, **Send Text** (as though typed), **Run
Command in Window**, **Copy**.

Legacy parameter substitutions:

```
\0  full match        \d  current directory
\1..\9 capture groups \u  current user name    } need Shell Integration
\n  newline           \h  current host name    } when sshed
\\  backslash
```

Ticking **"Use interpolated strings for parameters"** switches to `\( … )`
syntax evaluated in the session's context, with an extra array `matches` —
`matches[0]` is the full match, `matches[i]` the *i*th group. `\(path)` is
the equivalent of legacy `\d`.

Relevant advanced settings, verbatim from the binary:

- `Smart Selection Actions Use Interpolated Strings`
- `Smart Selection Ignoring Newlines`
- `Semantic History: Check smart selection actions before existing files on cmd-click?`

Regexes are ICU, same as triggers.

## Semantic History

> Semantic history is used to open a file when you Cmd-Click on it. The
> current working directory for each line in the terminal is tracked to help
> find files.

Profile key: **`Semantic History`**. Five actions: **Open with default app**,
**Open URL...**, **Open with editor...**, **Run command...**, **Always run
command...** — the last being "like Run command, but takes effect even if the
object clicked on is not an existing filename."

**The substitutions are numbered differently from Smart Selection's, and this
is the trap:**

| | Smart Selection | Semantic History |
| --- | --- | --- |
| `\0` | full match | — |
| `\1` | first capture group | **filename** |
| `\2` | second group | **line number** (if applicable) |
| `\3` | third group | text in the line **before** the click |
| `\4` | fourth group | text in the line **after** the click |
| `\5` | fifth group | **working directory** of the clicked line |

`\3`–`\5` are documented only for the command actions, not for Open URL. In
interpolated form the filename is `\(semanticHistory.path)`; both strings are
in the binary.

Other ways in: the pointer action **Open URL/Semantic History** (and its
"in background" variant), and **Edit > Open Selection**. Two escape codes
feed it: `OSC 1337 ; CurrentDir=…` and, since 3.4, an OSC 8 hyperlink with a
`file:` scheme and a `#` fragment — `file:///tmp/file.txt#123` opens at that
line.

Nearly all of its guessing is tunable from **Settings > Advanced**. The
complete set in 3.6.11, verbatim from the binary:

```
Characters never considered part of a URL.
Characters to ignore at the end of a URL
Check smart selection actions before existing files on cmd-click?
Default URL scheme.
Enable semantic history for network-mounted filesystems?
Maximum number of bytes of text before and after click location to take
  into account.
Non-alphanumeric characters considered part of a filename. Note that URL
  characters (a separate advanced setting) are also allowed.
Non-alphanumeric characters considered part of a URL or file name for
  Semantic History.
Only consider a two+ part domain-name to be a URL if it also contains a
  slash.
Paths to ignore for Semantic History.
Respect soft boundaries for computing the prefix and suffix text passed to
  semantic history commands?
URLs must contain a scheme?
```

"Enable semantic history for network-mounted filesystems?" is off by default
for a good reason: statting a path on a stalled network mount blocks the
click. Worth knowing on a machine that mounts remote directories.

Related, and often mistaken for it:

> Enable "Settings > Profiles > Terminal > Click on a path in a shell prompt
> to open Navigator" to navigate your filesystem by clicking on paths in your
> prompt. Requires Shell Integration. *(it2tip)*

## The Toolbelt

**There is no Toolbelt page.** `documentation-toolbelt.html` is a 404, the
documentation index has no entry for it, and the one-page build has no
Toolbelt section. It is documented only as a subtree of the Menu Items page.

- **View > Toolbelt > Show Toolbelt** — "toggles the visibility of the
  Toolbelt on the **right side** of all windows." Right side only; unlike the
  tab bar, there is no documented way to move it.
- **View > Toolbelt > Set Default Width** — saves the current width as the
  default for new windows (`Default Toolbelt Width`). The width is stored in
  window arrangements.
- **Settings > Profiles > Window > Open Toolbelt** — per-profile, opens it
  for windows created from that profile.
- **No default keyboard shortcut** is documented for the toolbelt or any tool.

The eleven tools in 3.6.11 (confirmed against the app's own class names):

| Tool | What it is | Needs Shell Integration |
| --- | --- | --- |
| Actions | Actions configured under Settings > Shortcuts > Actions | no |
| Captured Output | Lines caught by a **Capture Output trigger**; see below | **yes** |
| Codecierge | AI assistant that follows a goal; see `references/ai-plugin.md` | no (needs the AI plugin) |
| Command History | Recent commands; bold = current session; double-click enters it, option-double-click emits a `cd` to where it last ran | **yes** |
| Jobs | Running jobs in the session, and lets you signal them | no |
| Named Marks | Jump to saved locations in history (and to saved spots on a page in browser sessions) | no |
| Notes | Freeform scratchpad, persists across restarts in `~/Library/Application Support/iTerm2/notes.rtfd` | no |
| Paste History | Recently pasted strings | no |
| Profiles | Click to open a window/tab/pane with that profile | no |
| Recent Directories | Sorted by "frecency"; double-click types the path, option-double-click emits `cd`; right-click stars one to pin it to the bottom | **yes** |
| Snippets | Frequently used text strings | no |

Command history and recent directories are stored **per username+hostname**,
and persist across restarts only when Settings > General > Magic > *Save
copy/paste and command history to disk* is on — up to 200 commands per
user/host.

The Python API can register **dynamic tools** as well — the binary posts
`iTermToolbeltDidRegisterDynamicToolNotification` — so a long-running script
can add its own panel. See `references/python-api.md`.

### Captured Output is the one worth setting up

<https://iterm2.com/documentation-captured-output.html>

> A Trigger whose action is **Capture Output** looks for lines of output that
> match its regular expression. When one is found, the entire line is added
> to the Captured Output tool. When the user clicks on a line in the Captured
> Output tool, iTerm2 scrolls to reveal that line. **Double-clicking on a line
> in the Captured Output tools run a user-defined Coprocess.**

So: a trigger matches your compiler's error format → the lines collect in the
sidebar → click to jump there, double-click to run a coprocess with the
trigger's capture groups substituted, e.g. opening an editor at the line. It
requires shell integration, because capture is scoped to one command's output
and iTerm2 has to know where that starts and ends.

## Docs vs. the binary (3.6.11)

| Claim | Reality |
| --- | --- |
| APS has "three optional components" | Four — the job name (`&`) is documented in the same section. |
| APS matches the job name | Since 3.6 it matches the **full command line**; the switcher is handed both. |
| APS rules are a UI-only list | They are the `Bound Hosts` profile key, so a Dynamic Profile can generate them. |
| Smart Selection precision is absolute | The page says both "highest precision class wins" and "unless Word matches a much longer string". |
| `smart_selection_cases.txt` is a resource | Plain text on the page, not a link, not reachable. |
| The Toolbelt is documented | `documentation-toolbelt.html` is a 404 and the index has no entry; it lives inside the Menu Items page. |
| Menu path for the toolbelt | Two pages say `Toolbelt > …`, the Menu Items page says `View > Toolbelt > …`. The latter is right. |
| Smart Selection and Semantic History use the same substitutions | They do not. `\1` is a capture group in one and the filename in the other. |
| `it2tip` | 123 features enumerated by the app itself, documented nowhere on the site. |
