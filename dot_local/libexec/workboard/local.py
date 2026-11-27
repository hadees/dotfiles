"""The work board's local reader: repositories, worktrees, claims, the coordination log.

read(links, also, now) -> the local document (local/1). It runs git, worktabs
and claude-peer and writes nothing. Run by hand it prints one line of counts and
never the document; with --fixture <dir> it prints <dir>/local.json and reads
nothing live. Standard library, clean on 3.9.
"""
import json
import os
import subprocess
import sys
import time
from typing import List, Optional

TIMEOUT = 10
LOG_LINES = 200
DOC_KEYS = ["v", "generated_at", "skipped", "repos", "worktrees", "links", "log"]


def _run(argv: list, cwd: Optional[str] = None, codes: tuple = (0,)) -> Optional[str]:
    """Stdout of a command, or None when it is missing, slow or exits with a code not in `codes`."""
    try:
        p = subprocess.run(argv, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=TIMEOUT)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    return p.stdout.decode("utf-8", "replace") if p.returncode in codes else None


def _git(*args: str, cwd: Optional[str] = None) -> Optional[str]:
    return _run(["git"] + list(args), cwd)


def _config(key: str, cwd: Optional[str] = None) -> str:
    return (_git("config", "--get", key, cwd=cwd) or "").strip()


def _tool(env: str, default: str) -> Optional[str]:
    path = os.environ.get(env) or os.path.expanduser(default)
    return path if os.path.isfile(path) and os.access(path, os.X_OK) else None


def _expand(path: str) -> str:
    return os.path.expanduser(path) if path.startswith("~") else path


def slug_of(dir: str) -> Optional[str]:
    """The origin remote as a lowercase owner/repo slug; the rule of git_origin_slug (dot_functions)."""
    url = _config("remote.origin.url", cwd=dir)
    if url.endswith("/"):
        url = url[:-1]
    if url.endswith(".git"):
        url = url[:-4]
    if "://" in url:
        slug = url.split("://", 1)[1].partition("/")[2]
    elif ":" in url:
        slug = url.split(":", 1)[1]
    else:
        return None
    slug = slug.lower()
    return slug if "/" in slug else None


def account_of(owner: str) -> str:
    """The pinned GitHub account of an owner, or "-". Written a second time, not shared with github.py."""
    return _config("credential.https://github.com/%s.username" % owner.lower()) or "-"


def profile_of(slug: str, account: str) -> str:
    """The profile directory claude() would use for a repository; the rule of claude_profile_dir."""
    dir = ""
    pin = _config("claude.%s.profile" % slug)
    if pin:
        dir = _config("claude.profile.%s" % pin)
        if not dir and pin[0] in "~/":
            dir = pin
    if not dir:
        dir = _config("claude.profile.%s" % ("default" if account == "-" else account))
    if not dir:
        return os.path.abspath(os.path.expanduser("~/.claude"))
    if dir.startswith("~"):
        dir = os.environ.get("HOME", "") + dir[1:]
    return os.path.abspath(dir)


def _plan_rows() -> List[tuple]:
    """(dir, group) of every worktabs entry whose directory exists, enabled or not."""
    tool = _tool("WORKBOARD_WORKTABS", "~/bin/worktabs")
    out = _run([tool, "plan"]) if tool else None
    rows = []
    for line in (out or "").splitlines():
        f = line.split("\t")
        if len(f) >= 5 and f[2] in ("ok", "disabled") and os.path.isdir(f[4]):
            rows.append((f[4], f[0] or "-"))
    return rows


def _main_checkout(dir: str) -> Optional[tuple]:
    """(main checkout, git common dir) of the repository holding dir."""
    out = _git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=dir)
    common = (out or "").strip()
    return (os.path.dirname(common), common) if common else None


def _repos(also: list) -> tuple:
    candidates = _plan_rows()
    for d in (_git("config", "--get-all", "workboard.repo") or "").splitlines():
        candidates.append((_expand(d.strip()), "-"))
    candidates += [(d, "-") for d in also]
    found = {}
    skipped = 0
    for dir, group in candidates:
        if not os.path.isdir(dir):
            continue
        main = _main_checkout(dir)
        if main is None or main[0] in found:
            continue
        slug = slug_of(main[0])
        if slug is None:
            found[main[0]] = None
            skipped += 1
            continue
        found[main[0]] = (slug, main[0], main[1], group)
    repos = []
    for slug, dir, common, group in (v for v in found.values() if v):
        key = "workboard.%s." % slug
        intake = _config(key + "intake", cwd=dir)
        take = _config(key + "take", cwd=dir)
        account = account_of(slug.split("/")[0])
        repos.append({
            "slug": slug, "name": slug.split("/")[1], "dir": dir, "common": common, "group": group,
            "account": account, "profile": profile_of(slug, account),
            "intake": intake if intake in ("all", "none") or intake.startswith("label:") else "mine",
            "write": _config(key + "write", cwd=dir) == "true",
            "take": take if take == "auto" or take.startswith("auto:") else "ask",
            "notify_lead": _config(key + "notify-lead", cwd=dir) == "true"})
    return repos, skipped


