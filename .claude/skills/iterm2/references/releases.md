# How iTerm2 ships, and how to find what changed

This is the file the version nudge points at. When `verify.sh` or
`iterm2-doctor` says the installed version has moved past the stamp, this is
how to find out what that means.

## The one link that matters

<https://iterm2.com/downloads.html>

It is the **complete changelog** — 95 stable versions back to 2.1.1 and 272
beta builds, each with its full release notes in a collapsed block plus a
PGP-signed SHA-256 of the zip. Expand the entries between the stamp and the
installed version.

Do not go looking anywhere else first:

- **GitHub publishes no releases.** `gnachman/iTerm2` has an empty releases
  list.
- **There is no CHANGELOG file** in the repo. The only version-shaped file at
  the root is `version.txt`, containing the build template `3.7.%(extra)s`.
- **<https://iterm2.com/news.html> is stale** — its most recent entry is the
  3.5 release in May 2024. It carries major releases and security advisories
  only, and has not been touched for the 3.6 line. Absence of news there is
  not evidence that nothing changed.

The page is 1.25 MB with every changelog inside collapsed blocks, so a
summarising fetch will truncate it and may report sections that are plainly
there as missing. Fetch the raw HTML and search it.

## Channels

Four, all served from iterm2.com. The site's own headings are *Stable
Releases*, *Test Releases*, *Older Stable Releases*, *Older Test Releases*,
*Nightly Builds*.

| Channel | Site's wording | Zip | Appcast |
| --- | --- | --- | --- |
| Stable | "update rarely but have no serious bugs" | `/downloads/stable/iTerm2-3_6_11.zip` | `appcasts/final_modern.xml` |
| Beta ("Test Releases") | "update many times a year and are occasionally unstable" | `/downloads/beta/iTerm2-3_7_0beta11.zip` | `appcasts/testing_modern.xml` |
| Nightly | "made at midnight Pacific time on days where a change was committed" | `/downloads/nightly/iTerm2-3_7_20260823-nightly.zip` | `appcasts/nightly_modern.xml` |

The project's word for beta is **"test release"** — which is why the
preference key is `CheckTestRelease` and the feed is `testing_modern.xml`.
"Beta" appears only in the URL path and the version string. Legacy feeds
(`final.xml`, `testing.xml`, `nightly.xml`, `canary.xml`, `legacy_*.xml`)
still resolve but are pre-Sparkle-2.

`https://iterm2.com/nightly/latest` is a 302 to the current nightly zip — a
stable endpoint for "what is the newest nightly".

Homebrew has all three, mutually `conflicts_with`, all installing to the same
`/Applications/iTerm.app`:

```
iterm2           stable, depends_on macos: :monterey, auto_updates true
iterm2@beta      depends_on macos: :ventura,          auto_updates true
iterm2@nightly   depends_on macos: :ventura,          no auto_updates
```

Note the stable and beta casks deliberately **do not** livecheck iterm2.com's
appcast; both point at the website repo instead
(`raw.githubusercontent.com/gnachman/iterm2-website/master/source/appcasts/...`)
to work around an upstream issue. Nightly uses `iterm2.com/nightly/latest`
with a header-match strategy.

## Reading a version number

| Shape | Channel | Example |
| --- | --- | --- |
| `MAJOR.MINOR.PATCH` | stable | `3.6.11` |
| `MAJOR.MINOR.0betaN` | beta | `3.7.0beta11` |
| `MAJOR.MINOR.YYYYMMDD-nightly` | nightly | `3.7.20260823-nightly` |

`CFBundleShortVersionString` and `CFBundleVersion` are the same string; there
is no separate build number.

**The beta line is always one minor ahead of stable.** While 3.6.x is stable,
betas are 3.7.0betaN — exactly as 3.5.0betaN ran alongside stable 3.4.x. So a
`3.7.x` on a machine means the beta channel, *not* a newer stable, and the
skill stamp comparison should be read with that in mind.

Zip filenames underscore the dots (`3.6.11` becomes `iTerm2-3_6_11.zip`), and
the nightly cask drops the `-nightly` suffix (`3_7_20260823`).

