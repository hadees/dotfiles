#!/usr/bin/env python3
"""Parity contract and transport harness for the claude-codex proxy.

    claude-proxy-parity.py transport --proxy-bin PATH
    claude-proxy-parity.py assess --report PATH

Both print one JSON object (schema in docs/claude-proxy.md). `transport` runs
the proxy against a loopback fixture upstream and checks that Anthropic
traffic passes through unchanged; it never contacts a real provider and uses
no credentials. `assess` validates a complete acceptance report. Standard
library only.
"""
import argparse
import collections
import http.client
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCHEMA_VERSION = 2
PINNED_PROXY_VERSION = "0.8.0"
PINNED_SOURCE_COMMIT = "ead919ff0d8993696a496cce19ef31becf90260b"

TRANSPORT_IDS = [
    "transport.messages",
    "transport.count-tokens",
    "transport.body",
    "transport.request-headers",
    "transport.response-headers",
    "transport.streaming",
    "transport.quota-429",
    "transport.throttle-429",
]
ACCEPTANCE_IDS = [
    "cli.cache-read",
    "cli.cache-ttl",
    "cli.token-count",
    "cli.tool-search",
    "cli.effort",
    "cli.provider-routing",
    "cli.gpt-tool-roundtrip",
    "cli.fable-handover",
    "cli.route-modes",
    "interactive.usage",
    "interactive.context",
    "interactive.fast",
    "interactive.remote-control",
    "interactive.direct-feature-inventory",
    "service.lifecycle",
]
REQUIRED_IDS = TRANSPORT_IDS + ACCEPTANCE_IDS
STATUSES = ["pass", "fail", "blocked", "skipped", "accepted_difference"]
LAYERS = ["transport", "cli", "interactive", "service"]
FEATURE_PREFIX = "interactive.feature."
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]*$")
# The one check that may be an accepted difference, and what must back it.
REMOTE_CONTROL = "interactive.remote-control"
REMOTE_CONTROL_EVIDENCE = ["direct:", "routed-refused:", "opt-out:"]

# Transport framing, excluded from application-header equality.
FRAMING = {
    "host", "content-length", "content-encoding", "accept-encoding", "connection",
    "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer",
    "transfer-encoding", "upgrade",
}

# ---------------------------------------------------------------------------
# Fixtures: request and response bytes the checks send and expect back.
# ---------------------------------------------------------------------------

MESSAGES_TARGET = "/v1/messages?beta=true"
COUNT_TARGET = "/v1/messages/count_tokens?beta=true"

# Deliberately non-canonical (key order, spacing, escapes, number spelling)
# so that any re-serialisation changes the bytes.
RICH_BODY = (
    b'{ "model" : "claude-sonnet-4-5",\n'
    b' "max_tokens":64 , "effort":"medium",\n'
    b' "system":[{"type":"text","text":"second \\u00e9 first?"},\n'
    b'   {"type":"text","text":"cached","cache_control":{"type":"ephemeral","ttl":"1h"}}],\n'
    b' "x_unknown_field":{"b":[1.0e0,2,{"z":null,"a":true}]},\n'
    b' "output_config":{"effort":"high"},\n'
    b' "tools":[{"name":"parity_echo","description":"Echo text.",\n'
    b'   "input_schema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]},\n'
    b'   "cache_control":{"type":"ephemeral","ttl":"1h"}}],\n'
    b' "messages":[\n'
    b'  {"role":"user","content":"hello","effort":"low"},\n'
    b'  {"role":"assistant","content":[\n'
    b'    {"type":"thinking","thinking":"hm","signature":"c2lnbmVkLWJ5LWFudGhyb3BpYw=="},\n'
    b'    {"type":"tool_use","id":"toolu_01","name":"parity_echo","input":{"text":"x"}}]},\n'
    b'  {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01","content":"x"}]}\n'
    b' ] }  \n'
)
PLAIN_BODY = (
    b'{"messages":[{"role":"user","content":"hi"}],"stream":false,'
    b'"max_tokens":8,"model":"claude-haiku-4-5","system":"plain"}'
)
COUNT_BODY = (
    b'{ "tools":[], "messages":[{"role":"user","content":"count me"}],\n'
    b'  "model":"claude-sonnet-4-5" }'
)

