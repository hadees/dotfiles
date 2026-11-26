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
#
# `live` (real client, real accounts, real quota) and tests/helpers/
# claude-proxy-mcp.py have fixture-level tests below: the MCP server is driven
# over stdio, the Fable-limit upstream is driven over loopback, the route-mode
# cases run against stub curl and claude, and the evidence-directory and
# merge rules are called in-process. No test starts `live` itself.

setup() {
  # python3 is resolved to its real interpreter before anything else: an asdf
  # shim resolves relative to $HOME and exits 126 if HOME is ever faked.
  PY="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)" || PY=''
  [ -n "$PY" ] || skip "python3 not installed"
  HELPER="$BATS_TEST_DIRNAME/helpers/claude-proxy-parity.py"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  REPORT="$BATS_TEST_TMPDIR/report.json"
  MCP="$BATS_TEST_DIRNAME/helpers/claude-proxy-mcp.py"
  DOTFUNCTIONS="$BATS_TEST_DIRNAME/../dot_functions"

  # Run the python statements in $2 with the helper loaded as `m`.
  cat > "$BATS_TEST_TMPDIR/withm.py" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("parity", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
exec(sys.argv[2])
PY

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
from http.server import BaseHTTPRequestHandler
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

srv = m.LoopbackServer(("127.0.0.1", 0), Ref)
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

@test "transport: the fixture servers come up without the reverse lookup of their address" {
  run "$PY" "$BATS_TEST_TMPDIR/withm.py" "$HELPER" '
import runpy, socket, sys
def no_lookup(*a): raise AssertionError("socket.getfqdn was called")
socket.getfqdn = no_lookup
try:
    socket.getfqdn(); sys.exit("vacuous: the replacement is not live")
except AssertionError: pass
up = m.Upstream()
m.TapUpstream(up.url)
sys.argv = ["refproxy.py", sys.argv[1], "faithful"]
runpy.run_path("'"$BATS_TEST_TMPDIR"'/refproxy.py", run_name="__main__")
'
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

# ---------------------------------------------------------------------------
# claude-proxy-mcp.py: the harmless MCP server
# ---------------------------------------------------------------------------

# Feed the lines in $1 to the server; the replies land in $output, one per line.
mcp() {
  run "$PY" -I "$MCP" <<< "$1"
  [ "$status" -eq 0 ]
}

@test "mcp: initialize answers with the client's protocol version and a tools capability" {
  mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}'
  [ "$output" = '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"parity","version":"1"}}}' ]
  mcp '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}'
  [[ "$output" == *'"protocolVersion":"2025-11-25"'* ]]
}

@test "mcp: ping, tools/list and tools/call, with notifications answered by silence" {
  mcp '{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"ping"}
{"jsonrpc":"2.0","method":"anything/unknown"}

{"jsonrpc":"2.0","id":3,"method":"tools/list"}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"parity_echo","arguments":{"text":"héllo"}}}'
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = '{"jsonrpc":"2.0","id":2,"result":{}}' ]
  [[ "${lines[1]}" == *'"name":"parity_echo"'* && "${lines[1]}" == *'"required":["text"]'* ]]
  [ "${lines[2]}" = '{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"h\u00e9llo"}],"isError":false}}' ]
}

