#!/usr/bin/env python3
"""Parity contract and transport harness for the claude-codex proxy.

    claude-proxy-parity.py transport --proxy-bin PATH
    claude-proxy-parity.py assess --report PATH
    claude-proxy-parity.py live --claude-bin PATH --proxy-bin PATH --functions PATH --evidence-dir PATH
    claude-proxy-parity.py merge --report PATH --attended PATH

Each prints one JSON object (schema in docs/claude-proxy.md). `transport` runs
the proxy against a loopback fixture upstream and checks that Anthropic
traffic passes through unchanged; it never contacts a real provider and uses
no credentials. `assess` validates a complete acceptance report. `live` runs
the real client against disposable proxies and writes an acceptance report
and its evidence outside the repository; only an operator starts it, and it
spends real quota. `merge` folds attended results into that report. Standard
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
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

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


def _start_proxy(binary, upstream_url, work, port=None, extra_env=None):
    """Start a disposable proxy; returns (process, port) or (None, reason).

    `upstream_url` None leaves the proxy's own default upstream. `port` None
    takes a free one (retrying if it is lost), else exactly that port, once.
    """
    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": work,
        "XDG_CONFIG_HOME": os.path.join(work, "config"),
        "XDG_STATE_HOME": os.path.join(work, "state"),
        "CCP_CONFIG_DIR": os.path.join(work, "ccp"),
        "CCP_BIND_ADDRESS": "127.0.0.1",
        "CCP_ALIAS_PROVIDER": "anthropic",
        "NO_PROXY": "*",
    }
    if upstream_url:
        env["CCP_ANTHROPIC_BASE_URL"] = upstream_url
    env.update(extra_env or {})
    os.makedirs(env["CCP_CONFIG_DIR"], exist_ok=True)
    log = open(os.path.join(work, "proxy.log"), "wb")
    last = "proxy did not start"
    for _ in range(1 if port else 3):  # the free port can be taken between probe and bind
        use = port or _free_port()
        proc = subprocess.Popen([binary, "serve", "--port", str(use), "--no-monitor"],
                                env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
        # Startup loads the system certificates, which has taken 25 seconds here.
        deadline = time.monotonic() + float(os.environ.get("CCP_PARITY_START_TIMEOUT", 90))
        while time.monotonic() < deadline and proc.poll() is None:
            try:
                conn = http.client.HTTPConnection("127.0.0.1", use, timeout=1)
                conn.request("GET", "/healthz")
                if conn.getresponse().status == 200:
                    return proc, use
            except OSError:
                time.sleep(0.1)
        proc.kill()
        proc.wait()
        with open(os.path.join(work, "proxy.log"), errors="replace") as f:
            last = "proxy did not become healthy: " + f.read()[-300:].strip()
    return None, last


def _stop_proxy(proc):
    proc.terminate()
    try:
        proc.wait(5)
    except subprocess.TimeoutExpired:
        proc.kill()


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
            _stop_proxy(proc)
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


# ---------------------------------------------------------------------------
# live: real-client evidence for the acceptance report (explicit, never CI)
# ---------------------------------------------------------------------------

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ZSH = shutil.which("zsh") or "zsh"
PROXY_PORT = 18765  # fixed in the claude() wrapper, so the disposable proxy needs it free
CODEX_MODEL = "gpt-6-astra"
FEATURES = ["auth-profile", "resume", "tools", "mcp", "hooks-permissions", "web"]
ATTENDED = {
    "interactive.usage": "attended: run /usage in a routed session and a direct one",
    "interactive.context": "attended: run /context in a routed session; token counting must survive",
    "interactive.fast": "attended: compare /fast availability direct and routed under the same account",
    "interactive.remote-control": "attended: Remote Control direct, refused routed, restored by the opt-out",
    "interactive.direct-feature-inventory": "attended: review the direct baseline and add the active integrations",
    "service.lifecycle": "operator: activate the LaunchAgent, then verify load, loopback listener, recovery, doctor",
    FEATURE_PREFIX + "web": "attended: WebSearch and WebFetch direct and routed",
}
FABLE_QUOTA_BODY = (b'{"type":"error","error":{"type":"rate_limit_error",'
                    b'"message":"You\'ve hit your Fable limit \xc2\xb7 resets 11pm"}}')
FABLE_SCENARIOS = {  # tap mode -> (status, headers, body); quota-partial is streamed
    "quota": (429, SCENARIOS["quota"][1], FABLE_QUOTA_BODY),
    "throttle": SCENARIOS["throttle"],
}
SSE_PARTIAL = [
    b'event: message_start\ndata: {"type":"message_start","message":{"id":"msg_fixture","type":"message",'
    b'"role":"assistant","model":"claude-fable-5-2","content":[],"stop_reason":null,'
    b'"usage":{"input_tokens":1,"output_tokens":1}}}\n\n',
    b'event: content_block_start\ndata: {"type":"content_block_start","index":0,'
    b'"content_block":{"type":"text","text":""}}\n\n',
    b'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,'
    b'"delta":{"type":"text_delta","text":"A partial plan, then the allowance ran out."}}\n\n',
    b'event: error\ndata: {"type":"error","error":{"type":"rate_limit_error",'
    b'"message":"You\'ve hit your Fable limit"}}\n\n',
]
_DROP = {"host", "content-length", "connection", "keep-alive", "transfer-encoding", "te", "trailer",
         "upgrade", "proxy-authorization", "proxy-authenticate"}


class _TapHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        tap = self.server
        body = self.rfile.read(int(self.headers.get("content-length") or 0))
        try:
            model = str(json.loads(body).get("model", ""))
        except (ValueError, AttributeError):
            model = ""
        mode = tap.mode if "fable" in model.lower() else None
        # Metadata only: no header or body ever reaches the log.
        tap.log.append({"method": self.command, "target": self.path, "model": model, "served": mode or "forwarded"})
        if mode == "quota-partial":
            self._stream(SSE_PARTIAL)
        elif mode:
            self._send(*FABLE_SCENARIOS[mode])
        else:
            self._forward(body)

    do_GET = do_POST

    def _send(self, status, headers, payload):
        self.send_response_only(status)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _chunk(self, data):
        self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
        self.wfile.flush()

    def _stream(self, events):
        self.send_response_only(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()
        for ev in events:
            self._chunk(ev)
        self.wfile.write(b"0\r\n\r\n")

    def _forward(self, body):
        u = urlsplit(self.server.target)
        conn_class = http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection
        try:
            conn = conn_class(u.hostname, u.port, timeout=900)
            conn.putrequest(self.command, self.path, skip_host=True, skip_accept_encoding=True)
            conn.putheader("host", u.netloc)
            for k, v in self.headers.items():
                if k.lower() not in _DROP:
                    conn.putheader(k, v)
            conn.putheader("content-length", str(len(body)))
            conn.endheaders(body)
            resp = conn.getresponse()
        except OSError as e:
            self._send(502, [JSON_CT], json.dumps({"type": "error", "error": {"message": str(e)}}).encode())
            return
        self.send_response_only(resp.status)
        for k, v in resp.getheaders():
            if k.lower() not in _DROP:
                self.send_header(k, v)
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()
        while True:
            data = resp.read1(65536)
            if not data:
                break
            self._chunk(data)
        self.wfile.write(b"0\r\n\r\n")
        conn.close()


class TapUpstream(ThreadingHTTPServer):
    """Forwards everything to `target` except Fable requests, which it answers
    as `mode` says (quota, quota-partial or throttle). Keeps no credentials."""
    daemon_threads = True

    def __init__(self, target):
        super().__init__(("127.0.0.1", 0), _TapHandler)
        self.target = target
        self.mode = None
        self.log = []
        threading.Thread(target=self.serve_forever, daemon=True).start()

    @property
    def url(self):
        return "http://127.0.0.1:%d" % self.server_address[1]


def _listening(port):
    with socket.socket() as s:
        s.settimeout(1)
        return s.connect_ex(("127.0.0.1", port)) == 0


def _clean_env():
    """The caller's environment minus anything that would pre-empt the wrapper's own routing."""
    drop = re.compile(r"^(ANTHROPIC_|CLAUDE_CODEX_|CLAUDE_CODE_USE_|CLAUDECODE$|CLAUDE_CODE_ENTRYPOINT$|CLAUDE_CONFIG_DIR$)")
    return {k: v for k, v in os.environ.items() if not drop.match(k)}


def _version_of(argv):
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=20).stdout
        return re.search(r"\d+\.\d+\.\d+\S*", out).group(0)
    except (OSError, subprocess.SubprocessError, AttributeError):
        return None


def _codex_auth_file():
    path = (os.environ.get("CCP_CODEX_AUTH_FILE")
            or os.path.join(os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex"), "auth.json"))
    return path if os.path.isfile(path) else None


def _live_problems(args):
    """Why `live` must not start, before it touches anything."""
    problems = []
    ev = os.path.realpath(args.evidence_dir)
    root = os.path.realpath(REPO_ROOT)
    if ev == root or ev.startswith(root + os.sep):
        problems.append("evidence directory is inside the repository")
    near = ev
    while not os.path.exists(near):
        near = os.path.dirname(near)
    if subprocess.run(["git", "-C", near, "rev-parse", "--show-toplevel"],
                               capture_output=True, stdin=subprocess.DEVNULL).returncode == 0:
        problems.append("evidence directory is inside a git work tree")
    if os.path.exists(ev) and (not os.path.isdir(ev) or os.listdir(ev)):
        problems.append("evidence directory must be new or empty")
    for flag, path in (("--claude-bin", args.claude_bin), ("--proxy-bin", args.proxy_bin)):
        if not (os.path.isfile(path) and os.access(path, os.X_OK)):
            problems.append("%s not found or not executable: %s" % (flag, path))
    if not os.path.isfile(args.functions):
        problems.append("--functions file not found: %s" % args.functions)
    if not shutil.which("zsh"):
        problems.append("zsh is required to run the claude() wrapper")
    return problems


class Run:
    """One print-mode claude invocation: its stream-json events and what the proxy saw."""

    def __init__(self, label, path, code, events, stderr):
        self.label, self.path, self.code, self.events, self.stderr = label, path, code, events, stderr
        self.requests, self.captures = [], []

    def result(self):
        done = [e for e in self.events if e.get("type") == "result"]
        return done[-1] if done else None

    def ok(self):
        r = self.result()
        return self.code == 0 and bool(r) and not r.get("is_error")

    def usage(self):
        return (self.result() or {}).get("usage") or {}

    def blocks(self):
        for e in self.events:
            content = (e.get("message") or {}).get("content")
            for b in content if isinstance(content, list) else []:
                if isinstance(b, dict):
                    yield e.get("type"), b

    def tool_uses(self):
        return [(b.get("name", ""), b.get("input") or {}) for t, b in self.blocks() if b.get("type") == "tool_use"]

    def text(self):
        """Everything said: assistant text, tool results and the final result."""
        parts = []
        for _, b in self.blocks():
            if b.get("type") == "text":
                parts.append(str(b.get("text", "")))
            elif b.get("type") == "tool_result":
                parts.append(json.dumps(b.get("content")))
        parts.append(str((self.result() or {}).get("result", "")))
        return "\n".join(parts)


class Proxy:
    """A disposable proxy on the wrapper's fixed port, with traffic capture in the evidence directory."""

    def __init__(self, live, name, upstream_url=None):
        self.work = os.path.join(live.ev, name)
        os.makedirs(self.work)
        extra = {"CCP_TRAFFIC_LOG": "1"}
        auth = _codex_auth_file()
        if auth:
            extra["CCP_CODEX_AUTH_FILE"] = auth  # the real login, by reference, never copied
        self.proc, self.port = _start_proxy(live.proxy_bin, upstream_url, self.work, PROXY_PORT, extra)
        self.state = os.path.join(self.work, "state", "claude-code-proxy")
        self.log = os.path.join(self.state, "proxy.log")

    def stop(self):
        if self.proc is not None:
            _stop_proxy(self.proc)

    def mark(self):
        size = os.path.getsize(self.log) if os.path.exists(self.log) else 0
        return size, self._captures()

    def _captures(self):
        found = set()
        for d, _, files in os.walk(os.path.join(self.state, "traffic")):
            if files and re.match(r"^\d{6}-(anthropic|codex)-", os.path.basename(d)):
                found.add(d)
        return found

    def since(self, mark):
        """(completed requests, new capture directories) after `mark`."""
        size, before = mark
        done = []
        if os.path.exists(self.log):
            with open(self.log, "rb") as f:
                f.seek(size)
                for line in f.read().decode(errors="replace").splitlines():
                    try:
                        entry = json.loads(line)
                    except ValueError:
                        continue
                    if entry.get("msg") == "request_completed":
                        done.append(entry.get("fields") or {})
        return done, sorted(self._captures() - before)