REQUEST_HEADERS = [
    ("content-type", "application/json"),
    ("authorization", "Bearer dummy-token-not-a-credential"),
    ("anthropic-version", "2023-06-01"),
    ("anthropic-beta", "claude-code-20250219,oauth-2025-04-20"),
    ("anthropic-beta", "extended-cache-ttl-2025-04-11"),
    ("anthropic-future-widget", "7"),
    ("x-app", "cli"),
    ("x-fixture-dup", "one"),
    ("x-fixture-dup", "two"),
    ("user-agent", "parity-fixture/1"),
    ("x-claude-code-session-id", "00000000-0000-4000-8000-000000000000"),
]

UNIFIED = [
    ("anthropic-ratelimit-unified-status", "allowed_warning"),
    ("anthropic-ratelimit-unified-reset", "1893456000"),
    ("anthropic-ratelimit-unified-5h-utilization", "0.42"),
    ("anthropic-ratelimit-unified-7d-utilization", "0.91"),
    ("anthropic-ratelimit-unified-representative-claim", "seven_day"),
]
JSON_CT = ("content-type", "application/json")
OK_BODY = b'{"id":"msg_fixture","type":"message","role":"assistant","content":[],"usage":{"input_tokens":1,"output_tokens":1}}'
OVERLOADED_BODY = b'{"type":"error","error":{"type":"overloaded_error","message":"fixture overloaded"}}'
QUOTA_BODY = b'{"type":"error","error":{"type":"rate_limit_error","message":"fixture usage limit reached"}}'
THROTTLE_BODY = b'{"type":"error","error":{"type":"rate_limit_error","message":"fixture transient throttle"}}'
SSE_FIRST = (
    b'event: message_start\ndata: {"type":"message_start","message":{"id":"msg_s"}}\n\n'
    b'event: ping\ndata: {"type":"ping"}\n\n'
)
SSE_REST = [
    b'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"a"}}\n\n',
    b'event: ping\ndata: {"type":"ping"}\n\n',
    b'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\n',
    b'event: message_stop\ndata: {"type":"message_stop"}\n\n',
]

# scenario -> (status, headers, body); the stream scenario is special-cased.
SCENARIOS = {
    "ok": (200, [JSON_CT, ("request-id", "req_fixture_ok"),
                 ("x-fixture-dup", "one"), ("x-fixture-dup", "two")] + UNIFIED, OK_BODY),
    "count": (200, [JSON_CT], b'{"input_tokens":42}'),
    "overloaded": (529, [JSON_CT, ("retry-after", "7"), ("anthropic-should-retry", "true"),
                         ("request-id", "req_fixture_529")] + UNIFIED, OVERLOADED_BODY),
    "quota": (429, [JSON_CT, ("retry-after", "3600"),
                    ("anthropic-ratelimit-unified-status", "rejected"),
                    ("anthropic-ratelimit-unified-reset", "1893456000"),
                    ("anthropic-ratelimit-unified-representative-claim", "seven_day_overage_included"),
                    ("anthropic-ratelimit-unified-overage-status", "rejected")], QUOTA_BODY),
    "throttle": (429, [JSON_CT, ("retry-after", "2"),
                       ("anthropic-ratelimit-requests-remaining", "0"),
                       ("anthropic-ratelimit-unified-status", "allowed")], THROTTLE_BODY),
    "stream": (200, [("content-type", "text/event-stream"), ("cache-control", "no-cache")], None),
}


