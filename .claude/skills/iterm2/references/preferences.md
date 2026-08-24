# Preferences, startup, and restoration

## Where settings live

```
~/Library/Preferences/com.googlecode.iterm2.plist
```

The only official statement of this is the FAQ, not the preferences
reference: "Preferences, including profiles, are stored in
`~/Library/Preferences/com.googlecode.iterm2.plist`. To modify it, use the
`defaults` command."

```bash
defaults read  com.googlecode.iterm2 <key>
defaults write com.googlecode.iterm2 <key> -bool true
defaults delete com.googlecode.iterm2            # nuke everything
```

macOS caches the domain, so a `defaults write` while iTerm2 is running may be
overwritten when it quits. Change it in the UI, or quit first.

## Custom prefs folder

Settings > General > Settings:

- **Load settings from a custom folder or URL** — "iTerm2 will load its
  settings from the specified folder or URL. After setting this, you'll be
  prompted when you quit iTerm2 if you'd like to save changes to the folder."
- **Save changes to folder when iTerm2 quits.**

The backing keys, both present in the 3.6.11 binary:

```
LoadPrefsFromCustomFolder   bool
PrefsCustomFolder           string (a tilde path is accepted, e.g. ~/code/dotfiles)
```

iTerm2 writes `com.googlecode.iterm2.plist` into that folder, which makes the
folder trackable in git. Two things make that work in practice:

### The `NoSync*` convention

Keys whose names begin with `NoSync` are **machine-local state, excluded from
the custom prefs folder**. Verified on this machine: the live domain carries
26 `NoSync*` keys — `NoSyncInstallationId`, `NoSyncLastOSVersion`,
`NoSyncBFPRecents`, `NoSyncCommandHistoryHasEverBeenUsed` and so on — and the
copy written to the custom folder carries **zero**. That is what stops a
shared prefs folder churning on every machine that opens it.

### Secrets are not in the plist

The AI provider API key goes to the **Keychain**. See
`references/ai-plugin.md`; this is the property that makes a git-tracked prefs
folder safe, and it is worth re-checking rather than assuming after an update.

**None of `LoadPrefsFromCustomFolder`, `PrefsCustomFolder`, or the `NoSync`
convention appears anywhere on iterm2.com** — not in the preferences
reference, not in the FAQ, not on the hidden-settings page. They are real keys
in the binary and stable in practice, but they are reverse-engineered and
unsupported. Say so when recommending them.

## Startup and restoration — measured, not recalled

Two behaviours that are easy to state wrongly from memory, both measured on
3.6.11:

**iTerm2 opens one window of its own at every launch.** Not a restored window
— a new one. Suppress it with:

```
OpenNoWindowsAtStartup       bool   suppress the automatic window
OpenArrangementAtStartup     bool   open the saved arrangement instead
AlwaysOpenWindowAtStartup    bool   the neighbouring key; open one even when told not to
```

All three are in the 3.6.11 binary.

**Without a saved arrangement, iTerm2 restores nothing across a quit.** Two
windows — one with a user variable set on its session, one plain — were both
gone after quit and relaunch, replaced by a single fresh window. Session
contents, variables, layout: none of it survives. Anything you want back has
to be a saved arrangement (Window > Save Window Arrangement) or built by an
AutoLaunch script.

The combination that actually works for a scripted layout is
`OpenNoWindowsAtStartup` **plus** an AutoLaunch script — otherwise the script
races the app's own window and you get both.

macOS's own window restoration is a separate mechanism again; iTerm2 tracks
it with `NoSyncIgnoreSystemWindowRestoration`.

## Updater keys

In the app's `Info.plist` (read-only, iTerm2's own keys, not Sparkle's):

```
SUFeedURLForFinal    https://iterm2.com/appcasts/final_modern.xml
SUFeedURLForTesting  https://iterm2.com/appcasts/testing_modern.xml
```

In the user domain:

```
CheckTestRelease         bool, default NO   -- "Check for test releases"
SUEnableAutomaticChecks  bool, default YES  -- Sparkle's own key
SUFeedURL                                   -- written by iTerm2 at launch
```

At launch iTerm2 picks one of the two Info.plist feeds according to
`CheckTestRelease`, appends a random `?shard=N` for staged rollout, and writes
the result into the user-defaults `SUFeedURL` that Sparkle actually reads. So
`SUFeedURL` in the user domain is an output, not a setting. Full detail in
`references/releases.md`.

## Export / import

Settings > General offers **Export All Settings and Data**, whose contents are
the closest thing to an official statement of what iTerm2 keeps and where:

- Python API runtimes
- Secure user defaults (settings that require your password to change)
- Everything in the Settings window
- The contents of `~/.iterm2` (shell integration scripts)
- The contents of `~/Library/Application Support/iTerm2` (toolbelt notes,
  dynamic profiles, and more)
- Python API scripts

## Docs vs. the binary (3.6.11)

| Claim | Reality |
| --- | --- |
| The preferences reference documents the settings | `documentation-preferences.html` is a table of contents only; content is on eight per-section pages. |
| `LoadPrefsFromCustomFolder` / `PrefsCustomFolder` / `NoSync*` / `EnableAPIServer` | Zero hits across the whole documentation set including the hidden-settings page. Real keys, undocumented. |
| The plist path | Documented only in the FAQ. |
| The custom-folder UI text | Says nothing about which keys are excluded, what the URL form fetches, or how conflicts resolve. The `NoSync` behaviour above is observed, not promised. |