def _capture_text(dirs, provider):
    out = []
    for d in dirs:
        if "-%s-" % provider not in os.path.basename(d):
            continue
        for name in sorted(os.listdir(d)):
            try:
                with open(os.path.join(d, name), errors="replace") as f:
                    out.append(f.read(4_000_000))
            except OSError:
                pass
    return out


class Live:
    def __init__(self, args, ev):
        self.ev, self.functions, self.proxy_bin = ev, os.path.abspath(args.functions), args.proxy_bin
        self.routed = []  # every run that went through a disposable proxy
        self.runs = os.path.join(ev, "runs")
        self.fixtures = os.path.join(ev, "fixtures")
        self.bindir = os.path.join(ev, "bin")
        for d in (self.runs, self.fixtures, self.bindir):
            os.makedirs(d, exist_ok=True)
        os.symlink(os.path.abspath(args.claude_bin), os.path.join(self.bindir, "claude"))
        mcp = {"mcpServers": {"parity": {"command": sys.executable,
                                         "args": [os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                               "claude-proxy-mcp.py")]}}}
        self.mcp_config = os.path.join(self.fixtures, "mcp.json")
        with open(self.mcp_config, "w") as f:
            json.dump(mcp, f)

    def env(self, route, extra=None):
        e = _clean_env()
        e["PATH"] = self.bindir + os.pathsep + e.get("PATH", "")
        if route == "direct":
            e["CLAUDE_CODEX_PROXY"] = "0"
        e.update(extra or {})
        return e

    def decision(self, route):
        """What the wrapper decides for a launch in this environment: 'routed healthy', 'direct opt-out', ..."""
        cp = subprocess.run([ZSH, "-c", 'source "$1" && { typeset -a reply; claude_proxy_decide; print -r -- "$reply[1] $reply[2]"; }',
                             "zsh", self.functions], env=self.env(route), capture_output=True, text=True, timeout=30)
        return cp.stdout.strip() or "no answer: " + cp.stderr.strip()[-200:]

    def claude(self, label, route, prompt, *args, proxy=None, env=None, timeout=900):
        """Run claude through the wrapper (so the profile and its credentials are the real ones)."""
        cmd = [ZSH, "-c", 'source "$1" || exit 97; shift; claude "$@"', "zsh", self.functions,
               "-p", "--output-format", "stream-json", "--verbose", *args]
        mark = proxy.mark() if proxy else None
        try:
            cp = subprocess.run(cmd, input=prompt, env=self.env(route, env), capture_output=True,
                                text=True, timeout=timeout)
            out, err, code = cp.stdout, cp.stderr, cp.returncode
        except subprocess.TimeoutExpired as t:
            out = t.stdout.decode(errors="replace") if isinstance(t.stdout, bytes) else (t.stdout or "")
            err, code = "timeout after %ds" % timeout, 124
        path = os.path.join(self.runs, label + ".jsonl")
        with open(path, "w") as f:
            f.write(out)
        with open(path + ".stderr", "w") as f:
            f.write(err)
        events = []
        for line in out.splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
        run = Run(label, path, code, events, err)
        if proxy:
            run.requests, run.captures = proxy.since(mark)
            self.routed.append(run)
        return run


