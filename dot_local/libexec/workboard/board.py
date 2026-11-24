"""workboard: the process behind `bin/workboard`.

    board.py serve  --port <n> --panel-url <url> [--fixture <dir>]   the server (foreground)
    board.py cli    <verb> [args]                                     the client verbs
    board.py detach <log> <argv>...                                   run argv in a session of its own
    board.py ping   <port>                                            print the server's pid; exit 3 when silent

Standard library only, clean on 3.9, run as `python3 -I -B board.py ...`. Nothing the
server holds is written: the four input documents and the board live in memory. The state
directory gets `secret`, `tally.json` (numbers), and what `bin/workboard` puts there.
"""
import glob
import hashlib
import hmac
import http.client
import importlib
import inspect
import json
import os
import re
import runpy
import secrets
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import github  # noqa: E402
import inbox  # noqa: E402
import local  # noqa: E402
import model  # noqa: E402
import who  # noqa: E402

PLUGINS = ("verbs", "mcp_endpoint", "service", "notice", "pane")
READERS = {"model": "model", "poll": "github", "local": "local", "who": "who", "inbox": "inbox"}
CSP = ("default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
       "connect-src 'self'")
DEFAULT_PORT = 47601
EMPTY = {
    "github": {"v": 1, "accounts": {}, "repos": {}, "issues": [], "prs": []},
    "local": {"v": 1, "generated_at": 0.0, "skipped": 0, "repos": [], "worktrees": [], "links": [], "log": {}},
    "who": {"v": 1, "fetched_at": None, "sources": {"panel": "down", "jobs": "off"}, "rows": []},
    "inbox": {"v": 1, "fetched_at": None, "source": "none", "errors": {}, "rows": []},
}


def log(msg):
    sys.stderr.write("%s workboard: %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg))
    sys.stderr.flush()


# --- state directory, secret, tokens -------------------------------------------------

def state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "workboard")


def write_private(path, text):
    tmp = "%s.tmp%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def load_secret():
    d = state_dir()
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    path = os.path.join(d, "secret")
    if not os.path.exists(path):
        write_private(path, secrets.token_hex(32) + "\n")
    with open(path, encoding="ascii") as f:
        return f.read().strip()


def token(secret, what):
    return hmac.new(secret.encode("ascii"), what.encode("utf-8"), hashlib.sha256).hexdigest()[:32]


def url_text(port, tok, group=None, repo=None):
    frag = ""
    if group:
        frag = "#g=" + quote(group, safe="")
    elif repo:
        frag = "#r=" + quote(repo, safe="")
    return "http://127.0.0.1:%d/b/%s/%s" % (port, tok, frag)


def read_links():
    out = []
    try:
        with open(os.path.join(state_dir(), "links.tsv"), encoding="utf-8") as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) == 4 and p[1].isdigit() and p[3].isdigit():
                    out.append({"slug": p[0], "number": int(p[1]), "worktree": p[2], "at": int(p[3])})
    except OSError:
        pass
    return out


def profile_header():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")


# --- the plug-in interface -------------------------------------------------------------

class Ctx:
    def __init__(self, core, port):
        self._core, self.port, self.state_dir = core, port, state_dir()

    def board(self):
        return self._core.board if self._core else None

    def local(self):
        return self._core.docs["local"] if self._core else None

    def inbox(self):
        return self._core.docs["inbox"] if self._core else None

    def poll_now(self, account):
        if self._core:
            self._core.poll_now(account)

    def count(self, name):
        if self._core:
            self._core.count(str(name))

    def account_of(self, owner):
        return github.account_of(owner)

    def token_for(self, account):
        return github.token_for(account)

    def profile_dirs(self):
        return who.profile_dirs()


class App:
    def __init__(self, ctx):
        self.ctx = ctx
        self.apis, self.clis, self.commands, self.routes = {}, {}, {}, {}
        self.after_githubs, self.statuses, self.plugins = [], [], []

    def api(self, name, fn):
        self.apis[name] = fn

    def cli(self, name, parse):
        self.clis[name] = parse

    def command(self, name, fn):
        self.commands[name] = fn

    def route(self, method, path, fn):
        self.routes[(method, path)] = fn

    def after_github(self, fn):
        self.after_githubs.append(fn)

    def status(self, name, fn):
        self.statuses.append((name, fn))


