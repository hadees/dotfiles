---
name: iterm2
description: >-
  Everything this machine's iTerm2 can actually do, verified against the
  installed app rather than recalled — the AppleScript dictionary, the Python
  API and its auth model, Dynamic Profiles, shell integration and the it2*
  utilities, triggers, badges, the status bar, hotkey windows, tmux -CC,
  Automatic Profile Switching, Smart Selection and Semantic History, the
  Toolbelt, SSH Integration and ssh:// URLs, preferences and startup
  behaviour, the AI plugin and its permission model, and how the project ships
  releases. Use this skill whenever a task touches iTerm2 in any way: driving
  it from a script (AppleScript or Python), creating or editing profiles,
  writing an AutoLaunch script, setting a badge or a trigger or a status-bar
  component, making cmd-click or quad-click do something, switching profiles
  by host, changing preferences or the custom prefs folder, debugging why a
  window did or did not appear at startup, wondering what a new iTerm2 version
  changed, or answering "can iTerm2 do X" at all. Reach for it even when the
  user says "the terminal" or "my terminal" and this is a Mac — guessing at
  iTerm2's API from memory is exactly what this skill exists to stop.
---

# iTerm2

This skill is a **checked record of one version of iTerm2**, not a summary of
its manual. Every claim in `references/` was read off an installed
`iTerm.app` — its `Info.plist`, its AppleScript dictionary, the strings in
its executable, its `utilities` directory — and the mechanically checkable
part of that is listed in `scripts/manifest.txt` so a later version cannot
quietly falsify it.

**Written against iTerm2 3.6.11.** That number is the load-bearing fact here.
iTerm2 updates itself through Sparkle without asking, so a description of it
decays on its own; the version stamp is what turns that decay into something
you can see.

## Start here, always

Before answering anything about iTerm2, confirm the record still applies:

```bash
.claude/skills/iterm2/scripts/verify.sh     # from the repo root; or run it
                                            # by its path from anywhere
```

It prints the installed version, compares it to the stamp, and re-checks
every recorded name against the bundle. Exit 0 means the record holds; exit 1
lists exactly what no longer does; exit 2 means it could not check (no
`iTerm.app`). `--quiet` suppresses everything but the failures, for a script.

`iterm2-doctor` (in `~/.functions`) prints the same version comparison as one
line alongside the rest of this machine's iTerm2 state, and `doctor` runs it
with the others.

If the installed version is **newer** than the stamp, say so before advising,
then read what changed: <https://iterm2.com/downloads.html> — expand the
per-version notes. Do not look for a GitHub release or a `CHANGELOG` file;
the repo publishes neither (see `references/releases.md`). And note what the
checks can and cannot prove: most of them only ask whether a name still
exists, so they are blind to anything *added*. The one exception is the tip
count — iTerm2's own feature tour, which grows with the app. That is why the
version comparison still matters more than the check count.

## What is in here

| File | Read it when |
| --- | --- |
| `references/applescript.md` | Driving iTerm2 from AppleScript or `osascript`; the deprecated-but-complete dictionary, the `user.*` variable rules, the `missing value` trap |
| `references/python-api.md` | Writing a Python script, an AutoLaunch daemon, an RPC, a title provider or status-bar component; the cookie/socket auth model |
| `references/dynamic-profiles.md` | Creating profiles from a file; the plist format, required keys, inheritance, hot reload, badges |
| `references/preferences.md` | The prefs plist, the custom prefs folder, `NoSync*`, startup and window-restoration behaviour |
| `references/shell-integration.md` | Marks, prompt navigation, the `it2*` utilities, escape codes, badges, triggers, the status bar, hotkey windows, `tmux -CC` |
| `references/workflow.md` | Automatic Profile Switching, Smart Selection, Semantic History and cmd-click, the Toolbelt — and `it2tip`, the app's own list of its 123 features |
| `references/ssh.md` | SSH Integration (the 3.5+ feature, not shell integration), `it2ssh` and how it really works, `ssh://` URL handling |
| `references/ai-plugin.md` | The separate AI plugin, AI Chat and its tri-state permission model, which providers work, where the API key lives and why that matters when the prefs folder is a git repo |
| `references/releases.md` | Channels, version-number shapes, appcasts, finding what changed between two versions |
| `scripts/manifest.txt` | The machine-checkable facts, one per line, with the verbs explained at the top |
| `scripts/verify.sh` | The checker |

Read only the file the task needs. They are independent.

## The seven things most often gotten wrong from memory

These are here rather than buried in a reference because they are the
mistakes that survive being confidently stated.