class _UpstreamHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        up = self.server
        body = self.rfile.read(int(self.headers.get("content-length") or 0))
        up.requests.append({
            "target": self.path,
            "headers": [(k.lower(), v) for k, v in self.headers.items()],
            "body": body,
        })
        status, headers, payload = SCENARIOS[self.headers.get("x-parity-scenario", "ok")]
        self.send_response_only(status)
        for k, v in headers:
            self.send_header(k, v)
        if payload is not None:
            self.send_header("content-length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()
        up.gate.clear()
        self._chunk(SSE_FIRST)
        # Hold the rest until the client reports it has the first events. A
        # proxy that buffers until completion never reports, so this times out.
        up.gate_timed_out = not up.gate.wait(3)
        for ev in SSE_REST:
            self._chunk(ev)
        self.wfile.write(b"0\r\n\r\n")

    def _chunk(self, data):
        self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
        self.wfile.flush()


class Upstream(ThreadingHTTPServer):
    """Loopback stand-in for the Anthropic API that records what it receives."""
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), _UpstreamHandler)
        self.requests = []
        self.gate = threading.Event()
        self.gate_timed_out = False
        threading.Thread(target=self.serve_forever, daemon=True).start()

    @property
    def url(self):
        return "http://127.0.0.1:%d" % self.server_address[1]


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _post(port, target, body, headers, read_hook=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    conn.putrequest("POST", target, skip_accept_encoding=True)
    for k, v in headers + [("content-length", str(len(body)))]:
        conn.putheader(k, v)
    conn.endheaders(body)
    resp = conn.getresponse()
    if read_hook:
        data = read_hook(resp)
    else:
        data = resp.read()
    out = (resp.status, [(k.lower(), v) for k, v in resp.getheaders()], data)
    conn.close()
    return out


def _application(headers):
    return collections.Counter((k.lower(), v) for k, v in headers if k.lower() not in FRAMING)


def _lost(sent, got):
    """Application headers in `sent` that are missing or altered in `got`."""
    return sorted("%s: %s" % kv for kv in (_application(sent) - _application(got)))


def _exchange(ctx, scenario, target, body, headers=REQUEST_HEADERS, read_hook=None):
    """One request through the proxy; returns (response, upstream request, index)."""
    before = len(ctx.requests)
    resp = _post(ctx.port, target, body, headers + [("x-parity-scenario", scenario)], read_hook)
    seen = ctx.requests[before:]
    if len(seen) != 1:
        raise AssertionError("upstream saw %d requests, expected 1" % len(seen))
    return resp, seen[0], before


class Context:
    def __init__(self, port, upstream):
        self.port = port
        self.requests = upstream.requests
        self.upstream = upstream


def _fail(reason):
    raise AssertionError(reason)


def _check_messages(ctx):
    (status, _, _), req, i = _exchange(ctx, "ok", MESSAGES_TARGET, PLAIN_BODY)
    if req["target"] != MESSAGES_TARGET:
        _fail("upstream target %r, sent %r" % (req["target"], MESSAGES_TARGET))
    if status != 200:
        _fail("status %d" % status)
    return ["upstream-request:%d" % i]


def _check_count_tokens(ctx):
    (status, _, body), req, i = _exchange(ctx, "count", COUNT_TARGET, COUNT_BODY)
    if req["target"] != COUNT_TARGET:
        _fail("upstream target %r, sent %r" % (req["target"], COUNT_TARGET))
    if status != 200 or body != SCENARIOS["count"][2]:
        _fail("status %d body %r" % (status, body))
    if req["body"] != COUNT_BODY:
        _fail("count_tokens body changed")
    return ["upstream-request:%d" % i]


def _check_body(ctx):
    evidence = []
    for name, target, body in (("rich", MESSAGES_TARGET, RICH_BODY), ("plain", MESSAGES_TARGET, PLAIN_BODY),
                               ("count", COUNT_TARGET, COUNT_BODY)):
        (status, _, _), req, i = _exchange(ctx, "ok", target, body)
        if status != 200:
            _fail("%s body: status %d" % (name, status))
        if req["body"] != body:
            _fail("%s body bytes changed (%d sent, %d received)" % (name, len(body), len(req["body"])))
        evidence.append("upstream-request:%d" % i)
    return evidence


def _check_request_headers(ctx):
    _, req, i = _exchange(ctx, "ok", MESSAGES_TARGET, PLAIN_BODY)
    lost = _lost(REQUEST_HEADERS, req["headers"])
    if lost:
        _fail("request headers lost or altered: %s" % "; ".join(lost))
    return ["upstream-request:%d" % i]


def _check_response_headers(ctx):
    evidence = []
    for scenario in ("ok", "overloaded"):
        status, headers, payload = SCENARIOS[scenario]
        (got_status, got_headers, got_body), _, i = _exchange(ctx, scenario, MESSAGES_TARGET, PLAIN_BODY)
        lost = _lost(headers, got_headers)
        if got_status != status or got_body != payload or lost:
            _fail("%s: status %d (want %d), body %s, headers lost or altered: %s" % (
                scenario, got_status, status, "same" if got_body == payload else "changed", "; ".join(lost) or "none"))
        evidence.append("upstream-request:%d" % i)
    return evidence


def _check_streaming(ctx):
    seen_first = {}

    def read(resp):
        buf = b""
        while True:
            chunk = resp.read1(65536)
            if not chunk:
                return buf
            buf += chunk
            if not seen_first and SSE_FIRST in buf:
                seen_first["t"] = True
                ctx.upstream.gate.set()

    (status, _, body), _, i = _exchange(ctx, "stream", MESSAGES_TARGET, PLAIN_BODY, read_hook=read)
    ctx.upstream.gate.set()
    if status != 200:
        _fail("status %d" % status)
    if ctx.upstream.gate_timed_out:
        _fail("first events did not arrive before the upstream finished: response is buffered")
    if body != SSE_FIRST + b"".join(SSE_REST):
        _fail("event stream bytes or order changed")
    return ["upstream-request:%d" % i]


def _check_429(scenario):
    def check(ctx):
        status, headers, payload = SCENARIOS[scenario]
        (got_status, got_headers, got_body), _, i = _exchange(ctx, scenario, MESSAGES_TARGET, PLAIN_BODY)
        lost = _lost(headers, got_headers)
        if got_status != status or got_body != payload or lost:
            _fail("status %d (want %d), body %s, headers lost or altered: %s" % (
                got_status, status, "same" if got_body == payload else "changed", "; ".join(lost) or "none"))
        return ["upstream-request:%d" % i]
    return check


TRANSPORT_CHECKS = {
    "transport.messages": _check_messages,
    "transport.count-tokens": _check_count_tokens,
    "transport.body": _check_body,
    "transport.request-headers": _check_request_headers,
    "transport.response-headers": _check_response_headers,
    "transport.streaming": _check_streaming,
    "transport.quota-429": _check_429("quota"),
    "transport.throttle-429": _check_429("throttle"),
}


def run_transport(port, upstream):
    """Run every transport check against a proxy on `port`; returns check dicts."""
    ctx = Context(port, upstream)
    checks = []
    for cid in TRANSPORT_IDS:
        try:
            evidence = TRANSPORT_CHECKS[cid](ctx)
            checks.append(_check(cid, "pass", "ok", evidence))
        except Exception as e:  # any defect is this check's failure, not a crash
            checks.append(_check(cid, "fail", str(e) or type(e).__name__, []))
    return checks


def _check(cid, status, reason, evidence):
    return {"id": cid, "layer": cid.split(".")[0], "status": status, "reason": reason, "evidence": evidence}


def _counts(checks):
    c = collections.Counter(ch["status"] for ch in checks)
    return {s: c.get(s, 0) for s in STATUSES}


def _report(scope, checks, proxy_version, source_commit, **extra):
    report = {
        "schema_version": SCHEMA_VERSION,
        "scope": scope,
        "source_commit": source_commit,
        "claude_version": None,
        "proxy_version": proxy_version,
        "codex_version": None,
        "feature_inventory": [],
        "checks": checks,
        "counts": _counts(checks),
        "eligible": False,
    }
    report.update(extra)
    return report


# ---------------------------------------------------------------------------
# transport: start the real proxy against the fixture upstream
# ---------------------------------------------------------------------------

def _blocked(reason, proxy_version="unknown"):
    checks = [_check(cid, "blocked", reason, []) for cid in TRANSPORT_IDS]
    return _report("transport", checks, proxy_version, "unknown")


def _start_proxy(binary, upstream_url, work):
    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": work,
        "XDG_CONFIG_HOME": os.path.join(work, "config"),
        "XDG_STATE_HOME": os.path.join(work, "state"),
        "CCP_CONFIG_DIR": os.path.join(work, "ccp"),
        "CCP_BIND_ADDRESS": "127.0.0.1",
        "CCP_ALIAS_PROVIDER": "anthropic",
        "CCP_ANTHROPIC_BASE_URL": upstream_url,
        "NO_PROXY": "*",
    }
    os.makedirs(env["CCP_CONFIG_DIR"], exist_ok=True)
    log = open(os.path.join(work, "proxy.log"), "wb")
    last = "proxy did not start"
    for _ in range(3):  # the free port can be taken between probe and bind
        port = _free_port()
        proc = subprocess.Popen([binary, "serve", "--port", str(port), "--no-monitor"],
                                env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and proc.poll() is None:
            try:
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
                conn.request("GET", "/healthz")
                if conn.getresponse().status == 200:
                    return proc, port
            except OSError:
                time.sleep(0.1)
        proc.kill()
        proc.wait()
        with open(os.path.join(work, "proxy.log"), errors="replace") as f:
            last = "proxy did not become healthy: " + f.read()[-300:].strip()
    return None, last


def cmd_transport(args):
    binary = args.proxy_bin
    if not (os.path.isfile(binary) and os.access(binary, os.X_OK)):
        return _blocked("proxy binary not found or not executable: %s" % binary), 2
    try:
        out = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=10).stdout
        version = re.search(r"\d+\.\d+\.\d+\S*", out).group(0)
    except (OSError, subprocess.SubprocessError, AttributeError) as e:
        return _blocked("cannot read proxy version: %s" % e), 2
    work = tempfile.mkdtemp(prefix="claude-proxy-parity-")
    upstream = Upstream()
    proc = None
    try:
        proc, port = _start_proxy(binary, upstream.url, work)
        if proc is None:
            return _blocked(port, version), 2
        checks = run_transport(port, upstream)
    finally:
        if proc is not None:
            proc.terminate()
            try:
                proc.wait(5)
            except subprocess.TimeoutExpired:
                proc.kill()
        upstream.shutdown()
        shutil.rmtree(work, ignore_errors=True)
    # The commit is the one the pinned release was built from; any other
    # release has no commit this harness knows.
    commit = PINNED_SOURCE_COMMIT if version == PINNED_PROXY_VERSION else "unknown"
    report = _report("transport", checks, version, commit)
    return report, (1 if report["counts"]["fail"] else 0)