class Staged:
    """What a plug-in's register() sees: nothing reaches the App unless register() returns."""

    def __init__(self, app):
        self.ctx, self._app, self._calls = app.ctx, app, []

    def api(self, name, fn):
        self._calls.append(("api", (name, fn)))

    def cli(self, name, parse):
        self._calls.append(("cli", (name, parse)))

    def command(self, name, fn):
        self._calls.append(("command", (name, fn)))

    def route(self, method, path, fn):
        self._calls.append(("route", (method, path, fn)))

    def after_github(self, fn):
        self._calls.append(("after_github", (fn,)))

    def status(self, name, fn):
        self._calls.append(("status", (name, fn)))

    def commit(self):
        for kind, args in self._calls:
            getattr(self._app, kind)(*args)


def load_plugins(app, on_error):
    for name in PLUGINS:
        try:
            mod = importlib.import_module(name)
        except ModuleNotFoundError as err:
            if err.name != name:
                on_error(name, err)
            continue
        except Exception as err:
            on_error(name, err)
            continue
        try:
            staged = Staged(app)
            mod.register(staged)
            staged.commit()
            app.plugins.append(name)
        except Exception as err:
            on_error(name, err)


# --- the server ----------------------------------------------------------------------------

class Core:
    def __init__(self, port, panel_url, fixture, tick):
        self.port, self.panel_url, self.fixture, self.tick = port, panel_url, fixture, tick
        self.rest = float(os.environ.get("WORKBOARD_REST") or 900)
        self.lock = threading.RLock()
        self.wake = threading.Event()
        self.secret = load_secret()
        self.docs = dict((k, dict(v)) for k, v in EMPTY.items())
        self.board, self.board_key, self.rev, self.scoped = None, None, 0, {}
        self.tally = self.load_tally()
        self.start = time.time()
        self.last_page, self.last_any, self.paused = 0.0, self.start, False
        self.gh_done, self.gh_first_at, self.gh_next, self.gh_requests = False, 0.0, {}, set()
        self.next_local, self.saved_at = 0.0, self.start
        self.caches = {"who": {}, "inbox": {}}
        self.budget = self.config_int("workboard.budget", 1200)
        self.trial_days = self.config_int("workboard.trial-days", 7)
        self.entry = os.environ.get("WORKBOARD_ENTRY")
        self.build_raw = self.newest()
        self.build = "%d" % (self.build_raw * 1000)
        self.ctx = Ctx(self, port)
        self.app = App(self.ctx)
        load_plugins(self.app, self.plugin_error)
        if fixture:
            self.load_fixture()
        self.rebuild()

    # counts and logs
    def count(self, name, n=1):
        with self.lock:
            self.tally[name] = self.tally.get(name, 0) + n

    def plugin_error(self, name, err):
        log("plugin %s failed: %s" % (name, err.__class__.__name__))
        self.count("plugin_errors")

    def guard(self, name, fn, *args):
        """Run one pass; a failure is the pass's name and the exception's class, never its message."""
        try:
            return fn(*args)
        except Exception as err:
            log("pass %s failed: %s" % (name, err.__class__.__name__))
            self.count("pass_errors")
            return None

    @staticmethod
    def config_int(key, default):
        try:
            out = subprocess.run(["git", "config", "--get", key], stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, timeout=5).stdout.decode().strip()
            return int(out) if out.isdigit() and int(out) > 0 else default
        except (OSError, subprocess.SubprocessError):
            return default

    def load_tally(self):
        try:
            with open(os.path.join(state_dir(), "tally.json"), encoding="ascii") as f:
                return dict((k, v) for k, v in json.load(f).items()
                            if isinstance(k, str) and isinstance(v, int) and not isinstance(v, bool))
        except (OSError, ValueError, AttributeError):
            return {}

    def save_tally(self):
        self.saved_at = time.time()
        try:
            with self.lock:
                text = json.dumps(self.tally, sort_keys=True) + "\n"
            write_private(os.path.join(state_dir(), "tally.json"), text)
        except OSError:
            log("tally not written")

    # code following
    def newest(self):
        files = glob.glob(os.path.join(HERE, "*.py")) + ([self.entry] if self.entry else [])
        best = 0.0
        for f in files:
            try:
                best = max(best, os.stat(f).st_mtime)
            except OSError:
                pass
        return best

    def reexec(self, httpd):
        self.save_tally()
        httpd.server_close()
        os.execv(sys.executable, [sys.executable, "-I", "-B", os.path.abspath(__file__)] + sys.argv[1:])

    # tokens and scope
    def profiles(self):
        """abs profile directory -> label."""
        return dict((os.path.abspath(d), label) for label, d in who.profile_dirs().items())

    def full_token(self):
        return token(self.secret, "all")

    def profile_token(self, abs_dir):
        return token(self.secret, "profile:" + abs_dir)

    def auth(self, tok):
        """(True, scope) for a valid token (scope None for the full one), else (False, None)."""
        want = tok.encode("utf-8")
        found, scope = hmac.compare_digest(self.full_token().encode(), want), None
        for d in self.profiles():
            if hmac.compare_digest(self.profile_token(d).encode(), want):
                found, scope = True, d
        return found, scope

    # activity
    def touch(self, page=False):
        now = time.time()
        with self.lock:
            viewing = now - self.last_page <= 10
            self.last_any = now
            wake = self.paused or (page and not viewing)
            if page:
                self.last_page = now
            if self.paused:
                self.paused, self.gh_next = False, {}
        if wake:
            self.wake.set()

    def poll_now(self, account):
        with self.lock:
            self.gh_requests.add(account)
        self.wake.set()

    # the board
    def rebuild(self):
        now = time.time()
        d = self.docs
        board = model.build_board(d["github"], d["local"], d["who"], d["inbox"], self.trial_days, now, None)
        key = dict(board)
        key.pop("generated_at", None)
        key["health"] = dict((k, v) for k, v in key.get("health", {}).items() if k != "panel_age")
        key = json.dumps(key, sort_keys=True)
        with self.lock:
            previous = self.board
            if key != self.board_key:
                self.rev, self.board_key = self.rev + 1, key
            self.board, self.scoped = board, {}
        return previous, board

    def board_for(self, scope):
        if self.fixture:
            self.load_fixture()
            self.rebuild()
        if scope is None:
            return self.board
        with self.lock:
            hit = self.scoped.get(scope)
        if hit is None:
            d = self.docs
            hit = model.build_board(d["github"], d["local"], d["who"], d["inbox"], self.trial_days, time.time(), scope)
            with self.lock:
                self.scoped[scope] = hit
        return hit

    def load_fixture(self):
        for name in ("github", "local", "who", "inbox"):
            with open(os.path.join(self.fixture, name + ".json"), encoding="utf-8") as f:
                self.docs[name] = json.load(f)

    def pids_in_scope(self, scope):
        label = self.profiles().get(scope) if scope else None
        return set(r["pid"] for r in self.docs["who"].get("rows", [])
                   if isinstance(r.get("pid"), int) and (scope is None or r.get("profile") == label))

    # the clocks
    def local_pass(self, now):
        def go():
            also = sorted(set(r["dir"] for r in self.docs["who"].get("rows", []) if r.get("dir")))
            self.docs["local"] = local.read(read_links(), also, now)
            self.count("local_passes")
            return True
        if not self.guard("local", go):
            return False
        self.guard("inbox", self.inbox_pass, now)
        return True

    def inbox_pass(self, now):
        self.docs["inbox"] = inbox.read(self.docs["local"], now, self.caches["inbox"])
        return True

    def who_pass(self, now):
        def go():
            self.docs["who"] = who.read(self.panel_url, who.profile_dirs(), self.docs["local"], now, self.caches["who"])
            self.count("who_passes")
            if inbox.changed(self.docs["local"], self.caches["inbox"]):
                self.inbox_pass(now)
            return True
        return bool(self.guard("who", go))

    def github_pass(self, now):
        with self.lock:
            requested, self.gh_requests = set(self.gh_requests), set()
        accounts = list(self.docs["github"].get("accounts") or {})
        if not self.gh_done:
            if now < self.gh_first_at:
                return False
            only = None
        else:
            only = sorted(set(a for a in accounts if self.gh_next.get(a, 0) <= now) | requested)
            if not only:
                return False
        prior = self.docs["github"] if self.gh_done else None
        doc = self.guard("github", github.poll, self.docs["local"], prior, self.budget, now, only)
        if doc is None:
            if self.gh_done:
                for a in only:
                    self.gh_next[a] = now + 60
            else:
                self.gh_first_at = now + 60
            return False
        self.docs["github"], self.gh_done = doc, True
        self.count("github_passes")
        for a, info in (doc.get("accounts") or {}).items():
            if only is None or a in only:
                iv = self.guard("interval", github.next_interval, info.get("cost", 0), info.get("remaining", 0), self.budget)
                self.gh_next[a] = now + (iv if iv else 300)
        return True

    def run(self, httpd):
        first = True
        while True:
            if not first:
                self.wake.wait(self.tick)
                self.wake.clear()
            first = False
            now = time.time()
            if self.newest() != self.build_raw:
                self.reexec(httpd)
            if now - self.saved_at >= 60:
                self.save_tally()
            if self.fixture:
                continue
            changed, gh = False, False
            if not self.paused and now - self.last_any > self.rest:
                self.paused = True
                self.count("paused")
            if now >= self.next_local:
                self.next_local = now + 60
                changed = self.local_pass(now) or changed
            if not self.paused:
                gh = bool(self.github_pass(now))
                changed = gh or changed
            if now - self.last_page <= 10:
                changed = self.who_pass(now) or changed
            if changed:
                built = self.guard("build", self.rebuild)
                if built and gh:
                    for fn in list(self.app.after_githubs):
                        try:
                            fn(self.ctx, built[1], built[0])
                        except Exception as err:
                            self.plugin_error("after_github", err)

    # status.json: numbers and fixed words only
    def status_doc(self):
        now = time.time()
        d, board = self.docs, self.board or {}
        age = lambda t: None if t is None else max(0, int(now - t))  # noqa: E731
        health = board.get("health", {})
        stages = {}
        for c in board.get("cards", []):
            stages[c.get("stage")] = stages.get(c.get("stage"), 0) + 1
        rows = d["who"].get("rows", [])
        out = {
            "server": {"pid": os.getpid(), "port": self.port, "build": self.build, "fixture": bool(self.fixture),
                       "launchd": os.environ.get("XPC_SERVICE_NAME") == "local.workboard", "paused": self.paused},
            "github": dict((a, {"age": age(i.get("fetched_at")), "interval": i.get("interval"),
                                "remaining": i.get("remaining"), "error": bool(i.get("error"))})
                           for a, i in (d["github"].get("accounts") or {}).items()),
            "local": {"repos": len(d["local"].get("repos", [])), "worktrees": len(d["local"].get("worktrees", [])),
                      "claims": sum(1 for w in d["local"].get("worktrees", []) if w.get("claim")),
                      "skipped": d["local"].get("skipped", 0)},
            "who": {"panel": d["who"]["sources"].get("panel"), "age": age(d["who"].get("fetched_at")),
                    "sessions": sum(1 for r in rows if r.get("source") == "session"), "jobs": d["who"]["sources"].get("jobs"),
                    "job_rows": sum(1 for r in rows if r.get("source") == "job"),
                    "stale": health.get("stale_jobs", 0), "unjoined_jobs": health.get("unjoined_jobs", 0)},
            "inbox": {"source": d["inbox"].get("source"), "rows": len(d["inbox"].get("rows", [])),
                      "errors": len(d["inbox"].get("errors", {}))},
            "cards": {"inbox": stages.get("inbox", 0), "building": stages.get("building", 0),
                      "review": stages.get("review", 0), "landed": stages.get("landed", 0),
                      "unattended": health.get("unattended", 0), "unjoined": health.get("unjoined", 0)},
            "needs": {"board": len(board.get("needs", [])), "panel": sum(1 for r in rows if r.get("needs"))},
        }
        with self.lock:
            out["tally"] = dict(self.tally)
        out["plugins"] = list(self.app.plugins)
        for name, fn in self.app.statuses:
            try:
                got = fn()
                out.setdefault(name, dict((k, v) for k, v in got.items() if isinstance(v, (int, float, str, bool))))
            except Exception as err:
                self.plugin_error(name, err)
        out["plugin_errors"] = self.tally.get("plugin_errors", 0)
        return out

    # /api/url
    def api_url(self, profile, data):
        if not profile:
            return 2, "workboard: X-Workboard-Profile is required"
        abs_dir = os.path.abspath(os.path.expanduser(profile))
        if abs_dir not in self.profiles():
            return 2, "workboard: that is not a profile directory"
        group, repo = data.get("group"), data.get("repo")
        if not all(v is None or isinstance(v, str) for v in (group, repo)) or (group and repo):
            return 2, "workboard: want one of group, repo, as text"
        return 0, url_text(self.port, self.profile_token(abs_dir), group, repo)

    # /go
    def relay_go(self, pid):
        """-> (status, body bytes, content type)."""
        import urllib.request
        import urllib.error
        req = urllib.request.Request(self.panel_url.rstrip("/") + "/go", data=("pid=%d" % pid).encode("ascii"),
                                     headers={"X-Claude-Tab": "1"}, method="POST")
        try:
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=10) as r:
                return r.status, r.read(), r.headers.get("Content-Type", "application/json")
        except urllib.error.HTTPError as err:
            return err.code, err.read(), err.headers.get("Content-Type", "application/json")
        except (OSError, http.client.HTTPException):
            return 502, b"The panel did not answer.\n", "text/plain; charset=utf-8"


