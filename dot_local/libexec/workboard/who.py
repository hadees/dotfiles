"""The who source of the work board: which sessions are on which directory.

The who document (`who/1`) is the session join's contract. This implementation
reads the claude-tab panel's `GET /snapshot.json` and each session's registry
record for its `cwd`; it knows no subagent jobs yet (`sources.jobs` is `off`).

Run by hand it prints counts, never a label or a directory:
    who.py [--panel-url <url>]    one line: panel, rows, needs, dir
    who.py --fixture <dir>        prints <dir>/who.json and asks nothing
Standard library only.
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request


def _git_config(*args):
    try:
        out = subprocess.run(["git", "config"] + list(args), capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout if out.returncode == 0 else ""


def _label(path):
    base = os.path.basename(path)
    if base == ".claude":
        return "default"
    if base.startswith(".claude-"):
        return base[len(".claude-"):]
    return base


def profile_dirs():
    """Label to directory for every Claude profile directory that exists."""
    home = os.path.expanduser("~")
    found = [os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude"), os.path.join(home, ".claude")]
    for line in _git_config("--get-regexp", r"^claude\.profile\.").splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2:
            found.append(parts[1].strip())
    out, seen = {}, set()
    for d in found:
        if d.startswith("~/"):
            d = os.path.join(home, d[2:])
        if not d or d in seen or not os.path.isdir(d):
            continue
        seen.add(d)
        out.setdefault(_label(d), d)
    return out


def _snapshot(panel_url):
    """The panel's snapshot as a dict, or None. No proxy: this is loopback."""
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(panel_url.rstrip("/") + "/snapshot.json", timeout=1) as r:
            if r.status != 200:
                return None
            doc = json.loads(r.read().decode("utf-8"))
    except Exception:
        return None
    return doc if isinstance(doc, dict) else None


def _cwd(profiles, label, pid):
    d = profiles.get(label)
    if not d:
        return None
    try:
        with open(os.path.join(d, "sessions", "%d.json" % pid), encoding="utf-8") as f:
            cwd = json.load(f).get("cwd")
    except Exception:
        return None
    return cwd if isinstance(cwd, str) and cwd else None


def read(panel_url, profiles, local, now, cache):
    """The who document. `local` is accepted and not used by this implementation."""
    snap = _snapshot(panel_url)
    if snap is None:
        return {"v": 1, "fetched_at": now, "sources": {"panel": "down", "jobs": "off"}, "rows": []}
    picked = [(r, True) for r in snap.get("needs") or []]
    for g in snap.get("others") or []:
        picked += [(r, False) for r in (g.get("rows") or [])]
    rows, live = [], set()
    for r, needs in picked:
        if not isinstance(r, dict) or not isinstance(r.get("pid"), int):
            continue
        key = (r.get("profile"), r["pid"])
        if key in live:
            continue
        live.add(key)
        if key not in cache:
            cache[key] = _cwd(profiles, r.get("profile"), r["pid"])
        rows.append({"id": "s:%s:%d" % key, "source": "session", "pid": r["pid"],
                     "profile": r.get("profile"), "label": r.get("label"), "group": r.get("group"),
                     "role": r.get("role"), "seat": None, "text": None, "kind": r.get("kind"),
                     "reason": r.get("reason") or "", "since": int(r.get("since") or 0),
                     "seen": bool(r.get("seen")), "needs": needs, "stale": False, "dir": cache[key]})
    for key in [k for k in cache if k not in live]:
        del cache[key]
    return {"v": 1, "fetched_at": now, "sources": {"panel": "ok", "jobs": "off"}, "rows": rows}


def _panel_url():
    url = _git_config("--get", "workboard.panel-url").strip()
    if url:
        return url
    return "http://127.0.0.1:%s" % (_git_config("--get", "claude-tab.panel-port").strip() or "47600")


def main(argv):
    ap = argparse.ArgumentParser(prog="who.py")
    ap.add_argument("--panel-url")
    ap.add_argument("--fixture")
    a = ap.parse_args(argv)
    if a.fixture:
        with open(os.path.join(a.fixture, "who.json"), encoding="utf-8") as f:
            doc = json.load(f)
        if set(doc) != {"v", "fetched_at", "sources", "rows"}:
            print("who.json: unexpected top-level keys", file=sys.stderr)
            return 1
        print(json.dumps(doc))
        return 0
    doc = read(a.panel_url or _panel_url(), profile_dirs(), {}, time.time(), {})
    rows = doc["rows"]
    print("panel %s · rows %d · needs %d · dir %d" % (
        doc["sources"]["panel"], len(rows), sum(r["needs"] for r in rows), sum(r["dir"] is not None for r in rows)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
