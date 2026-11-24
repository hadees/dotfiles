# TEST STAND-IN for the plug-in interface `board.py` (step 7) hands each optional
# module's register(app). App records every registration in a list a test can
# read: apis [(name, fn)], clis [(name, parse)], commands [(name, fn)], routes
# [(method, path, fn, open)], after_githubs [fn], statuses [(name, fn)]. Its
# ctx serves the demo documents from $WORKBOARD_DEMO; ctx.counts holds the
# names given to count(), ctx.polls the accounts given to poll_now(), ctx.asks
# the (name, body, profile) of each ask(). Req is the request a plug-in handler
# is called with. Not product code; never deployed. A step that finds it wrong hands back; it does not
# patch it.
#
# Tests reach it through wb_driver, which puts its directory on sys.path
# after the module directory:   import app; a = app.App()
import importlib.util
import json
import os


def _demo(name):
    with open(os.path.join(os.environ["WORKBOARD_DEMO"], name + ".json"), encoding="utf-8") as f:
        return json.load(f)


def _stub(name):
    """The stub module <name>.py beside the real file of this one."""
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("stub_" + name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class _Ctx:
    def __init__(self):
        self.state_dir = os.path.join(os.environ["BATS_TEST_TMPDIR"], "workboard-state")
        os.makedirs(self.state_dir, mode=0o700, exist_ok=True)
        self.port = 47601
        self.counts, self.polls, self.asks = [], [], []

    def board(self):
        board = _demo("board")
        board.pop("rev", None)
        board.pop("build", None)
        return board

    def local(self):
        return _demo("local")

    def inbox(self):
        return _demo("inbox")

    def poll_now(self, account):
        self.polls.append(account)

    def count(self, name):
        self.counts.append(name)

    def account_of(self, owner):
        return _stub("github").account_of(owner)

    def token_for(self, account):
        return _stub("github").token_for(account)

    def profile_dirs(self):
        return _stub("who").profile_dirs()

    def ask(self, name, body, profile=None):
        self.asks.append((name, body, profile))
        label = next((k for k, d in self.profile_dirs().items() if d == profile), None)
        return 0, "fixture-key-" + (label or "none")


class Req:
    def __init__(self, method, path, body=b"", headers=None, profile=None):
        self.method, self.path, self.body, self.profile = method, path, body, profile
        self.headers = headers or {}

    def header(self, name):
        for k, v in self.headers.items():
            if k.lower() == name.lower():
                return v
        return None


class App:
    def __init__(self):
        self.ctx = _Ctx()
        self.apis, self.clis, self.commands, self.routes, self.after_githubs, self.statuses = [], [], [], [], [], []

    def api(self, name, fn):
        self.apis.append((name, fn))

    def cli(self, name, parse):
        self.clis.append((name, parse))

    def command(self, name, fn):
        self.commands.append((name, fn))

    def route(self, method, path, fn, open=False):
        self.routes.append((method, path, fn, open))

    def after_github(self, fn):
        self.after_githubs.append(fn)

    def status(self, name, fn):
        self.statuses.append((name, fn))
