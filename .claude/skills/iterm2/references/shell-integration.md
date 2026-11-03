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

3.7.5 tells a local terminal from a remote one by **machine identity**, not
hostname, so drag-and-drop paths and "is this local" logic work over a VPN or
Tailscale — but only after reinstalling shell integration (iTerm2 > Install
Shell Integration), since the scripts carry the new report.

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

**Nineteen** ship inside the 3.7.6 bundle, at
`/Applications/iTerm.app/Contents/Resources/utilities/` — the authoritative
list, and each is checked by `scripts/verify.sh`:

```
cc-status  imgcat   imgls    it2      it2api        it2attention  it2cat
it2check   it2copy  it2dl    it2getvar     it2git   it2profile
it2setcolor         it2setkeylabel  it2ssh      it2tip   it2ul
it2universion
```

3.7 added `it2` and `cc-status`, both compiled Swift rather than scripts (see
below and `references/session-status.md`). Of the seventeen 3.6.11 scripts
only three changed: `it2check` drains its reply with a timed read under
bash 4+, `it2git` gained line and file counts, and `it2ssh` looks for a
second instance's socket (`IT2_SUITE`).

**Eleven are documented**; `it2api`, `it2cat`, `it2git`, `it2profile`,
`it2ssh` and `it2tip` appear nowhere on iterm2.com, and `it2` and
`cc-status` only in the release notes. They exist and they work; they are
just unsupported surface.

### `it2`, the 3.7 CLI

"iTerm2 CLI - Control iTerm2 from the command line." Shell integration puts it
on `PATH`, and it works on hosts reached through SSH Integration. It talks to
the Python API (one connection per command), so the API must be enabled.
Subcommand groups: `app`, `window`, `tab`, `session`, `profile`, `monitor`,
`auth`, `notify` (push to a paired Companion phone), plus shortcuts (`ls`,
`new`, `newtab`, `run`, `send`, `clear`) and `alias`/`load` from its own
config file (`it2 config-path`). `it2 <group> --help` lists the verbs; the
`session` group is the big one — `list` (`--format '<interpolated string>'`
since 3.7.5), `send`, `run`, `read`, `capture`, `split`, `focus`,
`set-name`, `get-var`/`set-var`, `set-color`, and the status verbs in
`references/session-status.md`. What it cannot do: open the toolbelt or pick
a toolbelt tool.

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
`; D ; [Ps] ST` command finished with exit status. 3.7 extends them: an
`aid=` parameter nests prompts (shell integration inside a nested shell), and
`A;k=s|c|r` marks secondary, continuation and right prompts so they are not
counted as typed input.

3.7 additions to `OSC 1337`, all new strings in the binary:

```
Button=type=custom;code=N;icon=…    an in-terminal button (SF Symbol icon)
UpdateBlock=id=…;action=fold|unfold fold or unfold a block
SetProfileProperty=<name>=<base64 JSON>[;…]   change a profile key at runtime
SetWindowFrame=x;y;w;h              (3.7.5)  ReportWindowFrame  ReportScreenFrames
SetColors=badge=i:3                 (3.7.5) palette indexes as colours
```

And two new OSC numbers, both for status: `OSC 21337` (one status per
session) and `OSC 7501` (the Program Status Protocol, several tasks per
program). Both are in `references/session-status.md`. Outside the OSC space,
3.7 also speaks DECSET 2031 / DSR 996–997 (light/dark detection), dual-mode
SGR colours (`CSI 38:12:…`), double-width and double-height lines, and the
Kitty drag-and-drop protocol.

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

3.7 adds **Set Tab Status**, **Set Profile Setting** (3.7.5), and the
workgroup actions (**Enter Workgroup** and its exit, each with a browser
variant: classes `EnterWorkgroupTrigger`, `ExitWorkgroupTrigger`,
`EnterWorkgroupBrowserTrigger`, `ExitWorkgroupBrowserTrigger`). It also
changes what a trigger can be:

- **Event triggers** fire on an event rather than on output — session end, a
  hostname change, Job Started / Job Ended, a session variable changing to a
  value matching a regex.
- A trigger can be given a **job**, and is then active only while that job
  runs.
- Triggers export and import as `.it2triggers` files.
- The regex defines what counts as a word character, and NULs are matched as
  spaces.

Parameter substitutions (Run Command, Run Coprocess, Post Notification, Send
Text, Show Alert): `\0` whole match, `\1`–`\9` capture groups, `\a` BEL, `\b`
backspace, `\e` ESC, `\n` newline, `\r` carriage return, `\t` tab, `\xNN` hex.
(The docs describe `\r` as "A linefeed character" — wrong; `\n` is the
linefeed.)

Two actions are worth following up elsewhere: **Capture Output** feeds the
Toolbelt tool of the same name, which is what turns a build log into
clickable errors, and *Report User & Host* / *Report Directory* are how you
get shell-integration behaviour — and therefore Automatic Profile Switching —
on a host you cannot install anything on. Both are in
`references/workflow.md`.

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

3.7 additions: an optional separator line between the status bar and the
terminal, a *Copy* item on every component's menu, a proxy icon on Current
Directory (3.7.5), and in an Interpolated String component an undefined
variable shows as `[undef: x]` — write `\(x?)` to treat it as empty.
Interpolated strings can do arithmetic and comparisons since 3.7.0, and
colour and checkbox settings can be bound to expressions.

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

3.7 leans on newer tmux for its additions: bracketed-paste and per-pane
`modifyOtherKeys` state restored on attach (tmux 3.5+), floating panes (3.7+,
moving them 3.8+), and tmux encoding keys itself (3.9+). Session Status rows
appear for Claude Code in tmux-integration panes, never in plain tmux.

## Docs vs. the binary (3.6.11, re-checked on 3.7.6)

| Claim | Reality |
| --- | --- |
| The utilities page lists the utilities | It documents 11; the bundle ships 19. `it2api`, `it2cat`, `it2git`, `it2profile`, `it2ssh`, `it2tip` are undocumented, and `it2` and `cc-status` appear only in release notes. |
| `it2ul` "specifies the directory to place downloaded files" | It uploads. Wrong verb on the page. |
| The `it2dl` usage block | Stranded at the bottom of the page under the wrong heading. |
| Triggers: `\r` is "A linefeed character" | It is a carriage return. |
| `it2getvar`: "For a list of session variables, see the Badges page" | The list moved to documentation-variables.html. |
| `SetBadgeFormat` | Missing from the escape-codes reference. |
| SCP config path `~/Library/Application Support/iTerm/ssh_config` | Missing the `2`; everything else in the app uses `iTerm2`. |
| tmux minimum version | Not stated at all. |
| Triggers, Smart Selection, Semantic History and APS are separate features | They share the Profiles > Advanced tab and interlock: a trigger feeds the Captured Output toolbelt tool, and triggers substitute for shell integration where APS needs it. See `references/workflow.md`. |
