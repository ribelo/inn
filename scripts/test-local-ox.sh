#!/usr/bin/env bash
# Build and test Inn against source from Ox without changing the shared opam switch.
set -euo pipefail

inn_root="$(cd "$(dirname "$0")/.." && pwd -P)"
ox_root="$(cd "${OX_PATH:-$inn_root/../ocaml/ox}" && pwd -P)"

if [[ "${1:-}" != --in-shell ]]; then
  exec nix develop "$ox_root" -c bash "$0" --in-shell
fi

# The Ox Nix shell supplies native SQLite/OpenSSL headers and pkg-config;
# every OCaml dependency comes from the existing shared OxCaml switch.
export OPAMROOT="$HOME/.cache/opam"
eval "$(opam env --switch 5.4.0+ox --set-switch)"
pkg-config --exists sqlite3 openssl || {
  echo 'Ox needs SQLite and OpenSSL native libraries in the Nix shell.' >&2
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
  echo 'Local Ox installation did not take precedence over the shared switch.' >&2
  exit 1
fi
# The Ox guide's exporter snippet and its isolated-Inn check are compiled
# against this local Ox. The shared switch carries the same ox_otel, so the
# same tests can be enabled there with INN_ETA_GUIDE_SNIPPET=1.
# test/ox_guide_snippet.ml mirrors docs/guides/ox.md.
export INN_ETA_GUIDE_SNIPPET=1
dune build --root "$inn_root" --build-dir "$inn_root/_dev/inn-build"
dune runtest --force --root "$inn_root" --build-dir "$inn_root/_dev/inn-build"
