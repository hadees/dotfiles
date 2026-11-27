"""The work board's model: four input documents in, one board document out.

build_board(github, local, who, inbox, trial_days, now, scope) is a pure
function: no network, no git, and no clock but `now`. The documents are the
frozen github/1, local/1, who/1 and inbox/1; the result is board/1.

    model.py --github <file> --local <file> [--who <file>] [--inbox <file>]
             [--trial-days <n>] [--now <epoch>] [--scope <dir>]

prints the board built from those files (it has no live source). Standard
library only, clean on Python 3.9.
"""
import argparse
import json
import os
import sys
import time
from typing import Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import origin

STAGES = ("inbox", "building", "review", "landed")
NO_WHO = {"v": 1, "fetched_at": None, "sources": {"panel": "down", "jobs": "off"}, "rows": []}
NO_INBOX = {"v": 1, "fetched_at": None, "source": "none", "errors": {}, "rows": []}


def _label(profile_dir: str) -> str:
    """claude-tab's profile_label: `default` for .claude, the part after .claude-, else the base name."""
    base = os.path.basename(profile_dir.rstrip("/"))
    if base == ".claude":
        return "default"
    return base[len(".claude-"):] if base.startswith(".claude-") else base


def _inside(path: str, parent: str) -> bool:
    """path is parent or below it, compared by components: /w/alpha does not hold /w/alpha-two."""
    parent = parent.rstrip("/")
    return path.rstrip("/") == parent or path.startswith(parent + "/")


def _pr(p: dict) -> dict:
    """A card's pull request entry. An inline entry (an issue's) has no checks, review or merge."""
    return {"number": p["number"], "url": p["url"], "state": p["state"], "draft": p["draft"],
            "checks": p.get("checks", "NONE"), "review": p.get("review", "NONE"),
            "merge": p.get("merge", "UNKNOWN"), "branch": p["branch"], "merged_at": p["merged_at"]}


def _put_pr(card: dict, pr: dict) -> None:
    """The detailed entry replaces the inline one of the same number; otherwise it is added."""
    for i, old in enumerate(card["prs"]):
        if old["number"] == pr["number"]:
            card["prs"][i] = pr
            return
    card["prs"].append(pr)


def _score(card: dict) -> float:
    try:
        return float(card["queue"]["score"])
    except (TypeError, ValueError):
        return 0.0


def _stage(card: dict, login: Optional[str], assignees: list) -> str:
    prs = card["prs"]
    if any(p["state"] == "OPEN" and not p["draft"] and p["review"] != "CHANGES_REQUESTED" for p in prs):
        return "review"
    if any(p["state"] == "OPEN" for p in prs):
        return "building"
    if any(p["state"] == "MERGED" for p in prs):
        return "landed"
    if card["queue"] and card["queue"]["state"] == "taken":
        return "building"
    if card["form"] == "local" or card["sessions"] or (login and login in assignees):
        return "building"
    return "inbox"


def _sort_key(card: dict):
    stage = STAGES.index(card["stage"])
    if card["stage"] == "inbox":
        q = card["queue"]
        if q and q["order"] is not None:
            tier = q["tier"] if q["tier"] is not None else sys.maxsize
            return (stage, 0, tier, -_score(card), card["slug"], q["order"], card["key"])
        return (stage, 1, -card["updated_at"], card["key"])
    if card["stage"] == "building":
        return (stage, 0 if card["sessions"] else 1, -card["updated_at"], card["key"])
    if card["stage"] == "review":
        failing = any(p["checks"] == "FAILURE" for p in card["prs"])
        return (stage, 0 if failing else 1, -card["updated_at"], card["key"])
    newest = max((p["merged_at"] or 0) for p in card["prs"])
    return (stage, -newest, card["key"])


