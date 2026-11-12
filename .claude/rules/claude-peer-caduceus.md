---
paths:
  - "**/bin/executable_claude-peer"
  - "**/tests/claude-peer.bats"
  - "**/tests/claude-peer-screen.bats"
---

# Claude peers: the Hermes pane's caduceus

What the Hermes peer's waiting pane draws. The pane itself, and the sleeper the
slot panes draw, are in `claude-peer.md`.

The Hermes peer waits under Hermes's own caduceus, not the
sleeper: `HERMES_CADUCEUS` is read at run time from the installed Hermes
(`hermes_cli/banner.py` under `~/.hermes/hermes-agent`, else the root install
`/usr/local/lib/hermes-agent`; MIT, Nous Research) and never copied here,
its rich tags and any escape or control bytes stripped. Dark bronze (150,92,36), a band about
three cells wide lit toward (255,214,150) sweeping down it diagonally, then a pause (one cycle
is rows + columns + 40 frames of 70 ms), and `waiting · ⏎ to start Hermes · q for a shell` under it; no z's.
`herm_py` (python3, which Hermes itself needs) writes every frame once per wait; the band's
seven levels come from `art_mode` and, in 256 colours, `art_c256` (the sleeper's mapping, also
`art_hat`'s). `art --hermes --wait` draws them for `claude-peer.art-seconds` from the start and
after each line typed (echo off; a background drawer stopped by a file between frames, so the
cursor is always back under the figure), then the still frame with no process running; Return
is 0, `q` or end of input 1, and the figure is erased either way. Status 3, silent, is no
terminal, `claude-peer.art false`, no figure, or a pane smaller than it: `hermes_peer` then
asks in words as before. `art --hermes [--at <n>]` prints one frame (0 is still).
