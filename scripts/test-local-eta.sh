#!/usr/bin/env bash
# Build and test Inn against source from Eta without changing the shared opam switch.
set -euo pipefail

inn_root="$(cd "$(dirname "$0")/.." && pwd -P)"
eta_root="$(cd "${ETA_PATH:-$inn_root/../ocaml/Eta}" && pwd -P)"

if [[ "${1:-}" != --in-shell ]]; then
  exec nix develop "$eta_root" -c bash "$0" --in-shell
fi

# The Eta Nix shell supplies native SQLite/OpenSSL headers and pkg-config;
# every OCaml dependency comes from the existing shared OxCaml switch.
export OPAMROOT="$HOME/.cache/opam"
eval "$(opam env --switch 5.4.0+ox --set-switch)"
pkg-config --exists sqlite3 openssl || {
  echo 'Eta needs SQLite and OpenSSL native libraries in the Nix shell.' >&2
  exit 1
}

mirror="$inn_root/_dev/eta-source"
prefix="$inn_root/_dev/eta-install"
mkdir -p "$inn_root/_dev"
rm -rf "$mirror" "$prefix"
mkdir -p "$mirror"
# Dune does not traverse directory symlinks. Mirror real directories and symlink
# each source file, so edits in Eta are picked up without writing into Eta.
cp -rs "$eta_root/lib" "$mirror/lib"
ln -s "$eta_root/dune-project" "$mirror/dune-project"

packages=eta,eta_blocking,eta_sql_driver,eta_sql_dsl,eta_sql,eta_eio,eta_observability,eta_http,eta_http_h1,eta_http_h2,eta_http_tls_openssl,eta_http_ws,eta_stream,eta_http_eio,eta_router,eta_http_service,eta_http_service_eio
dune build --root "$mirror" --only-packages "$packages" @install
dune install --root "$mirror" --only-packages "$packages" --prefix "$prefix"

export OCAMLPATH="$prefix/lib${OCAMLPATH:+:$OCAMLPATH}"
if [[ "$(ocamlfind query eta_sql)" != "$prefix/lib/eta_sql" ]]; then
  echo 'Local Eta installation did not take precedence over the shared switch.' >&2
  exit 1
fi
dune build --root "$inn_root" --build-dir "$inn_root/_dev/inn-build"
dune runtest --force --root "$inn_root" --build-dir "$inn_root/_dev/inn-build"
