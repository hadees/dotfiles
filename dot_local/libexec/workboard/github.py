"""The work board's GitHub reader: one GraphQL request per account, normalised
into the github/1 document. Standard library only, clean on 3.9.

Nothing here writes a file or a log: no document, response or token is ever
kept outside this process's memory. Run by hand it prints counts, never a
title, a body or a label.

    github.py --local <file> [--budget <n>]    one live pass, one line per account
    github.py --fixture <dir>                  print <dir>/github.json, call nothing
"""
import argparse
import calendar
import json
import math
import os
import subprocess
import sys
import time
from typing import Optional

DEFAULT_BUDGET = 1200
TIMEOUT = 20
OPEN_LIMIT = 50
TOO_MANY = "more than %d open pull requests; some are not shown" % OPEN_LIMIT
LOW = "rate budget low"
KEYS = ["v", "accounts", "repos", "issues", "prs"]

_TOKENS = {}  # account -> token, in memory only
_LOGINS = {}  # account -> login, in memory only
_TALLY = {"polls": 0, "poll_errors": 0, "skipped_budget": 0}


def _git_config(key: str) -> str:
    try:
        out = subprocess.run(["git", "config", "--get", key], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, universal_newlines=True, timeout=TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return out.stdout.strip()


def account_of(owner: str) -> str:
    """The rule of bin/executable_git-credential-gh-user and of gh() in dot_functions."""
    return _git_config("credential.https://github.com/%s.username" % owner.lower()) or "-"


def _gh() -> str:
    return os.environ.get("WORKBOARD_GH") or "gh"


def token_for(account: str) -> Optional[str]:
    if account == "-":
        return None
    try:
        out = subprocess.run([_gh(), "auth", "token", "--user", account], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, universal_newlines=True, timeout=TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip() or None


def _budget(budget) -> int:
    if budget and budget > 0:
        return int(budget)
    try:
        n = int(_git_config("workboard.budget"))
    except ValueError:
        n = 0
    return n if n > 0 else DEFAULT_BUDGET


def next_interval(cost: int, remaining: int, budget: int) -> int:
    if remaining < 300:
        return 0
    n = max(60, math.ceil(3600 * cost / budget))
    return n * 2 if remaining < 1000 else n


def tally() -> dict:
    return dict(_TALLY)


def build_query(repos: list) -> str:
    """Owner, name and label reach the document only as JSON string literals (json.dumps)."""
    order = "orderBy: {field: UPDATED_AT, direction: DESC}"
    closing = ("closingIssuesReferences(first: 5) { nodes { number title url state "
               "repository { nameWithOwner } } }")
    issue = ("number title url updatedAt body author { login } assignees(first: 5) { nodes { login } } "
             "labels(first: 10) { nodes { name } } "
             "closedByPullRequestsReferences(first: 5, includeClosedPrs: true) { nodes { number url state "
             "isDraft merged mergedAt headRefName author { login } } }")
    parts = [
        "query($login: String!) {",
        "rateLimit { cost remaining }",
        "viewer {",
        "open: pullRequests(first: %d, states: OPEN, %s) { totalCount nodes { number url title isDraft "
        "headRefName updatedAt reviewDecision mergeStateStatus repository { nameWithOwner } %s "
        "commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } }" % (OPEN_LIMIT, order, closing),
        "merged: pullRequests(first: 30, states: MERGED, %s) { nodes { number url title mergedAt "
        "headRefName repository { nameWithOwner } %s } }" % (order, closing),
        "}",
    ]
    for i, r in enumerate(repos):
        owner, name = r["slug"].split("/", 1)
        intake = r.get("intake", "none")
        body = ["defaultBranchRef { name }"]
        if intake == "mine":
            body.append("assigned: issues(first: 30, filterBy: {assignee: $login, states: OPEN}, %s) { nodes { %s } }"
                        % (order, issue))
            body.append("created: issues(first: 30, filterBy: {createdBy: $login, states: OPEN}, %s) { nodes { %s } }"
                        % (order, issue))
        elif intake == "all":
            body.append("issues(first: 50, states: OPEN, %s) { nodes { %s } }" % (order, issue))
        elif intake.startswith("label:"):
            body.append("issues(first: 50, labels: [%s], states: OPEN, %s) { nodes { %s } }"
                        % (json.dumps(intake[6:]), order, issue))
        parts.append("r%d: repository(owner: %s, name: %s) { %s }"
                     % (i, json.dumps(owner), json.dumps(name), " ".join(body)))
    parts.append("}")
    return "\n".join(parts)


def _epoch(s) -> Optional[int]:
    return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ")) if s else None


def _nodes(conn) -> list:
    return (conn or {}).get("nodes") or []


def _login(who) -> Optional[str]:
    return (who or {}).get("login")


def _checks(pr: dict) -> str:
    rollup = None
    for n in _nodes(pr.get("commits")):
        rollup = ((n.get("commit") or {}).get("statusCheckRollup") or {}).get("state")
    return {"SUCCESS": "SUCCESS", "FAILURE": "FAILURE", "ERROR": "FAILURE", "PENDING": "PENDING",
            "EXPECTED": "PENDING"}.get(rollup, "NONE")


def normalize(account: str, login: str, response: dict, repos: list) -> dict:
    """A partial github/1 document for one account: no fetched_at or interval (poll adds them)."""
    data = response.get("data") or {}
    errors = response.get("errors") or []
    by_lower = {r["slug"].lower(): r["slug"] for r in repos}
    rate = data.get("rateLimit") or {}
    viewer = data.get("viewer") or {}
    acct = {"login": login, "cost": rate.get("cost", 0), "remaining": rate.get("remaining", 0), "error": None}
    if (viewer.get("open") or {}).get("totalCount", 0) > OPEN_LIMIT:
        acct["error"] = TOO_MANY
    out = {"accounts": {account: acct}, "repos": {}, "issues": [], "prs": []}

    seen = set()
    for state, key in (("OPEN", "open"), ("MERGED", "merged")):
        for p in _nodes(viewer.get(key)):
            slug = by_lower.get(((p.get("repository") or {}).get("nameWithOwner") or "").lower())
            if slug is None or (slug, p["number"]) in seen:
                continue
            seen.add((slug, p["number"]))
            merged_at = _epoch(p.get("mergedAt"))
            out["prs"].append({
                "slug": slug, "number": p["number"], "title": p["title"], "url": p["url"], "state": state,
                "draft": bool(p.get("isDraft")), "branch": p["headRefName"],
                "updated_at": _epoch(p.get("updatedAt")) or merged_at, "merged_at": merged_at,
                "review": p.get("reviewDecision") or "NONE", "merge": p.get("mergeStateStatus") or "UNKNOWN",
                "checks": _checks(p) if state == "OPEN" else "NONE",
                "closes": [{"slug": by_lower.get(c["repository"]["nameWithOwner"].lower(),
                                                 c["repository"]["nameWithOwner"]),
                            "number": c["number"], "title": c["title"], "url": c["url"], "state": c["state"]}
                           for c in _nodes(p.get("closingIssuesReferences"))]})

    for i, r in enumerate(repos):
        alias = "r%d" % i
        node = data.get(alias)
        if node is None:
            msg = next((e.get("message") for e in errors if (e.get("path") or [None])[0] == alias), None)
            out["repos"][r["slug"]] = {"account": account, "default_branch": None,
                                       "error": msg or "repository not found"}
            continue
        out["repos"][r["slug"]] = {"account": account, "error": None,
                                   "default_branch": (node.get("defaultBranchRef") or {}).get("name")}
        found = {}
        for key in ("assigned", "created", "issues"):
            for n in _nodes(node.get(key)):
                found[n["number"]] = n
        for n in found.values():
            out["issues"].append({
                "slug": r["slug"], "number": n["number"], "title": n["title"], "url": n["url"],
                "body": n.get("body") or "", "updated_at": _epoch(n.get("updatedAt")),
                "author": _login(n.get("author")), "assignees": [a["login"] for a in _nodes(n.get("assignees"))],
                "labels": [l["name"] for l in _nodes(n.get("labels"))],
                "prs": [{"number": p["number"], "url": p["url"], "state": p["state"], "draft": bool(p.get("isDraft")),
                         "merged_at": _epoch(p.get("mergedAt")), "branch": p["headRefName"],
                         "author": _login(p.get("author"))}
                        for p in _nodes(n.get("closedByPullRequestsReferences"))]})
    return out


def _json(text: str):
    try:
        return json.loads(text)
    except ValueError:
        return None


def _request(account: str, query: str, login: Optional[str] = None):
    """-> (response body, None) or (None, a fixed failure word). The token is asked for again only
    after an authentication failure. gh prints the body and exits non-zero when the response carries
    `errors`, so a body with data is used whatever the exit status."""
    for attempt in (0, 1):
        token = None
        if account != "-":
            token = _TOKENS.get(account) or token_for(account)
            if not token:
                return None, "no token for " + account
            _TOKENS[account] = token
        argv = [_gh(), "api", "graphql", "-f", "query=" + query]
        if login:
            argv += ["-f", "login=" + login]
        env = dict(os.environ)
        if token:
            env["GH_TOKEN"] = token
        try:
            p = subprocess.run(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               universal_newlines=True, timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            return None, "request timed out"
        except OSError:
            return None, "gh not found"
        body = _json(p.stdout)
        if isinstance(body, dict) and body.get("data"):
            return body, None
        auth = "401" in p.stderr or "bad credentials" in p.stderr.lower()
        if auth and attempt == 0 and account != "-":
            _TOKENS.pop(account, None)
            continue
        return None, "authentication failed" if auth else "request failed"
    return None, "authentication failed"


def _carry(prior: dict, account: str, repos: list, error: Optional[str] = None) -> dict:
    """The account's part of the prior document as it was, with `error` set on it when given."""
    slugs = [r["slug"] for r in repos]
    a = dict((prior.get("accounts") or {}).get(account) or
             {"login": account, "fetched_at": 0.0, "cost": 0, "remaining": 0, "interval": 60, "error": None})
    if error:
        a["error"] = error
    out_repos = {}
    for s in slugs:
        r = dict((prior.get("repos") or {}).get(s) or
                 {"account": account, "default_branch": None, "error": "not fetched yet"})
        if error:
            r["error"] = error
        out_repos[s] = r
    return {"accounts": {account: a}, "repos": out_repos,
            "issues": [i for i in prior.get("issues") or [] if i["slug"] in slugs],
            "prs": [p for p in prior.get("prs") or [] if p["slug"] in slugs]}


def _fetch(account: str, repos: list, prior: dict, budget: int, now: float) -> dict:
    was = (prior.get("accounts") or {}).get(account)
    # ponytail: GitHub's limit resets hourly, so a budget-low skip is lifted an hour after the last fetch
    if was and was.get("interval") == 0 and now - was.get("fetched_at", 0) < 3600:
        _TALLY["skipped_budget"] += 1
        return _carry(prior, account, repos, LOW)
    _TALLY["polls"] += 1
    login = _LOGINS.get(account)
    failure = None
    if not login:
        body, failure = _request(account, "query { viewer { login } }")
        login = (((body or {}).get("data") or {}).get("viewer") or {}).get("login")
        if login:
            _LOGINS[account] = login
        else:
            failure = failure or "request failed"
    if not failure:
        body, failure = _request(account, build_query(repos), login)
    if failure:
        _TALLY["poll_errors"] += 1
        return _carry(prior, account, repos, failure)
    part = normalize(account, login, body, repos)
    a = part["accounts"][account]
    a["fetched_at"] = float(now)
    a["interval"] = next_interval(a["cost"], a["remaining"], budget)
    if a["interval"] == 0:
        a["error"] = LOW
    return part


def poll(local: dict, prior: Optional[dict], budget: int, now: float, only: Optional[list]) -> dict:
    prior = prior or {}
    budget = _budget(budget)
    by_account = {}
    for r in local["repos"]:
        by_account.setdefault(r["account"], []).append(r)
    doc = {"v": 1, "accounts": {}, "repos": {}, "issues": [], "prs": []}
    for account, repos in by_account.items():
        if only is not None and account not in only:
            part = _carry(prior, account, repos)
        else:
            part = _fetch(account, repos, prior, budget, now)
        doc["accounts"].update(part["accounts"])
        doc["repos"].update(part["repos"])
        doc["issues"] += part["issues"]
        doc["prs"] += part["prs"]
    return doc


def _counts(doc: dict) -> list:
    lines = []
    for key, a in doc["accounts"].items():
        slugs = [s for s, r in doc["repos"].items() if r["account"] == key]
        lines.append("%s · cost %d · remaining %d · interval %d · issues %d · prs %d · %s" % (
            key, a["cost"], a["remaining"], a["interval"],
            sum(1 for i in doc["issues"] if i["slug"] in slugs), sum(1 for p in doc["prs"] if p["slug"] in slugs),
            "error" if a["error"] else "ok"))
    return lines


def main(argv: list) -> int:
    ap = argparse.ArgumentParser(prog="github.py")
    ap.add_argument("--local")
    ap.add_argument("--budget", type=int)
    ap.add_argument("--fixture")
    args = ap.parse_args(argv)
    if args.fixture:
        with open(os.path.join(args.fixture, "github.json"), encoding="utf-8") as f:
            text = f.read()
        doc = _json(text)
        if not isinstance(doc, dict) or list(doc) != KEYS:
            print("github.py: top-level keys are not %s" % ", ".join(KEYS), file=sys.stderr)
            return 1
        print(text.strip())
        return 0
    if not args.local:
        ap.error("--local or --fixture is required")
    with open(args.local, encoding="utf-8") as f:
        local = json.load(f)
    print("\n".join(_counts(poll(local, None, args.budget, time.time(), None))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