@test "mcp: unknown methods, unknown tools, bad arguments and bad JSON are protocol errors" {
  mcp '{"jsonrpc":"2.0","id":1,"method":"resources/list"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"nope","arguments":{}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"parity_echo","arguments":{"text":7}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"parity_echo","arguments":{"text":"a","extra":1}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"parity_echo"}}
{not json
{"id":6,"method":"ping"}'
  [ "${#lines[@]}" -eq 7 ]
  [[ "${lines[0]}" == *'"id":1'*'"code":-32601'* ]]
  [[ "${lines[1]}" == *'"id":2'*'"code":-32602'* ]]
  [[ "${lines[2]}" == *'"id":3'*'"code":-32602'* ]]
  [[ "${lines[3]}" == *'"id":4'*'"code":-32602'* ]]
  [[ "${lines[4]}" == *'"id":5'*'"code":-32602'* ]]
  [[ "${lines[5]}" == *'"id":null'*'"code":-32700'* ]]
  [[ "${lines[6]}" == *'"id":6'*'"code":-32600'* ]]
}

@test "mcp: the server imports nothing that could reach a network, a file or a model" {
  run grep -E '^\s*(import|from)\s' "$MCP"
  [ "$output" = $'import json\nimport sys' ]
}

# ---------------------------------------------------------------------------
# live: the pieces that run without a client, an account or a network
# ---------------------------------------------------------------------------

@test "live: the documented command line parses, and every flag it names is required" {
  run "$PY" "$HELPER" live --help
  [ "$status" -eq 0 ]
  for flag in --claude-bin --proxy-bin --functions --evidence-dir; do [[ "$output" == *"$flag"* ]]; done
  run "$PY" "$HELPER" live --claude-bin x --proxy-bin y --functions z
  [ "$status" -ne 0 ]
  [[ "$output" == *'--evidence-dir'* ]]
}

@test "live: it refuses an evidence directory inside the repository or already holding files, before doing anything" {
  mkdir -p "$BATS_TEST_TMPDIR/full" "$BATS_TEST_TMPDIR/ok"
  : > "$BATS_TEST_TMPDIR/full/leftover"
  : > "$BATS_TEST_TMPDIR/stub"; chmod +x "$BATS_TEST_TMPDIR/stub"
  run "$PY" "$BATS_TEST_TMPDIR/withm.py" "$HELPER" '
import argparse
def probe(d, bin="'"$BATS_TEST_TMPDIR"'/stub", fn="'"$DOTFUNCTIONS"'"):
    return m._live_problems(argparse.Namespace(claude_bin=bin, proxy_bin=bin, functions=fn, evidence_dir=d))
print(probe("'"$BATS_TEST_TMPDIR"'/ok"))
print(probe(m.REPO_ROOT + "/evidence"))
print(probe("'"$BATS_TEST_TMPDIR"'/full"))
print(probe("'"$BATS_TEST_TMPDIR"'/ok", bin="'"$BATS_TEST_TMPDIR"'/absent"))
print(probe("'"$BATS_TEST_TMPDIR"'/ok", fn="'"$BATS_TEST_TMPDIR"'/absent"))
'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '[]' ]
  [[ "${lines[1]}" == *'inside the repository'* ]]
  [[ "${lines[2]}" == *'must be new or empty'* ]]
  [[ "${lines[3]}" == *'--claude-bin not found'* && "${lines[3]}" == *'--proxy-bin not found'* ]]
  [[ "${lines[4]}" == *'--functions file not found'* ]]
}

@test "live: it refuses an evidence directory inside any git work tree, existing or not" {
  mkdir -p "$BATS_TEST_TMPDIR/tree" "$BATS_TEST_TMPDIR/plain"
  git init -q "$BATS_TEST_TMPDIR/tree"
  : > "$BATS_TEST_TMPDIR/stub"; chmod +x "$BATS_TEST_TMPDIR/stub"
  run "$PY" "$BATS_TEST_TMPDIR/withm.py" "$HELPER" '
import argparse
def probe(d):
    b = "'"$BATS_TEST_TMPDIR"'/stub"
    return m._live_problems(argparse.Namespace(claude_bin=b, proxy_bin=b, functions="'"$DOTFUNCTIONS"'", evidence_dir=d))
print(probe("'"$BATS_TEST_TMPDIR"'/tree"))
print(probe("'"$BATS_TEST_TMPDIR"'/tree/not/yet/there"))
print(probe("'"$BATS_TEST_TMPDIR"'/plain/not/yet/there"))
'
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *'inside a git work tree'* ]]
  [[ "${lines[1]}" == *'inside a git work tree'* ]]
  [ "${lines[2]}" = '[]' ]
}

@test "live: evidence paths in the report are relative to the evidence directory" {
  run "$PY" "$BATS_TEST_TMPDIR/withm.py" "$HELPER" '
checks = [m._check("cli.x", "pass", "ok", ["/ev/runs/a.jsonl", "upstream-request:1", "/elsewhere/b", "/evidence/c"])]
m._relative_evidence(checks, "/ev")
print(checks[0]["evidence"])
'
  [ "$output" = "['runs/a.jsonl', 'upstream-request:1', '/elsewhere/b', '/evidence/c']" ]
}

@test "live: a refused start reports every required check blocked, never passed" {
  run "$PY" "$BATS_TEST_TMPDIR/withm.py" "$HELPER" '
r = m._blocked_report("because")
print(r["counts"]["blocked"] == len(m.REQUIRED_IDS), r["counts"]["pass"], r["eligible"])
'
  [ "$output" = "True 0 False" ]
}

