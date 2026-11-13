---
paths:
  - "**/bin/executable_claude-peer"
  - "**/dot_config/claude-peer/**"
  - "**/tests/claude-peer.bats"
  - "**/tests/claude-peer-screen.bats"
---

# Claude peers: the sleeper that moves while it is looked at

The part of `bin/claude-peer` that moves a waiting pane's figure only while the operator
looks at it: `look`, its trigger and its lock. The limited timer it replaces, and the rest
of the script, are in `claude-peer.md`.

**It moves while it is looked at.** The limited timer above moves a figure in a tab nobody
watches, and a background tab left on a waiting picker never clears its activity indicator.
So the pane has three modes, chosen per launch in `pane_fzf`. *Look*: the layout is not
`none` and `pn_look` is set. *Limited*: the layout is not `none`, `art-seconds` is over 0 and
`pn_look` is empty, today's timer byte for byte. *Still*: everything else. `pn_look` (and
`pn_look_id`, the session id) is set when no `claude-peer.art-seconds` of the operator's own
is a number, `<look dir>/kind` is readable, `$ITERM_SESSION_ID` holds a valid id after its
colon (`look_ok`: 36 characters of hex and `-`), and the socket path fits 100 bytes
(`sun_path` is 104 on macOS). The look directory is
`${CLAUDE_PEER_LOOK:-$HOME/.local/state/claude-peer/look}` (`look_dir`), fixed under `$HOME`
rather than `XDG_STATE_HOME` because the trigger's command runs in iTerm2's environment, not
the pane's, and both must name one directory. In it: `kind` (`variable`; only `look on`
writes it, and its presence means looking is installed), `focus` (line 1 is the session id
last reported looked at, or empty), `<id>.sock` (the fzf of a waiting pane in look mode),
`lock` and `unlocked` (below). A look-mode fzf is fed by `pane_feed`: one input line per
header line (`-`, then the four poses and the still frame as tab fields, shown through
`--header-lines`), then the rows with their display repeated in fields 2 to 6; it runs
with `--listen=<sock>`, `--bind=start:unbind(every(1))` unless `focus` already names this
session, and last `--bind=every(1):change-with-nth(2|3|4|5)`: fzf rotates the poses itself
with no `--with-shell` and no `bg-transform`, so a moving pane forks nothing, and an unbound
one writes nothing. The socket is removed after every return of that fzf and in
`pane_cleanup`.

`claude-peer look gained|lost <session id>` is what tells it: `gained` writes the id to
`focus`, posts `unbind(every(1))` to the socket of the session looked at before and
`rebind(every(1))` to the new one (a duplicate does nothing: every session of a window
reports one change); `lost` empties `focus` if it names the id and unbinds it. The pose
**freezes on the way out, with no redraw to the still frame**: a redraw in a background tab
is the thing being avoided. It **always exits 0 and prints nothing on either stream**,
whatever happens, because iTerm2 posts a notification for a failed trigger command and logs
what it prints; a socket that does not answer is left alone (removing it could unlink the
socket of an fzf that is just starting). The caller is a Variable Changed trigger that
`look on` writes, with iTerm2 quit like the Enter triggers, into every profile that has the
claude Enter job trigger (`look off` removes it, and never a trigger it did not write): it
watches `tab.window.currentTab.currentSession.id`, passes the value filter
`^[0-9A-Fa-f-]{36}$`, and runs one `/bin/sh` line (`LOOK_CMD`) that takes the id as `\0`,
ends unless `~/bin/claude-peer` exists, and `exec`s `look gained` only when `focus` does not
already name it. That test of `focus` stays outside the lock below: it is what drops a stale
id (in the live check on iTerm2 3.7.7 the stale id was each time the session looked at
before the swap, and the command reads `focus` before any call of the burst has written it);
moved under the lock, or deleted because `look` checks anyway, the stale call would queue
with the others and win whenever it was given the lock last. The marker is written after the
store, so a pane never listens for a trigger that is not there.

**No trigger written here may contain an interpolation or set the profile's "Triggers Use
Interpolated Strings".** The parameter holds `\0` only, never `\(` followed by anything but
`matches[N])`. On iTerm2 3.7.7 a Variable Changed trigger on a `tab.` path whose parameter
needs the session's variables crashes the app when a session is made by a split or is
closed (two crash reports, 2026-11-13; the scope is evaluated through
`VT100Screen.m:2377-2380` at `v3.7.7`, which hands the evaluator a delegate that is nil while
a split's new session is half built and during teardown). A parameter with no scope takes
the plain backreference path, which messages that nil delegate and does nothing. The live
check on 3.7.7 (a second instance under `-suite`, never the operator's own) ran this shape
through a split, a new tab, pane, tab and window closes, a workgroup's enter, swap and
exit, and quit with no crash. Whether a window or a notification appears was checked only
through Accessibility, which saw none. The tests assert both halves of the rule.

One `look` runs at a time. iTerm2 starts the commands of a burst together, up to 16, in no
fixed order (each waits for its own `PATH` lookup first), and one tab switch fires one to
four of them because the variable trigger fires in every session of the window, buried
workgroup peers included; two `gained` calls that overlap can each bind a pane. So
`cmd_look` takes a `flock(2)` lock on descriptor 9, opened on `<look dir>/lock`, with `flock`
where it exists and `lockf` on macOS (`look_lock`), and holds it from the read of `focus`
to the last post (`look_turn`). It is not the symlink lock the slots use: the kernel drops
this one when the descriptor closes, so a killed holder leaves nothing to break, and this
call cannot tell anybody about a stale one. It waits 5 seconds (`CLAUDE_PEER_LOOK_WAIT`,
whole seconds, the tests' handle). A call that cannot lock **goes ahead rather than being
dropped**, and `unlocked` records it: the single line `notool` when no tool on the machine
locks a descriptor, or one `timeout` line per call that passed a live holder. `status`
reports it. `lock` is never removed by any code (not by `look on` or `look off`): a new file
at that path would be a second lock beside a live holder's. `look on` and `look off` do
remove `unlocked`, so its count starts again. On a machine with a waiting `lockf` the
waiter polls, so waits of seconds cost a core while they last.

The limits, accepted: one pane moves at a time, machine-wide (the active session of the tab
last switched to; with two windows a tab switch in one freezes a visible sleeper in the
other); nothing fires on an app or window switch, so leaving iTerm2 does not stop it and
coming back does not start it; a tick that lands between the switch and the unbind draws
once in a background tab; and the lock orders nothing, so which call of a burst runs last
is still iTerm2's. `claude-peer status` has a `look:` line (`off`, `on (variable trigger in
<n> of <m> profiles); <k> panes listening, <s> stale; last event <age> ago`, the marker
without the trigger, the trigger without the marker, or out of date), ending with the
`unlocked` count when there is one. Its age is the count of the mechanism: `gained`
rewrites `focus` on every accepted event, so a trigger that has stopped firing shows as an
age that keeps growing while tabs are switched. Undo: remove `<look dir>/kind` (panes
started afterwards use today's limit), or `claude-peer look off` with iTerm2 quit. The
event that would replace the variable trigger, and the fzf route that needs no trigger at
all, are on the watchlist (`docs/watchlist.md`). The upstream crash fix is
https://github.com/gnachman/iTerm2/pull/822 (issue
https://gitlab.com/gnachman/iterm2/-/work_items/13210); the Focus Changed proposal is
https://gitlab.com/gnachman/iterm2/-/work_items/13211.