# ---------------------------------------------------------------------------
# assess: validate an acceptance report
# ---------------------------------------------------------------------------

def _validate(report):
    """Return (problems, normalised checks list)."""
    problems = []
    if not isinstance(report, dict):
        return ["report is not a JSON object"], []
    if report.get("schema_version") != SCHEMA_VERSION:
        problems.append("schema_version must be %d" % SCHEMA_VERSION)
    if report.get("scope") != "acceptance":
        problems.append("scope must be \"acceptance\", not %r" % report.get("scope"))
    for key in ("source_commit", "claude_version", "proxy_version", "codex_version"):
        v = report.get(key)
        if not isinstance(v, str) or not v.strip() or v == "unknown":
            problems.append("%s must be a known version string" % key)
    if report.get("proxy_version") != PINNED_PROXY_VERSION:
        problems.append("proxy_version %r is not the pinned %s" % (report.get("proxy_version"), PINNED_PROXY_VERSION))
    if report.get("source_commit") != PINNED_SOURCE_COMMIT:
        problems.append("source_commit does not match the pinned release")
    inv = report.get("feature_inventory")
    if not (isinstance(inv, list) and inv and all(isinstance(s, str) and SLUG.match(s) for s in inv)):
        problems.append("feature_inventory must be a nonempty list of slugs")
        inv = []
    checks = report.get("checks")
    if not isinstance(checks, list):
        return problems + ["checks must be a list"], []
    seen = collections.Counter()
    good = []
    allowed = set(REQUIRED_IDS) | {FEATURE_PREFIX + s for s in inv}
    for ch in checks:
        if not isinstance(ch, dict) or not isinstance(ch.get("id"), str):
            problems.append("check without an id")
            continue
        cid = ch["id"]
        seen[cid] += 1
        if cid not in allowed:
            problems.append("unknown check %s" % cid)
        if ch.get("layer") != cid.split(".")[0] or ch.get("layer") not in LAYERS:
            problems.append("%s: layer does not match its id" % cid)
        if ch.get("status") not in STATUSES:
            problems.append("%s: invalid status %r" % (cid, ch.get("status")))
            continue
        if not isinstance(ch.get("reason"), str) or not ch["reason"].strip():
            problems.append("%s: reason must be a nonempty string" % cid)
        ev = ch.get("evidence")
        if not (isinstance(ev, list) and all(isinstance(e, str) and e.strip() for e in ev)):
            problems.append("%s: evidence must be a list of nonempty strings" % cid)
            continue
        if ch["status"] in ("pass", "accepted_difference") and not ev:
            problems.append("%s: %s without evidence" % (cid, ch["status"]))
        if ch["status"] == "accepted_difference":
            if cid != REMOTE_CONTROL:
                problems.append("%s: accepted_difference is only legal for %s" % (cid, REMOTE_CONTROL))
            for prefix in REMOTE_CONTROL_EVIDENCE:
                if not any(e.startswith(prefix) for e in ev):
                    problems.append("%s: accepted_difference needs %s evidence" % (cid, prefix))
        good.append(ch)
    problems += ["duplicate check %s" % c for c, n in seen.items() if n > 1]
    problems += ["missing check %s" % c for c in sorted(allowed - set(seen))]
    if not problems and report.get("counts") != _counts(good):
        problems.append("counts do not match the checks")
    return problems, good


