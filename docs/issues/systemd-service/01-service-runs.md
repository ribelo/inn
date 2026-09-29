---
status: completed
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

After Inn builds on the latest Ox, install it into the shared OxCaml switch
together with the latest Ox. Before that, confirm that the other installed
Ox dependents in that switch (pie and grip) still build on that Ox. Restart
the user service and check that it is healthy. Inn behaves well under systemd:
it logs to stderr (journald), shuts down cleanly on SIGTERM, and its CLI hints
mention the systemd service.

## User Stories

1. As a developer, I want `systemctl --user status inn` to show the service active after login, so that my apps' telemetry is collected ^svc-1qs5
2. As a developer, I want `inn health` and `curl 127.0.0.1:27687/health` to succeed against the service, so that I can confirm it is up ^svc-v677
3. As a developer, I want the shared switch's Ox upgraded only after pie and grip are shown to build on it, so that upgrading Inn does not break my other tools ^svc-is5q
4. As a developer, I want Inn to finish in-flight requests, stop the pruner, and close the store cleanly on SIGTERM, so that `systemctl --user restart inn` never leaves a damaged WAL or a hung process ^svc-pehm
5. As a developer, I want the "cannot connect" hint in the CLI and MCP to mention `systemctl --user start inn` as well as `inn server`, so that the hint matches how Inn actually runs ^svc-xd4x
6. As a developer, I want the server to log its listen address, database path, and retention settings to stderr at startup, so that `journalctl --user -u inn` shows its effective configuration ^svc-dh98
7. As a developer, I want a documented, repeatable command that reinstalls Inn into the shared switch after future changes, so that the service can be updated in one step ^svc-k4u6

## Implementation Decisions

- **Install path (decided after the compatibility check).** pie and grip do
  NOT build on current Ox master. They break on Ox_http.Client.t, the
  Ox.Queue kinds, Ox_linux_input.Device.fd, and the Ox_otel.create and
  shutdown signatures, all from Ox commit 992ed936. Upgrading Ox in the
  shared switch would therefore break them, so this spec must not upgrade
  Ox there. Instead, add a script that builds Inn against the local Ox (as
  the existing local-Ox test script does). The script then installs only the
  `inn` executable at the path the unit runs
  (`$OPAMROOT/5.4.0+ox/bin/inn`, with OPAMROOT defaulting to
  `~/.cache/opam`). It copies the binary to a temporary file in the same
  directory, then renames it into place atomically, then restarts
  `inn.service` if the unit exists, then checks health. Document this in the
  README as the service update command. Once pie and grip are ported, the
  opam-managed `inn-opam-install` path can replace it.
- svc-is5q is satisfied by the decision not to touch Ox in the switch.
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

- Depends on the Ox migration spec. It should run last, after the retention
  and ingest specs land, so the service runs the fixed code. It can also run
  earlier and simply be repeated.
