## Claude in Chrome: which browser to drive

- Several Chrome profiles are deliberately paired to the same Anthropic
  account, so `list_connected_browsers` will usually show more than one. Do
  NOT resolve that by asking me or by broadcasting a Connect prompt
  (`switch_browser`). The choice is already made: run `chrome-pairing
  session` (in `~/bin`; it reads the alias the `claude()` wrapper exported
  for this session and answers from Finicky's config and Chrome's own files
  on disk) and call `select_browser` with the device id it prints. That is my
  standing answer for this session's browser — I made it once via the
  per-profile pins, not per session.
- Ask only when `chrome-pairing session` prints nothing (unpinned session,
  no pairing on disk) or the id it prints is not among the connected
  browsers (that profile's Chrome window is not open — say so, since
  opening it is the fix). `chrome-pairing list` shows every profile with its
  device id and pairing name if you need to explain a mismatch.
- When the task concerns a specific site or account that has its own Chrome
  profile — a repo that serves several sites is the usual case — the right
  browser is the one that site's tabs open in, not the session default:
  `chrome-pairing for https://<site>/` asks Finicky where that site goes and
  prints that profile's id. Pick by the site the task is about, and say
  which profile you picked. If I name a profile outright, `chrome-pairing
  for <profile name>` gives its id; use that instead.
- To *show* me a page beside the terminal — a localhost dashboard, a status
  page, a report — run `open-as iterm2 <url>`: it opens in an iTerm2 browser
  tab in this session's window and reuses it on the next call. If it cannot,
  it says why and opens the normal browser instead. It is for viewing only;
  Claude in Chrome stays the way to automate a page.
