#!/usr/bin/env bash
# svc-k4u6, svc-is5q: build Inn against the local Ox checkout and install only
# the inn executable into the shared OxCaml switch, then restart the systemd
# user service that runs it.
#
#   ./scripts/install-inn-service.sh
#
# The script never runs `opam install`, `opam upgrade`, or `opam pin`: the Ox
# installed in the shared switch is left exactly as it is, because pie and grip
# still build against it. Only $OPAMROOT/<switch>/bin/inn is replaced, by
# staging a copy in the same directory and renaming it into place, so the
# service never observes a half-written executable.
#
# Options:
#   --no-restart   install the binary, do not touch inn.service
# Environment:
#   OX_PATH           Ox checkout (default: <inn>/../ocaml/ox)
#   OPAMROOT           opam root (default: ~/.cache/opam)
#   INN_OPAM_SWITCH    switch name (default: 5.4.0+ox)
#   INN_SYSTEMD_UNIT   user unit to restart (default: inn)
#   INN_BASE_URL       health URL base (default: http://127.0.0.1:27687)
set -euo pipefail

inn_root="$(cd "$(dirname "$0")/.." && pwd -P)"
ox_root="$(cd "${OX_PATH:-$inn_root/../ocaml/ox}" && pwd -P)"
opamroot="${OPAMROOT:-$HOME/.cache/opam}"
switch="${INN_OPAM_SWITCH:-5.4.0+ox}"
bin_dir="$opamroot/$switch/bin"
unit="${INN_SYSTEMD_UNIT:-inn}"
base_url="${INN_BASE_URL:-http://127.0.0.1:27687}"

restart=1
for arg in "$@"; do
  case "$arg" in
    --in-shell) ;;
    --no-restart) restart=0 ;;
    *)
      echo "install-inn-service.sh: unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ "${1:-}" != --in-shell ]]; then
  # The Ox Nix shell supplies the native SQLite/OpenSSL headers and pkg-config;
  # every OCaml dependency comes from the existing shared OxCaml switch.
  exec nix develop "$ox_root" -c bash "$0" --in-shell "$@"
fi

export OPAMROOT="$opamroot"
eval "$(opam env --switch "$switch" --set-switch)"
pkg-config --exists sqlite3 openssl || {
  echo 'install-inn-service.sh: Ox needs SQLite and OpenSSL native libraries in the Nix shell.' >&2
  exit 1
}

mirror="$inn_root/_dev/ox-source"
prefix="$inn_root/_dev/ox-install"
mkdir -p "$inn_root/_dev"
rm -rf "$mirror" "$prefix"
mkdir -p "$mirror"
# Dune does not traverse directory symlinks. Mirror real directories and symlink
# each source file, so edits in Ox are picked up without writing into Ox.
cp -rs "$ox_root/lib" "$mirror/lib"
ln -s "$ox_root/dune-project" "$mirror/dune-project"

packages=ox,ox_blocking,ox_sql_driver,ox_sql_dsl,ox_sql,ox_eio,ox_observability,ox_otel,ox_http,ox_http_h1,ox_http_h2,ox_http_tls_openssl,ox_http_ws,ox_stream,ox_http_eio,ox_router,ox_http_service,ox_http_service_eio
dune build --root "$mirror" --only-packages "$packages" @install
dune install --root "$mirror" --only-packages "$packages" --prefix "$prefix"

export OCAMLPATH="$prefix/lib${OCAMLPATH:+:$OCAMLPATH}"
if [[ "$(ocamlfind query ox_sql)" != "$prefix/lib/ox_sql" ]]; then
  echo 'install-inn-service.sh: local Ox did not take precedence over the shared switch.' >&2
  exit 1
fi

build_dir="$inn_root/_dev/inn-build"
dune build --root "$inn_root" --build-dir "$build_dir" bin/main.exe
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
