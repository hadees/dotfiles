---
paths:
  - "**/.claude/skills/iterm2/**"
  - "**/tests/iterm2-doctor.bats"
  - "**/com.googlecode.iterm2.plist"
---

# iTerm2, and the skill that records what it can do

iTerm2 updates itself through Sparkle without asking, so anything written
about it decays on its own and the only symptom is confident, wrong advice.
The `.claude/skills/iterm2/` skill exists to make that decay visible instead:
it is a **version-stamped, machine-checkable record** of one release —
AppleScript dictionary, Python API and its cookie/socket auth model, Dynamic
Profiles, shell integration and the `it2*` utilities, triggers, badges, status
bar, hotkey windows, `tmux -CC`, Automatic Profile Switching, Smart Selection
and Semantic History, the Toolbelt, the 3.7 Session Status / Claude Code
integration / Workgroups layer, SSH Integration and `ssh://` URLs,
preferences and startup behaviour, the AI plugin and its permission model, and
how the project ships releases. Every claim was read off the installed bundle
rather than recalled, and the mechanically checkable part of it — sdef
commands, Dynamic Profile / APS / Smart Selection / preference key names, the
bundled utilities, updater `Info.plist` keys — is one fact per line in
`scripts/manifest.txt`. `scripts/verify.sh` re-reads all of it from the bundle
and exits non-zero on any drift.

Every check asks whether a name still *exists*, so the manifest is blind to a
feature being **added**. The `tipcount` entry was meant to cover that —
iTerm2 ships `Contents/Resources/utilities/it2tip`, a Python script holding
the app's own feature tour, 123 entries with menu paths — but it does not:
3.7 added Session Status, Workgroups, floating panes and a Companion app, and
the tour kept the same 123 titles. What notices an addition is **diffing the
bundle against the stamped release's** (download the old zip, never run it,
`comm` the two executables' `strings`, `diff` the `.sdef`s); `SKILL.md`'s
refresh procedure spells it out, and `verify.sh --app <old bundle>` should
then fail on exactly the facts recorded as new. The 3.6.11 → 3.7.6 refresh
also showed the release notes are silent on the AppleScript dictionary and
preference keys, both of which changed.

Three consequences shape the code here:

- **The version is read off the bundle, never from Homebrew.** `auto_updates
  true` on the cask means brew installs once and Sparkle takes over; on this
  machine the Caskroom said 3.6.3 while the app said 3.6.11, and says 3.7.3
  while the app says 3.7.6. The house rule
  (`defaults read /Applications/iTerm.app/Contents/Info
  CFBundleShortVersionString` — read the version, never execute the thing) is
  not a stylistic preference here, it is the only correct answer.
- **The stamp is duplicated on purpose.** It lives in `manifest.txt`, in
  `SKILL.md`, and as a `local stamp=` in `iterm2-doctor` — because the doctor
  is deployed to machines with no copy of the skill and has to carry its own.
  `tests/iterm2-doctor.bats` extracts all three from the source and fails if
  they disagree, so a half-done refresh cannot land.
- **`iterm2-doctor` is in the `doctor` aggregator** even though it is not
  per-repo routing like the others: it is the terminal all of them run inside,
  and a stale skill is exactly the silent change `doctor` exists to surface.
  It reports the bundle and version, the stamp comparison, the Caskroom
  channel, the plugin bundles, the prefs/API/startup keys, and **counts, never
  names**, of dynamic profiles and AutoLaunch scripts — those are usually
  named after a host or a client.

- **`claude` compares the two at every attended launch.** `iterm2_skill_drift`
  (beside `iterm2_app_path`) reads `Contents/Info.plist` once with `$(<file)`,
  takes the version from the `CFBundleShortVersionString` string, and takes the
  stamp from the body of `iterm2-doctor` (`functions[iterm2-doctor]`, matching
  the `local stamp=` literal) without running the doctor, so it forks nothing.
  It sets `REPLY` to `iTerm2 <ver> is newer|older than the skill's notes
  (<stamp>): run iterm2-doctor`, or to empty when the versions are equal or
  anything is missing (no app, a binary plist, no match). `claude` prints it as
  a `claude:` stderr line and `claude-doctor` as its `iterm2:` line;
  `git config claude.iterm2-check false` silences both, the same switch as the
  API-cookie line. The `local stamp=` literal must stay one plain
  `local stamp=<version>;` assignment, or the match misses and the check goes
  silent. `tests/claude-profiles.bats` points `ITERM2_APP` at a path that does
  not exist in `setup`, so no test meets the developer's real iTerm2.

Two facts from that research matter to this repo directly. `PrefsCustomFolder`
points at this clone, so `com.googlecode.iterm2.plist` is tracked here — and,
because the clone is where iTerm2 both reads and writes it, the plist is a
**repo-level file in `.chezmoiignore`, never deployed to `$HOME`**. A copy
there would be read by nothing: iTerm2 looks in the custom folder or in its
Preferences domain, and neither is `$HOME`. Worse, iTerm2 writes into that
folder — chezmoi's own source — so every prefs change would ask chezmoi to
re-deploy ~99KB that nothing opens. It is also why a modified
`com.googlecode.iterm2.plist` in `git status` is normal: that is iTerm2
saving, not you. Tracking it at all is safe only because the AI provider key
goes to the **Keychain**, not the plist (the binary says so, and
`verify.sh` checks that sentence is still there), and
because keys prefixed `NoSync*` are excluded from the custom folder (verified:
26 in the live domain, 0 in the tracked copy). And none of
`LoadPrefsFromCustomFolder`, `PrefsCustomFolder`, `NoSync*` or
`EnableAPIServer` is documented anywhere on iterm2.com — they are real keys,
reverse-engineered, and free to change in a point release. Where the docs and
the binary disagree the skill records both and trusts the binary; that
disagreement is half of what makes it worth keeping.

Tests: `tests/iterm2-doctor.bats` (fake `iTerm.app` bundles and a stub
`defaults`; nothing ever touches the real iTerm2 or opens a dialog).