def cmd_assess(args):
    try:
        with open(args.report) as f:
            report = json.load(f)
    except (OSError, ValueError) as e:
        return _report("acceptance", [], "unknown", "unknown", problems=["cannot read report: %s" % e]), 2
    problems, checks = _validate(report)
    bad = [c for c in checks if c["status"] == "fail"]
    unfinished = [c for c in checks if c["status"] in ("blocked", "skipped")]
    eligible = not (problems or bad or unfinished)
    if isinstance(report, dict) and report.get("eligible") is True and not eligible:
        problems.append("eligible is claimed but not earned")
    out = _report("acceptance", checks, None, None, problems=problems)
    if isinstance(report, dict):
        out.update({k: report[k] for k in ("source_commit", "claude_version", "proxy_version",
                                           "codex_version", "feature_inventory") if k in report})
    out["eligible"] = eligible
    if problems:
        return out, 2
    out["problems"] = ["failed: " + c["id"] for c in bad] + ["unfinished: " + c["id"] for c in unfinished]
    return out, 1 if bad else 2 if unfinished else 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="command", required=True)
    t = sub.add_parser("transport")
    t.add_argument("--proxy-bin", required=True)
    t.set_defaults(func=cmd_transport)
    a = sub.add_parser("assess")
    a.add_argument("--report", required=True)
    a.set_defaults(func=cmd_assess)
    args = p.parse_args(argv)
    report, code = args.func(args)
    print(json.dumps(report, indent=2))
    return code


if __name__ == "__main__":
    sys.exit(main())