class Req:
    def __init__(self, handler, method, path, body):
        self.method, self.path, self.body, self._h = method, path, body, handler.headers

    def header(self, name):
        return self._h.get(name)


def make_handler(core):
    hosts = ("127.0.0.1:%d" % core.port, "localhost:%d" % core.port)
    origins = tuple("http://" + h for h in hosts)
    plain = "text/plain; charset=utf-8"

    class Handler(BaseHTTPRequestHandler):
        server_version = "workboard"
        sys_version = ""
        timeout = 10

        def log_message(self, *args):
            pass

        def reply(self, code, body=b"", ctype="application/json", extra=()):
            if isinstance(body, str):
                body = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            for k, v in extra:
                self.send_header(k, v)
            self.end_headers()
            if code != 304:
                self.wfile.write(body)

        def say(self, code, sentence):
            """A refusal the page shows as it is: one sentence of plain text."""
            self.reply(code, sentence + "\n", plain)

        def do_GET(self):
            self.handle_any("GET")

        def do_POST(self):
            self.handle_any("POST")

        def handle_any(self, method):
            try:
                self.handle_one(method)
            except Exception as err:  # the class only: a message can quote a response
                log("request failed: %s" % err.__class__.__name__)
                core.count("route_errors")
                try:
                    self.reply(500, '{"error": "failed"}')
                except OSError:
                    pass

        def handle_one(self, method):
            core.count("requests")
            if self.headers.get("Host") not in hosts:
                return self.reply(403, '{"error": "bad host"}')
            origin = self.headers.get("Origin")
            if origin is not None and origin not in origins:
                return self.reply(403, '{"error": "bad origin"}')
            path = self.path.split("?", 1)[0]
            body = b""
            if method == "POST":
                try:
                    n = int(self.headers.get("Content-Length") or 0)
                except ValueError:
                    n = -1
                if not 0 <= n <= 65536:
                    return self.reply(413, '{"error": "bad body"}')
                body = self.rfile.read(n)
            route = core.app.routes.get((method, path))
            if route:
                core.touch()
                return self.run_route(route, Req(self, method, path, body))
            parts = path.split("/")
            if method == "GET" and path == "/health":
                return self.reply(200, json.dumps({"ok": True, "pid": os.getpid(), "build": core.build,
                                                   "fixture": bool(core.fixture)}))
            if method == "GET" and path == "/status.json":
                return self.reply(200, json.dumps(core.status_doc(), sort_keys=True))
            if len(parts) >= 3 and parts[1] == "b":
                return self.under_token(method, parts[2], parts[3:], body)
            if method == "POST" and len(parts) == 3 and parts[1] == "api":
                return self.api(parts[2], body)
            self.reply(404, '{"error": "not found"}')

        def run_route(self, fn, req):
            try:
                code, headers, out = fn(req)
            except Exception as err:
                log("route %s failed: %s" % (req.path, err.__class__.__name__))
                core.count("route_errors")
                return self.reply(500, '{"error": "route failed"}')
            self.reply(code, out, headers.get("Content-Type", "application/octet-stream"),
                       [(k, v) for k, v in headers.items() if k != "Content-Type"])

        def api(self, name, body):
            core.touch()
            fn = core.app.apis.get(name)
            if name != "url" and fn is None:
                return self.reply(404, '{"error": "no such verb"}')
            if self.headers.get("X-Workboard") != "1":
                return self.reply(403, '{"error": "missing header"}')
            profile = self.headers.get("X-Workboard-Profile") or None
            try:
                data = json.loads(body.decode("utf-8") or "{}")
            except ValueError:
                data = None
            if not isinstance(data, dict):
                code, text = 2, "workboard: the body must be a JSON object"
            elif name == "url":
                code, text = core.api_url(profile, data)
            else:
                try:
                    inspect.signature(fn).bind(core.ctx, profile=profile, **data)
                except TypeError:
                    code, text = 2, "workboard: that verb does not take those fields"
                else:
                    try:
                        code, text = fn(core.ctx, profile=profile, **data)
                    except Exception as err:
                        log("verb %s failed: %s" % (name, err.__class__.__name__))
                        core.count("api_errors")
                        code, text = 1, "workboard: the verb failed"
            self.reply(200, json.dumps({"code": code, "text": text}))

        def under_token(self, method, tok, rest, body):
            ok, scope = core.auth(tok)
            if not ok:
                core.count("token_rejects")
                return self.reply(403, '{"error": "bad token"}')
            page = method == "GET" and rest in ([""], ["board.json"])
            core.touch(page=page)
            if method == "GET" and rest == [""]:
                html = os.environ.get("WORKBOARD_HTML") or os.path.expanduser("~/.local/share/workboard/board.html")
                try:
                    with open(html, "rb") as f:
                        page_bytes = f.read()
                except OSError:
                    return self.reply(500, "workboard: board page missing: %s\n" % html, plain)
                return self.reply(200, page_bytes, "text/html; charset=utf-8", [("Content-Security-Policy", CSP)])
            if method == "GET" and rest == ["board.json"]:
                try:
                    doc = dict(core.board_for(scope))
                except Exception as err:
                    log("board failed: %s" % err.__class__.__name__)
                    core.count("pass_errors")
                    return self.reply(500, '{"error": "board build failed"}')
                doc["rev"], doc["build"] = core.rev, core.build
                etag = '"%d"' % core.rev
                if self.headers.get("If-None-Match") == etag:
                    return self.reply(304, b"", extra=[("ETag", etag)])
                return self.reply(200, json.dumps(doc), extra=[("ETag", etag)])
            if method == "POST" and rest in (["go"], ["open"]):
                return self.go(scope, body) if rest == ["go"] else self.open_card(scope, body)
            self.reply(404, '{"error": "not found"}')

        def post_ok(self, body, field):
            """-> the field's value, or None after answering the refusal."""
            if self.headers.get("X-Workboard") != "1":
                self.say(403, "The request lacks its header.")
                return None
            m = re.fullmatch(r"%s=(.{1,512})" % field, body.decode("utf-8", "replace"), re.S)
            if not m:
                self.say(400, "The request body is not what this takes.")
                return None
            return parse_qs(body.decode("utf-8", "replace")).get(field, [None])[0]

        def go(self, scope, body):
            pid = self.post_ok(body, "pid")
            if pid is None:
                return
            if core.fixture:
                return self.say(409, "A fixture board relays no click.")
            if not pid.isdigit():
                return self.say(400, "The pid is not a number.")
            if int(pid) not in core.pids_in_scope(scope):
                return self.say(404, "No session of this board has that pid.")
            status, out, ctype = core.relay_go(int(pid))
            self.reply(status, out, ctype)

        def open_card(self, scope, body):
            key = self.post_ok(body, "key")
            if key is None:
                return
            cards = [c for c in core.board_for(scope).get("cards", []) if c.get("key") == key]
            url = cards[0].get("url") if cards else None
            if not url or not url.startswith(("https://", "http://")):
                return self.say(404, "That card has no page to open.")
            opener = os.environ.get("WORKBOARD_OPEN") or "/usr/bin/open"
            try:
                subprocess.run([opener, url], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=10, check=True)
            except (OSError, subprocess.SubprocessError):
                return self.say(502, "The opener failed.")
            self.reply(200, '{"ok": true}')

    return Handler


