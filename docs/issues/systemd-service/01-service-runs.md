---
status: ready-for-agent
---

# Inn runs as the systemd user service

## Problem Statement

The home-manager configuration in `~/nixos-config` (the `shell-stack.nix`
module) already defines an enabled `inn.service` systemd user unit. The unit
runs `~/.cache/opam/5.4.0+ox/bin/inn server`. The service has been failing on
every login with exit status 127, because that binary does not exist: Inn was
never installed into the shared OxCaml switch after its move to OxCaml. Apps
exporting OTLP to `127.0.0.1:27687` therefore send into nothing. Inn's own
messages also still point users to its homegrown `inn daemon`, rather than
the service that actually runs it.

## Solution

After Inn builds on the latest Eta, install it into the shared OxCaml switch
together with the latest Eta. Before that, confirm that the other installed
Eta dependents in that switch (pie and grip) still build on that Eta. Restart
the user service and check that it is healthy. Inn behaves well under systemd:
it logs to stderr (journald), shuts down cleanly on SIGTERM, and its CLI hints
mention the systemd service.

## User Stories

1. As a developer, I want `systemctl --user status inn` to show the service active after login, so that my apps' telemetry is collected ^svc-1qs5
2. As a developer, I want `inn health` and `curl 127.0.0.1:27687/health` to succeed against the service, so that I can confirm it is up ^svc-v677
3. As a developer, I want the shared switch's Eta upgraded only after pie and grip are shown to build on it, so that upgrading Inn does not break my other tools ^svc-is5q
4. As a developer, I want Inn to finish in-flight requests, stop the pruner, and close the store cleanly on SIGTERM, so that `systemctl --user restart inn` never leaves a damaged WAL or a hung process ^svc-pehm
5. As a developer, I want the "cannot connect" hint in the CLI and MCP to mention `systemctl --user start inn` as well as `inn server`, so that the hint matches how Inn actually runs ^svc-xd4x
6. As a developer, I want the server to log its listen address, database path, and retention settings to stderr at startup, so that `journalctl --user -u inn` shows its effective configuration ^svc-dh98
7. As a developer, I want a documented, repeatable command that reinstalls Inn into the shared switch after future changes, so that the service can be updated in one step ^svc-k4u6

## Implementation Decisions

- Order of operations:
  1. Build and test pie and grip against the local Eta master without
     touching the switch. Use the same isolated mechanism the Eta migration
     spec introduces, or those projects' own dev shells.
  2. Only if both pass, run Inn's existing install helper
     (`inn-opam-install`). It installs the local Eta checkout into the switch
     and pins Inn from the local repository.
  3. Restart `inn.service` and verify health.
  4. If pie or grip fail, stop. Do not install. Report the exact failures:
     those projects are outside this spec.
- The helper pins Inn from `git+file://...#master`. The installed binary
  therefore reflects committed state only. Commit before installing.
- Do not restart pie or other services. The rebuilt pie binary takes effect
  at the next restart the user chooses.
- SIGTERM: install a handler that cancels the server switch, so that the store
  is closed through the existing `Fun.protect`. Exiting with status 0 after a
  SIGTERM shutdown is expected by the unit's `Restart=on-failure`.
- Keep the `inn daemon`, `inn stop`, and `inn restart` commands. Do not
  remove them in this spec.
- The unit in `~/nixos-config` needs no change. If a change turns out to be
  required, make it as a local commit in that repository and describe it in the
  final report.

## Testing Decisions

- Manual acceptance on this machine: `systemctl --user restart inn`, then
  `systemctl --user is-active inn`, then `inn health`, then a sample OTLP
  JSON trace POST followed by `inn traces` (svc-1qs5, svc-v677).
- Automated test: start the server on a temporary port and state directory,
  send SIGTERM, check exit status 0 and that the database opens cleanly again
  (svc-pehm). A cram or subprocess test fits.
- The CLI hint text is checked with a cram test against a closed port
  (svc-xd4x).
- The startup log line is checked in the same subprocess test (svc-dh98).

## Out of Scope

- Rewriting the home-manager module, or packaging Inn with Nix for the service.
- Removing the homegrown daemon commands.

## Further Notes

- Depends on the Eta migration spec. It should run last, after the retention
  and ingest specs land, so the service runs the fixed code. It can also run
  earlier and simply be repeated.
