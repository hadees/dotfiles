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

The backing keys, present in the 3.6.11 and 3.7.6 binaries:

```
LoadPrefsFromCustomFolder   bool
PrefsCustomFolder           string (a tilde path is accepted, e.g. ~/code/dotfiles)
```

iTerm2 writes `com.googlecode.iterm2.plist` into that folder, which makes the
folder trackable in git. Since 3.7.7, quitting no longer asks to copy
settings to the folder just because iTerm2 migrated an older setting saved
there.

**Since 3.7 the folder can carry data files too** — snippets, global notes and
session-icon customisations. iTerm2 asks once whether to sync them, and asks
which copy wins on a conflict; the answer is machine-local
(`NoSyncSyncDataFilesWithCustomFolder`). Say no when the folder is a public
repo: notes and snippets are exactly the kind of content that names clients
and hosts.

Two things make a tracked plist work in practice:

### The `NoSync*` convention

Keys whose names begin with `NoSync` are **machine-local state, excluded from
the custom prefs folder**. Verified on this machine: the live domain carries
60 `NoSync*` keys on 3.7.6 (26 on 3.6.11) — `NoSyncInstallationId`,
`NoSyncLastOSVersion`, `NoSyncBFPRecents`, the 3.7 `NoSyncCompanion*` relay
state and so on — and the copy written to the custom folder carries **zero**. That is what stops a
shared prefs folder churning on every machine that opens it.

### Secrets are not in the plist

The AI provider API keys go to the **Keychain**, one per provider since 3.7,
as does the Companion app's pairing identity. See `references/ai-plugin.md`;
this is the property that makes a git-tracked prefs folder safe, and it is
worth re-checking rather than assuming after an update.

**One exception arrived in 3.7**: custom HTTP headers for a manually
configured AI model are "stored unencrypted in iTerm2's preferences"
(`AICustomHeaders`, gated by `AICustomHeadersEnabled`). A
gateway token put in a header therefore lands in the plist, and from there
in the custom folder. Never configure one on a machine whose prefs folder is
tracked; `plutil -p <folder>/com.googlecode.iterm2.plist | grep AICustomHeaders`
is the check.

**None of `LoadPrefsFromCustomFolder`, `PrefsCustomFolder`, or the `NoSync`
convention appears anywhere on iterm2.com** — not in the preferences
reference, not in the FAQ, not on the hidden-settings page. They are real keys
in the binary and stable in practice, but they are reverse-engineered and
unsupported. Say so when recommending them.

## Settings > General > Magic

The pane whose name gives no clue what is in it. It is **not** the AI pane —
AI has its own sections under Settings > General (`references/ai-plugin.md`),
and confusing the two is the usual reason someone cannot find a setting.

The eight documented options
(<https://iterm2.com/documentation-preferences-general.html>):

| Option | What it does |
| --- | --- |
| Add Bonjour hosts to profiles | "all Bonjour hosts on the local network have a profile created for them as long as they're around" |
| Instant Replay Uses X MB per Session | Per tab or split pane; more memory means further back. Enter with View > Step Back in Time |
| Save copy/paste and command history to disk | Copy/paste: the last 20 values, read via Edit > Open Paste History. With shell integration it also persists command history, directory history, and remote host/usernames. **Unchecking erases all of it** |
| Enable Python API | The `EnableAPIServer` key; see `references/python-api.md` |
| Custom Python API Scripts Folder | Overrides `~/Library/Application Support/iTerm2/Scripts` |
| GPU Rendering | Plus two advanced settings: disable when on battery, and prefer the integrated GPU |
| Maximize throughput at the cost of higher latency | Lowers the frame rate under heavy output and prioritises input over redraw. "You probably need to disable this to hit 120 FPS" |
| Compress scrollback history in the background | More idle CPU, "significantly reduce memory usage when there are large scrollback buffers" |

**A ninth option is in the pane but not in the pane's documentation**: *Allow
all apps to connect*, the Python API's cookie escape hatch. It is described
only on the Python API Security page — see `references/python-api.md` for the
root-owned file it actually writes. That page still calls the pane
"Prefs > General > Magic"; everything else says Settings.

Two numbers on the same checkbox disagree across pages: "the last 20 values"
(Magic) versus "up to 200 commands per user/hostname" (Shell Integration).
Both are right — 20 is the copy/paste ring, 200 the command history.

Adjacent and easily confused: **Settings > General > Experimental** holds
exactly two options, *Enable support for right-to-left scripts* and *Use SSH
integration for ssh: URLs* (`references/ssh.md`) — still both in 3.7.6, read
off `PreferencePanel.nib`. Right-to-left support is **on by default since
3.7.0**; this is where to turn it off. There is no general "enable
experimental features" switch.

## Startup and restoration — measured, not recalled

Two behaviours that are easy to state wrongly from memory, both measured on
3.6.11 and not re-measured on 3.7.6:

**iTerm2 opens one window of its own at every launch.** Not a restored window
— a new one. Suppress it with:

```
OpenNoWindowsAtStartup       bool   suppress the automatic window
OpenArrangementAtStartup     bool   open the saved arrangement instead
AlwaysOpenWindowAtStartup    bool   the neighbouring key; open one even when told not to
```

All three are in the 3.6.11 and 3.7.6 binaries.

**Without a saved arrangement, iTerm2 restored nothing across a quit** on
3.6.11 — not re-measured on 3.7.6, whose notes list a run of restoration
fixes but no change of policy. Two
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

## Two of the same

3.7.5 warns when a second copy of iTerm2 starts with the same settings, since
the two could overwrite each other's prefs and saved windows. Deliberate
multiple instances use `-suite com.iterm2.<id>`, each with its own
application-support directory (`references/python-api.md`).

## Suppressed alerts

Answering a dialog with *Remember my selection* suppresses it. 3.7 lists every
suppressed alert under **iTerm2 > Suppressed Alerts**, where any can be
un-suppressed; the old *View > Always Show Alerts with Remembered Selections*
is a checkbox there now. With a custom folder and *Save changes:
Automatically*, a suppression survives relaunch.

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

3.7 adds **Erase All Settings and Data** beside it, in Settings > General >
Settings.

## Docs vs. the binary (3.6.11, re-checked on 3.7.6)

| Claim | Reality |
| --- | --- |
| The preferences reference documents the settings | `documentation-preferences.html` is a table of contents only; content is on eight per-section pages. |
| `LoadPrefsFromCustomFolder` / `PrefsCustomFolder` / `NoSync*` / `EnableAPIServer` | Zero hits across the whole documentation set including the hidden-settings page. Real keys, undocumented. |
| The plist path | Documented only in the FAQ. |
| The custom-folder UI text | Says nothing about which keys are excluded, what the URL form fetches, or how conflicts resolve. The `NoSync` behaviour above is observed, not promised. |
