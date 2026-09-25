"""svc-pehm: SIGTERM stops the server cleanly -- exit status 0, no hung process,
and the database opens cleanly again with its data intact.
svc-dh98: the startup log names the listen address, the database path, and the
effective retention settings, so journalctl --user -u inn shows them.

The check runs the real bin/main.exe server on a free port and a temporary
state directory, ingests one trace, sends SIGTERM, requires exit status 0,
starts the server again on the same state directory, and requires the trace to
still be there. The second start also proves the store was closed, not left
with a WAL nothing can recover.
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
    "INN_TRACES_RETENTION_HOURS": "72",
    "INN_LOGS_RETENTION_HOURS": "6",
    "INN_METRICS_RETENTION_HOURS": "12",
    "INN_PRUNE_INTERVAL_SECONDS": "45",
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


def stop(proc, base_url):
    proc.send_signal(signal.SIGTERM)
    try:
        returncode = proc.wait(timeout=20)
    except subprocess.TimeoutExpired:
        proc.kill()
        raise AssertionError("SIGTERM left the server running (svc-pehm)")
    assert returncode == 0, "SIGTERM exit status was %d, not 0" % returncode
    deadline = time.time() + 5
    while time.time() < deadline:
        try:
            get(base_url + "/health")
        except Exception:
            return
        time.sleep(0.05)
    raise AssertionError("the server still answers after SIGTERM (svc-pehm)")


root = tempfile.mkdtemp(prefix="inn-service-check-")
state_dir = os.path.join(root, "state")
log_path = os.path.join(root, "server.log")
port = free_port()
base_url = "http://127.0.0.1:%d" % port
db_path = os.path.join(state_dir, "telemetry.sqlite")

try:
    server = start(state_dir, port, log_path)
    wait_health(base_url, server)

    status, _ = post(base_url + "/v1/traces", trace_payload)
    assert status == 200, "ingest answered %d" % status

    stop(server, base_url)

    with open(log_path, "r", errors="replace") as handle:
        log = handle.read()
    for fragment in (
        "inn server listening on http://127.0.0.1:%d" % port,
        "traces_retention=72h",
        "logs_retention=6h",
        "metrics_retention=12h",
        "prune_interval=45s",
        "max_db_size=2048MB",
        "database=%s" % db_path,
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
    stop(server, base_url)
finally:
    if os.path.exists(log_path):
        os.remove(log_path)
    import shutil

    shutil.rmtree(root, ignore_errors=True)

print(
    "svc-pehm svc-dh98: SIGTERM exits 0, the reopened store still has its data, "
    "and the startup log names the effective configuration"
)
