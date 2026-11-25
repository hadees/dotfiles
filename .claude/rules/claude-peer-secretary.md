---
paths:
  - "**/bin/executable_claude-peer"
  - "**/dot_config/claude-peer/**"
  - "**/tests/claude-peer.bats"
  - "**/tests/claude-peer-screen.bats"
---

# Claude peers: the jobs record, the queue and the secretary pane

The part of `bin/claude-peer` that keeps what Lead dispatched, queues what the
operator thought up, and runs the one pane to think in. The rest of the script is
in `claude-peer.md`.

## The bar

The bar is Lead and `Secretary`: `build_base` returns the root and one peer, id
`<prefix>.secretary`, command `claude-peer run --as secretary --wait`, so
`Claude Peers` (`claudePeer.workgroup`) has two sessions and `Claude Peers +
Hermes` (`claudePeer.h`) three (`with_hermes` is unchanged). The root's id, which
the Enter triggers are keyed to, is `<prefix>.main` as before. The label is
`label_of` of the slot, `secretary`.

`install` builds no overlay pair: it passes no overlay names, so a stale
`Claude Peers + Overlays` pair and the overlays state file are removed (the branch
a machine with no overlays already took) and `here` answers `base`. The overlay
code (`build_overlays`, `overlay`, the `overlays:` lines of `status`) stays until
the step that deletes it, and `status` still says `overlays: not installed` for a
machine that has overlays. `status` reports `workgroup:` and `hermes:` as `installed,
out of date (...)` until the next `install` (iTerm2 quit); a tab opened before the
relaunch keeps its five panes.
