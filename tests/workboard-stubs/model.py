# TEST STAND-IN for dot_local/libexec/workboard/model.py (step 2 builds the real
# one). It returns the demo scenario's board from $WORKBOARD_DEMO and builds
# nothing. Not product code; never deployed. A step that finds it wrong hands
# back; it does not patch it.
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


def _label(profile_dir):
    base = os.path.basename(profile_dir.rstrip("/"))
    if base == ".claude":
        return "default"
    return base[len(".claude-"):] if base.startswith(".claude-") else base


@_stub
def build_board(github: dict, local: dict, who: dict, inbox: dict, trial_days: int, now: float,
                scope: Optional[str]) -> dict:
    board = _demo("board")
    board.pop("rev", None)
    board.pop("build", None)
    if scope is not None:
        label = _label(scope)
        slugs = {r["slug"] for r in _demo("local")["repos"] if _label(r["profile"]) == label}
        board["scope"] = scope
        board["repos"] = [r for r in board["repos"] if r["slug"] in slugs]
        board["cards"] = [c for c in board["cards"] if c["slug"] in slugs]
        board["needs"] = [n for n in board["needs"] if n["profile"] == label]
    return board