1. **The AppleScript API is deprecated and complete at the same time.** The
   documentation index labels it "Deprecated" and the Python tutorial calls
   itself "a replacement for the AppleScript API that preceded it" — but
   nothing has been removed. `iTerm2.sdef` in 3.6.11 ships 25 commands and
   four classes, all functional. Deprecated means "no longer receiving
   improvements", not "gone". Prefer Python for anything new; do not tell
   someone their working AppleScript is broken.

2. **`set variable` only accepts `user.` names, and an unset one reads back
   as `missing value`.** Coerce that to text and you get the literal string
   `"missing value"`, which compares equal to nothing you expect and is a
   miserable bug to find. Test with `if x is missing value`, never
   `if x as text is ""`.

3. **iTerm2 opens one window of its own at every launch, and restores
   nothing without a saved arrangement.** Measured on 3.6.11: a window with a
   user variable set and a plain window were both gone after a quit and
   relaunch, replaced by one fresh window. `OpenNoWindowsAtStartup` suppresses
   the automatic window; `OpenArrangementAtStartup` and
   `AlwaysOpenWindowAtStartup` are its neighbours. An AutoLaunch script that
   creates a window therefore usually wants that pref set, or it races the
   app's own.

4. **The AI API key is in the Keychain, not in the prefs plist.** The binary
   says so — "The key will be stored securely in the Keychain" — and carries a
   `NoSyncMoveOpenAIAPIKeyIntoKeychain` migration from when it wasn't. This is
   what makes it safe to track a prefs folder in git; see
   `references/ai-plugin.md` before assuming it stays true.

5. **Half of what people configure has no official documentation.**
   `LoadPrefsFromCustomFolder`, `PrefsCustomFolder`, the `NoSync*` convention
   and `EnableAPIServer` appear nowhere on iterm2.com — not even on its
   hidden-settings page. Neither do `it2ssh`, `it2api`, `it2cat`, `it2git`,
   `it2profile` or `it2tip`, and there is no Toolbelt page or SSH Integration
   page at all. These are real, working things; they are simply unsupported
   and free to change in a point release. Say that when recommending one.

6. **Smart Selection and Semantic History both own cmd-click, and their
   substitutions are numbered differently.** A Smart Selection rule with an
   action pre-empts Semantic History. In Smart Selection `\1` is the first
   capture group; in Semantic History `\1` is the *filename* and `\2` the
   line number. Conflating them produces a rule that silently does the wrong
   thing. See `references/workflow.md`.

7. **The app ships its own feature list, and it is the best answer to "what
   can this version do".** `Contents/Resources/utilities/it2tip` — 123
   entries in 3.6.11, each with a menu path. `verify.sh` counts them, which
   makes it the one check here that can notice a feature being *added*.

## Where the documentation and the binary disagree

When they conflict, **the binary wins** — it is what runs. Recording the
disagreement is half the value of this skill, because a reader who checks
only the docs will believe the wrong thing with a citation to back it up.
Each reference file has a "Docs vs. the binary" section; the disagreements
found while writing this against 3.6.11 are listed there rather than
duplicated here.

## Rules for touching a running iTerm2

Almost everything worth knowing can be read off disk. Prefer that:

- **Version**: `defaults read /Applications/iTerm.app/Contents/Info CFBundleShortVersionString`.
  Never `brew list --cask --versions iterm2` — iTerm2 self-updates through
  Sparkle, so Homebrew's record is stale by design and disagrees on this very
  machine.
- **Dictionary**: read `/Applications/iTerm.app/Contents/Resources/iTerm2.sdef`
  as a file. It is plain XML.
- **Preferences**: `defaults read com.googlecode.iterm2 <key>`.
- **Feature list**: run `Contents/Resources/utilities/it2tip`, or read it as a
  file — it is a Python script with the whole tour in a literal list.
- **The bundled utilities themselves** are readable shell and Python. When
  `it2ssh` or `it2ul` misbehaves, the script is the documentation; six of the
  seventeen have no other.

If you must script a live iTerm2, remember you are inside someone's working
session: creating windows, splitting panes, and `write text` all land in
front of them. Never trigger a modal dialog, and never send `write text` to a
session you did not create — it types into whatever shell is there.

## Refreshing this skill

When `verify.sh` reports drift, the update is one motion:

1. Read the release notes at <https://iterm2.com/downloads.html> for every
   version between the stamp and the installed one.
2. Re-read the primary sources for whatever changed — the `.sdef`, the
   binary's strings, <https://iterm2.com/documentation.html> — and correct the
   reference files. Verify against the app, not against the docs.
3. Add or remove `manifest.txt` lines to match what the references now claim.
4. Update **three** stamps to the new version: the `version` line in
   `manifest.txt`, the "Written against" line above, and the `stamp` local in
   `iterm2-doctor` in `dot_functions`. `tests/iterm2-doctor.bats` fails if
   they disagree, which is deliberate — the doctor is deployed to machines
   that have no copy of this skill, so it has to carry its own stamp.
