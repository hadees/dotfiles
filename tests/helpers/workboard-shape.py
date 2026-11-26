"""workboard-shape.py <github|local|who|inbox|board> <file>

The frozen work-board documents as an executable check: exit 0 when the file is
one line of JSON with exactly the frozen keys at every level, each of the
frozen kind; else exit 1 and one line naming the first key that is missing,
unknown or of the wrong kind. Exit 2 is usage. Standard library, clean on 3.9.
"""
import json
import sys

# A schema is a type name, a dict (exactly these keys; a key starting with "?"
# may be absent), or one of the tuples built by the helpers below.
STR, INT, NUM, BOOL, PATH = "str", "int", "num", "bool", "path"


def maybe(t):
    return ("maybe", t)


def enum(*values):
    return ("enum", values)


def many(t):
    return ("list", t)


def table(t):
    return ("map", t)


def kind_of(v):
    return "null" if v is None else type(v).__name__


def want(schema):
    if isinstance(schema, dict):
        return "object"
    if isinstance(schema, str):
        return schema
    tag, arg = schema
    if tag == "maybe":
        return want(arg) + "|null"
    if tag == "enum":
        return "one of " + "/".join(str(a) for a in arg)
    return "list" if tag == "list" else "object of " + want(arg)


def check(v, schema, where):
    """Return None when v fits, else one line saying where it does not."""
    if isinstance(schema, dict):
        if not isinstance(v, dict):
            return "%s: want object, got %s" % (where, kind_of(v))
        for k, s in schema.items():
            if not k.startswith("?") and k not in v:
                return '%s: missing key "%s"' % (where, k)
        known = set(k.lstrip("?") for k in schema)
        for k in v:
            if k not in known:
                return '%s: unknown key "%s"' % (where, k)
        for k, s in schema.items():
            k = k.lstrip("?")
            if k in v:
                bad = check(v[k], s, where + "." + k)
                if bad:
                    return bad
        return None
    if isinstance(schema, str):
        ok = {STR: isinstance(v, str), PATH: isinstance(v, str) and v.startswith("/"),
              INT: isinstance(v, int) and not isinstance(v, bool),
              NUM: isinstance(v, (int, float)) and not isinstance(v, bool),
              BOOL: isinstance(v, bool)}[schema]
        return None if ok else "%s: want %s, got %s" % (where, schema, kind_of(v))
    tag, arg = schema
    if tag == "maybe":
        return None if v is None else check(v, arg, where)
    if tag == "enum":
        return None if any(type(v) is type(a) and v == a for a in arg) else "%s: want %s, got %s" % (where, want(schema), json.dumps(v))
    if tag == "list":
        if not isinstance(v, list):
            return "%s: want list, got %s" % (where, kind_of(v))
        for i, item in enumerate(v):
            bad = check(item, arg, "%s[%d]" % (where, i))
            if bad:
                return bad
        return None
    if not isinstance(v, dict):
        return "%s: want object, got %s" % (where, kind_of(v))
    for k, item in v.items():
        bad = check(item, arg, '%s["%s"]' % (where, k))
        if bad:
            return bad
    return None


V1 = enum(1)
PR_STATE = enum("OPEN", "MERGED", "CLOSED")
REVIEW = enum("APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED", "NONE")
CHECKS = enum("SUCCESS", "FAILURE", "PENDING", "NONE")
LOG_ENTRY = {"at": STR, "who": STR, "kind": STR, "text": STR}

GITHUB = {
    "v": V1,
    "accounts": table({"login": STR, "fetched_at": NUM, "cost": INT, "remaining": INT, "interval": INT, "error": maybe(STR)}),
    "repos": table({"account": STR, "default_branch": maybe(STR), "error": maybe(STR)}),
    "issues": many({
        "slug": STR, "number": INT, "title": STR, "url": STR, "body": STR, "updated_at": INT,
        "author": maybe(STR), "assignees": many(STR), "labels": many(STR),
        "prs": many({"number": INT, "url": STR, "state": PR_STATE, "draft": BOOL, "merged_at": maybe(INT),
                     "branch": STR, "author": maybe(STR)})}),
    "prs": many({
        "slug": STR, "number": INT, "title": STR, "url": STR, "state": enum("OPEN", "MERGED"), "draft": BOOL,
        "branch": STR, "updated_at": INT, "merged_at": maybe(INT), "review": REVIEW, "merge": STR, "checks": CHECKS,
        "closes": many({"slug": STR, "number": INT, "title": STR, "url": STR, "state": enum("OPEN", "CLOSED")})}),
}

LOCAL = {
    "v": V1, "generated_at": NUM, "skipped": INT,
    "repos": many({"slug": STR, "name": STR, "dir": PATH, "common": PATH, "group": STR, "account": STR, "profile": PATH,
                   "intake": STR, "write": BOOL, "take": STR, "notify_lead": BOOL}),
    "worktrees": many({
        "slug": STR, "path": PATH, "name": STR, "branch": maybe(STR), "main": BOOL,
        "claim": maybe({"label": STR, "by": STR, "task": maybe(STR), "handoff": BOOL, "started": maybe(INT)}),
        "open_claim": maybe(STR)}),
    "links": many({"slug": STR, "number": INT, "worktree": PATH, "at": INT}),
    "log": table(many(LOG_ENTRY)),
}

