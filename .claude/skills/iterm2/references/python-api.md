# Python API

The supported scripting interface, and the one to reach for in new work.
Docs: <https://iterm2.com/python-api/> and
<https://iterm2.com/documentation-scripting-fundamentals.html>.
Auth model: <https://iterm2.com/python-api-auth.html>.

## Shape of a script

```python
#!/usr/bin/env python3
import iterm2

async def main(connection):
    app = await iterm2.async_get_app(connection)
    window = app.current_terminal_window
    if window is not None:
        await window.async_create_tab()

iterm2.run_until_complete(main)
```

`run_until_complete(main)` returns when `main` does. `run_forever(main)` never
returns and is what a daemon, an RPC, a title provider or a status-bar
component needs. Both take `retry=False, debug=False`.

Naming convention: **every coroutine is named `async_*`**. Forgetting `await`
does not raise — you get a warning in the Script Console (Scripts > Manage >
Console) and a coroutine object where you wanted a value.

## The package and the runtime

`iterm2` is on PyPI. It is built on **protobuf and websockets**; the wire
format is `proto/api.proto` in the GitHub repo.

Two dependency facts worth knowing before pinning anything: the package
declares `protobuf` and `websockets` **unpinned**, and sets no
`requires_python`. So a fresh `pip install iterm2` resolves whatever those two
projects released most recently, and nothing stops it installing under a
Python it was never tested on. In a script you intend to keep, pin all three
yourself.

iTerm2 also ships its own runtime, `iterm2env`, and two script flavours:

| Flavour | Interpreter |
| --- | --- |
| Basic | `~/Library/ApplicationSupport/iTerm2/iterm2env/versions/*/bin/python3` |
| Full Environment | `~/Library/ApplicationSupport/iTerm2/Scripts/YourScript/iterm2env/versions/*/bin/python3` |

`ApplicationSupport` with no space is a symlink iTerm2 creates, because shell
scripts cannot have spaces in their interpreter paths. A basic script is run
as `<basic interpreter> YourScript.py`.

The Scripts menu lists, from `~/Library/Application Support/iTerm2/Scripts`:
any `.py` file (basic), any folder containing an `iterm2env` folder (full
environment), and AppleScript files. Update the runtime from Scripts > Manage
> Check for updated runtime.

Two gotchas the docs call out: **unset `PYTHONPATH`** before running a script,
and a Homebrew `pip3 install iterm2` is an explicitly sanctioned alternative
to the bundled runtime.

`iterm2env` is present as a string in the 3.6.11 binary; the directory itself
only appears once the Python API has been used, so its absence under
`~/Library/Application Support/iTerm2/` means "never run a script", not
"broken install".

## Enabling it, and the auth model

Settings > General > Magic > **Enable Python API**. The backing plist key is
`EnableAPIServer` (`defaults write com.googlecode.iterm2 EnableAPIServer -bool true`) —
present in the binary, and **documented nowhere on iterm2.com**, not even on
its hidden-settings page. Treat it as reverse-engineered.

How access is granted, from the 3.4+ page:

- Disabled by default; nothing can use the API in that state.
- Enabled, iTerm2 listens on a **unix domain socket**. Any local program may
  open it, so a connection must authenticate.
- A **cookie is a 128-bit random number**. When iTerm2 launches a script
  itself, it sets `ITERM2_COOKIE` in the environment; the script passes it
  back on connect (header `x-iterm2-cookie`). `ITERM2_KEY` accompanies it.
- An outside program must **request a cookie through AppleScript**
  (`request cookie`, see `references/applescript.md`). That is deliberate: it
  routes the request through macOS's Automation permission.
- Administrator escape hatch, "Allow all apps to connect": a file at
  `$HOME/Library/Application Support/iTerm2/disable-automation-auth` that must
  be **owned by root**, whose contents are the hex-encoded absolute path of
  the file itself followed by the magic string
  `61DF88DC-3423-4823-B725-22570E01C027`. The root ownership and the embedded
  path exist to stop a non-administrator creating a hard link to it. If your
  home directory moves or the file changes, the API is disabled and you
  re-enable it in Settings.

All five of `ITERM2_COOKIE`, `ITERM2_KEY`, `x-iterm2-cookie`,
`disable-automation-auth` and that magic string are in the 3.6.11 binary.

**Superseded, but still linked from the current page**: the GitLab wiki
describing iTerm2 3.3 says the API listens on **TCP port 1912** on 127.0.0.1.
That was replaced by the unix socket in 3.4.0. If you find port 1912 in a
guide, the guide is at least two majors old. The wiki does still carry the one
useful thing the 3.4 page dropped: grants may be one-time or persistent, and
persistent grants expire after thirty days.

Failure signatures worth recognising: a script dying immediately with a **401**
means permission denied — check Settings > General > Magic > Permissions. An
unregistered title provider renders as `…`; a broken status-bar component
renders as a ladybug.

## AutoLaunch

Put a script in `~/Library/Application Support/iTerm2/Scripts/AutoLaunch/` and
iTerm2 runs it at startup. AppleScript's equivalent is the single file
`Scripts/AutoLaunch.scpt`.

A newly added AutoLaunch script **does not start until iTerm2 restarts**, but
you can run it immediately from the Scripts menu.

