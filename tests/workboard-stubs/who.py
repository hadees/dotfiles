# TEST STAND-IN for dot_local/libexec/workboard/who.py (step 5 builds the real
# one). It returns the demo scenario's who document from $WORKBOARD_DEMO and
# asks no panel. Not product code; never deployed. A step that finds it wrong
# hands back; it does not patch it.
import functools
import inspect
import json
import os


def _demo(name):
    with open(os.path.join(os.environ["WORKBOARD_DEMO"], name + ".json"), encoding="utf-8") as f:
        return json.load(f)


def _stub(fn):
    """Log the call to $WORKBOARD_DEMO/calls.log; raise when WORKBOARD_STUB_RAISE names the function."""
    sig = inspect.signature(fn)
    label = os.path.splitext(os.path.basename(__file__))[0] + "." + fn.__name__

    @functools.wraps(fn)
    def run(*args, **kw):
        given = [k for k, v in sig.bind(*args, **kw).arguments.items() if v is not None]
        with open(os.path.join(os.environ["WORKBOARD_DEMO"], "calls.log"), "a", encoding="utf-8") as f:
            f.write(" ".join([label] + given) + "\n")
        if os.environ.get("WORKBOARD_STUB_RAISE") in (label, fn.__name__):
            raise RuntimeError(_demo("board")["cards"][0]["title"])
        return fn(*args, **kw)
    return run


@_stub
def read(panel_url: str, profiles: dict, local: dict, now: float, cache: dict) -> dict:
    return _demo("who")


@_stub
def profile_dirs() -> dict:
    return {"default": os.path.expanduser("~/.claude"), "personal": os.path.expanduser("~/.claude-personal")}
