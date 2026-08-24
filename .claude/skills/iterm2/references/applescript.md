# AppleScript

Verified against `/Applications/iTerm.app/Contents/Resources/iTerm2.sdef` in
iTerm2 3.6.11. That file is the dictionary Script Editor shows; read it
directly rather than trusting any prose about it, including this page.

Official page: <https://iterm2.com/documentation-scripting.html>

## Status: deprecated, and entirely present

The documentation index lists it as "Scripting with AppleScript
(Deprecated)", and the Python tutorial says "The iTerm2 Python API is a
replacement for the AppleScript API that preceded it". The page body itself
carries no warning and still opens "iTerm2 has sophisticated AppleScript
support".

The 3.6.11 dictionary contains **25 commands** in the iTerm2 suite plus the
Standard Suite, and **four classes** (`application`, `window`, `tab`,
`session`). Nothing is missing. The only things the sdef marks deprecated are
four window properties — `position`, `origin`, `size`, `frame` — each
annotated "Deprecated; use bounds instead."

So: deprecated means frozen, not removed. New work belongs in the Python API
(`references/python-api.md`), but existing AppleScript is not broken and does
not need rewriting to keep working.

Target the app as `"iTerm2"`. `tell application "iTerm"` appears only in the
legacy-compatibility section of the docs, for versions before 2.9.20140903.

## The object model

The application has windows; a window has tabs; a tab has sessions. More than
one session in a tab means split panes.

```
application
  current window        -> window     (frontmost)
  windows               -> list       (terminal windows only; not Settings)
window
  current tab, current session, tabs
  id                    -> integer    (usable with `screencapture -l`)
  alternate identifier  -> text       (the pre-3.0.4 "window-1" style id)
  is hotkey window      -> boolean
  hotkey window profile -> text
tab
  current session, sessions, index (from 0), title
session
  profile name          -> text, READ-ONLY   (code Pfnm)
  id, unique ID         -> text        (both map to the session guid)
  tty, columns, rows, name, contents, text
  is at shell prompt    -> boolean     (false without shell integration)
  is processing         -> boolean
  transparency, background image, answerback string, color preset
  background/bold/cursor/cursor text/foreground/selected text/selection color
  ANSI {black,red,green,yellow,blue,magenta,cyan,white} color
  ANSI bright <same eight> color, underline color, use underline color
```

`contents` and `text` are the same value; `text` is read-only, `contents` is
not marked so.

## Creating things

```applescript
tell application "iTerm2"
    -- windows
    create window with default profile
    create window with default profile command "top"
    set w to create window with profile "Work"
    create window with profile "Work" command "ssh somewhere"
    create hotkey window with profile "Hotkey Window"   -- profile must have a hotkey

    -- tabs (sent to a window)
    tell w
        create tab with default profile
        create tab with profile "Work" command "make watch"
    end tell

    -- splits (sent to a session); horizontal split = horizontal divider
    tell current session of current window
        split vertically with default profile
        split vertically with same profile
        split horizontally with profile "Work" command "tail -f log"
    end tell
end tell
```

Every one of these returns a reference to what it made. `command` overrides
the profile's command, which by default is `login`.

Also present: `write`, `select`, `close`, `reveal/hide/toggle hotkey window`,
`request cookie`, `launch API script named`, `invoke API expression`.

```applescript
tell current session of current window
    write text "echo hello"
    write text "no newline" newline no
    write contents of file "/tmp/script.sh"
end tell
```

`select` on a session makes it visible and selected but, per the docs, "Does
not affect which tab is selected or which window has keyboard focus."

## Variables — and the trap

Two commands, both on `session`:

```applescript
tell current session of current window
    set variable named "user.project" to "widget"
    set v to variable named "user.project"
end tell
```

**You may only *set* names beginning with `user.`.** Reading is unrestricted —
`variable named "path"`, `"hostname"`, `"jobName"` and the rest of the session
scope all work (full list:
<https://iterm2.com/documentation-variables.html>).

**The trap.** An unset variable answers `missing value`. AppleScript will
happily coerce that to the four-word *string* `"missing value"`, so the
obvious test silently passes:

```applescript
-- WRONG: v is the literal text "missing value", which is not empty
set v to (variable named "user.nope") as text
if v is "" then ...

-- RIGHT
set v to variable named "user.nope"
if v is missing value then set v to "default"
```

Anything that concatenates a variable into a title, a badge, or a shell
command will embed those two words rather than failing, which is why this
costs an hour to find.

## Colors

From the docs, verbatim: "Because AppleScript is kind of a dumpster fire, the
standard syntax for a color is `{red, green, blue, alpha}` where each value is
a number between 0 and 65535."

```applescript
tell current session of current window
    set foreground color to {65535, 0, 0, 0}
end tell
```

## Autolaunch and user scripts

- `~/Library/Application Support/iTerm2/Scripts/AutoLaunch.scpt` runs at
  startup. iTerm2 invokes it itself.
- Falls back to the legacy `~/Library/Application Support/iTerm/Scripts/AutoLaunch.scpt`
  (note: no `2`) when the modern folder is absent.
- User scripts appear in the Scripts menu and must be named `.scpt` or `.app`.

**Measured on this machine: a script iTerm2 launches this way needs no
Automation (TCC) grant.** Self-automation is implicitly allowed and is never
recorded in `TCC.db`. Verified with a detached shell reparented to launchd
performing both a read (`count windows`) and a write (`create window`), with
no new TCC row appearing, against a control that was properly reset first.
The same script run from Terminal, an editor, or a Claude Code Bash tool
*does* need the grant, and the first attempt raises a modal dialog — which is
why nothing here should be run speculatively against a live iTerm2.

## Driving the Python API from AppleScript

Three commands bridge the two APIs, and they are the supported way for an
outside program to reach the Python API at all:

```applescript
tell application "iTerm2"
    request cookie                                  -- 128-bit auth cookie
    request cookie and key for app named "my tool"  -- name shown in the console
    launch API script named "thing.py"
    launch API script named "thing.py" arguments {"--flag", "value"}
    invoke API expression "my_function(x: 1)"
end tell
```

```bash
ITERM2_COOKIE=$(osascript -e 'tell application "iTerm2" to request cookie') ./myscript.py
```

`invoke API expression` returns a string representation of the result where
one is available; the sdef notes "Function calls' return values are not
available."

Requiring AppleScript here is deliberate: it forces the caller through
macOS's Automation permission prompt. See `references/python-api.md`.

## Docs vs. the binary (3.6.11)

| Claim | Reality |
| --- | --- |
| Index says "Deprecated" | Every command and class is still in the sdef and works. Only four window geometry properties are annotated deprecated. |
| The AppleScript page documents the whole dictionary | It omits `request cookie`, `launch API script named`, and `invoke API expression` entirely. All three are in the sdef; the first two are documented only in the GitLab security wiki. |
| Variables are "described in Badges" | The badges page no longer lists variables. The list lives at documentation-variables.html. |
| User scripts live in `~/Library/Application Support/iTerm/Scripts` | Stale `iTerm` spelling; everything else in the app uses `iTerm2`. Both paths are honoured for `AutoLaunch.scpt`. |
| The Tab section lists `sessions` twice, with an orphaned sentence | Editing bug on the docs page; harmless. |