def serve(argv):
    opts, it = {"port": DEFAULT_PORT, "panel-url": "http://127.0.0.1:47600", "fixture": None}, iter(argv)
    for a in it:
        name = a[2:] if a.startswith("--") else None
        if name not in opts:
            sys.stderr.write("workboard: serve: unknown argument\n")
            return 2
        opts[name] = next(it, None)
    try:
        port = int(opts["port"])
    except (TypeError, ValueError):
        sys.stderr.write("workboard: serve: --port wants a number\n")
        return 2
    tick = float(os.environ.get("WORKBOARD_TICK") or 2)
    core = Core(port, opts["panel-url"], opts["fixture"], tick)
    try:
        httpd = ThreadingHTTPServer(("127.0.0.1", port), make_handler(core))
    except OSError:
        sys.stderr.write("workboard: port %d is in use\n" % port)
        return 1
    httpd.daemon_threads = True

    def bye(*_):
        core.save_tally()
        os._exit(0)
    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGINT, bye)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    sys.stdout.write("workboard: on http://127.0.0.1:%d/\n" % port)
    sys.stdout.flush()
    core.run(httpd)


# --- the client ----------------------------------------------------------------------------

def request(method, path, body=None, headers=None):
    port = int(os.environ.get("WORKBOARD_PORT") or DEFAULT_PORT)
    try:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        conn.request(method, path, body=body, headers=headers or {})
        resp = conn.getresponse()
        return resp.status, resp.read()
    except (OSError, http.client.HTTPException):
        return None


