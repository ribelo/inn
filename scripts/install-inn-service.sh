#!/usr/bin/env bash
# svc-k4u6, svc-is5q, bcache-i9st: build Inn exactly as the gates do (Inn's
# own Nix shell over the shared OxCaml switch) and install only the inn
# executable into that switch, then restart the systemd user service that runs
# it and wait for its health check.
#
#   ./scripts/install-inn-service.sh
#
# The script never runs `opam install`, `opam upgrade`, or `opam pin`: the Ox
# installed in the shared switch is left exactly as it is. Only
# $OPAMROOT/<switch>/bin/inn is replaced, by staging a copy in the same
# directory and renaming it into place, so the service never observes a
# half-written executable.
#
# Options:
#   --no-restart   install the binary, do not touch inn.service
# Environment:
#   OPAMROOT           opam root (default: ~/.cache/opam)
#   INN_OPAM_SWITCH    switch name (default: 5.4.0+ox)
#   INN_SYSTEMD_UNIT   user unit to restart (default: inn)
#   INN_BASE_URL       health URL base (default: http://127.0.0.1:27687)
set -euo pipefail

inn_root="$(cd "$(dirname "$0")/.." && pwd -P)"
opamroot="${OPAMROOT:-$HOME/.cache/opam}"
switch="${INN_OPAM_SWITCH:-5.4.0+ox}"
bin_dir="$opamroot/$switch/bin"
unit="${INN_SYSTEMD_UNIT:-inn}"
base_url="${INN_BASE_URL:-http://127.0.0.1:27687}"

restart=1
for arg in "$@"; do
  case "$arg" in
    --no-restart) restart=0 ;;
    *)
      echo "install-inn-service.sh: unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

build_dir="$inn_root/_dev/inn-build"
nix develop "$inn_root" -c dune build --root "$inn_root" --build-dir "$build_dir" bin/main.exe
built="$build_dir/default/bin/main.exe"

mkdir -p "$bin_dir"
target="$bin_dir/inn"
staged="$(mktemp "$bin_dir/.inn.XXXXXX")"
cp -f "$built" "$staged"
chmod 755 "$staged"
mv -f "$staged" "$target"
echo "installed $target"

if [[ "$restart" -ne 1 ]]; then
  exit 0
fi

if ! systemctl --user cat "$unit.service" >/dev/null 2>&1; then
  echo "install-inn-service.sh: $unit.service is not installed; skipping the restart" >&2
  exit 0
fi

systemctl --user restart "$unit.service"
for _ in $(seq 1 50); do
  if curl -fsS --max-time 2 "$base_url/health" >/dev/null 2>&1; then
    echo "inn service is healthy on $base_url"
    exit 0
  fi
  sleep 0.2
done
echo "install-inn-service.sh: $unit.service did not answer $base_url/health" >&2
echo "check: systemctl --user status $unit; journalctl --user -u $unit -n 20" >&2
exit 1
