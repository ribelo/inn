  $ python3 check_cli.py ../bin/main.exe
  win-y63l and srch-fe5d: windows and search flags match CLI commands
  tree-d24c and aic-5j9w: tree rendering and AI flags match CLI commands
  $ python3 check_trace_cli.py ../bin/main.exe
  tree-d24c: inn trace prints a tree and --json, against a live server
  desc-85u9: inn docs lists, reads, and fails loudly on an unknown name
  $ python3 check_service.py ../bin/main.exe
  svc-pehm svc-dh98: SIGTERM drains an in-flight request and exits 0, SIGINT exits 0, both traces survive reopen, and startup logs config
  $ python3 check_hints.py ../bin/main.exe
  svc-xd4x: the CLI and MCP connect hints name systemctl --user start inn and inn server
  $ python3 check_install.py
  svc-k4u6 svc-is5q: the documented install command stages bin/inn, renames it into place, restarts inn.service, and never runs opam install/upgrade/pin
  $ python3 check_effect_guide.py