def _token():
    return "T" + os.urandom(6).hex()


def _verdict(cid, direct, routed, why, evidence):
    """The common shape of a direct-baseline against routed comparison."""
    if not direct:
        return _check(cid, "blocked", "direct baseline did not show it: " + why, evidence)
    if not routed:
        return _check(cid, "fail", "direct shows it, routed does not: " + why, evidence)
    return _check(cid, "pass", "direct and routed both: " + why, evidence)


def _stage_cache(live, proxy, put):
    filler = "The quick brown fox jumps over the lazy dog. " * 600
    runs = {}
    for route in ("direct", "routed"):
        system = "Acceptance nonce %s. %s" % (_token(), filler)
        runs[route] = [live.claude("cache-%s-%d" % (route, n), route, "Reply with the single word ok.",
                                   "--model", "haiku", "--max-turns", "1", "--append-system-prompt", system,
                                   proxy=proxy if route == "routed" else None) for n in (1, 2)]
    evidence = [r.path for rs in runs.values() for r in rs]
    if not all(r.ok() and r.usage() for rs in runs.values() for r in rs):
        why = "a cache run failed or reported no usage: " + ", ".join(r.label for rs in runs.values() for r in rs if not (r.ok() and r.usage()))
        put("cli.cache-read", "blocked", why, evidence)
        put("cli.cache-ttl", "blocked", why, evidence)
        return runs
    bad = []
    for route, (a, b) in runs.items():
        if not a.usage().get("cache_creation_input_tokens", 0) > 0:
            bad.append("%s run 1 created no cache" % route)
        if not b.usage().get("cache_read_input_tokens", 0) > 0:
            bad.append("%s run 2 read no cache" % route)
    put("cli.cache-read", "fail" if bad else "pass", "; ".join(bad) or "creation then nonzero reads, direct and routed", evidence)
    # One-hour TTL: the per-TTL usage breakdown on both routes, and the routed request itself.
    split = {r: rs[0].usage().get("cache_creation") for r, rs in runs.items()}
    if not all(isinstance(v, dict) for v in split.values()):
        put("cli.cache-ttl", "blocked", "usage has no per-TTL cache_creation breakdown", evidence)
        return runs
    bad = ["%s run 1 created no one-hour cache" % r for r, v in split.items() if not v.get("ephemeral_1h_input_tokens", 0) > 0]
    text = "\n".join(_capture_text(runs["routed"][0].captures, "anthropic"))
    if not text:
        put("cli.cache-ttl", "blocked", "no routed request capture to read the TTL field and beta from", evidence)
    elif not re.search(r'"ttl"\s*:\s*"1h"', text):
        put("cli.cache-ttl", "fail", "; ".join(bad + ["routed request carries no 1h ttl"]), evidence)
    elif "extended-cache-ttl" not in text and "anthropic-beta" not in text.lower():
        put("cli.cache-ttl", "blocked", "routed capture records no anthropic-beta header to check", evidence)
    elif "extended-cache-ttl" not in text:
        put("cli.cache-ttl", "fail", "; ".join(bad + ["routed request lacks the extended-cache-ttl beta"]), evidence)
    else:
        put("cli.cache-ttl", "fail" if bad else "pass", "; ".join(bad) or "one-hour cache direct and routed; routed request has the ttl and the beta", evidence)
    return runs


