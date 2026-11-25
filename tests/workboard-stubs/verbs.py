# TEST STAND-IN for dot_local/libexec/workboard/verbs.py (step 8 builds the real
# one). Each verb answers (0, "<name> ok") and writes nothing; register(app)
# registers them as step 8 does, with parsers that only split the command line
# into the body keys the functions take. Not product code; never deployed. A
# step that finds it wrong hands back; it does not patch it.
import functools
import inspect
import os


def _stub(fn):
    """Log the call to $WORKBOARD_DEMO/calls.log when that is set."""
    sig = inspect.signature(fn)

    @functools.wraps(fn)
    def run(*args, **kw):
        demo = os.environ.get("WORKBOARD_DEMO")
        if demo:
            given = [k for k, v in sig.bind(*args, **kw).arguments.items() if v is not None]
            with open(os.path.join(demo, "calls.log"), "a", encoding="utf-8") as f:
                f.write(" ".join(["verbs." + fn.__name__] + given) + "\n")
        return fn(*args, **kw)
    return run


@_stub
def list_cards(ctx, dir, stage=None, profile=None):
    return 0, "list ok"


@_stub
def take(ctx, dir, ref, force=False, profile=None):
    return 0, "take ok"


@_stub
def add(ctx, dir, title, body="", take=False, profile=None):
    return 0, "add ok"


@_stub
def move(ctx, dir, ref, to, force=False, profile=None):
    return 0, "move ok"


def _parser(positional=(), options=(), flags=()):
    def parse(argv):
        body, rest, it = {"dir": os.getcwd()}, [], iter(argv)
        for a in it:
            name = a[2:] if a.startswith("--") else None
            if name == "dir" or name in options:
                body[name] = next(it, None)
                if body[name] is None:
                    raise ValueError("--%s needs a value" % name)
            elif name in flags:
                body[name] = True
            else:
                rest.append(a)
        if len(rest) != len(positional):
            raise ValueError("expected " + " ".join(positional))
        body.update(zip(positional, rest))
        return body
    return parse


def register(app):
    for name, fn in (("list", list_cards), ("take", take), ("add", add), ("move", move)):
        app.api(name, fn)
    app.cli("list", _parser(options=("stage",)))
    app.cli("take", _parser(("ref",), flags=("force",)))
    app.cli("add", _parser(("title",), options=("body",), flags=("take",)))
    app.cli("move", _parser(("ref", "to"), flags=("force",)))
    app.status("writes", lambda: {"done": 0, "forced": 0, "refused_rule": 0, "refused_write_off": 0, "refused_profile": 0})