def api_call(name, body):
    headers = {"X-Workboard": "1", "Content-Type": "application/json"}
    if os.environ.get("CLAUDECODE"):
        headers["X-Workboard-Profile"] = profile_header()
    got = request("POST", "/api/" + name, json.dumps(body).encode("utf-8"), headers)
    if got is None:
        sys.stderr.write("workboard: not running\n")
        return 3
    if got[0] != 200:
        sys.stderr.write("workboard: the server answered %d\n" % got[0])
        return 1
    doc = json.loads(got[1].decode("utf-8"))
    sys.stdout.write(doc["text"] if doc["text"].endswith("\n") else doc["text"] + "\n")
    return int(doc["code"])


def cli_url(argv):
    group = repo = None
    it = iter(argv)
    for a in it:
        val = next(it, None)
        if a == "--group" and val and not repo:
            group = val
        elif a == "--repo" and val and not group:
            repo = val
        else:
            sys.stderr.write("usage: workboard url [--group <g>|--repo <r>]\n")
            return 2
    if os.environ.get("CLAUDECODE"):
        return api_call("url", dict((k, v) for k, v in (("group", group), ("repo", repo)) if v))
    port = int(os.environ.get("WORKBOARD_PORT") or DEFAULT_PORT)
    print(url_text(port, token(load_secret(), "all"), group, repo))
    return 0


