---
status: ready-for-agent
category: bug
package: inn CLI entry point
consumer: Inn operators
---

# Classify cancellation from delayed CLI commands

## Problem Statement

The all-rule lint repair (^innlint-b7km) makes
[delay](../../../bin/main.ml#L16) and [http_request](../../../bin/main.ml#L205)
propagate cancellation, preserving its original exception and backtrace. `http_request` [enters an owned scope](../../../bin/main.ml#L212)
that classifies to an integer, but its callers need the cancellation itself, not
an ordinary HTTP error. The [Door command builder](../../../bin/main.ml#L1338)
executes delayed commands outside that classifying owned scope.

Observed with SIGINT during a blocked `inn health` HTTP read: cancellation
escapes `Eio_main`, stdout is empty, and the process exits 2 with
`Fatal error: exception Cancelled: Cancelled: Ox__Interrupt_id.Stop(0)` and the
original HTTP-read backtrace. [check_door_cli.py](../../../test/check_door_cli.py)
pins this result, so a later change to the cancellation boundary will be visible.

## User Stories

1. As an Inn operator, I want delayed CLI commands to run inside the Door
   classifying scope, so that cancellation becomes a recorded stop with the
   [ADR-0011](../../../../ocaml/ox/docs/adr/0011-cancellation-as-a-value.md)
   exit-code contract instead of an uncaught `Cancelled` escaping `Eio_main`.
   ^inncancel-k8vd

## Implementation and Testing Decisions

- Fix the delayed-command ownership boundary, not cancellation rendering inside
  `delay` or `http_request`; a Door-recorded stop in `run_owned_code` uses
  `interrupt_exit` (130 by default), while foreign stops retain defect handling.
- Update the pinned blocked-HTTP SIGINT case to the recorded-stop result when the
  boundary changes; preserve ordinary command outputs, errors and exit codes.
- Keep the separate restart follow-up unchanged.
