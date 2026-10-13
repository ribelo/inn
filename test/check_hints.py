"""svc-xd4x, bcache-d0nd: the "cannot connect" hint in the CLI and in the MCP
server names the systemd user service (systemctl --user restart inn), the only
way Inn runs.

Both probes point at a port nothing listens on: the CLI health command and an
MCP inn_stats tool call, which proxies the same HTTP API.
"""
import json
import os
import socket
import subprocess
import sys

exe = os.path.abspath(sys.argv[1])


def closed_port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


base_url = "http://127.0.0.1:%d" % closed_port()
required = ("systemctl --user restart inn",)

cli = subprocess.run(
    [exe, "health", "--base-url", base_url],
    capture_output=True,
    text=True,
    timeout=30,
)
assert cli.returncode == 1, (cli.returncode, cli.stdout, cli.stderr)
for fragment in required + (base_url,):
    assert fragment in cli.stderr, "%r missing from %r" % (fragment, cli.stderr)

request = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {"name": "inn_stats", "arguments": {}},
}
mcp = subprocess.run(
    [exe, "mcp", "--base-url", base_url],
    input=json.dumps(request) + "\n",
    capture_output=True,
    text=True,
    timeout=30,
)
lines = [line for line in mcp.stdout.splitlines() if line.strip()]
assert len(lines) == 1, mcp.stdout
response = json.loads(lines[0])
result = response["result"]
assert result["isError"] is True, result
text = result["content"][0]["text"]
for fragment in required:
    assert fragment in text, "%r missing from %r" % (fragment, text)

print(
    "svc-xd4x bcache-d0nd: the CLI and MCP connect hints name "
    "systemctl --user restart inn"
)
