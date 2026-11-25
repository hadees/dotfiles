# TEST STAND-IN for dot_local/libexec/workboard/github.py (step 3 builds the real
# one). It returns the demo scenario's GitHub document from $WORKBOARD_DEMO and
# reads no network. Not product code; never deployed. A step that finds it
# wrong hands back; it does not patch it.
import functools
import inspect
import json
import os
import subprocess
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
def poll(local: dict, prior: Optional[dict], budget: int, now: float, only: Optional[list]) -> dict:
    return _demo("github")


@_stub
def account_of(owner: str) -> str:
    out = subprocess.run(["git", "config", "--get", "credential.https://github.com/%s.username" % owner],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True)
    return out.stdout.strip() or "-"


@_stub
def token_for(account: str) -> Optional[str]:
    return None if account == "-" else "fixture-token-" + account


@_stub
def next_interval(cost: int, remaining: int, budget: int) -> int:
    return 60


@_stub
def tally() -> dict:
    return {}