**A script iTerm2 launches this way needs no Automation (TCC) grant** —
measured on this machine, see `references/applescript.md` for the method. The
cookie is injected, self-automation is implicitly allowed, and no TCC row is
created for either a read or a write.

Startup ordering matters here: iTerm2 opens one window of its own at every
launch (see `references/preferences.md`), so an AutoLaunch script that builds
a layout usually wants `OpenNoWindowsAtStartup` set, or it races the app.

## RPCs, hooks, monitors

```python
@iterm2.RPC
async def clear_session(session_id=iterm2.Reference("id")):
    ...
await clear_session.async_register(connection)
```

- Registered RPCs live in **one global namespace**, identified by the function
  name plus the *set* of argument names, order-insensitive. Name collisions
  are silent and confusing.
- `iterm2.Reference("id")` injects a variable. If the variable is undefined
  the call is simply not made; `Reference("id?")` passes `None` instead.
- **If a session does not have keyboard focus, no `session.` variables are
  available.**
- Invocation syntax is not Python: `my_func(session: id, nickname: "Joe")`.
  Bind it from Settings > Keys (action *Invoke Script Function*) or from a
  trigger. Calls compose and independent ones may run concurrently.
- **Default timeout is five seconds** — iTerm2 stops waiting, the function
  keeps running. Pass `timeout=` to `async_register`.

Two hooks, both daemons, both therefore in `AutoLaunch/`:

- `@iterm2.TitleProviderRPC`, registered with `display_name=` and
  `unique_identifier=`. Selected in Settings > Profiles > General > Title. It
  re-runs once on attach and thereafter only when a variable named by an
  `iterm2.Reference` default changes — to force a redraw you must change a
  `user.*` variable.
- `iterm2.StatusBarComponent(...)` plus `@iterm2.StatusBarRPC`. Selected in
  Settings > Profiles > Session > Configure Status Bar.

Monitors, used as async context managers: `FocusMonitor`, `KeystrokeMonitor`,
`KeystrokeFilter`, `LayoutChangeMonitor`, `NewSessionMonitor`, `PromptMonitor`,
`ScreenStreamer`, `SessionTerminationMonitor`, `VariableMonitor`,
`CustomControlSequenceMonitor`, and `Transaction`.

Two sharp edges: a custom control sequence **stays registered after `main`
returns**, and running several monitors at once needs each wrapped in its own
`asyncio.create_task` — otherwise control never leaves the first one. And
always catch exceptions inside an async task; Python swallows them silently.

## LocalWriteOnlyProfile

The way to restyle one session without editing the profile every other
session shares:

```python
p = iterm2.LocalWriteOnlyProfile()
p.set_foreground_color(iterm2.Color(255, 0, 0))
await session.async_set_profile_properties(p)
```

Per the docs it is "A profile that can be modified but not read and does not
send changes on each write." Also reachable as `Profile.local_write_only_copy`.
The full family on that page is `Profile`, `LocalWriteOnlyProfile`,
`PartialProfile`.

This is a Python-side class, so it is deliberately **not** in the manifest —
there is no string in the app binary to check it against. It moves with the
`iterm2` package version, not with the app.

## Signatures you will reach for

```python
# Window
await iterm2.Window.async_create(connection, profile=None, command=None,
                                 profile_customizations=None)
await window.async_create_tab(profile=None, command=None, index=None)
await window.async_activate(); await window.async_close(force=False)
await window.async_set_variable(name, value)
window.current_tab, window.tabs, window.window_id

# Tab
await tab.async_activate(); await tab.async_set_title(t)
await tab.async_select_pane_in_direction(d); await tab.async_update_layout()
tab.current_session, tab.sessions, tab.tab_id, tab.window

# Session
await session.async_split_pane(vertical=False, before=False, profile=None)
await session.async_send_text(text, suppress_broadcast=False)
await session.async_inject(data)                 # bytes, as if received
await session.async_get_variable(name)
await session.async_set_variable(name, value)    # name must begin with "user."
await session.async_get_screen_contents()
await session.async_get_contents(first_line, number_of_lines)
await session.async_invoke_function(invocation, timeout=-1)
session.session_id, session.tab, session.window, session.grid_size

# Variables
iterm2.VariableMonitor(connection, scope, name, identifier)
# VariableScopes.SESSION=1 TAB=2 WINDOW=3 APP=4
# identifier: "all" or "active" for SESSION/WINDOW; None for APP
```

## Docs vs. the binary (3.6.11)

| Claim | Reality |
| --- | --- |
| `EnableAPIServer` | Real key in the binary, documented nowhere on iterm2.com. Unsupported. |
| Wiki: API on TCP port 1912 | Superseded in 3.4.0 by a unix domain socket. The current page still links that wiki without qualification. |
| running.html: "Any folder having an `itermenv` folder" | Typo for `iterm2env`; every other mention spells it correctly. |
| Wiki: "In the future, the Python API will perform the cookie request automatically" | Has not happened; 3.4+ still requires the AppleScript request. |
| hooks.html sample shebang `#!/usr/bin/env python3.7` | Dated; use `python3`. |
| `iterm2` package pins its dependencies | It does not, and it declares no `requires_python`. |