def _stage_token_count(live, proxy, put):
    seen = [f for r in live.routed for f in r.requests if f.get("countTokens")]
    evidence = [proxy.log]
    if not seen:
        put("cli.token-count", "blocked", "no count_tokens request in the routed print-mode runs; the attended /context check must supply it", evidence)
    elif any(f.get("status") != 200 for f in seen):
        put("cli.token-count", "fail", "a routed count_tokens request was not answered 200", evidence)
    else:
        put("cli.token-count", "pass", "%d routed count_tokens request(s), all 200" % len(seen), evidence)


def _mcp_probe(live, proxy, label, route, tool_search):
    token = _token()
    prompt = ("%s Call it with the text %s and reply with exactly what it returned." % (
        "Use tool search to find the tool that echoes text." if tool_search else "Use the parity_echo tool.", token))
    run = live.claude("%s-%s" % (label, route), route, prompt, "--model", "sonnet", "--max-turns", "8",
                      "--mcp-config", live.mcp_config, "--strict-mcp-config", "--allowedTools", "mcp__parity", "ToolSearch",
                      "--permission-mode", "dontAsk", proxy=proxy if route == "routed" else None,
                      env={"ENABLE_TOOL_SEARCH": "true" if tool_search else "false"})
    names = [n for n, _ in run.tool_uses()]
    echo = [i for i, n in enumerate(names) if n.endswith("parity_echo")]
    searched = any(n.lower() == "toolsearch" and i < (echo[0] if echo else -1) for i, n in enumerate(names))
    return run, run.ok() and bool(echo) and token in run.text() and (searched or not tool_search)


def _stage_tool_search(live, proxy, put):
    (d, dok), (r, rok) = (_mcp_probe(live, proxy, "tool-search", route, True) for route in ("direct", "routed"))
    c = _verdict("cli.tool-search", dok, rok, "ToolSearch ran before the deferred fixture tool was called", [d.path, r.path])
    put(c["id"], c["status"], c["reason"], c["evidence"])
    run, ok = _mcp_probe(live, proxy, "mcp", "routed", False)
    drun, dok2 = _mcp_probe(live, proxy, "mcp", "direct", False)
    return _verdict("interactive.feature.mcp", dok2, ok, "the fixture tool was called and returned its text", [drun.path, run.path])


def _feature_probes(live, proxy):
    """interactive.feature.* checks that need no operator: each run direct, then routed."""
    checks = []
    read_file = os.path.join(live.fixtures, "read.txt")
    token = _token()
    with open(read_file, "w") as f:
        f.write("The token is %s.\n" % token)
    for slug, args, prompt, verify in (
        ("tools", ["--add-dir", live.fixtures, "--allowedTools", "Read", "--permission-mode", "dontAsk"],
         "Read %s and reply with the token in it." % read_file,
         lambda r, route: any(n == "Read" for n, _ in r.tool_uses()) and token in r.text()),
    ):
        pair = [live.claude("feature-%s-%s" % (slug, route), route, prompt, "--model", "haiku", "--max-turns", "4", *args,
                            proxy=proxy if route == "routed" else None) for route in ("direct", "routed")]
        ok = [r.ok() and verify(r, route) for r, route in zip(pair, ("direct", "routed"))]
        checks.append(_verdict(FEATURE_PREFIX + slug, ok[0], ok[1], "Read tool ran under a dontAsk allowlist", [r.path for r in pair]))
    # hooks and permissions: a PreToolUse hook must fire, with Read allowed by the permission rules
    pair, ok = [], []
    for route in ("direct", "routed"):
        marker = os.path.join(live.fixtures, "hook-%s" % route)
        settings = json.dumps({"hooks": {"PreToolUse": [{"matcher": "Read", "hooks": [{"type": "command", "command": "touch '%s'" % marker}]}]}})
        r = live.claude("feature-hooks-%s" % route, route, "Read %s and reply with the token in it." % read_file,
                        "--model", "haiku", "--max-turns", "4", "--add-dir", live.fixtures, "--allowedTools", "Read",
                        "--permission-mode", "dontAsk", "--settings", settings, proxy=proxy if route == "routed" else None)
        pair.append(r)
        ok.append(r.ok() and os.path.exists(marker) and token in r.text())
    checks.append(_verdict(FEATURE_PREFIX + "hooks-permissions", ok[0], ok[1], "the PreToolUse hook fired and the allowlisted Read ran", [r.path for r in pair]))
    # resume: a second invocation resumes the first one's conversation
    pair, ok = [], []
    for route in ("direct", "routed"):
        secret = _token()
        first = live.claude("feature-resume-%s-1" % route, route, "Remember the code %s. Reply ok." % secret,
                            "--model", "haiku", "--max-turns", "1", proxy=proxy if route == "routed" else None)
        sid = (first.result() or {}).get("session_id")
        second = live.claude("feature-resume-%s-2" % route, route, "What code did I ask you to remember? Reply with only the code.",
                             "--model", "haiku", "--max-turns", "1", "--resume", sid or "missing",
                             proxy=proxy if route == "routed" else None)
        pair += [first, second]
        ok.append(first.ok() and bool(sid) and second.ok() and secret in second.text())
    checks.append(_verdict(FEATURE_PREFIX + "resume", ok[0], ok[1], "a resumed session recalled its first prompt", [r.path for r in pair]))
    return checks


