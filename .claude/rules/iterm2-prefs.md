---
paths:
  - "**/bin/executable_iterm2-prefs"
  - "**/tests/iterm2-prefs.bats"
  - "**/dot_config/iterm2/**"
---

# iterm2-prefs: iTerm2's preferences, composed from fragments

`bin/executable_iterm2-prefs` (deployed to `~/bin/iterm2-prefs`, macOS only)
builds the one preferences file iTerm2 loads out of fragments, the way
`git-allowed-signers` builds `allowed_signers`
(`composed-identity-files.md`). It is a POSIX `sh` wrapper around one
`python3 -I -` heredoc, standard library only, Python 3.9 clean. Exit codes: 0
done, 1 failed or refused, 2 usage or not macOS.

**State of the switch-over.** The mechanism is built, tested and deployed, but
the live cut-over has NOT happened: iTerm2 still loads the tracked
`com.googlecode.iterm2.plist` in the clone, which is still the store. Until
`iterm2-prefs install` runs by hand with iTerm2 quit, `status` reads `store:
folder ...; not the composed folder`, and `dotfiles` prints nothing new
because `compose --auto` is silent when iTerm2 does not load the composed
folder. Prose elsewhere that calls the clone iTerm2's prefs folder is still
true for that reason.

## Three locations, three owners

```
~/.config/iterm2/prefs.d/10-base.plist       public repo (dot_config/iterm2/prefs.d/)
~/.config/iterm2/prefs.d/NN-<name>.plist     an overlay, only keys of its own (optional)
~/.local/state/iterm2/prefs/com.googlecode.iterm2.plist
                                             COMPOSED store, machine-local; iTerm2's
                                             custom folder points at the folder
~/.local/state/iterm2/prefs-sourced.plist    the record: what the sources said at the
                                             last compose
```

Both state paths are outside every git repository. A fragment is a regular XML
plist named `NN-<name>.plist` (two digits, a hyphen, lowercase letters, digits,
`-`, `_`), read in byte order of the name; any other entry in the directory is
skipped and counted. The tests move the paths with `ITERM2_PREFS_FRAGMENTS`,
`ITERM2_PREFS_DIR` and `ITERM2_PREFS_RECORD`; `ITERM2_PREFS_RUNNING=1` stands in
for "iTerm2 is running" (the shell asks `ps` once and passes the answer in).

## Why a three-way merge

iTerm2 is a second writer. With a custom folder, launch drops every syncable
key from the domain and loads the folder's, and quit writes every syncable key
back to the folder. A composer that regenerated the file would undo every
change made in Settings. So `compose` merges per unit against the record:

- the store already equals the sources: nothing;
- the sources moved and iTerm2 did not (store equals the record): apply the
  source value, or delete the key;
- iTerm2 moved it: the unit is **kept** and counted, until `capture` makes a
  source equal to the store or `compose --reset` makes the store equal to the
  sources.

After a compose that writes, the record becomes the sources' values, so a kept
unit stays kept across later source changes. Nothing is lost silently either way.
A profile no fragment lists any more is dropped only when every recorded key of
it was unchanged in iTerm2; otherwise it stays whole.

## The unit, later wins, reserved keys

The unit is one key: `K` (top level), `profile/<Guid>/K`, or on the command
line a whole `profile/<Guid>`. `Guid` is identity, never a unit. A fragment may
set top-level keys, add a profile of its own, or repeat a Guid to set some
keys of a profile another fragment defines. The **later fragment wins** a key
both set, as in `.gitconfig` and opposite to ssh's first-wins; a test pins it by
renaming.

Reserved keys are never composed and never touched; a fragment that sets one
has it ignored, counted and named:

- `Workgroups` and each profile's `Triggers`: `claude-peer install` and iTerm2's
  onboarding write them (`claude-peer.md`), and `claude-peer` reads the custom
  folder from the domain, so it finds the composed store by itself.
- `LoadPrefsFromCustomFolder`, `PrefsCustomFolder`, and every key iTerm2 itself
  does not sync (its exempt list and the `NS`, `SU`, `NoSync`, `UK` prefixes):
  they never reach the folder, so a fragment holding one could not take effect.
- a profile's `Dynamic Profile*` keys: iTerm2 mirrors dynamic profiles into the
  file with an absolute home path; the owner is the Dynamic Profiles file.

Everything else in the store is local: window and tool state, migration latches,
profiles no fragment lists. The composer leaves local keys alone.

## Only while iTerm2 is quit

iTerm2 holds the truth in memory and overwrites the file at quit; a file that
changed under it raises "Settings ... changed since iTerm2 started". So
`compose` and `install` write nothing while iTerm2 runs (as `claude-peer
install` already does). While it runs, `compose` says how many source changes
wait; `status` judges `waiting` and `kept` against the filtered domain then, and
against the store otherwise.

## The verbs and their frozen strings

Tests match these.

