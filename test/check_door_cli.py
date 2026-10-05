"""inndoor-k4px: explicit Door arguments preserve delay and daemon behavior.

HTTP output, trace tree/JSON and connection failures are covered by the other
CLI checks. This check owns an isolated daemon and exercises process authority.
"""
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile

exe = os.path.abspath(sys.argv[1])
env = {key: value for key, value in os.environ.items() if not key.startswith("INN_")}
env["EIO_BACKEND"] = "posix"

with tempfile.TemporaryDirectory(prefix="inn-door-") as state:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    env.update(INN_STATE_DIR=state, INN_HOST="127.0.0.1", INN_PORT=str(port))

    def run(command, *args, code=0):
        proc = subprocess.run(
            [exe, command, *args], env=env, capture_output=True, text=True, timeout=30
        )
        assert proc.returncode == code, (command, proc.returncode, proc.stdout, proc.stderr)
        return proc

    # An exception before fork reaches delay's captured stderr capability.
    obstruction = os.path.join(state, "file")
    with open(obstruction, "w") as handle:
        handle.write("not a directory")
    failed = run("daemon", "--state-dir", os.path.join(obstruction, "child"), code=1)
    assert failed.stdout == "", failed.stdout
    assert "mkdir" in failed.stderr and "Not a directory" in failed.stderr, failed.stderr

    # ^innlint-b7km: hold an actual HTTP read, then cancel only after the
    # request arrives. No sleep or race with the owned signal monitor.
    def http_check(response=None):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            listener.settimeout(10)
            url = "http://127.0.0.1:%d" % listener.getsockname()[1]
            child_env = dict(env, OCAMLRUNPARAM="b")
            child = subprocess.Popen(
                [exe, "health", "--base-url", url], env=child_env,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
            )
            try:
                connection, _ = listener.accept()
                with connection:
                    connection.settimeout(10)
                    request = b""
                    while b"\r\n\r\n" not in request:
                        chunk = connection.recv(4096)
                        assert chunk, request
                        request += chunk
                    if response is None:
                        child.send_signal(signal.SIGINT)
                    else:
                        connection.sendall(response)
                    stdout, stderr = child.communicate(timeout=10)
                return child.returncode, stdout, stderr
            finally:
                if child.poll() is None:
                    child.kill()
                    child.communicate()

    code, stdout, stderr = http_check()
    assert code == 2 and stdout == "", (code, stdout, stderr)
    assert stderr.splitlines()[0] == (
        "Fatal error: exception Cancelled: Cancelled: Ox__Interrupt_id.Stop(0)"
    ), stderr
    # The original suspended HTTP read survives both re-raises: neither the
    # ordinary HTTP-error branch nor delay's exception hook erased its trace.
    assert "Raised at Stdlib__Effect.Deep.discontinue" in stderr, stderr
    assert "Called from Ox_http__Client.read_head" in stderr, stderr
    assert "Re-raised at Dune__exe__Main.http_request" in stderr, stderr
    assert "Re-raised at Dune__exe__Main.delay" in stderr, stderr
    assert "HTTP request did not run" not in stderr, stderr

    ordinary = b"ordinary HTTP error"
    response = (
        b"HTTP/1.1 503 Unavailable\r\nContent-Length: "
        + str(len(ordinary)).encode()
        + b"\r\nConnection: close\r\n\r\n" + ordinary
    )
    assert http_check(response) == (1, "", ordinary.decode())

    registry_path = os.path.join(state, "server.json")
    saved_registry = None
    try:
        started = run("daemon")
        assert started.stderr == "", started.stderr
        first = json.loads(started.stdout)
        assert first["running"] and first["managed"] and first["healthy"], first
        assert json.loads(run("daemon").stdout) == first
        assert json.loads(run("status").stdout) == first
        assert json.loads(run("health").stdout)["pid"] == first["pid"]

        # The same live pid with a wrong registry identity must never be killed.
        with open(registry_path) as handle:
            saved_registry = handle.read()
        wrong = json.loads(saved_registry)
        wrong["instanceId"] = "not-the-running-instance"
        with open(registry_path, "w") as handle:
            json.dump(wrong, handle)
        refused = run("stop", code=1)
        assert "refusing to stop pid %d" % first["pid"] in refused.stderr, refused.stderr
        assert not json.loads(refused.stdout)["managed"]
        os.kill(first["pid"], 0)
        with open(registry_path, "w") as handle:
            handle.write(saved_registry)
        saved_registry = None

        stopped = run("stop")
        assert stopped.stderr == "" and not json.loads(stopped.stdout)["running"]
        started_again = run("daemon")
        assert started_again.stderr == "", started_again.stderr
        second = json.loads(started_again.stdout)
        assert second["running"] and second["managed"]
        assert second["pid"] != first["pid"]
        assert second["instanceId"] != first["instanceId"]
        stopped = run("stop")
        assert stopped.stderr == "" and not json.loads(stopped.stdout)["running"]
        assert not os.path.exists(registry_path)
        assert not os.path.exists(os.path.join(state, "server.pid"))
        assert not json.loads(run("stop").stdout)["running"]
        run("status", code=1)
    finally:
        if saved_registry is not None:
            with open(registry_path, "w") as handle:
                handle.write(saved_registry)
        subprocess.run([exe, "stop"], env=env, capture_output=True, timeout=30)

print("inndoor-k4px: delay errors and daemon start/status/refusal/stop preserve behavior")
