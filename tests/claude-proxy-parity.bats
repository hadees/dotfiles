#!/usr/bin/env bats

# tests/helpers/claude-proxy-parity.py holds the parity contract for routing
# Claude Code through claude-codex: `assess` validates an acceptance report,
# `transport` runs the proxy against a loopback fixture upstream. These tests
# drive the assessor with synthetic reports, drive the transport checks
# against an in-process reference proxy that is faithful or tampers in one
# named way, and, only where claude-codex is installed, run the real proxy
# against the fixture. Nothing leaves loopback, no credential exists anywhere,
# and the package is never needed: without claude-codex (CI has none) only
# the last test skips and the rest still run; without python3 all skip.

setup() {
  # python3 is resolved to its real interpreter before anything else: an asdf
  # shim resolves relative to $HOME and exits 126 if HOME is ever faked.
  PY="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)" || PY=''
  [ -n "$PY" ] || skip "python3 not installed"
  HELPER="$BATS_TEST_DIRNAME/helpers/claude-proxy-parity.py"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  REPORT="$BATS_TEST_TMPDIR/report.json"

  # A complete, eligible acceptance report, changed by the python statement in
  # $1 (it sees `r`, the report, and `m`, the helper) and written to $REPORT.
  # `recount = False` in the statement keeps its counts as written.
  cat > "$BATS_TEST_TMPDIR/mkreport.py" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("parity", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
checks = []
for cid in m.REQUIRED_IDS + [m.FEATURE_PREFIX + "mcp"]:
    ch = m._check(cid, "pass", "verified", ["evidence-dir:" + cid])
    checks.append(ch)
rc = next(c for c in checks if c["id"] == m.REMOTE_CONTROL)
rc.update(status="accepted_difference",
          evidence=["direct:rc-direct", "routed-refused:rc-routed", "opt-out:rc-optout"])
r = {"schema_version": 2, "scope": "acceptance", "source_commit": m.PINNED_SOURCE_COMMIT,
     "claude_version": "2.1.325", "proxy_version": m.PINNED_PROXY_VERSION,
     "codex_version": "0.167.0", "feature_inventory": ["mcp"], "checks": checks, "eligible": True}
recount = True
exec(sys.argv[3])
if recount:
    r["counts"] = m._counts(r["checks"])
json.dump(r, open(sys.argv[2], "w"))
PY

  # A reference proxy in front of the fixture upstream. Mode "faithful" copies
  # bytes and headers; every other mode breaks exactly one property. It prints
  # the IDs of the transport checks that failed.
  cat > "$BATS_TEST_TMPDIR/refproxy.py" <<'PY'
import http.client, importlib.util, json, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
spec = importlib.util.spec_from_file_location("parity", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
mode = sys.argv[2]
up = m.Upstream()

class Ref(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length") or 0))
        target = self.path
        headers = [(k, v) for k, v in self.headers.items() if k.lower() not in m.FRAMING]
        if mode == "body": body = json.dumps(json.loads(body)).encode()
        if mode == "query": target = target.split("?")[0]
        if mode == "request-headers": headers = [h for h in headers if h[0].lower() != "anthropic-beta"]
        c = http.client.HTTPConnection("127.0.0.1", up.server_address[1])
        c.putrequest("POST", target, skip_accept_encoding=True, skip_host=True)
        for k, v in headers + [("content-length", str(len(body)))]: c.putheader(k, v)
        c.endheaders(body)
        r = c.getresponse()
        out = [(k, v) for k, v in r.getheaders() if k.lower() not in m.FRAMING]
        if mode == "response-headers":
            out = [h for h in out if h[0].lower() != "anthropic-ratelimit-unified-5h-utilization"]
        quota = ("retry-after", "3600") in out
        self.send_response_only(r.status)
        for k, v in out: self.send_header(k, v)
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()
        def chunk(d):
            self.wfile.write(b"%x\r\n%s\r\n" % (len(d), d)); self.wfile.flush()
        if mode == "buffer":
            chunk(r.read())
        elif mode == "quota" and quota:
            r.read(); chunk(b'{"type":"error","error":{"type":"api_error","message":"generic"}}')
        else:
            while True:
                d = r.read1(65536)
                if not d: break
                chunk(d)
        self.wfile.write(b"0\r\n\r\n")

srv = ThreadingHTTPServer(("127.0.0.1", 0), Ref)
srv.daemon_threads = True
threading.Thread(target=srv.serve_forever, daemon=True).start()
checks = m.run_transport(srv.server_address[1], up)
print(",".join(c["id"] for c in checks if c["status"] == "fail"))
PY
}

assess_with() {
  "$PY" "$BATS_TEST_TMPDIR/mkreport.py" "$HELPER" "$REPORT" "$1"
  run "$PY" "$HELPER" assess --report "$REPORT"
}

@test "assess: a complete report with only the Remote Control difference is eligible" {
  assess_with 'pass'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"eligible": true'* ]]
  [[ "$output" == *'"accepted_difference": 1'* ]]
}

@test "assess: Remote Control may pass instead of differing" {
  assess_with 'next(c for c in r["checks"] if c["id"] == m.REMOTE_CONTROL).update(status="pass", evidence=["x"])'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"eligible": true'* ]]
}

@test "assess: an accepted difference on any other check is rejected" {
  assess_with 'r["checks"][0].update(status="accepted_difference", evidence=["direct:a", "routed-refused:b", "opt-out:c"])'
  [ "$status" -eq 2 ]
  [[ "$output" == *'only legal for interactive.remote-control'* ]]
  [[ "$output" == *'"eligible": false'* ]]
}

@test "assess: the Remote Control difference needs direct, routed and opt-out evidence" {
  assess_with 'next(c for c in r["checks"] if c["id"] == m.REMOTE_CONTROL)["evidence"].pop()'
  [ "$status" -eq 2 ]
  [[ "$output" == *'needs opt-out: evidence'* ]]
}

@test "assess: a pass without evidence is rejected" {
  assess_with 'r["checks"][0]["evidence"] = []'
  [ "$status" -eq 2 ]
  [[ "$output" == *'pass without evidence'* ]]
}

@test "assess: a duplicate check is rejected" {
  assess_with 'r["checks"].append(dict(r["checks"][0]))'
  [ "$status" -eq 2 ]
  [[ "$output" == *'duplicate check transport.messages'* ]]
}

@test "assess: a missing required check is rejected" {
  assess_with 'r["checks"].pop(0)'
  [ "$status" -eq 2 ]
  [[ "$output" == *'missing check transport.messages'* ]]
}

@test "assess: an unknown check ID is rejected" {
  assess_with 'r["checks"].append(m._check("cli.invented", "pass", "x", ["e"]))'
  [ "$status" -eq 2 ]
  [[ "$output" == *'unknown check cli.invented'* ]]
}

@test "assess: a feature check outside the inventory, or an inventory entry without one, is rejected" {
  assess_with 'r["checks"].append(m._check("interactive.feature.hooks", "pass", "x", ["e"]))'
  [ "$status" -eq 2 ]
  [[ "$output" == *'unknown check interactive.feature.hooks'* ]]
  assess_with 'r["feature_inventory"].append("hooks")'
  [ "$status" -eq 2 ]
  [[ "$output" == *'missing check interactive.feature.hooks'* ]]
}

@test "assess: an empty feature inventory is rejected" {
  assess_with 'r["feature_inventory"] = []; r["checks"].pop()'
  [ "$status" -eq 2 ]
  [[ "$output" == *'feature_inventory must be a nonempty list'* ]]
}

@test "assess: fabricated counts are rejected" {
  assess_with 'recount = False; r["counts"] = {"pass": 99, "fail": 0, "blocked": 0, "skipped": 0, "accepted_difference": 0}'
  [ "$status" -eq 2 ]
  [[ "$output" == *'counts do not match'* ]]
}

@test "assess: a null or mismatched version is rejected" {
  assess_with 'r["claude_version"] = None'
  [ "$status" -eq 2 ]
  [[ "$output" == *'claude_version must be a known version'* ]]
  assess_with 'r["proxy_version"] = "0.9.0"'
  [ "$status" -eq 2 ]
  [[ "$output" == *'is not the pinned'* ]]
  assess_with 'r["source_commit"] = "0" * 40'
  [ "$status" -eq 2 ]
  [[ "$output" == *'source_commit does not match'* ]]
}

@test "assess: a transport-scope report is not an acceptance report" {
  assess_with 'r["scope"] = "transport"'
  [ "$status" -eq 2 ]
  [[ "$output" == *'scope must be'* ]]
}

@test "assess: a falsely green report is rejected rather than trusted" {
  assess_with 'r["checks"][2].update(status="fail", reason="body changed", evidence=[])'
  [ "$status" -eq 2 ]
  [[ "$output" == *'eligible is claimed but not earned'* ]]
  [[ "$output" == *'"eligible": false'* ]]
}

@test "assess: an honest failure exits 1 and names the check" {
  assess_with 'r["checks"][2].update(status="fail", reason="body changed", evidence=[]); r["eligible"] = False'
  [ "$status" -eq 1 ]
  [[ "$output" == *'failed: transport.body'* ]]
}

@test "assess: a blocked or skipped required check exits 2 and is never eligible" {
  assess_with 'next(c for c in r["checks"] if c["id"] == "service.lifecycle").update(status="blocked", evidence=[]); r["eligible"] = False'
  [ "$status" -eq 2 ]
  [[ "$output" == *'unfinished: service.lifecycle'* ]]
  [[ "$output" == *'"eligible": false'* ]]
  assess_with 'r["checks"][3].update(status="skipped", evidence=[]); r["eligible"] = False'
  [ "$status" -eq 2 ]
  [[ "$output" == *'unfinished: transport.request-headers'* ]]
}

@test "assess: a missing or unparseable report exits 2" {
  run "$PY" "$HELPER" assess --report "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *'cannot read report'* ]]
  echo '{not json' > "$REPORT"
  run "$PY" "$HELPER" assess --report "$REPORT"
  [ "$status" -eq 2 ]
}

@test "transport: a faithful reference proxy passes every transport check" {
  run "$PY" "$BATS_TEST_TMPDIR/refproxy.py" "$HELPER" faithful
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# One tampering mode per defect, each caught by exactly the named checks.
@test "transport: each defect fails its named check" {
  while read -r mode expected; do
    run "$PY" "$BATS_TEST_TMPDIR/refproxy.py" "$HELPER" "$mode"
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ] || { echo "mode $mode: failed '$output', expected '$expected'"; return 1; }
  done <<'MODES'
body transport.count-tokens,transport.body
query transport.messages,transport.count-tokens
request-headers transport.request-headers
response-headers transport.response-headers
buffer transport.streaming
quota transport.quota-429
MODES
}

@test "transport: a missing proxy binary is a counted blocked result, not a pass" {
  run "$PY" "$HELPER" transport --proxy-bin "$BATS_TEST_TMPDIR/no-such-proxy"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"blocked": 8'* ]]
  [[ "$output" == *'"pass": 0'* ]]
  [[ "$output" == *'"eligible": false'* ]]
}

@test "transport: the installed claude-codex passes every transport check" {
  PROXY="$(command -v claude-codex)" || skip "claude-codex not installed"
  run "$PY" "$HELPER" transport --proxy-bin "$PROXY"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"pass": 8'* ]]
  [[ "$output" == *'"scope": "transport"'* ]]
  [[ "$output" == *'"eligible": false'* ]]
}
