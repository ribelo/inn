"""svc-k4u6: one documented, repeatable command reinstalls Inn into the shared
switch: scripts/install-inn-service.sh, as documented in the README.
svc-is5q: that command never upgrades the Ox installed in the shared switch --
it builds Inn as the gates do and installs only the inn executable, so pie and
grip keep building against the Ox they were built with.

The first half checks the README and the script text. The second half runs the
real script with stubbed nix/opam/dune/systemctl/curl on
PATH, against a throwaway root, and checks what it did: the executable landed in
$OPAMROOT/<switch>/bin/inn by rename with no staged file left behind, the unit
was restarted, health was polled, no opam package operation ran, and nothing
under the switch's lib directory was touched.
"""
import os
import shutil
import stat
import subprocess
import tempfile

repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
script = os.path.join(repo, "scripts", "install-inn-service.sh")
readme = os.path.join(repo, "README.md")

assert os.path.exists(script), script
assert os.stat(script).st_mode & stat.S_IXUSR, "the install script is not executable"

syntax = subprocess.run(["bash", "-n", script], capture_output=True, text=True)
assert syntax.returncode == 0, syntax.stderr

with open(readme, encoding="utf-8") as handle:
    docs = handle.read()
assert "./scripts/install-inn-service.sh" in docs, "the README does not document the command"
assert "systemd user service" in docs, docs
assert "$OPAMROOT/5.4.0+ox/bin/inn" in docs, docs

with open(script, encoding="utf-8") as handle:
    body = handle.read()
# Comments may name the operations the script refuses to run; only executable
# lines count.
code = "\n".join(
    line for line in body.splitlines() if not line.lstrip().startswith("#")
)
for forbidden in ("opam install", "opam upgrade", "opam pin", "opam remove", "opam switch"):
    assert forbidden not in code, "%r must not be part of the install path (svc-is5q)" % forbidden
assert "mktemp" in code and "mv -f" in code, "the install is not a staged rename"
assert "systemctl --user restart" in code, code
assert "/health" in code, code

root = tempfile.mkdtemp(prefix="inn-install-check-")
try:
    os.makedirs(os.path.join(root, "scripts"))
    shutil.copy2(script, os.path.join(root, "scripts", "install-inn-service.sh"))

    opamroot = os.path.join(root, "opam")
    switch_lib = os.path.join(opamroot, "5.4.0+ox", "lib")
    bindir = os.path.join(opamroot, "5.4.0+ox", "bin")
    fakebin = os.path.join(root, "fakebin")
    calls_path = os.path.join(root, "calls.log")
    os.makedirs(fakebin)

    def stub(name, text):
        path = os.path.join(fakebin, name)
        with open(path, "w") as handle:
            handle.write(text)
        os.chmod(path, 0o755)

    stub(
        "nix",
        "#!/usr/bin/env bash\n"
        'echo "nix $*" >> "$FAKE_LOG"\n'
        "shift 3\n"
        'exec "$@"\n',
    )
    stub(
        "opam",
        "#!/usr/bin/env bash\n"
        'echo "opam $*" >> "$FAKE_LOG"\n'
        'if [ "$1" = env ]; then exit 0; fi\n'
        'echo "install-inn-service.sh must not run opam $1" >&2\n'
        "exit 9\n",
    )
    stub(
        "dune",
        "#!/usr/bin/env bash\n"
        'echo "dune $*" >> "$FAKE_LOG"\n'
        'build_dir=""\n'
        'prev=""\n'
        'for arg in "$@"; do\n'
        '  if [ "$prev" = "--build-dir" ]; then build_dir="$arg"; fi\n'
        '  prev="$arg"\n'
        "done\n"
        'if [ -n "$build_dir" ]; then\n'
        '  mkdir -p "$build_dir/default/bin"\n'
        '  printf "stub-inn-binary\\n" > "$build_dir/default/bin/main.exe"\n'
        "fi\n"
        "exit 0\n",
    )
    stub(
        "systemctl",
        "#!/usr/bin/env bash\n"
        'echo "systemctl $*" >> "$FAKE_LOG"\n'
        'if [ "$1" = --user ] && { [ "$2" = cat ] || [ "$2" = restart ]; }; then\n'
        "  exit 0\n"
        "fi\n"
        "exit 1\n",
    )
    stub("curl", '#!/usr/bin/env bash\necho "curl $*" >> "$FAKE_LOG"\nexit 0\n')

    env = dict(os.environ)
    env["PATH"] = fakebin + os.pathsep + env["PATH"]
    env["OPAMROOT"] = opamroot
    env["FAKE_LOG"] = calls_path
    env["FAKE_INN_ROOT"] = root
    env["INN_BASE_URL"] = "http://127.0.0.1:27687"

    proc = subprocess.run(
        ["bash", os.path.join(root, "scripts", "install-inn-service.sh")],
        env=env,
        capture_output=True,
        text=True,
        timeout=300,
    )
    calls = open(calls_path).read().splitlines() if os.path.exists(calls_path) else []
    assert proc.returncode == 0, (proc.returncode, proc.stdout, proc.stderr, calls)

    opam_calls = [call for call in calls if call.startswith("opam ")]
    assert all(call.startswith("opam env ") for call in opam_calls), opam_calls
    assert any(call.startswith("nix develop ") for call in calls), calls
    assert any(
        call.startswith("systemctl --user restart inn.service") for call in calls
    ), calls
    assert any(
        call.startswith("curl ") and "/health" in call for call in calls
    ), calls

    installed = os.path.join(bindir, "inn")
    assert os.path.exists(installed), os.listdir(bindir)
    with open(installed) as handle:
        assert handle.read() == "stub-inn-binary\n", "the installed file is not the built binary"
    leftovers = [name for name in os.listdir(bindir) if name.startswith(".inn.")]
    assert not leftovers, leftovers
    assert not os.path.exists(switch_lib), "the shared switch's library tree was touched (svc-is5q)"
    assert "installed %s" % installed in proc.stdout, proc.stdout
finally:
    shutil.rmtree(root, ignore_errors=True)

print(
    "svc-k4u6 svc-is5q: the documented install command stages bin/inn, renames "
    "it into place, restarts inn.service, and never runs opam install/upgrade/pin"
)
