# TEST STAND-IN for dot_local/libexec/workboard/local.py (step 4 builds the real
# one). It returns the demo scenario's local document from $WORKBOARD_DEMO and
# reads no git. Not product code; never deployed. A step that finds it wrong
# hands back; it does not patch it.
import functools
import inspect
import json
import os
from typing import Optional


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
def read(links: list, also: list, now: float) -> dict:
    doc = _demo("local")
    doc["links"] = links
    return doc


@_stub
def profile_of(slug: str, account: str) -> str:
    return next((r["profile"] for r in _demo("local")["repos"] if r["slug"] == slug), "")


@_stub
def slug_of(dir: str) -> Optional[str]:
    doc = _demo("local")
    paths = [(r["dir"], r["slug"]) for r in doc["repos"]] + [(w["path"], w["slug"]) for w in doc["worktrees"]]
    hits = [(len(p), s) for p, s in paths if dir == p or dir.startswith(p + "/")]
    return max(hits)[1] if hits else None


# Added with the working-set view. Not logged: no test of the server's calls counts them.
def sets(repos: list) -> dict:
    return {}


def _main_checkout(dir: str) -> Optional[tuple]:
    return None


def _config(key: str, cwd: Optional[str] = None) -> str:
    return ""
