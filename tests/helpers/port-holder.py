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