def _stage_gpt(live, proxy, put):
    """cli.gpt-tool-roundtrip, cli.provider-routing and the Codex half of cli.effort from one plan-gpt run."""
    token = _token()
    file = os.path.join(live.fixtures, "gpt-read.txt")
    with open(file, "w") as f:
        f.write("The token is %s.\n" % token)
    brief = "Read the file %s with your Read tool and reply with exactly the token it contains, then DONE. Do not write a plan." % file
    prompt = ("Follow the GPT seats protocol, including its readiness check, then dispatch the plan-gpt agent with this "
              "brief, verbatim and unchanged: %s\nAfter it ends, print its reply." % brief)
    run = live.claude("gpt-roundtrip", "routed", prompt, "--max-turns", "12", "--add-dir", live.fixtures,
                      "--allowedTools", "Agent", "Task", "Read", "Bash(claude_gpt_ready *)", "--permission-mode", "dontAsk", proxy=proxy)
    evidence = [run.path, proxy.log]
    dispatched = [i for n, i in run.tool_uses() if n in ("Agent", "Task") and i.get("subagent_type") == "plan-gpt"]
    codex = [f for f in run.requests if f.get("provider") == "codex"]
    claude = [f for f in run.requests if f.get("provider") == "anthropic"]
    if not dispatched:
        why = "the orchestrator never dispatched plan-gpt (see the run for its readiness line)"
        for cid in ("cli.gpt-tool-roundtrip", "cli.provider-routing"):
            put(cid, "fail", why, evidence)
        return None
    good = [f for f in codex if f.get("model") == CODEX_MODEL and f.get("status") == 200]
    put("cli.gpt-tool-roundtrip", "pass" if len(good) >= 2 and token in run.text() else "fail",
        "%d Codex turn(s) on %s; token %s in the reply" % (len(good), CODEX_MODEL, "present" if token in run.text() else "absent"), evidence)
    put("cli.provider-routing", "pass" if good and claude else "fail",
        "%d Anthropic and %d Codex request(s); Codex model %s" % (len(claude), len(good), CODEX_MODEL), evidence)
    return run


def _effort_check(live, proxy, gpt_run, put):
    run = live.claude("effort-claude", "routed", "Reply with the single word ok.", "--model", "sonnet", "--effort", "low",
                      "--max-turns", "1", proxy=proxy)
    evidence = [run.path]
    claude_text = "\n".join(_capture_text(run.captures, "anthropic"))
    codex = _capture_text(gpt_run.captures, "codex") if gpt_run else []
    if not claude_text or len(codex) < 2:
        put("cli.effort", "blocked", "no request capture for the Claude run, or fewer than two Codex turns to read", evidence)
    elif '"effort"' not in claude_text or not any('"effort"' in c for c in codex):
        put("cli.effort", "blocked", "capture records no effort field to check", evidence)
    else:
        bad = []
        if not re.search(r'"effort"\s*:\s*"low"', claude_text):
            bad.append("the selected Claude effort did not reach the Anthropic request")
        high = [c for c in codex if re.search(r'"effort"\s*:\s*"high"', c)]
        if len(high) < 2:
            bad.append("only %d Codex request(s) carry high effort" % len(high))
        put("cli.effort", "fail" if bad else "pass", "; ".join(bad) or "Claude effort low and Codex effort high on every captured turn", evidence)


