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