- `lint [--public] <file>...`: problems on stderr as `<file>: <problem>`, exit 1
  on any. `--public` adds data and date values, home paths, paths and URLs
  anywhere (no key is exempt: the base leaves `AitermURL` out, since
  `UseRecommendedAIModel` with `AIVendor` already selects the vendor's endpoint,
  and a machine with an endpoint of its own keeps it local or in its overlay's
  fragment), at-signs, and non-empty `Bound Hosts`,
  `Command`, `Initial Text`, `Badge Text`, `Tags`.
- `compose [--auto] [--reset] [--print]`: summary `iterm2-prefs: <a> units
  applied from <n> fragments; <k> kept as changed in iTerm2 (iterm2-prefs
  capture); <i> reserved keys ignored` when any count is non-zero. Running
  without `--auto`: refusal, exit 1. Running with `--auto`: one line only when
  source changes wait, exit 0. Not installed: refusal without `--auto`, silence
  with it. `--print` writes the would-be store to stdout, touches nothing, never
  reads the domain.
- `status [--line]`: lines `store:`, `iterm2:`, `fragments:`, `sourced:`,
  `waiting:`, `kept:`, `ignored:`, `skipped:` (`skipped` only when non-zero;
  `waiting` and `kept` only once installed). `--line` is one of
  `composed, in sync`, `composed, <w> waiting, <k> kept`, `not composed (folder
  <plist>)`, `not composed (folder <plist>, inside a git repository)`, `not
  composed (domain)`. `iterm2-doctor` prints it as `store:`.
- `capture [--from domain|store|<plist>] [--all] [--values] [--owned <fragment>]
  [<unit>...] [--into <fragment> | --file <plist>]`: list mode prints
  `changed|absent|unsourced<TAB><unit><TAB><owner>` rows and a stderr summary;
  write mode (`--into` or `--file`) prints `iterm2-prefs: wrote <n> units to
  <path>; commit it there, then run dotfiles`. It writes only the destination it
  is given, never the store, the record or a deployed fragment. A session uses
  `--file` into its own worktree; `--into` resolves the chezmoi source and is
  the operator's shortcut.
- `install [--dry-run] [--no-seed]`: with iTerm2 quit, seeds the store from the
  old one, lets the sources win every key they set, writes store and record, and
  only then repoints `PrefsCustomFolder` and `LoadPrefsFromCustomFolder`. Before
  anything else it saves the whole domain (`defaults export`, unfiltered, 0600)
  as `prefs-before-install.<UTC time>.plist` beside the record, and stops if it
  cannot. Prints three lines: what iTerm2 now loads, where the saved domain is,
  and the way back, `defaults import` of that file followed by the
  `defaults write` that repoints. The saved file is machine-local and holds every
  key of the domain; it is not a fragment and nothing reads it but that command.
  `--dry-run` prefixes them `would: ` and prints a `differs` row per unit where
  the source value replaces the old store's. It refuses a folder inside a git
  repository, a URL store, and a running iTerm2.

Values are never printed, only unit names (iTerm2 key names and Guids), except
by `capture --values`, which cuts them at 200 characters and shows data values
as `<data N bytes>`.

## Why `dotfiles()` and not chezmoi

`dotfiles()` runs `iterm2-prefs compose --auto` after every overlay has applied,
beside `git-allowed-signers`. Not a chezmoi script, `modify_` or hook, for three
reasons: each overlay is its own chezmoi config and source, so a script in any
one of them composes before the later sources have deployed their fragments
(one apply stale); a `modify_` script would make the store a chezmoi target
evaluated on every `apply`, `diff` and `verify`, when it must not be written
while iTerm2 runs, and it keeps no record for the three-way; and a hook is a
setting of one config file, fires after the public apply and before the overlays,
and runs even with `--dry-run`.

## The public base

`dot_config/iterm2/prefs.d/10-base.plist` holds theme, fonts, key bindings,
the Default profile and the settings the public tools rely on (session
restoration running jobs in servers and restoring window contents, Session
Status kept per peer, the slow-trigger offer declined; startup windows are
left to each machine), extracted with an explicit include list through `capture
--from domain --file`, never by copying the domain. It must pass `iterm2-prefs
lint --public` (no data value, no path or host list, no address); a key outside
the list does not get in by being convenient.

The base's Default profile keeps the Guid it was captured with. On a machine whose
own default profile has another Guid, which is every machine but that one,
`install` adds the base profile beside the existing one and makes it the
default, so Settings > Profiles shows two named Default until one is deleted
there. `install --dry-run` shows what would change first, `install --no-seed`
starts the store from the fragments alone, and the saved domain is the way back
from either.

## What an overlay implements

Optional. It deploys one
`dot_config/iterm2/prefs.d/NN-<name>.plist` (by convention `20-personal`,
`30-work`; `10-` is the public base), adds `.config/iterm2` to its own
`.chezmoiignore` off Darwin, and writes it with `iterm2-prefs capture --file
<its worktree path> <unit>...` from its own session. The peer bar label is not
a fragment key (`Workgroups` is reserved). `docs/private-overlays.md` has the
manual.
