# Watchlist

Tools and changes worth keeping an eye on: not adopted yet, but likely to
matter to this setup later. Each entry says what it is, why it is
interesting here, what stops us today, and **what would make it worth
another look**, so that revisiting is a check rather than a re-evaluation.

Add an entry when something gets evaluated and the answer is "not yet";
delete it once it is adopted or ruled out for good (the commit that
removes it says which).

## pymacos

https://github.com/JeanExtreme002/pymacos
(docs: https://macos.readthedocs.io/en/latest/)

- **Evaluated:** 2026-10-02, at v1.19.1.
- **What:** a zero-dependency Python library that controls macOS. Most of it
  calls Apple's frameworks directly (CFPreferences, Security, Accessibility,
  CoreGraphics, Vision) through a hand-written ctypes Objective-C bridge;
  about a third of the modules just wrap CLI tools (`say`, `tmutil`,
  `mdfind`, `shortcuts`, `launchctl`, `osascript`).
- **Why it matters here:** `macos.settings.export()` / `apply(json)` is a
  read-compare-write convergence engine: it changes only settings that
  differ, returns what changed, and restarts the Dock and Finder once. A
  pinned `mac.json` could supplement or replace `.macos`, and covers what
  `.macos` does badly or not at all: Dock contents, default apps per file
  type, app and system shortcuts, login items. Ansible would add nothing
  for a single machine converging its own settings.
- **What stops us:** the repo was five days old (created 2026-09-27, ~72
  PRs, 20 stars), with releases hours apart. Every framework call has its
  types declared by hand, so a macOS change crashes or returns garbage
  instead of failing cleanly.
- **Ceilings whatever runs it:** `hidutil` key remaps reset at reboot (they
  need a login LaunchAgent); `set_default_for` asks the user to confirm on
  macOS 26 and cannot set the default browser; Dock, wallpaper and window
  control need the logged-in GUI session, not SSH.
- **Revisit when:** releases are weeks apart, it has users beyond its
  author, and a few months have passed (earliest ~2027-01). Then: pin an
  exact version, run `settings.export()` on a configured Mac, and diff
  it against `.macos`.

## iTerm2 focus-changed event trigger

https://iterm2.com/downloads.html

- **Evaluated:** 2026-11-13, at 3.7.7 (source read to nightly `b4e21eb62`).
- **What:** an event trigger that fires when a session gains or loses keyboard
  focus.
- **Why it matters here:** it would start the sleeper on a return from another
  app or window and stop it on leaving, make "one mover" exact with several
  windows, and fire in two sessions per change rather than every session of
  the window.
- **What stops us:** no such event exists (the trigger types end at 115). It
  has been proposed upstream in an issue
  (https://gitlab.com/gnachman/iterm2/-/work_items/13211) and nothing is built
  until the maintainer answers. The crash that makes the variable trigger
  fragile is a separate pull request (https://github.com/gnachman/iTerm2/pull/822,
  issue https://gitlab.com/gnachman/iterm2/-/work_items/13210).
- **Revisit when:** the release notes name it. Then: `claude-peer look on`
  writes that trigger instead, calling `look gained|lost`.

## fzf terminal-focus events

https://github.com/junegunn/fzf/blob/master/CHANGELOG.md

- **Evaluated:** 2026-11-12, at fzf 0.75.0 (changelog read to 0.75.1).
- **What:** fzf learning that its terminal gained or lost focus.
- **Why it matters here:** it is the route that would need no iTerm2 trigger
  at all: iTerm2 already reports focus to the pty on tab, pane, window and app
  changes (DECSET 1004), so a waiting pane's fzf could start and stop its own
  timer.
- **What stops us:** fzf has no such event and reads those reports as `alt-[`
  and a typed `I` or `O`.
- **Revisit when:** its changelog names a terminal focus event.
