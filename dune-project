(lang dune 3.21)

(generate_opam_files true)

(name inn)
(version 0.1.0)

(package
 (name inn)
 (synopsis "Cwd-independent local OpenTelemetry collector and query service")
 (description
  "Inn is an OxCaml/Eta local telemetry collector and query service. It stores OTLP traces, logs, and metrics in one user-level SQLite database and exposes server-owned CLI and HTTP query surfaces that never derive identity from the caller's current working directory.")
 (depends
  (ocaml (>= 5.1))
  (dune (>= 3.0))
  cmdliner
  eta
  eta_http
  eta_sql
  eio
  eio_main
  yojson
  (alcotest :with-test)))
