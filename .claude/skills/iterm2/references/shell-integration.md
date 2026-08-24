# Shell integration, utilities, and the interactive feature surface

## Shell integration

Compatible with bash, fish (2.3+), tcsh, xonsh (iTerm2 3.6.10+), and zsh.

Four ways in:

1. **Automatic (3.5+)** — Settings > Profiles > General > Command >
   *Load shell integration automatically*. Available when Command is SSH, or
   is Login Shell and the shell is supported. Nothing to install.
2. **Menu item** — iTerm2 > Install Shell Integration. Runs
   `curl -L https://iterm2.com/shell_integration/install_shell_integration.sh | bash`,
   or offers an Internet-Free Install. It asks first whether to also install
   the Utilities Package.
3. **By hand** — download `https://iterm2.com/shell_integration/<shell>`:

   | shell | file | sourced from |
   | --- | --- | --- |
   | bash | `~/.iterm2_shell_integration.bash` | end of `~/.bash_profile` or `~/.profile` |
   | zsh | `~/.iterm2_shell_integration.zsh` | end of `~/.zshrc` |
   | fish | `~/.iterm2_shell_integration.fish` | end of `~/.config/fish/config.fish` |
   | tcsh | `~/.iterm2_shell_integration.tcsh` | end of `~/.login` |
   | xonsh | `~/.config/xonsh/rc.d/iterm2.xsh` | auto-loaded |

   At the **end**, because other scripts may overwrite what it needs
   (`PROMPT_COMMAND`, and the prompt itself).
4. **Triggers** — for hosts you cannot install on, e.g. root. Actions
   *Report User & Host*, *Report Directory*, *Prompt Detected*, with **Instant
   enabled** so they fire before the newline. For a prompt like
   `user@host:/home/user%`:

   ```
   ^(\w+)@([\w.]+):.+%      Report User & Host   \1@\2
   ^\w+@[\w.]+:([^%]+)%     Report Directory     \1
   ```

Under `sudo -s`, source it explicitly:
`test $(whoami) == root && source "$HOME/.iterm2_shell_integration.bash"`.

### What it buys

