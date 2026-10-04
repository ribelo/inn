"""inndoor-k4px: explicit Door arguments preserve delay and daemon behavior.

HTTP output, trace tree/JSON and connection failures are covered by the other
CLI checks. This check owns an isolated daemon and exercises process authority.
"""
import json
import os
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