def _stage_handover(live, put):
    token = _token()
    brief = "Acceptance probe %s: plan nothing; reply with the single word PROBE and nothing else." % token
    prompt = ("Dispatch the plan-fable agent with exactly this brief, verbatim and unchanged: %s\n"
              "When it has ended, follow the GPT seats protocol for its result: classify it, dispatch plan-gpt "
              "only as the protocol says, and emit the GPT_HANDOVER line. Then repeat the lines you emitted." % brief)
    tap = TapUpstream("https://api.anthropic.com")
    proxy = None
    try:
        proxy = Proxy(live, "proxy-b", tap.url)
        if proxy.proc is None:
            put("cli.fable-handover", "blocked", "rehearsal proxy did not start: %s" % proxy.port, [])
            return
        want = {"quota": ("fable-limit", 1), "quota-partial": ("fable-limit", 1), "throttle": ("not-fable-limit", 0)}
        results, evidence = [], [proxy.log]
        for mode, (reason, gpt) in want.items():
            tap.mode = mode
            before = len(tap.log)
            run = live.claude("handover-%s" % mode, "routed", prompt, "--max-turns", "12", "--allowedTools",
                              "Agent", "Task", "Read", "Bash(claude_gpt_ready *)", "--permission-mode", "dontAsk", proxy=proxy)
            evidence.append(run.path)
            served = [e for e in tap.log[before:] if e["served"] == mode]
            leaked = [e for e in tap.log[before:] if "fable" in e["model"].lower() and e["served"] == "forwarded"]
            calls = [(n, i) for n, i in run.tool_uses() if n in ("Agent", "Task")]
            fable = [i for n, i in calls if i.get("subagent_type") == "plan-fable"]
            gpts = [i for n, i in calls if i.get("subagent_type") == "plan-gpt"]
            line = re.search(r"GPT_HANDOVER attempted=(\d) dispatched=(\d) unavailable=(\d) reason=([a-z-]+)", run.text())
            if not served or not fable:
                results.append(("blocked", "%s: plan-fable was not invoked or never reached the fixture" % mode))
            elif leaked or len(gpts) != gpt or any(brief not in str(i.get("prompt", "")) or "model" in i for i in gpts):
                results.append(("fail", "%s: %d plan-gpt dispatch(es) (want %d), brief unchanged and no model override required%s" % (
                    mode, len(gpts), gpt, "; a Fable request was served" if leaked else "")))
            elif not line or line.group(4) != reason or int(line.group(2)) != gpt:
                results.append(("blocked", "%s: dispatch count right but the GPT_HANDOVER line is missing or wrong" % mode))
            else:
                results.append(("pass", "%s: %d dispatch(es), %s" % (mode, gpt, line.group(0))))
        evidence.append(os.path.join(live.ev, "handover-tap.json"))
        with open(evidence[-1], "w") as f:
            json.dump(tap.log, f, indent=1)
        status = "fail" if any(s == "fail" for s, _ in results) else "blocked" if any(s == "blocked" for s, _ in results) else "pass"
        put("cli.fable-handover", status, "; ".join(r for _, r in results) + "; no Fable request reached Anthropic, so nothing was served that consent or credits could have paid for", evidence)
    finally:
        if proxy:
            proxy.stop()
        tap.shutdown()


def _stub_sandbox(root, name, binary=True, curl="ok"):
    """A fresh fake HOME with stub claude and curl, for the hermetic route-mode cases."""
    home = os.path.join(root, name)
    for d in ("bin", "home/.cargo/bin", "repo"):
        os.makedirs(os.path.join(home, d))
    scripts = {
        "bin/claude": '#!/bin/sh\necho "ROUTE=${CLAUDE_CODEX_ROUTE-UNSET} REASON=${CLAUDE_CODEX_REASON-UNSET} URL=${ANTHROPIC_BASE_URL-UNSET}"\n'
                      'echo "FG=${CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING-UNSET} TS=${ENABLE_TOOL_SEARCH-UNSET} HINT=${CLAUDE_CODE_GATEWAY_HINT_HEADERS-UNSET}"\n',
        "bin/curl": '#!/bin/sh\ncase "%s" in\n  down) exit 7;;\n  *) printf \'{"ok":true}\\n200\';;\nesac\n' % curl,
    }
    if binary:
        scripts["home/.cargo/bin/claude-codex"] = "#!/bin/sh\nexit 0\n"
    for rel, body in scripts.items():
        with open(os.path.join(home, rel), "w") as f:
            f.write(body)
        os.chmod(os.path.join(home, rel), 0o755)
    subprocess.run(["git", "init", "-q", os.path.join(home, "repo")], check=True,
                   env={"PATH": os.environ.get("PATH", ""), "HOME": os.path.join(home, "home")})
    return home


def route_modes(functions, root):
    """Drive the wrapper's route decisions, markers, preflight and doctor with stubs only.

    No network, no real proxy, no real claude: curl and claude are stubs on PATH and
    HOME is empty. Returns (failures, cases) where each case records got and want.
    """
    specs = []

    def case(name, script, want, curl="ok", binary=True, env=None):
        specs.append((name, script, want, curl, binary, env or {}))

    def run(n, spec):
        name, script, want, curl, binary, env = spec
        home = _stub_sandbox(root, "rm-%02d" % n, binary, curl)
        e = {"PATH": os.path.join(home, "bin") + ":/usr/bin:/bin", "HOME": os.path.join(home, "home"),
             "GIT_CONFIG_GLOBAL": os.path.join(home, "gitconfig"), "GIT_CONFIG_SYSTEM": "/dev/null",
             "GIT_CONFIG_NOSYSTEM": "1", "ITERM2_APP": os.path.join(home, "none.app")}
        e.update(env)
        cp = subprocess.run([ZSH, "-c", 'source "$1"; cd "$2/repo"; ' + script, "zsh", functions, home],
                            env=e, capture_output=True, text=True, timeout=120)
        return {"case": name, "ok": all(w in cp.stdout for w in want), "want": want, "got": cp.stdout, "stderr": cp.stderr}

    routed = "ROUTE=routed REASON=healthy URL=http://127.0.0.1:18765"
    session = {"CLAUDE_CODEX_ROUTE": "routed", "CLAUDE_CODEX_REASON": "healthy", "ANTHROPIC_BASE_URL": "http://127.0.0.1:18765"}
    case("routed", "claude", [routed, "FG=1 TS=true HINT=1"])
    case("opt-out", "claude", ["ROUTE=direct REASON=opt-out URL=UNSET"], env={"CLAUDE_CODEX_PROXY": "0"})
    case("missing proxy", "claude", ["ROUTE=direct REASON=not-installed URL=UNSET"], binary=False)
    case("down proxy", "claude", ["ROUTE=direct REASON=unreachable URL=UNSET"], curl="down")
    case("external URL", "claude", ["ROUTE=external REASON=external-base-url URL=https://gateway.invalid"],
         env={"ANTHROPIC_BASE_URL": "https://gateway.invalid"})
    case("session ready", "claude_gpt_ready %s; echo rc=$?" % CODEX_MODEL, ["GPT_ROUTE_READY model=%s auth=untested" % CODEX_MODEL, "rc=0"], env=session)
    case("daemon lost mid-session", "claude_gpt_ready %s; echo rc=$?" % CODEX_MODEL, ["GPT_ROUTE_UNAVAILABLE reason=unreachable", "rc=1"],
         curl="down", env=session)
    case("recovery keeps a direct session direct", "claude_gpt_ready %s; echo rc=$?" % CODEX_MODEL, ["GPT_ROUTE_UNAVAILABLE reason=opt-out", "rc=1"],
         env={"CLAUDE_CODEX_ROUTE": "direct", "CLAUDE_CODEX_REASON": "opt-out"})
    case("doctor, routed session", "claude-doctor | grep '^proxy:'", ["scope=session mode=routed reason=healthy health=ok; GPT route ready"], env=session)
    case("doctor, daemon lost", "claude-doctor | grep '^proxy:'", ["health=unreachable; GPT unavailable"], curl="down", env=session)
    case("opt-out notice", "claude_proxy_notice opt-out",
         ["claude: direct by opt-out for Remote Control; GPT agents unavailable in this session."])
    case("unreachable notice", "claude_proxy_notice unreachable",
         ["claude: direct because proxy is unreachable; GPT agents unavailable in this session."])
    case("external notice", "claude_proxy_notice external-base-url",
         ["claude: external base URL preserved; GPT routing is unverified in this session."])
    # Each case has its own sandbox, and the wrapper takes seconds to start: run them side by side.
    with ThreadPoolExecutor(max_workers=len(specs)) as pool:
        cases = list(pool.map(lambda ns: run(*ns), enumerate(specs, 1)))
    return [c["case"] for c in cases if not c["ok"]], cases


