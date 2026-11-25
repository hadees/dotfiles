# The work board's LaunchAgent verbs: `workboard install` and `workboard
# uninstall`, registered as client commands (no server needed). The agent's
# plist is Library/LaunchAgents/local.workboard.plist.tmpl, deployed disabled;
# install never writes, edits or removes it, it only asks launchctl to load it.
import os
import signal
import subprocess
import sys
import time
import urllib.request

LABEL = "local.workboard"


def _home():
    return os.path.expanduser("~")


def _plist():
    return os.path.join(_home(), "Library", "LaunchAgents", LABEL + ".plist")


def _state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(_home(), ".local", "state")
    return os.path.join(base, "workboard")


def _launchctl():
    return os.environ.get("WORKBOARD_LAUNCHCTL") or "launchctl"


def _run(*args):
    return subprocess.run(list(args), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode


def _on_mac():
    try:
        out = subprocess.run(["uname", "-s"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             universal_newlines=True).stdout
    except OSError:
        return False
    return out.strip() == "Darwin"


def _port():
    try:
        out = subprocess.run(["git", "config", "--get", "workboard.port"], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, universal_newlines=True).stdout.strip()
    except OSError:
        out = ""
    return int(out) if out.isdigit() else 47601


def _wait(done, seconds):
    end = time.time() + seconds
    while time.time() < end:
        if done():
            return True
        time.sleep(0.1)
    return done()


def _healthy(port):
    try:
        # No proxy: the server is on loopback whatever http_proxy says.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open("http://127.0.0.1:%d/health" % port, timeout=1) as r:
            return r.status == 200
    except (OSError, ValueError):
        return False


def _stop_detached():
    """TERM the detached server named in <state>/pid, when that pid is still board.py."""
    try:
        with open(os.path.join(_state_dir(), "pid"), encoding="utf-8") as f:
            pid = int(f.read().split()[0])
        cmd = subprocess.run(["ps", "-p", str(pid), "-o", "command="], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, universal_newlines=True).stdout
    except (OSError, ValueError, IndexError):
        return
    if "board.py" not in cmd:
        return

    def gone():
        try:
            os.kill(pid, 0)
        except OSError:
            return True
        return False
    os.kill(pid, signal.SIGTERM)
    _wait(gone, 5)


def _lines(target):
    return [
        [_launchctl(), "enable", target],
        [_launchctl(), "bootout", target],
        [_launchctl(), "bootstrap", "gui/%d" % os.getuid(), _plist()],
        [_launchctl(), "kickstart", "-k", target],
    ]


def _not_mac(verb):
    print("workboard %s: the LaunchAgent is macOS only" % verb)
    return 2


def install(argv):
    if argv not in ([], ["--print"]):
        print("usage: workboard install [--print]", file=sys.stderr)
        return 2
    if not _on_mac():
        return _not_mac("install")
    target = "gui/%d/%s" % (os.getuid(), LABEL)
    if argv:
        for line in _lines(target):
            print(" ".join(line))
        return 0
    if not os.path.isfile(_plist()):
        print("workboard install: no %s; the dotfiles deploy it on the mac class" % _plist())
        return 1
    _stop_detached()
    enable, bootout, bootstrap, kickstart = _lines(target)
    _run(*enable)
    _run(*bootout)  # not loaded yet is fine
    # bootout returns before launchd has torn the job down; a bootstrap in that
    # window fails "5: Input/output error".
    _wait(lambda: _run(_launchctl(), "print", target) != 0, 10)
    for line in (bootstrap, kickstart):
        if _run(*line) != 0:
            print("workboard install: `%s` failed" % " ".join(line), file=sys.stderr)
            return 1
    port = _port()
    if not _wait(lambda: _healthy(port), 10):
        print("workboard install: loaded, but nothing answers on 127.0.0.1:%d (see ~/Library/Logs/workboard.log)" % port,
              file=sys.stderr)
        return 1
    print("workboard: listening on http://127.0.0.1:%d/ ; next: workboard connect" % port)
    return 0


def uninstall(argv):
    if argv:
        print("usage: workboard uninstall", file=sys.stderr)
        return 2
    if not _on_mac():
        return _not_mac("uninstall")
    target = "gui/%d/%s" % (os.getuid(), LABEL)
    _run(_launchctl(), "bootout", target)
    return 0 if _run(_launchctl(), "disable", target) == 0 else 1


def register(app):
    app.command("install", install)
    app.command("uninstall", uninstall)
