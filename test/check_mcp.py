"""mcp-gurs, mcp-dgq3, mcp-seqk, mcp-jovg stdio regression."""
import json
import subprocess
import sys

messages = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
]
input_text = "\n".join([json.dumps(messages[0]), "", json.dumps(messages[1]), json.dumps(messages[2]), "{bad", json.dumps({"jsonrpc": "2.0", "id": 3, "method": "ping"})]) + "\n"
proc = subprocess.run([sys.argv[1], "mcp"], input=input_text, text=True, capture_output=True, timeout=10)
assert proc.returncode == 0, (proc.returncode, proc.stderr)
assert not proc.stderr, proc.stderr
lines = proc.stdout.splitlines()
assert len(lines) == 4, lines
responses = [json.loads(line) for line in lines]
assert all(line == json.dumps(value, separators=(",", ":"), ensure_ascii=False) for line, value in zip(lines, responses)), lines
assert responses[0]["result"]["protocolVersion"] == "2025-06-18"
version = subprocess.run([sys.argv[1], "--version"], text=True, capture_output=True, timeout=10)
assert version.returncode == 0 and version.stderr == "", (version.returncode, version.stderr)
assert responses[0]["result"]["serverInfo"]["version"] == version.stdout.strip() != "dev"
assert responses[1]["id"] == 2 and len(responses[1]["result"]["tools"]) == 20
assert responses[2]["id"] is None and responses[2]["error"]["code"] == -32700
assert responses[3] == {"jsonrpc": "2.0", "id": 3, "result": {}}
print("mcp-gurs mcp-dgq3 mcp-seqk mcp-jovg: four compact responses, EOF exit 0")
