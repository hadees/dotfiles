"""port-holder.py <closed|listening|full> <file>

Writes a loopback port number to <file> and then stays alive until the caller
kills it. Kinds listening and full hold the port for that long, so test files
running side by side cannot take it:

  closed     nothing on it: a connect is refused. Released at once, because a
             socket that is bound and never listen()ed is not refused on macOS:
             the connect hangs until the kernel gives up, about 8 seconds.
  listening  listen(128), never accept()ed: a connect completes.
  full       listen(1), never accept()ed, and its backlog filled until a client
             connect times out: a connect neither completes nor is refused. Both
             kernels get there without this file knowing their backlog
             arithmetic. Writes 0 when twenty connects all complete.

Why these kinds: `ztcp` has no connect timeout, so a port whose listener never
accepts and whose backlog is full held a shell for about 8 seconds when the
connect ran in the shell (measured 2026-11-27); claude_tab_panel_ensure
therefore connects in a background subshell. On macOS a socket that is bound
and never listened on hangs the same way instead of being refused, so the
tests' closed port is one with nothing on it. A wedged or squatted port costs
each new shell one background process that waits for the kernel and then runs
`claude-tab panel ensure`.

Standard library, clean on 3.9.
"""
import socket
import sys
import time

kind, out = sys.argv[1], sys.argv[2]
s = socket.socket()
s.bind(("127.0.0.1", 0))
port = s.getsockname()[1]
if kind == "closed":
    s.close()
else:
    s.listen(128 if kind == "listening" else 1)
held = []
if kind == "full":
    stalled = False
    for _ in range(20):
        c = socket.socket()
        c.settimeout(0.5)
        held.append(c)
        try:
            c.connect(("127.0.0.1", port))
        except OSError:
            stalled = True
            break
    if not stalled:
        port = 0
with open(out, "w") as f:
    f.write(str(port))
time.sleep(600)