def _worktrees(repo: dict) -> list:
    out = _git("worktree", "list", "--porcelain", cwd=repo["dir"]) or ""
    trees = []
    for block in out.split("\n\n"):
        f = {}
        for line in block.splitlines():
            k, _, v = line.partition(" ")
            f[k] = v
        if "worktree" not in f or "bare" in f or "prunable" in f:
            continue
        branch = f.get("branch")
        trees.append({
            "slug": repo["slug"], "path": f["worktree"], "name": os.path.basename(f["worktree"]),
            "branch": branch[len("refs/heads/"):] if branch and branch.startswith("refs/heads/") else None,
            "main": not trees, "claim": None, "open_claim": None})
    return trees


def _claims(repo: dict) -> dict:
    """Real worktree path -> claim, one `claim` call per live claim."""
    tool = _tool("WORKBOARD_CLAUDE_PEER", "~/bin/claude-peer")
    if not tool:
        return {}
    claims = {}
    for line in (_run([tool, "peers", repo["dir"]]) or "").splitlines():
        path = line.split("\t")[0]
        rows = dict(l.split("\t", 1) for l in (_run([tool, "claim", path]) or "").splitlines() if "\t" in l)
        if not rows:
            continue
        started = rows.get("started", "-")
        claims[os.path.realpath(path)] = {
            "label": rows.get("label", "-"), "by": rows.get("by", "-"),
            "task": None if rows.get("task", "-") == "-" else rows["task"],
            "handoff": rows.get("handoff") == "handoff",
            "started": int(started) if started.isdigit() else None}
    return claims


def _log(repo: dict) -> list:
    tool = _tool("WORKBOARD_CLAUDE_PEER", "~/bin/claude-peer")
    out = _run([tool, "log", "show", "--all"], cwd=repo["dir"]) if tool else None
    entries = []
    for line in (out or "").splitlines()[-LOG_LINES:]:
        f = line.split("\t")
        if len(f) >= 4:
            entries.append({"at": f[0], "who": f[1], "kind": f[2], "text": f[3]})
    return entries


def _open_claim(label: str, entries: list) -> Optional[str]:
    text = None
    for e in entries:
        if e["kind"] == "claim" and e["who"] == label:
            text = e["text"]
        elif e["kind"] == "done" and e["who"] == label:
            text = None
        elif e["kind"] in ("stop", "end", "gone") and (e["text"] == label or e["text"].startswith(label + " ")):
            text = None
    return text


def sets(repos: list) -> dict:
    """Working set name -> slugs of the board's repositories that are its `ok` members, empty sets left out.

    `workset members` exits 2 when any row is not ok but still prints them, so that code is read too.
    """
    tool = _tool("WORKBOARD_WORKSET", "~/bin/workset")
    if not tool:
        return {}
    slug_of_dir = dict((os.path.realpath(r["dir"]), r["slug"]) for r in repos)
    found = {}
    for name in (_run([tool, "list"]) or "").split():
        rows = (_run([tool, "members", name], codes=(0, 2)) or "").splitlines()
        members = [slug_of_dir.get(os.path.realpath(f[1])) for f in (l.split("\t") for l in rows)
                   if len(f) >= 3 and f[2] == "ok"]
        if any(members):
            found[name] = sorted(set(m for m in members if m))
    return found


def read(links: list, also: list, now: float) -> dict:
    repos, skipped = _repos(also)
    worktrees, log = [], {}
    for repo in repos:
        claims = _claims(repo)
        log[repo["slug"]] = _log(repo)
        for wt in _worktrees(repo):
            wt["claim"] = claims.get(os.path.realpath(wt["path"]))
            if wt["claim"]:
                wt["open_claim"] = _open_claim(wt["claim"]["label"], log[repo["slug"]])
            worktrees.append(wt)
    return {"v": 1, "generated_at": float(now), "skipped": skipped, "repos": repos, "worktrees": worktrees,
            "links": [l for l in links if os.path.isdir(l["worktree"])], "log": log}


def main(argv: list) -> int:
    also, fixture, i = [], None, 1
    while i < len(argv):
        if argv[i] in ("--also", "--fixture") and i + 1 < len(argv):
            if argv[i] == "--also":
                also.append(argv[i + 1])
            else:
                fixture = argv[i + 1]
            i += 2
        else:
            print("usage: local.py [--also <dir>]... | --fixture <dir>")
            return 2
    if fixture is not None:
        try:
            with open(os.path.join(fixture, "local.json"), encoding="utf-8") as f:
                text = f.read()
            if list(json.loads(text)) != DOC_KEYS:
                raise ValueError
        except (OSError, ValueError, TypeError):
            print("local: fixture is not a local document")
            return 1
        sys.stdout.write(text)
        return 0
    doc = read([], also, time.time())
    print("local: repos %d · worktrees %d · claims %d · links %d · skipped %d" % (
        len(doc["repos"]), len(doc["worktrees"]), sum(1 for w in doc["worktrees"] if w["claim"]),
        len(doc["links"]), doc["skipped"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
