"""innnext-8nuj: the guide's compiled example exports to a real, isolated Inn.

The Ox guide's compiled snippet (test/ox_guide_snippet.ml) runs with
OTEL_EXPORTER_OTLP_ENDPOINT pointing at an Inn server started on a free port
and a temporary state directory, and the check then requires GET /metrics to
return the counter and the histogram the example recorded. The running user
service is neither used nor touched.
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

inn_exe = os.path.abspath(sys.argv[1])
snippet_exe = os.path.abspath(sys.argv[2])

SERVICE = "my-app"
COUNTER = "http.requests"
HISTOGRAM = "http.request.duration"


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def get(url):
    with urllib.request.urlopen(url, timeout=5) as response:
        return json.loads(response.read().decode())


def wait_for_health(base_url, proc, deadline):
    while time.time() < deadline:
        if proc.poll() is not None:
            raise AssertionError("inn exited early with %s" % proc.returncode)
        try:
            get(base_url + "/health")
            return
        except Exception:
            time.sleep(0.05)
    raise AssertionError("inn did not answer /health")


root = tempfile.mkdtemp(prefix="inn-ox-guide-")
state_dir = os.path.join(root, "state")
os.makedirs(state_dir)
port = free_port()
base_url = "http://127.0.0.1:%d" % port

server_env = dict(os.environ)
server_env.update(
    {
        "INN_STATE_DIR": state_dir,
        "INN_HOST": "127.0.0.1",
        "INN_PORT": str(port),
        "INN_BASE_URL": base_url,
    }
)

log = open(os.path.join(root, "inn.log"), "ab")
server = subprocess.Popen(
    [inn_exe, "server"],
    env=server_env,
    stdin=subprocess.DEVNULL,
    stdout=log,
    stderr=subprocess.STDOUT,
)
log.close()

try:
    wait_for_health(base_url, server, time.time() + 20)

    example_env = dict(os.environ)
    example_env.update(
        {
            "OTEL_EXPORTER_OTLP_ENDPOINT": base_url,
            # This sandbox caps io_uring memory; the posix backend is the same
            # Eio API without it.
            "EIO_BACKEND": "posix",
        }
    )
    example = subprocess.run(
        [snippet_exe],
        env=example_env,
        capture_output=True,
        text=True,
        timeout=60,
    )
    if example.returncode != 0:
        raise AssertionError(
            "the guide example failed: %s%s" % (example.stdout, example.stderr)
        )

    page = get("%s/metrics?service=%s&lookback=15m" % (base_url, SERVICE))
    points = page.get("metrics", [])
    names = sorted({point.get("name") for point in points})
    kinds = {point.get("name"): point.get("kind") for point in points}
    missing = [name for name in (COUNTER, HISTOGRAM) if name not in names]
    if missing:
        raise AssertionError("inn stored %s, not %s" % (names, missing))
    if kinds.get(COUNTER) != "sum":
        raise AssertionError("the counter arrived as %r, not a sum" % kinds.get(COUNTER))
    if kinds.get(HISTOGRAM) != "histogram":
        raise AssertionError(
            "the histogram arrived as %r, not a histogram" % kinds.get(HISTOGRAM)
        )
    print(
        "ox guide: %s and %s reached an isolated inn's POST /v1/metrics"
        % (COUNTER, HISTOGRAM)
    )
finally:
    server.send_signal(signal.SIGTERM)
    try:
        status = server.wait(timeout=20)
    except subprocess.TimeoutExpired:
        server.kill()
        raise AssertionError("inn did not stop on SIGTERM")
    if status != 0:
        raise AssertionError("inn exit status was %d, not 0" % status)
