"""tree-d24c: inn trace prints an indented tree by default and JSON with --json.

The check runs a real server on a free port, ingests one nested trace through
the OTLP/HTTP JSON endpoint, and reads it back with the CLI.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

exe = os.path.abspath(sys.argv[1])

TRACE_ID = "0123456789abcdef0123456789abcdef"
ROOT_ID = "1111111111111111"
CHILD_ID = "2222222222222222"

payload = {
    "resourceSpans": [
        {
            "resource": {
                "attributes": [
                    {"key": "service.name", "value": {"stringValue": "cli-svc"}}
                ]
            },
            "scopeSpans": [
                {
                    "scope": {"name": "cli"},
                    "spans": [
                        {
                            "traceId": TRACE_ID,
                            "spanId": ROOT_ID,
                            "name": "GET /tree",
                            "startTimeUnixNano": "1700000000000000000",
                            "endTimeUnixNano": "1700000005000000000",
                        },
                        {
                            "traceId": TRACE_ID,
                            "spanId": CHILD_ID,
                            "parentSpanId": ROOT_ID,
                            "name": "SELECT rows",
                            "startTimeUnixNano": "1700000001000000000",
                            "endTimeUnixNano": "1700000002000000000",
                            "status": {"code": 2},
                        },
                    ],
                }
            ],
        }
    ]
}


def free_port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


port = free_port()
state = tempfile.mkdtemp(prefix="inn-cram-")
env = dict(os.environ)
env.update(
    {
        "INN_STATE_DIR": state,
        "INN_DB_PATH": os.path.join(state, "telemetry.sqlite"),
        "INN_HOST": "127.0.0.1",
        "INN_PORT": str(port),
        # The sandbox caps locked memory, so io_uring ring creation fails; the
        # posix backend is the same Eio API (test/dune does the same).
        "EIO_BACKEND": "posix",
    }
)
base = "http://127.0.0.1:%d" % port
server = subprocess.Popen(
    [exe, "server"], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
)
try:
    deadline = time.time() + 15
    while True:
        if time.time() > deadline:
            raise SystemExit("server did not become healthy: %s" % server.stdout.read())
        try:
            with urllib.request.urlopen(base + "/health", timeout=1) as response:
                if response.status == 200:
                    break
        except Exception:
            time.sleep(0.1)

    request = urllib.request.Request(
        base + "/v1/traces",
        data=json.dumps(payload).encode(),
        headers={"content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        assert response.status == 200, response.status

    tree = subprocess.run(
        [exe, "trace", TRACE_ID],
        env=env,
        text=True,
        capture_output=True,
        timeout=20,
    )
    assert tree.returncode == 0, (tree.returncode, tree.stderr)
    lines = tree.stdout.splitlines()
    assert lines[0].startswith("trace %s" % TRACE_ID), lines
    assert lines[1].startswith("- GET /tree  (cli-svc, 5000.000ms)"), lines
    assert lines[2].startswith("  ! SELECT rows  (cli-svc, 1000.000ms)"), lines
    assert len(lines) == 3, lines

    raw = subprocess.run(
        [exe, "trace", TRACE_ID, "--json"],
        env=env,
        text=True,
        capture_output=True,
        timeout=20,
    )
    assert raw.returncode == 0, (raw.returncode, raw.stderr)
    body = json.loads(raw.stdout)
    spans = body["spans"]
    assert [span["depth"] for span in spans] == [0, 1], spans
    assert spans[1]["parentOperationName"] == "GET /tree", spans[1]
    assert spans[1]["rootOperationName"] == "GET /tree", spans[1]
    assert body["summary"]["warningCount"] == 0, body["summary"]
finally:
    server.terminate()
    try:
        server.wait(timeout=10)
    except subprocess.TimeoutExpired:
        server.kill()
    shutil.rmtree(state, ignore_errors=True)

print("tree-d24c: inn trace prints a tree and --json, against a live server")