def _guard(stage, ids, put, fn):
    """A harness crash is not an observed defect: it blocks what the stage owns."""
    try:
        return fn()
    except Exception as e:  # noqa: BLE001 - reported, never swallowed
        for cid in ids:
            put(cid, "blocked", "harness error in %s: %s: %s" % (stage, type(e).__name__, e), [])


def _blocked_report(reason, version=None, commit="unknown"):
    checks = [_check(cid, "blocked", reason, []) for cid in REQUIRED_IDS]
    return _report("acceptance", checks, version or "unknown", commit, problems=[reason])


def _relative_evidence(checks, ev):
    """Evidence paths relative to the report's directory, so the report names no home path."""
    for ch in checks:
        ch["evidence"] = [os.path.relpath(e, ev) if e.startswith(ev + os.sep) else e for e in ch["evidence"]]


def cmd_live(args):
    problems = _live_problems(args)
    if problems:
        return _blocked_report("; ".join(problems)), 2
    ev = os.path.realpath(args.evidence_dir)
    os.makedirs(ev, exist_ok=True)
    live = Live(args, ev)
    versions = {"claude": _version_of([args.claude_bin, "--version"]), "proxy": _version_of([args.proxy_bin, "--version"]),
                "codex": _version_of([args.codex_bin, "--version"]) if args.codex_bin else None}
    results = {}

    def put(cid, status, reason, evidence):
        results[cid] = _check(cid, status, reason, evidence)

    # Transport and route modes run anywhere: loopback fixtures and stubs only.
    def transport():
        report, _ = cmd_transport(argparse.Namespace(proxy_bin=args.proxy_bin))
        path = os.path.join(ev, "transport.json")
        with open(path, "w") as f:
            json.dump(report, f, indent=2)
        for ch in report["checks"]:
            results[ch["id"]] = _check(ch["id"], ch["status"], ch["reason"], ch["evidence"] + [path] if ch["status"] == "pass" else ch["evidence"])
    _guard("transport", TRANSPORT_IDS, put, transport)

    def modes():
        failed, cases = route_modes(live.functions, os.path.join(ev, "route-modes"))
        path = os.path.join(ev, "route-modes.json")
        with open(path, "w") as f:
            json.dump(cases, f, indent=2)
        put("cli.route-modes", "fail" if failed else "pass",
            ("failed: " + ", ".join(failed)) if failed else "%d cases: routed, opt-out, missing, down, external, preflight, recovery, doctor, notices" % len(cases), [path])
    _guard("route-modes", ["cli.route-modes"], put, modes)

    # Everything below needs the real client, the real login, and a free 18765.
    stage_a = ["cli.cache-read", "cli.cache-ttl", "cli.token-count", "cli.tool-search", "cli.effort", "cli.provider-routing",
               "cli.gpt-tool-roundtrip"] + [FEATURE_PREFIX + s for s in FEATURES if FEATURE_PREFIX + s not in ATTENDED]
    stage_b = ["cli.fable-handover"]
    skip = None
    if _listening(PROXY_PORT):
        skip = "port %d is occupied; the operator must stop that listener (the wrapper routes only to %d)" % (PROXY_PORT, PROXY_PORT)
    elif not versions["claude"]:
        skip = "cannot read the claude version"
    elif live.decision("direct") != "direct opt-out":
        skip = "the wrapper does not honour CLAUDE_CODEX_PROXY=0 (%s)" % live.decision("direct")
    elif live.decision("routed") != "direct unreachable":
        # Nothing listens yet, so a launch here must be an installed proxy found down.
        skip = "before the disposable proxy starts the wrapper decides %r, not 'direct unreachable'; is ~/.cargo/bin/claude-codex installed?" % live.decision("routed")
    if skip:
        for cid in stage_a + stage_b:
            put(cid, "blocked", skip, [])
    else:
        proxy = None
        try:
            proxy = Proxy(live, "proxy-a")
            if proxy.proc is None:
                for cid in stage_a:
                    put(cid, "blocked", "disposable proxy did not start: %s" % proxy.port, [])
            elif live.decision("routed") != "routed healthy":
                for cid in stage_a:
                    put(cid, "blocked", "with the disposable proxy up the wrapper decides %r, not 'routed healthy'" % live.decision("routed"), [])
            else:
                runs = _guard("cache", ["cli.cache-read", "cli.cache-ttl"], put, lambda: _stage_cache(live, proxy, put))
                if runs:
                    ok = all(r.ok() for rs in runs.values() for r in rs)
                    results[FEATURE_PREFIX + "auth-profile"] = _check(
                        FEATURE_PREFIX + "auth-profile", "pass" if ok else "blocked",
                        "cache runs authenticated under the wrapper's profile, direct and routed" if ok else "a cache run failed",
                        [r.path for rs in runs.values() for r in rs])
                found = _guard("tool-search", ["cli.tool-search", FEATURE_PREFIX + "mcp"], put, lambda: _stage_tool_search(live, proxy, put))
                if found:
                    results[found["id"]] = found
                for ch in _guard("features", [], put, lambda: _feature_probes(live, proxy)) or []:
                    results[ch["id"]] = ch
                gpt_ids = ["cli.gpt-tool-roundtrip", "cli.provider-routing"]
                if not _codex_auth_file():
                    for cid in gpt_ids + ["cli.effort"]:
                        put(cid, "blocked", "no Codex login found (codex login, or CODEX_HOME)", [])
                else:
                    gpt_run = _guard("gpt", gpt_ids, put, lambda: _stage_gpt(live, proxy, put))
                    _guard("effort", ["cli.effort"], put, lambda: _effort_check(live, proxy, gpt_run, put))
                _guard("token-count", ["cli.token-count"], put, lambda: _stage_token_count(live, proxy, put))
        finally:
            if proxy:
                proxy.stop()
        if not _codex_auth_file():
            put("cli.fable-handover", "blocked", "no Codex login found (codex login, or CODEX_HOME)", [])
        else:
            _guard("handover", stage_b, put, lambda: _stage_handover(live, put))

    for cid, why in ATTENDED.items():
        put(cid, "blocked", why, [])
    for cid in REQUIRED_IDS + [FEATURE_PREFIX + s for s in FEATURES]:
        results.setdefault(cid, _check(cid, "blocked", "stage did not run", []))
    checks = [results[cid] for cid in REQUIRED_IDS + [FEATURE_PREFIX + s for s in FEATURES]]
    _relative_evidence(checks, ev)
    commit = PINNED_SOURCE_COMMIT if versions["proxy"] == PINNED_PROXY_VERSION else "unknown"
    report = _report("acceptance", checks, versions["proxy"] or "unknown", commit, claude_version=versions["claude"],
                     codex_version=versions["codex"], feature_inventory=list(FEATURES))
    with open(os.path.join(ev, "report.json"), "w") as f:
        json.dump(report, f, indent=2)
    return report, 1 if report["counts"]["fail"] else 2