def build_board(github: dict, local: dict, who: dict, inbox: dict, trial_days: int, now: float,
                scope: Optional[str]) -> dict:
    label = _label(scope) if scope is not None else None
    repos = [r for r in local["repos"] if scope is None or r["profile"] == scope]
    repo_of = {r["slug"]: r for r in repos}
    worktrees = [w for w in local["worktrees"] if w["slug"] in repo_of]

    def default_branch(slug):
        return github["repos"].get(slug, {}).get("default_branch")

    def login_of(slug):
        account = github["repos"].get(slug, {}).get("account", repo_of[slug]["account"])
        return github["accounts"].get(account, {}).get("login")

    cards = {}      # key -> card, in creation order
    assignees = {}  # key -> logins, kept out of the card

    def add(slug, form, key, number, title, url, author, labels, body, updated_at, prs, kind=None, blockers=None):
        r = repo_of[slug]
        cards[key] = {
            "key": key, "form": form, "slug": slug, "repo": r["name"], "group": r["group"],
            "number": number, "title": title, "url": url, "stage": "inbox", "in_needs": False,
            "author": author, "mine": bool(author) and author == login_of(slug), "assigned": False,
            "labels": labels, "body": body[:4000], "updated_at": updated_at, "trial_day": None,
            "unattended": False, "takeable": "no", "queue": None, "prs": prs, "holders": [],
            "sessions": [], "log": [], "origin": kind, "blockers": blockers}
        assignees[key] = []
        return cards[key]

    # Rule 1: cards from GitHub.
    ignored = 0
    for i in github["issues"]:
        if i["slug"] in repo_of:
            key = "%s#%d" % (i["slug"], i["number"])
            kind, skipped = origin.classify(i, login_of(i["slug"]))  # the whole body, before the card cuts it
            ignored += skipped
            add(i["slug"], "issue", key, i["number"], i["title"], i["url"], i["author"], list(i["labels"]),
                i["body"], i["updated_at"], [_pr(p) for p in i["prs"]], kind, i.get("blockers"))
            assignees[key] = i["assignees"]
    for p in github["prs"]:
        slug = p["slug"]
        if slug not in repo_of:
            continue
        pr = _pr(p)
        attached = [cards["%s#%d" % (slug, c["number"])] for c in p["closes"]
                    if c["slug"] == slug and "%s#%d" % (slug, c["number"]) in cards]
        if attached:
            for card in attached:
                _put_pr(card, pr)
            continue
        login = login_of(slug)
        if p["state"] == "OPEN":
            add(slug, "pr", "%s#%d" % (slug, p["number"]), p["number"], p["title"], p["url"], login, [], "",
                p["updated_at"], [pr])
        elif p["state"] == "MERGED" and now - p["merged_at"] < trial_days * 86400:
            if p["closes"]:
                c = p["closes"][0]
                add(slug, "issue", "%s#%d" % (slug, c["number"]), c["number"], c["title"], c["url"], login, [], "",
                    p["updated_at"], [pr])
            else:
                add(slug, "pr", "%s#%d" % (slug, p["number"]), p["number"], p["title"], p["url"], login, [], "",
                    p["updated_at"], [pr])

    # Rule 2: queue rows.
    for row in inbox["rows"]:
        if row["state"] not in ("waiting", "taken") or row["slug"] not in repo_of:
            continue
        q = {"id": row["id"], "state": row["state"], "kind": row["kind"], "order": row["order"],
             "tier": row["tier"], "score": row["score"], "terms": row["terms"], "cand": row["cand"],
             "file": row["file"]}
        linked = cards.get("%s#%s" % (row["slug"], row["issue"])) if row["issue"] is not None else None
        if linked is not None and linked["queue"] is None:
            linked["queue"] = q
            continue
        card = add(row["slug"], "queue", "%s~%s" % (row["slug"], row["id"]), row["issue"], row["text"], None,
                   row["who"], [], "", row["added"] or 0, [])
        card["mine"] = False
        card["queue"] = q

    # Rule 4 (first half): which worktree a who row is in. The longest path wins.
    kept = [w["path"] for w in worktrees]
    rows = [r for r in who["rows"]
            if scope is None or r["profile"] == label
            or (r["profile"] == "-" and r["dir"] and any(_inside(r["dir"], p) for p in kept))]
    rows_in = {w["path"]: [] for w in worktrees}
    where = {}
    for r in rows:
        inside = [p for p in kept if r["dir"] and _inside(r["dir"], p)]
        if inside:
            where[r["id"]] = max(inside, key=len)
            rows_in[where[r["id"]]].append(r)

    # Rule 3: holders. First match per worktree: an open pull request on its branch, a link, a local card.
    holder_of = {}
    for w in worktrees:
        slug, path, branch = w["slug"], w["path"], w["branch"]
        card = None
        if branch:
            card = next((c for c in cards.values() if c["slug"] == slug
                         and any(p["state"] == "OPEN" and p["branch"] == branch for p in c["prs"])), None)
        if card is None:
            links = [l for l in local["links"] if l["slug"] == slug and l["worktree"] == path
                     and "%s#%d" % (slug, l["number"]) in cards]
            if links:
                card = cards["%s#%d" % (slug, max(links, key=lambda l: l["at"])["number"])]
        claim = w["claim"]
        if card is None and rows_in[path] and (
                (claim and claim["task"]) or w["open_claim"] or (branch and branch != default_branch(slug))):
            job = next((r["text"] for r in rows_in[path] if r["source"] == "job" and r["text"]), None)
            title = w["open_claim"] or (claim and claim["task"]) or job or branch
            card = add(slug, "local", "%s@%s" % (slug, w["name"]), None, title, None, None, [], "", 0, [])
        if card is not None:
            holder_of[path] = card
            card["holders"].append({"worktree": path, "name": w["name"], "label": claim["label"] if claim else None,
                                    "branch": branch, "task": claim["task"] if claim else None,
                                    "by": claim["by"] if claim else None})

    # Rule 4 (second half): sessions, and the rows that join nothing.
    unjoined = unjoined_jobs = 0
    needs = []
    for r in rows:
        card = holder_of.get(where.get(r["id"]))
        if card is not None:
            card["sessions"].append({"id": r["id"], "source": r["source"], "pid": r["pid"], "label": r["label"],
                                     "seat": r["seat"], "text": r["text"], "profile": r["profile"],
                                     "state": r["kind"], "needs": r["needs"], "seen": r["seen"],
                                     "stale": r["stale"]})
            if card["form"] == "local":
                card["updated_at"] = max(card["updated_at"], r["since"])
        elif r["source"] == "job":
            unjoined_jobs += 1
        elif not r["needs"]:
            unjoined += 1
        if r["needs"]:
            needs.append({"id": r["id"], "pid": r["pid"], "kind": r["kind"], "reason": r["reason"],
                          "since": r["since"], "seen": r["seen"], "label": r["label"], "group": r["group"],
                          "profile": r["profile"], "card": card["key"] if card is not None else None})
    stale_jobs = sum(1 for r in rows if r["source"] == "job" and r["stale"])

    # Rules 5 to 7: stage, flags, log.
    named = {n["card"] for n in needs}
    for key, card in cards.items():
        login = login_of(card["slug"])
        card["stage"] = _stage(card, login, assignees[key])
        if card["stage"] == "landed":
            newest = max(p["merged_at"] for p in card["prs"] if p["state"] == "MERGED")
            card["trial_day"] = 1 + int((now - newest) // 86400)
        queued = card["form"] == "queue"
        card["assigned"] = bool(login) and login in assignees[key]
        card["unattended"] = (card["stage"] == "building" and not card["sessions"]
                              and not any(p["state"] == "OPEN" for p in card["prs"])
                              and not (card["queue"] and card["queue"]["state"] == "taken"))
        card["in_needs"] = key in named  # the page draws a card in Needs you only through a `needs` entry
        take = repo_of[card["slug"]]["take"]
        if card["stage"] != "inbox" or queued:
            card["takeable"] = "no"
        elif (card["assigned"] or card["mine"] or take == "auto"
              or (take.startswith("auto:") and take[5:] in card["labels"])):
            card["takeable"] = "yes"
        else:
            card["takeable"] = "ask"
        labels = {h["label"] for h in card["holders"] if h["label"]}
        card["log"] = [e for e in local["log"].get(card["slug"], []) if e["who"] in labels][-20:]

    ordered = sorted(cards.values(), key=_sort_key)  # rule 9
    blocked = [c for c in ordered if c["form"] == "issue" and "blocked" in c["labels"]]
    errors = sum(1 for s in repo_of if github["repos"].get(s, {}).get("error"))
    used = {r["account"] for r in repos}
    panel_at = who["fetched_at"]
    groups = []
    for r in repos:
        if r["group"] not in groups:
            groups.append(r["group"])
    return {
        "v": 1, "generated_at": float(now), "scope": scope,
        "health": {
            "accounts": [{"account": a, "fetched_at": d["fetched_at"], "interval": d["interval"],
                          "remaining": d["remaining"], "error": d["error"]}
                         for a, d in github["accounts"].items() if scope is None or a in used],
            "panel": who["sources"]["panel"], "panel_age": None if panel_at is None else now - panel_at,
            "jobs": who["sources"]["jobs"], "inbox": inbox["source"], "inbox_errors": len(inbox["errors"]),
            "repos": len(repos), "repo_errors": errors, "cards": len(ordered),
            "unattended": sum(1 for c in ordered if c["unattended"]), "unjoined": unjoined,
            "unjoined_jobs": unjoined_jobs, "stale_jobs": stale_jobs,
            "stamps_ignored": ignored, "blocked": len(blocked),
            "blocked_linked": sum(1 for c in blocked if c["blockers"] and c["blockers"]["total"] > 0),
            "blocked_clear": sum(1 for c in blocked if c["blockers"] and c["blockers"]["total"] > 0
                                 and c["blockers"]["open"] == 0),
            "needs_human": sum(1 for c in ordered if c["form"] == "issue" and "needs-human" in c["labels"])},
        "groups": groups,
        "repos": [{"slug": r["slug"], "name": r["name"], "group": r["group"], "intake": r["intake"],
                   "write": r["write"]} for r in repos],
        "cards": ordered,
        "needs": needs,
    }


def main(argv: list) -> int:
    ap = argparse.ArgumentParser(prog="model.py", description="Print the board built from document files.")
    ap.add_argument("--github", required=True)
    ap.add_argument("--local", required=True)
    ap.add_argument("--who")
    ap.add_argument("--inbox")
    ap.add_argument("--trial-days", type=int, default=7)
    ap.add_argument("--now", type=float)
    ap.add_argument("--scope")
    a = ap.parse_args(argv)

    def read(path, default):
        if path is None:
            return default
        with open(path, encoding="utf-8") as f:
            return json.load(f)

    board = build_board(read(a.github, None), read(a.local, None), read(a.who, NO_WHO), read(a.inbox, NO_INBOX),
                        a.trial_days, time.time() if a.now is None else a.now, a.scope)
    print(json.dumps(board))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
