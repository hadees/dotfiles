# Dynamic Profiles

Profiles defined by a file on disk instead of by the Settings UI. The right
tool for generating profiles from a host list, a repo, or a config-management
run.

Docs: <https://iterm2.com/documentation-dynamic-profiles.html>
Available since iTerm2 2.9.20140923.

## The directory and the reload

```
~/Library/Application Support/iTerm2/DynamicProfiles/
```

iTerm2 creates it at startup, and: "While iTerm2 runs, it monitors the
contents of that folder. Any time the folder's contents change, **all** files
in it are reloaded."

That is a whole-folder reload, not a per-file one. The consequence is the
thing that catches people:

> "All files in the folder must be valid property lists. If any is malformed,
> then **no changes will be processed**."

One bad file and every dynamic profile stops updating, silently. Errors go to
Console.app, nowhere else. Write to a temp file and move it into place rather
than editing in the folder, and validate before installing:
`plutil -lint <file>`.

## Format

**Apple Property Lists** — "JSON, XML, or in binary". Not JSON specifically,
though JSON is the convenient choice. **No particular file extension is
required.**

Minimal, and these two keys are the only required ones:

```json
{
  "Profiles": [
    {
      "Name": "Example",
      "Guid": "ba19744f-6af3-434d-aaa6-0a48e0969958"
    }
  ]
}
```

- `Guid` — "a globally unique identifier. It is used to track changes to the
  profile over time. No other profile should ever have the same guid."
  `uuidgen` is the suggested source. **A dynamic profile whose `Guid` equals
  an existing regular profile's `Guid` is ignored** — silently.
- `Name` — as shown in the Profiles window and in Settings.

Every other profile preference iTerm2 supports may appear as a key. To
discover a key name for a setting you can see: Settings > Profiles > select
the profile > **Other Actions** > **Save Profile as JSON**, and read the key
out of the result. That beats guessing.

## Keys confirmed present in the 3.6.11 binary

```
Guid                          Name                     Tags
Command                       Custom Command           Working Directory
Custom Directory              Initial Text             Badge Text
Dynamic Profile Parent Name   Dynamic Profile Parent GUID
Dynamic Profile Filename      Rewritable
```

`Custom Command` and `Custom Directory` are the mode switches: set
`"Custom Command": "Yes"` for `Command` to be honoured, and
`"Custom Directory": "Yes"` for `Working Directory`. `Custom Directory` also
takes `"Recycle"` (reuse the previous session's directory) and `"Advanced"`.

`Dynamic Profile Filename` is written by iTerm2, not by you — it records which
file a profile came from.

## Inheritance

```json
{ "Dynamic Profile Parent Name": "Base" }
{ "Dynamic Profile Parent GUID": "ba19744f-6af3-434d-aaa6-0a48e0969958" }
```

- Parent by **name** is the readable form. Names are not unique; if no profile
  matches, **the default profile is used instead** — quietly, so a typo gives
  you a profile that works but inherits from the wrong place.
- Parent by **GUID** was added in 3.4.9 and **takes precedence** over the name
  form when both are present.
- Anything you do not specify comes from the parent (or from the default
  profile).

**Load order is alphabetical by filename**, and within a file it is list
order. This only matters when one dynamic profile is another's parent: the
parent must load first. Prefixing filenames (`00-base.json`,
`10-hosts.json`) is the usual fix.

## Editing, and the one-way rule

> "The only way to change a dynamic profile is to modify its parent profile or
> to modify the property list file. If you change its properties through the
> Settings UI those changes will not be reflected in the property list."

So the file is authoritative and the UI is a dead end — *unless* you opt in:

```json
{ "Rewritable": true }
```

which "means iTerm2 can make changes to the file on disk to reflect changes
made in the settings UI." `Rewritable` is present in the 3.6.11 binary. Do not
set it on a generated file: the next generation run will clobber whatever the
UI wrote.

## Tags

Every dynamic profile automatically gets the tag **`Dynamic`**. A `Tags` array
key also works and is present in the binary, but is undocumented — the
documentation page's only sentence about tags has the word "tag" missing from
it entirely ("The *Dynamic* will automatically be added to all Dynamic
Profiles").

## Badges

`Badge Text` holds an **interpolated string**, so a profile can carry a live
label:

```json
{ "Badge Text": "\\(user.project)@\\(hostname)" }
```

(In JSON the backslash needs escaping; the value iTerm2 sees is
`\(user.project)@\(hostname)`.)

Interpolation uses Swift-ish `\( … )` syntax over the variable scopes. Two
rules make or break it:

- **The badge is evaluated in the session's context**, so session variables
  are bare: `\(hostname)`, `\(path)`, `\(jobName)`. The `user.` prefix is
  required only for user-defined ones. The official badges example writes
  `\(session.name)`, which contradicts the variables reference — prefer the
  bare form.
- Titles are evaluated in *their* context. A window title reaching for the
  current session needs the full path:
  `\(currentTab.currentSession.hostname)`.

`user.*` variables are set from the shell (`iterm2_set_user_var`, see
`references/shell-integration.md`), from AppleScript, or from Python. A badge
can also be set at runtime:

```bash
printf "\033]1337;SetBadgeFormat=%s\a" "$(printf '%s' '\(user.gitBranch)' | base64)"
```

## Triggers in a dynamic profile

Highlight triggers normally serialise their colours as an opaque blob. In a
dynamic profile you may write `{#rrggbb,#rrggbb}` instead — foreground first,
background second. Either half may be empty: `{#ff0000,}` sets only the
foreground.

(The docs' own example transposes this as `#{ff0000,}`, two sentences after
defining the `{#…}` form. The braces-first form is the one that matches the
definition.)

## Docs vs. the binary (3.6.11)

| Claim | Reality |
| --- | --- |
| Tags | The page's only tag sentence is missing the word "tag". A `Tags` key exists in the binary but is undocumented. |
| Highlight colour syntax | The page defines `{#rrggbb,#rrggbb}` then exemplifies `#{ff0000,}`. |
| The page's ssh example JSON | Has trailing commas. Property-list parsers may accept it; `jq` and `plutil -lint` will not. |
| "Files ... formatted as Apple Property Lists" vs. everyone calling them JSON | Both are right; JSON is one plist encoding. XML and binary plists work too. |
