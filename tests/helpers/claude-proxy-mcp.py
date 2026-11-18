#!/usr/bin/env python3
"""Harmless MCP server for the claude-codex acceptance run.

Newline-delimited JSON-RPC over stdio: initialize, ping, tools/list and
tools/call, with one tool, `parity_echo`, that returns its `text` argument.
No network, no filesystem, no model: it only reads stdin and writes stdout.
Standard library only.
"""
import json
import sys

LATEST = "2025-11-25"
SUPPORTED = {"2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"}
TOOL = {
    "name": "parity_echo",
    "description": "Echo the given text back unchanged. Harmless; used to check tool discovery and calls.",
    "inputSchema": {
        "type": "object",
        "properties": {"text": {"type": "string", "description": "Text to echo."}},
        "required": ["text"],
        "additionalProperties": False,
    },
}


class RpcError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def handle(method, params):
    """The result for one request, or an RpcError."""
    if method == "initialize":
        asked = params.get("protocolVersion") if isinstance(params, dict) else None
        return {
            "protocolVersion": asked if asked in SUPPORTED else LATEST,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "parity", "version": "1"},
        }
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": [TOOL]}
    if method == "tools/call":
        if not isinstance(params, dict) or params.get("name") != TOOL["name"]:
            raise RpcError(-32602, "unknown tool")
        args = params.get("arguments")
        if not isinstance(args, dict) or set(args) != {"text"} or not isinstance(args["text"], str):
            raise RpcError(-32602, "arguments must be {\"text\": string}")
        return {"content": [{"type": "text", "text": args["text"]}], "isError": False}
    raise RpcError(-32601, "method not found: %s" % method)


def respond(msg):
    sys.stdout.write(json.dumps(msg, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def serve(lines):
    for line in lines:
        if not line.strip():
            continue
        try:
            req = json.loads(line)
        except ValueError:
            respond({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
            continue
        if not isinstance(req, dict) or req.get("jsonrpc") != "2.0" or not isinstance(req.get("method"), str):
            respond({"jsonrpc": "2.0", "id": req.get("id") if isinstance(req, dict) else None,
                     "error": {"code": -32600, "message": "invalid request"}})
            continue
        if "id" not in req:  # a notification gets no answer, even for an unknown method
            continue
        try:
            respond({"jsonrpc": "2.0", "id": req["id"], "result": handle(req["method"], req.get("params"))})
        except RpcError as e:
            respond({"jsonrpc": "2.0", "id": req["id"], "error": {"code": e.code, "message": e.message}})


if __name__ == "__main__":
    serve(sys.stdin)