Marks (a blue triangle at each prompt, **Cmd-Shift-Up/Down** to navigate, red
when the command failed, right-click for the return code); Select Output of
Last Command; alert when a command finishes (**Cmd-Opt-A** for the next mark);
command info — status, working directory, running time; right-click download
of a filename; option-drag upload over scp; command history
(**Shift-Cmd-;**) and Autocomplete (**Cmd-;**); Recent Directories by frecency
(**Cmd-Opt-/**); Automatic Profile Switching; a prompt guaranteed to start at
column 1 even after a command that ate the newline; Offscreen Command Line;
Auto Composer; Command Selection.

With *Save copy/paste history and command history to disk* on, history
survives restarts — up to 200 commands per user/hostname.

Custom mark placement in a multi-line prompt: zsh `%{$(iterm2_prompt_mark)%}`,
bash `\[$(iterm2_prompt_mark)\]`, fish `iterm2_prompt_mark` inside
`fish_prompt`. Not supported in tcsh. If a theme owns `PS1`, set
`export ITERM2_SQUELCH_MARK=1` *before* sourcing the integration.

### Limitations

"By default, shell integration does not work with tmux or screen." For tmux,
`export ITERM_ENABLE_SHELL_INTEGRATION_WITH_TMUX=1` before loading it. "It
works well with tmux integration (`tmux -CC`) but not with the regular tmux
UI."

File transfer: iTerm2 links libssh2 and does **not** shell out to `scp`. It
honours `known_hosts`, defaults to `~/.ssh/id_rsa|id_dsa|id_ed25519|id_ecdsa`,
and understands only `Host`, `HostName`, `User`, `Port`, `IdentityFile` from
ssh_config, read in the order
`~/Library/Application Support/iTerm/ssh_config` (note: no `2`), `~/.ssh/config`,
`/etc/ssh_config`. With SSH Integration in use, transfers go over its framing
protocol instead.

### User variables

Define `iterm2_print_user_vars` after sourcing the integration:

```zsh
iterm2_print_user_vars() {
  iterm2_set_user_var gitBranch "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
}
```

Those land in the `user.` scope and are what badges, titles and status-bar
interpolated strings read. The raw form is
`OSC 1337 ; SetUserVar=name=<base64 value> ST`; the docs recommend the helper
over sending it yourself. Read one back with `it2getvar session.name`.

## The it2* utilities

The Utilities Package installs shell scripts into `$HOME/.iterm2/` and adds
aliases at the bottom of `$HOME/.iterm2_shell_integration.$SHELL`. Most work
without shell integration. Source:
<https://github.com/gnachman/iTerm2-shell-integration/tree/main/utilities>

**Seventeen** ship inside the 3.6.11 bundle, at
`/Applications/iTerm.app/Contents/Resources/utilities/` — the authoritative
list, and each is checked by `scripts/verify.sh`:

```
imgcat   imgls    it2api        it2attention  it2cat   it2check
it2copy  it2dl    it2getvar     it2git        it2profile
it2setcolor       it2setkeylabel  it2ssh      it2tip   it2ul
it2universion
```

**Eleven of those are documented**; `it2api`, `it2cat`, `it2git`,
`it2profile`, `it2ssh` and `it2tip` appear nowhere on iterm2.com. They exist
and they work; they are just unsupported surface.

| Command | What it does |
| --- | --- |
| `imgcat file...` | Displays images inline, "all standard image formats, including animated GIFs". Also `cat img \| imgcat`. |
| `imgls [file...]` | `ls` with thumbnail previews. |
| `it2attention start\|stop\|fireworks` | Bounce the dock icon while another app is active; `fireworks` shows an explosion at the cursor. |
| `it2check` | Exit 0 if the terminal is iTerm2. |
| `it2copy [file]` | Copy to the pasteboard, works over ssh. Needs Settings > General > *Applications in terminal may access clipboard*. |
| `it2dl file` | Download to `~/Downloads` from a remote host. |
| `it2getvar session.name` | Read a session variable. |
| `it2setcolor` | Three forms, below. |
| `it2setkeylabel` | Touch Bar function-key labels, below. |
| `it2ul [dest [tar flags]]` | Upload; iTerm2 tars, gzips and base64s the selection, the script untars with `-xzfC`. Extra args go after a lone `-`. |
| `it2universion set 8\|9 \| push [name] \| pop [name]` | Set the session's Unicode width version. |

```
it2setcolor name color [name color ...]      # it2setcolor fg fff
   names:  fg bg bold link selbg selfg curbg curfg underline tab
           black red green yellow blue magenta cyan white
           br_black br_red ... br_white
   color:  RGB | RRGGBB | cs:RGB | cs:RRGGBB    (cs = srgb | rgb | p3; srgb default)
it2setcolor preset 'Light Background'
it2setcolor tab default

it2setkeylabel set F1..F20 Label
it2setkeylabel set status Label
it2setkeylabel push [name]     # a name beginning with "." keeps current labels
it2setkeylabel pop  [name]     # convention: push "<appname><random>", pop the same
```

## Escape codes

The proprietary set is `OSC 1337 ; … ST`:

```
SetMark                             CurrentDir=[dir]
RemoteHost=[user]@[fqdn]            (synonym: OSC 7 ; file://host/path ST)
SetUserVar=[key]=[base64]           SetBadgeFormat=[base64]
SetProfile=[profile name]           SetKeyLabel=[key]=[value]
RequestAttention=[value]            Copy=:[base64]
UnicodeVersion=[n]                  File=[args]
ClearCapturedOutput                 Custom=id=[secret]:[pattern]
ShellIntegrationVersion=[Pn];[Ps]   (the one-argument form is deprecated)
```

Plus the FinalTerm semantic prompt codes shell integration actually emits:
`OSC 133 ; A ST` prompt, `; B` command start, `; C` command executed,
`; D ; [Ps] ST` command finished with exit status.

`SetBadgeFormat` is missing from the escape-codes page; it is documented only
on the badges page.

## Badges

A large label in the top right of a session, holding an **interpolated
string** so it can show live state. Initial value: Settings > Profiles >
General > Badge. Colour: Settings > Profiles > Colors. Font and size: the
*Edit…* next to the Badge field.

```bash
printf "\e]1337;SetBadgeFormat=%s\a" \
  "$(printf '%s' '\(session.name) \(user.gitBranch)' | base64)"
```

Evaluated in the session's context, so plain session variables need no prefix
(`\(hostname)`, `\(path)`). The official example's `session.` prefix
contradicts the variables reference — the bare form is the documented one.
Full variable list: <https://iterm2.com/documentation-variables.html>.

## Triggers

Settings > Profiles > (profile) > **Advanced** > Triggers > Edit > `+`. Each
has a regex, an action, an optional parameter, and an Instant flag.

Matching, verbatim: ICU regular expressions; text written to the screen
including BEL is matched; **one line at a time**; by default on a newline or a
cursor-moving escape code; and "If a line is very long, then only the last
three wrapped lines are used" — raisable in Advanced Settings > *Number of
screen lines to match against trigger regular expressions*.

**Instant** fires once per line as soon as the match occurs, without waiting
for a newline — added for the password-manager trigger, since password prompts
have no newline. It makes greedy patterns like `.*` match less than they
otherwise would.

The 26 actions in 3.6.11: Annotate, Bounce Dock Icon, Capture Output, Change
Style, Fold to Named Mark, Highlight Line, Highlight Text, Inject Data, Invoke
Script Function, Make Hyperlink, Open Password Manager, Post Notification,
Prompt Detected, Report Directory, Report User & Host, Ring Bell, Run Command,
Run Coprocess, Run Silent Coprocess, Send Text, Set Mark, Set Named Mark, Set
Title, Set User Variable, Show Alert, Stop Processing Triggers.

Parameter substitutions (Run Command, Run Coprocess, Post Notification, Send
Text, Show Alert): `\0` whole match, `\1`–`\9` capture groups, `\a` BEL, `\b`
backspace, `\e` ESC, `\n` newline, `\r` carriage return, `\t` tab, `\xNN` hex.
(The docs describe `\r` as "A linefeed character" — wrong; `\n` is the
linefeed.)

## Status bar

Settings > Profiles > Session > **Status bar enabled** > **Configure Status
Bar**. Its *position* is elsewhere: Settings > Appearance > **Status Bar
Location**.

Components: Battery Level, CPU Utilization, Memory Utilization, Network
Throughput; Current Directory, Host Name, User Name, Job Name, git state;
Clock, Custom Action; Composer, Search Tool, Filter, Action, Snippet,
Triggers; Empty Space, Fixed-size Spacer, Spring; Interpolated String and Call
Script Function (the Python hooks — see `references/python-api.md`).

Per-component: background and text colour, **Priority** (default 5; lowest
priority is dropped first when space runs out), Compression Resistance (tight
packing only, "acts like a spring constant"), Size Multiple (stable
positioning only), minimum and maximum width in points.

Two layout algorithms: *Tight Packing* — springs, drop lowest priority first,
highest density "at the cost of their jumping around whenever a value
changes"; *Stable Positioning* — every component gets the base width times its
size multiple. **Stable Positioning is the default.**

The git component polls on a configurable interval and runs git "in a sandbox
that does not allow writing to the filesystem outside of `/tmp` and `/var` to
avoid side-effects" — worth knowing before wondering why a git hook did not
fire.

## Hotkey windows

Three kinds of hotkey:

- **Toggle All Windows** — Settings > Keys > *Show/hide all windows with a
  system-wide hotkey*. Does not move them.
- **Session Hotkeys** — Session > Edit Session, bottom of the General tab.
- **Dedicated Hotkey Windows** — a window bound to a profile, opened and
  closed by its hotkey. Create with Settings > Keys > *Create a Dedicated
  Hotkey Window*, which makes a profile called "Hotkey Window". Reconfigure at
  Settings > Profiles > Keys > *Configure Hotkey Window*; add more under
  *Additional Hotkeys*. Multiple hotkeys per profile, one hotkey across
  several profiles, and double-tapping a modifier are all allowed.

Its settings: **Pin hotkey window** (stay open when focus moves away;
otherwise it auto-hides), **Automatically reopen on app activation**,
**Animate showing and hiding**, **Floating window** (appears over other apps'
full-screen windows when the profile's Window > Space is All Spaces; overlaps
the dock), **On Dock icon click**.

From AppleScript: window properties `is hotkey window` and `hotkey window
profile`, commands `reveal` / `hide` / `toggle hotkey window`, and
`create hotkey window with profile "name"` (the profile must already have a
hotkey).

## tmux integration (`tmux -CC`)

`tmux -CC` starts a tmux session whose windows are **real iTerm2 windows**.
When iTerm2 quits or the ssh connection drops, tmux keeps running; reconnect
and `tmux -CC attach` reopens them in the same state.

Only `tmux -CC` and `tmux -CC attach` are documented. The widely used
`tmux -CC new-session -A -s <name>` is not, though it works.

The gateway terminal shows a control-mode menu:

```
esc  Detach cleanly.
  X  Force-quit tmux mode.
  L  Toggle logging.
  C  Run tmux command.
```

If `esc` does nothing the tmux client may have crashed — press `X`, then
`stty sane` if the terminal is left in a strange state.

Mapping: closing a session/tab/window kills the tmux session or window;
splitting a pane runs `split-window`; resizing a pane runs `resize-pane`;
resizing a window tells tmux the client size changed. Because "windows are
never larger than the smallest attached client", **all tmux windows and tabs
have the same number of rows and columns**, and a grey area on the right or
bottom means the physical window exceeds the maximum tmux window size.

Limitations, complete: a tab with a tmux window may not also hold non-tmux
split panes; and a tab with split panes may show empty areas, because tmux
wants every window the same size but the divider is not exactly one cell.

Configuration is Settings > General > tmux: how unseen windows open on attach;
automatically bury the client session; *Use "tmux" profile rather than profile
of connecting session* (off by default since 3.3, so the connecting session's
profile is used); whether the status bar shows tmux content or native
components; **pause a pane if it would take more than N seconds to catch up**
(tmux 3.2 and later only — a paused pane stops receiving data and may lose it
forever), warn before pausing, unpause automatically, mirror the tmux paste
buffer to the local clipboard.

**No minimum tmux version is stated anywhere in the docs**; 3.2 is the only
version mentioned and only for pausing.

## Docs vs. the binary (3.6.11)

| Claim | Reality |
| --- | --- |
| The utilities page lists the utilities | It documents 11; the bundle ships 17. `it2api`, `it2cat`, `it2git`, `it2profile`, `it2ssh`, `it2tip` are undocumented. |
| `it2ul` "specifies the directory to place downloaded files" | It uploads. Wrong verb on the page. |
| The `it2dl` usage block | Stranded at the bottom of the page under the wrong heading. |
| Triggers: `\r` is "A linefeed character" | It is a carriage return. |
| `it2getvar`: "For a list of session variables, see the Badges page" | The list moved to documentation-variables.html. |
| `SetBadgeFormat` | Missing from the escape-codes reference. |
| SCP config path `~/Library/Application Support/iTerm/ssh_config` | Missing the `2`; everything else in the app uses `iTerm2`. |
| tmux minimum version | Not stated at all. |