WHO = {
    "v": V1, "fetched_at": maybe(NUM),
    "sources": {"panel": enum("ok", "down"), "jobs": enum("off", "ok", "error")},
    "rows": many({
        "id": STR, "source": enum("session", "job"), "pid": maybe(INT), "profile": STR, "label": STR, "group": STR,
        "role": STR, "seat": maybe(STR), "text": maybe(STR), "kind": STR, "reason": STR, "since": INT, "seen": BOOL,
        "needs": BOOL, "stale": BOOL, "dir": maybe(STR)}),
}

STATE = enum("waiting", "taken", "done", "dropped", "parked")
INBOX = {
    "v": V1, "fetched_at": maybe(NUM), "source": enum("none", "queue"), "errors": table(STR),
    "rows": many({
        "slug": STR, "id": STR, "state": STATE, "kind": STR, "who": STR, "text": STR, "file": maybe(STR),
        "issue": maybe(INT), "added": maybe(INT), "order": maybe(INT), "tier": maybe(INT), "score": maybe(STR),
        "lo": maybe(STR), "hi": maybe(STR), "terms": maybe(STR), "cand": BOOL, "age": maybe(STR)}),
}

CARD = {
    "key": STR, "form": enum("local", "pr", "issue", "queue"), "slug": STR, "repo": STR, "group": STR,
    "number": maybe(INT), "title": STR, "url": maybe(STR), "stage": enum("inbox", "building", "review", "landed"),
    "in_needs": BOOL, "author": maybe(STR), "mine": BOOL, "assigned": BOOL, "labels": many(STR), "body": STR,
    "updated_at": INT, "trial_day": maybe(INT), "unattended": BOOL, "takeable": enum("yes", "ask", "no"),
    "queue": maybe({"id": STR, "state": STATE, "kind": STR, "order": maybe(INT), "tier": maybe(INT),
                    "score": maybe(STR), "terms": maybe(STR), "cand": BOOL, "file": maybe(STR)}),
    "prs": many({"number": INT, "url": STR, "state": PR_STATE, "draft": BOOL, "checks": CHECKS, "review": REVIEW,
                 "merge": STR, "branch": STR, "merged_at": maybe(INT)}),
    "holders": many({"worktree": PATH, "name": STR, "label": maybe(STR), "branch": maybe(STR), "task": maybe(STR),
                     "by": maybe(STR)}),
    "sessions": many({"id": STR, "source": enum("session", "job"), "pid": maybe(INT), "label": STR, "seat": maybe(STR),
                      "text": maybe(STR), "profile": STR, "state": STR, "needs": BOOL, "seen": BOOL, "stale": BOOL}),
    "log": many(LOG_ENTRY),
}

# "?rev", "?build" and "?sets" are what the server adds to the board it serves (and the
# demo board.json carries); a board straight from build_board has neither.
BOARD = {
    "v": V1, "generated_at": NUM, "scope": maybe(PATH),
    "health": {
        "accounts": many({"account": STR, "fetched_at": NUM, "interval": INT, "remaining": INT, "error": maybe(STR)}),
        "panel": enum("ok", "down"), "panel_age": maybe(NUM), "jobs": enum("off", "ok", "error"),
        "inbox": enum("none", "queue"), "inbox_errors": INT, "repos": INT, "repo_errors": INT, "cards": INT,
        "unattended": INT, "unjoined": INT, "unjoined_jobs": INT, "stale_jobs": INT},
    "groups": many(STR),
    "repos": many({"slug": STR, "name": STR, "group": STR, "intake": STR, "write": BOOL}),
    "cards": many(CARD),
    "needs": many({"id": STR, "pid": INT, "kind": STR, "reason": STR, "since": INT, "seen": BOOL, "label": STR,
                   "group": STR, "profile": STR, "card": maybe(STR)}),
    "?rev": INT, "?build": STR, "?sets": table(many(STR)),
}

SCHEMAS = {"github": GITHUB, "local": LOCAL, "who": WHO, "inbox": INBOX, "board": BOARD}


def main(argv):
    if len(argv) != 3 or argv[1] not in SCHEMAS:
        print("usage: workboard-shape.py <%s> <file>" % "|".join(SCHEMAS))
        return 2
    try:
        with open(argv[2], encoding="utf-8") as f:
            text = f.read()
        doc = json.loads(text)
    except (OSError, ValueError) as e:
        print("%s: %s" % (argv[2], type(e).__name__))
        return 1
    if "\n" in text.rstrip("\n"):
        print("document: not one line")
        return 1
    bad = check(doc, SCHEMAS[argv[1]], argv[1])
    if bad:
        print(bad)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