def cmd_merge(args):
    """Fold operator-supplied attended results into a live report; assess earns eligibility."""
    try:
        with open(args.report) as f:
            report = json.load(f)
        with open(args.attended) as f:
            supplied = json.load(f)
    except (OSError, ValueError) as e:
        return _report("acceptance", [], "unknown", "unknown", problems=["cannot read input: %s" % e]), 2
    problems = []
    by_id = {c["id"]: c for c in report.get("checks", []) if isinstance(c, dict) and "id" in c}
    if not isinstance(supplied, list):
        return _report("acceptance", [], "unknown", "unknown", problems=["attended file must be a list of checks"]), 2
    for ch in supplied:
        cid = ch.get("id") if isinstance(ch, dict) else None
        if not isinstance(cid, str) or cid.split(".")[0] not in ("interactive", "service"):
            problems.append("only interactive.* and service.* results may be supplied: %r" % cid)
            continue
        ch = {"id": cid, "layer": cid.split(".")[0], "status": ch.get("status"), "reason": ch.get("reason"), "evidence": ch.get("evidence")}
        if cid in by_id and by_id[cid].get("status") != "blocked":
            problems.append("%s already has an observed result (%s)" % (cid, by_id[cid].get("status")))
            continue
        if cid.startswith(FEATURE_PREFIX) and cid not in by_id:
            report["feature_inventory"].append(cid[len(FEATURE_PREFIX):])
        elif cid not in by_id:
            problems.append("unknown check %s" % cid)
            continue
        by_id[cid] = ch
    report["checks"] = list(by_id.values())
    report["counts"] = _counts([c for c in report["checks"] if c.get("status") in STATUSES])
    report["eligible"] = False
    if problems:
        report["problems"] = problems
    return report, 2 if problems else 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="command", required=True)
    t = sub.add_parser("transport")
    t.add_argument("--proxy-bin", required=True)
    t.set_defaults(func=cmd_transport)
    a = sub.add_parser("assess")
    a.add_argument("--report", required=True)
    a.set_defaults(func=cmd_assess)
    lv = sub.add_parser("live")
    lv.add_argument("--claude-bin", required=True)
    lv.add_argument("--proxy-bin", required=True)
    lv.add_argument("--functions", required=True)
    lv.add_argument("--evidence-dir", required=True)
    lv.add_argument("--codex-bin", default=shutil.which("codex"))
    lv.set_defaults(func=cmd_live)
    mg = sub.add_parser("merge")
    mg.add_argument("--report", required=True)
    mg.add_argument("--attended", required=True)
    mg.set_defaults(func=cmd_merge)
    args = p.parse_args(argv)
    report, code = args.func(args)
    print(json.dumps(report, indent=2))
    return code


if __name__ == "__main__":
    sys.exit(main())
