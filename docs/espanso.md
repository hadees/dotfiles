# Espanso (text expansion)

`cask 'espanso'` — a text expander whose entire configuration, snippets
included, is plain YAML in one directory. That property is the reason it was
chosen over Raycast/TextExpander/Keyboard Maestro: the others keep snippets in
an internal store that git can only ever hold a *dump* of (Raycast's snippet
import is additive and duplicate-skipping, so a repo can never be
authoritative; Keyboard Maestro's macro archive is a plist that diffs badly).
With espanso the tracked files *are* the files it reads.

So the config directory is **its own private repo**, cloned to `~/code/espanso`
and symlinked into place:

    ln -s ~/code/espanso "$HOME/Library/Application Support/espanso"

It is deliberately not a chezmoi target and not part of any overlay. Espanso
writes into its own config dir (it puts installed packages in
`$CONFIG/match/packages`), which fights chezmoi's ownership model and would
show up as permanent drift; and snippets accumulate project and client names
over time, which this public repo must never carry. Nothing here depends on
that repo existing — a machine without it just has no snippets.

Facts that shape the setup:

- **The symlink must exist before espanso's first launch.** Otherwise espanso
  creates its own config directory and you have to delete it before linking.
- **`backend: Clipboard` is load-bearing**, not a preference. The default
  keystroke backend delivers a newline as a literal Return keypress; in a
  browser chat UI Return *submits the form*, so a multi-line prompt snippet
  fires off as several half-written messages. The same keystroke path is
  behind espanso's long-standing auto-indent mangling in Vim/Neovim (issues
  #760, #962). Pasting hands the whole body over in one shot.
- **macOS config lives under `~/Library/Application Support/espanso`**, not
  `~/.config/espanso`. `espanso path` prints all three directories (config,
  packages, runtime) and is the fastest way to confirm what it is actually
  reading.
- **Two bracket syntaxes, easily confused.** `[[field]]` works *only* inside a
  form; variables substituted into a `replace:` string use `{{var}}`. A form's
  fields are addressable afterwards as `{{form1.<field>}}` — which is what
  `espanso match list` shows, and that command parses the config without the
  daemon running, so it doubles as a syntax check.
- **Per-app scoping** uses `filter_exec` on macOS. `filter_title` matches the
  app *identifier* there rather than the window title, and `filter_class` is
  effectively Windows/Linux-only.
- **Upgrades can silently break triggers.** Espanso's code-signing certificate
  changed maintainers while the bundle id stayed `com.federicoterzi.espanso`,
  which confuses macOS into keeping a stale TCC entry: the daemon runs, the
  search bar works, and no trigger fires. Fix is
  `sudo tccutil reset Accessibility com.federicoterzi.espanso` (sometimes
  Input Monitoring too), then re-grant. Fresh installs of 2.3+ are unaffected.

Not in Ubuntu's repos; on Linux it is a `.deb` from the project's GitHub
releases, so `packages-apt.txt` only carries a note.
