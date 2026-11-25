"""The inbox source of the work board.

The inbox document (`inbox/1`) is the Inbox order's contract. This
implementation has no queue to read: it returns the empty document, and a later
step fills it from `claude-peer queue`.

Run by hand it prints `source none · rows 0`; with `--fixture <dir>` it prints
<dir>/inbox.json and asks nothing. Standard library only.
"""
import argparse
import json
import os
import sys


def read(local, now, cache):
    return {"v": 1, "fetched_at": now, "source": "none", "errors": {}, "rows": []}


def changed(local, cache):
    return False


def main(argv):
    ap = argparse.ArgumentParser(prog="inbox.py")
    ap.add_argument("--fixture")
    a = ap.parse_args(argv)
    if not a.fixture:
        print("source none · rows 0")
        return 0
    with open(os.path.join(a.fixture, "inbox.json"), encoding="utf-8") as f:
        doc = json.load(f)
    if set(doc) != {"v", "fetched_at", "source", "errors", "rows"}:
        print("inbox.json: unexpected top-level keys", file=sys.stderr)
        return 1
    print(json.dumps(doc))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