Minimum macOS has diverged per channel: stable 3.6.11 wants 12.4+
(`LSMinimumSystemVersion`), beta and nightly want 13+.

## Diffing two versions

Mostly you cannot, with git. All ~1,200 tags on `gnachman/iTerm2` are
`v<YYYYMMDD>-nightly`; there are **no stable tags and no beta tags** (one
stray `vv3.4.0beta13` aside).

- Nightly to nightly works:
  `https://github.com/gnachman/iTerm2/compare/v20260801-nightly...v20260823-nightly`
- Stable to stable, e.g. 3.6.3 to 3.6.11, has no tag pair. Use the per-release
  notes on downloads.html, or date-bounded commits on `master`.
- Per-version branches (`3.0.x`, `3.1.1`, `3.3.1`) exist but stop long before
  3.4.

The Sparkle release-note text files are **latest-only deltas**, not archives:
`appcasts/full_changes.txt` (stable, a handful of lines about the newest
release), `appcasts/testing_changes3.txt` (headed "Changes since <previous
beta>"), `appcasts/nightly_changes.txt`. `appcasts/canary_changes.txt` is dead,
frozen at 1.0.0 from 2012.

Cheapest "is anything newer" probe is the appcast the app itself would use —
one small XML, read the `sparkle:version` attribute on the `<enclosure>`:

```bash
curl -s https://iterm2.com/appcasts/final_modern.xml | grep -o 'sparkle:version="[^"]*"' | head -1
```

## Where the project actually lives

- Code: <https://github.com/gnachman/iTerm2> — `master`, active, pushed daily.
  No releases, no changelog.
- **Bug tracker and wiki: GitLab**, not GitHub —
  <https://gitlab.com/gnachman/iterm2>. The website redirects a dozen help
  URLs into its wiki, and some documentation (the API security model, the
  AppleScript commands that bridge to the Python API) exists *only* there.
- Website source, if you want the appcasts under version control:
  <https://github.com/gnachman/iterm2-website>, appcasts in `source/appcasts/`.
  Its `source/3.6/downloads.md` and `source/3.7/downloads.md` are **stale**;
  the live page is generated and ahead of the committed markdown. Always fetch
  the live page.
- User forum: <https://groups.google.com/g/iterm2-discuss>. Q&A, not a release
  feed.
- Shipping mechanism: **Sparkle**, one appcast per channel.

## How the updater picks its feed

In the app's `Info.plist` (iTerm2's own keys, not Sparkle's):

```
SUFeedURLForFinal    https://iterm2.com/appcasts/final_modern.xml
SUFeedURLForTesting  https://iterm2.com/appcasts/testing_modern.xml
```

At launch iTerm2 reads `CheckTestRelease` (user domain, default `NO`), picks
one of those two, appends a random `?shard=N` for staged rollout, and writes
the result into the **user-defaults `SUFeedURL`** that Sparkle actually reads.
Sparkle's own automatic-check key is `SUEnableAutomaticChecks` (default
`YES`). Both feed keys are checked by `scripts/verify.sh`.

Consequences worth remembering:

- The user-domain `SUFeedURL` is an *output*. Setting it by hand is pointless;
  it is rewritten at the next launch.
- Toggling "Check for test releases" re-runs that immediately.
- Because a shard is random per install, two machines can legitimately be
  offered different versions on the same day.
- `SUFeedAlternateAppNameKey = iTerm` is set because this is a fork of
  Sparkle: a zip containing an `iTerm` directory still updates the bundle.

## Why the Homebrew version disagrees with the app

`auto_updates true` on the cask means Homebrew installs it once and Sparkle
takes over. On this machine the Caskroom directory says **3.6.3** while the
bundle says **3.6.11**. Homebrew is not wrong — it is recording what it
installed — but it is the wrong thing to ask.

Always:

```bash
defaults read /Applications/iTerm.app/Contents/Info CFBundleShortVersionString
```

`iterm2-doctor` prints both, labelled, for exactly this reason.
