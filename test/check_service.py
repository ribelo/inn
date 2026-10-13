"""svc-pehm: SIGTERM drains an in-flight request, exits 0 without hanging,
and the database opens cleanly again with its data intact.
svc-dh98: the startup log names the listen address, the data directory, and the
budget, so journalctl --user -u inn shows them.

The check runs the real bin/main.exe server on a free port and a temporary
state directory, ingests one trace, completes another across SIGTERM, requires
exit status 0, starts the server again on the same state directory, and requires
both traces to still be there. The second start also proves the store was closed,
not left with a WAL nothing can recover.
"""
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

exe = os.path.abspath(sys.argv[1])

TRACE_ID = "0123456789abcdef0123456789abcdef"
DRAIN_TRACE_ID = "fedcba9876543210fedcba9876543210"
SPAN_ID = "1111111111111111"
SERVICE = "service-check"

trace_payload = {
    "resourceSpans": [
        {
            "resource": {
                "attributes": [
                    {"key": "service.name", "value": {"stringValue": SERVICE}}
                ]
            },
            "scopeSpans": [
                {
                    "scope": {"name": "service-check"},
                    "spans": [
                        {
                            "traceId": TRACE_ID,
                            "spanId": SPAN_ID,
                            "name": "GET /service-check",
                            "startTimeUnixNano": "1700000000000000000",
                            "endTimeUnixNano": "1700000005000000000",
                        }
                    ],
                }
            ],
        }
    ]
}

retention_env = {
    "INN_MAX_DB_SIZE_MB": "2048",
}


def free_port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def get(url):
    with urllib.request.urlopen(url, timeout=2) as response:
        return response.status, json.loads(response.read())


def post(url, payload):
    body = json.dumps(payload).encode()
    request = urllib.request.Request(
        url, data=body, headers={"content-type": "application/json"}
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        return response.status, json.loads(response.read())


def wait_health(base_url, proc, timeout=20.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            raise AssertionError("server exited early with %s" % proc.returncode)
        try:
            status, body = get(base_url + "/health")
            if status == 200:
                return body
        except Exception:
            time.sleep(0.05)
    raise AssertionError("server did not answer /health")


def start(state_dir, port, log_path):
    env = dict(os.environ)
    env.update(
        {
            "INN_STATE_DIR": state_dir,
            "INN_HOST": "127.0.0.1",
            "INN_PORT": str(port),
            "INN_BASE_URL": "http://127.0.0.1:%d" % port,
        }
    )
    env.update(retention_env)
    log = open(log_path, "ab")
    proc = subprocess.Popen(
        [exe, "server"],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    log.close()
    return proc


def stop(proc, base_url, *, signal_sent=False, sig=signal.SIGTERM):
    name = signal.Signals(sig).name
    if not signal_sent:
        proc.send_signal(sig)
    try:
        returncode = proc.wait(timeout=20)
    except subprocess.TimeoutExpired:
        proc.kill()
        raise AssertionError("%s left the server running (svc-pehm)" % name)
    assert returncode == 0, "%s exit status was %d, not 0" % (name, returncode)
    deadline = time.time() + 5
    while time.time() < deadline:
        try:
            get(base_url + "/health")
        except Exception:
            return
        time.sleep(0.05)
    raise AssertionError("the server still answers after %s (svc-pehm)" % name)


def finish_inflight_across_sigterm(proc, port):
    payload = json.loads(json.dumps(trace_payload))
    payload["resourceSpans"][0]["scopeSpans"][0]["spans"][0]["traceId"] = DRAIN_TRACE_ID
    body = json.dumps(payload).encode()
    headers = (
        "POST /v1/traces HTTP/1.1\r\n"
        "Host: 127.0.0.1:%d\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n\r\n"
    ) % (port, len(body))
    with socket.create_connection(("127.0.0.1", port), timeout=7) as sock:
        sock.sendall(headers.encode() + body[: len(body) // 2])
        # The server has a partial request body; the response cannot finish yet.
        time.sleep(0.1)
        proc.send_signal(signal.SIGTERM)
        time.sleep(0.2)
        assert proc.poll() is None, "server exited before the request completed"
        sock.sendall(body[len(body) // 2 :])
        with sock.makefile("rb") as response:
            status_line = response.readline()
            assert status_line.startswith(b"HTTP/1.1 200 "), status_line
            while response.readline().strip():
                pass
            assert json.loads(response.read()) == {}, "in-flight ingest failed"


root = tempfile.mkdtemp(prefix="inn-service-check-")
state_dir = os.path.join(root, "state")
log_path = os.path.join(root, "server.log")
port = free_port()
base_url = "http://127.0.0.1:%d" % port
data_dir = os.path.join(state_dir, "segments")

try:
    server = start(state_dir, port, log_path)
    wait_health(base_url, server)
    for path in ("/ready", "/api/ready"):
        status, readiness = get(base_url + path)
        assert status == 200 and readiness["ready"] is True, readiness
        assert readiness["store"] == "ok", readiness

    status, _ = post(base_url + "/v1/traces", trace_payload)
    assert status == 200, "ingest answered %d" % status

    # An exporter batch of several megabytes is accepted, not reset by a 1 MiB
    # server limit, and its large value is cut and marked (bcache-t8nc).
    large = json.loads(json.dumps(trace_payload))
    large_span = large["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
    large_span["traceId"] = "a1" * 16
    large_span["attributes"] = [{"key": "universe", "value": {"stringValue": "u" * 3_000_000}}]
    status, _ = post(base_url + "/v1/traces", large)
    assert status == 200, "a 3 MB export answered %d" % status
    status, large_trace = get(base_url + "/traces/" + "a1" * 16)
    stored = large_trace["spans"][0]["attributes"]
    assert len(stored["universe"]) == 1024 and stored["inn.truncated"] is True, stored

    finish_inflight_across_sigterm(server, port)
    stop(server, base_url, signal_sent=True)

    with open(log_path, "r", errors="replace") as handle:
        log = handle.read()
    for fragment in (
        "inn server listening on http://127.0.0.1:%d" % port,
        "max_db_size=2048MB",
        "data=%s" % data_dir,
    ):
        assert fragment in log, "startup log is missing %r (svc-dh98):\n%s" % (
            fragment,
            log,
        )

    server = start(state_dir, port, log_path)
    wait_health(base_url, server)
    status, trace = get(base_url + "/traces/" + TRACE_ID)
    assert status == 200, "the reopened store answered %d" % status
    assert trace["summary"]["traceId"] == TRACE_ID, trace
    status, drained_trace = get(base_url + "/traces/" + DRAIN_TRACE_ID)
    assert status == 200, "the drained trace was not persisted"
    assert drained_trace["summary"]["traceId"] == DRAIN_TRACE_ID, drained_trace
    stop(server, base_url, sig=signal.SIGINT)
finally:
    if "server" in locals() and server.poll() is None:
        server.kill()
        server.wait(timeout=5)
    if os.path.exists(log_path):
        os.remove(log_path)
    import shutil

    shutil.rmtree(root, ignore_errors=True)

print(
    "svc-pehm svc-dh98: SIGTERM drains an in-flight request and exits 0, "
    "SIGINT exits 0, both traces survive reopen, and startup logs config"
)