def cli_status():
    got = request("GET", "/status.json")
    if got is None or got[0] != 200:
        print("server: not running")
        return 3
    st = json.loads(got[1].decode("utf-8"))

    def pairs(d):
        return " · ".join("%s %s" % (k.replace("_", " "), "-" if v is None else v) for k, v in d.items())
    s = st["server"]
    mode = "fixture" if s["fixture"] else ("launchd" if s["launchd"] else "detached")
    print("server: pid %s · port %s · build %s · %s" % (s["pid"], s["port"], s["build"], mode))
    for acct, i in sorted(st["github"].items()):
        print("github: %s · age %s · interval %s · remaining %s · error %s" % (
            acct, "-" if i["age"] is None else "%ds" % i["age"], i["interval"], i["remaining"],
            "yes" if i["error"] else "no"))
    print("local: " + pairs(st["local"]))
    w = dict(st["who"])
    w["age"] = "-" if w["age"] is None else "%ds" % w["age"]
    print("who: panel %s · age %s · %s" % (w.pop("panel"), w.pop("age"), pairs(w)))
    print("inbox: " + pairs(st["inbox"]))
    print("cards: " + pairs(st["cards"]))
    print("needs: %d (panel: %d)" % (st["needs"]["board"], st["needs"]["panel"]))
    print("tally: " + (pairs(st["tally"]) or "empty"))
    for name in sorted(set(st) - {"server", "github", "local", "who", "inbox", "cards", "needs", "tally",
                                  "plugins", "plugin_errors"}):
        print("%s: %s" % (name, pairs(st[name])))
    if st["plugin_errors"]:
        print("plugins: %s · plugin errors %d" % (" ".join(st["plugins"]) or "none", st["plugin_errors"]))
    return 0