@test "live: the Fable-limit upstream forwards everything except Fable, which it limits as told" {
  run "$PY" "$BATS_TEST_TMPDIR/withm.py" "$HELPER" '
up = m.Upstream()
tap = m.TapUpstream(up.url)
port = tap.server_address[1]
hdr = m.REQUEST_HEADERS + [("x-parity-scenario", "ok")]
plain, fable = b"{\"model\":\"claude-haiku-4-5\"}", b"{\"model\":\"claude-fable-5-2\"}"
status, _, body = m._post(port, m.MESSAGES_TARGET, plain, hdr)
assert (status, body) == (200, m.OK_BODY), (status, body)
assert up.requests[-1]["body"] == plain and up.requests[-1]["target"] == m.MESSAGES_TARGET
assert not m._lost(m.REQUEST_HEADERS, up.requests[-1]["headers"])
seen = len(up.requests)
tap.mode = "quota"
status, headers, body = m._post(port, m.MESSAGES_TARGET, fable, hdr)
assert status == 429 and b"hit your Fable limit" in body
assert ("anthropic-ratelimit-unified-representative-claim", "seven_day_overage_included") in headers
assert m._post(port, m.MESSAGES_TARGET, plain, hdr)[0] == 200  # Claude traffic is preserved
tap.mode = "throttle"
status, headers, body = m._post(port, m.MESSAGES_TARGET, fable, hdr)
assert status == 429 and b"Fable" not in body and ("retry-after", "2") in headers
tap.mode = "quota-partial"
status, _, body = m._post(port, m.MESSAGES_TARGET, fable, hdr)
assert status == 200 and b"A partial plan" in body and b"event: error" in body and b"hit your Fable limit" in body
assert len(up.requests) == seen + 1  # only the second plain request got through
assert [e["served"] for e in tap.log if "fable" in e["model"]] == ["quota", "throttle", "quota-partial"]
assert "dummy-token" not in json.dumps(tap.log)  # metadata only, never a header
print("ok")
'
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "live: the route-mode cases hold against the real wrapper, with stub curl and claude only" {
  command -v zsh >/dev/null || skip "zsh not installed"
  run "$PY" "$BATS_TEST_TMPDIR/withm.py" "$HELPER" '
failed, cases = m.route_modes("'"$DOTFUNCTIONS"'", "'"$BATS_TEST_TMPDIR"'/rm")
print(len(cases), failed)
for c in cases:
    if not c["ok"]: print(json.dumps(c))
'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "13 []" ]
}

@test "live: the route-mode cases fail, case by case, against a wrapper that does not route" {
  command -v zsh >/dev/null || skip "zsh not installed"
  printf 'claude() { echo nothing; }\nclaude_gpt_ready() { echo GPT_ROUTE_READY; }\n' > "$BATS_TEST_TMPDIR/fake-functions"
  run "$PY" "$BATS_TEST_TMPDIR/withm.py" "$HELPER" '
failed, cases = m.route_modes("'"$BATS_TEST_TMPDIR"'/fake-functions", "'"$BATS_TEST_TMPDIR"'/rm")
print(len(cases), len(failed), "routed" in failed, "daemon lost mid-session" in failed)
'
  [ "$output" = "13 13 True True" ]
}

# `merge` supplies attended results; it never overwrites an observed one and
# never makes a report eligible (assess does that).
@test "merge: attended results fill blocked checks and assess then accepts the report" {
  assess_with 'next(c for c in r["checks"] if c["id"] == "service.lifecycle").update(status="blocked", evidence=[]); r["eligible"] = False'
  [ "$status" -eq 2 ]
  cat > "$BATS_TEST_TMPDIR/attended.json" <<'JSON'
[{"id": "service.lifecycle", "status": "pass", "reason": "operator verified", "evidence": ["operator-notes"]},
 {"id": "interactive.feature.hooks", "status": "pass", "reason": "operator verified", "evidence": ["operator-notes"]}]
JSON
  run "$PY" "$HELPER" merge --report "$REPORT" --attended "$BATS_TEST_TMPDIR/attended.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"eligible": false'* ]]
  printf '%s' "$output" > "$BATS_TEST_TMPDIR/merged.json"
  run "$PY" "$HELPER" assess --report "$BATS_TEST_TMPDIR/merged.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"eligible": true'* ]]
  [[ "$output" == *'"hooks"'* ]]
}

@test "merge: automated layers and observed results cannot be overwritten" {
  assess_with 'pass'
  echo '[{"id": "cli.cache-read", "status": "pass", "reason": "x", "evidence": ["e"]}]' > "$BATS_TEST_TMPDIR/attended.json"
  run "$PY" "$HELPER" merge --report "$REPORT" --attended "$BATS_TEST_TMPDIR/attended.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *'only interactive.* and service.* results may be supplied'* ]]
  echo '[{"id": "interactive.usage", "status": "fail", "reason": "x", "evidence": []}]' > "$BATS_TEST_TMPDIR/attended.json"
  run "$PY" "$HELPER" merge --report "$REPORT" --attended "$BATS_TEST_TMPDIR/attended.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *'interactive.usage already has an observed result (pass)'* ]]
}