def cli(argv):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    if not argv:
        sys.stderr.write("usage: workboard <serve|start|stop|restart|open|url|status|model|poll|local|who|inbox|<verb>>\n")
        return 2
    verb, rest = argv[0], argv[1:]
    if verb == "status":
        return cli_status()
    if verb == "url":
        return cli_url(rest)
    if verb in READERS:
        path = os.path.join(HERE, READERS[verb] + ".py")
        sys.argv = [path] + rest
        runpy.run_path(path, run_name="__main__")
        return 0
    app = App(Ctx(None, int(os.environ.get("WORKBOARD_PORT") or DEFAULT_PORT)))
    load_plugins(app, lambda name, err: log("plugin %s failed: %s" % (name, err.__class__.__name__)))
    if verb in app.commands:
        return int(app.commands[verb](rest) or 0)
    if verb in app.clis:
        try:
            body = app.clis[verb](rest)
        except ValueError as err:
            sys.stderr.write("workboard %s: %s\n" % (verb, err))
            return 2
        return api_call(verb, body)
    sys.stderr.write("workboard: no verb %s\n" % verb)
    return 2


def detach(log_path, argv):
    """Run argv in a session of its own, so it outlives the shell that asked."""
    sys.stdout.flush()
    sys.stderr.flush()
    os.makedirs(os.path.dirname(log_path), mode=0o700, exist_ok=True)
    pid = os.fork()
    if pid:
        os.waitpid(pid, 0)
        return 0
    try:
        os.setsid()
        if os.fork():
            os._exit(0)
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        os.chdir("/")
        null = os.open(os.devnull, os.O_RDONLY)
        out = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        os.dup2(null, 0)
        os.dup2(out, 1)
        os.dup2(out, 2)
        os.closerange(3, 256)
        os.execvp(argv[0], argv)
    finally:
        os._exit(127)


def ping(port):
    os.environ["WORKBOARD_PORT"] = port
    got = request("GET", "/health")
    if got is None or got[0] != 200:
        return 3
    print(json.loads(got[1].decode("utf-8"))["pid"])
    return 0


if __name__ == "__main__":
    mode, args = (sys.argv[1] if len(sys.argv) > 1 else ""), sys.argv[2:]
    if mode == "serve":
        sys.exit(serve(args))
    if mode == "cli":
        sys.exit(cli(args))
    if mode == "detach" and len(args) >= 2:
        sys.exit(detach(args[0], args[1:]))
    if mode == "ping" and len(args) == 1 and args[0].isdigit():
        sys.exit(ping(args[0]))
    sys.stderr.write("usage: board.py serve|cli|detach|ping ...\n")
    sys.exit(2)
