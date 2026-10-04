---
status: done
category: bug
package: inn CLI entry point
consumer: Inn capability boundary
---

# Thread Door capabilities through CLI arguments and remove the allowance

## Problem Statement

The compiler-backed capability gate found five `ox-caps-signature` violations
only after Inn built real implementation `.cmt` evidence. Semgrep could not
see them: the calls already use sanctioned `Cap_*` wrappers, but the authority
comes from the mutable global `door_slot` through `door ()`, not an argument.

The migration measured zero source findings and eight typed-undecided modules
before building. Retaining byte evidence for the native executable exposed
all five findings with zero typed-undecided modules. The migration temporarily
allows exactly `bin/main.ml`; this row removes that allowance.

## Solution

Pass the capabilities minted by `Ox_app`'s Door down as explicit arguments or
as a genuine typed-token record argument. Cmdliner callbacks and error closures
may capture those argument capabilities. They must not read authority from a
mutable global slot. Refactor the CLI composition as a dedicated application
change, not as part of installing the lint tool.

## User Stories

1. As an Inn maintainer, I want CLI callbacks to receive the Door's capabilities
   through arguments instead of `door_slot`, so that dangerous operations have
   visible argument authority and all five typed findings disappear. ^inndoor-k4px
2. As an Inn maintainer, I want the temporary `bin/main.ml` allowance removed
   from the gate and development notes once those callbacks are typed-clean,
   so that the entire production CLI is checked again. ^inndoor-m8sw

## Finding Sites and Required Changes

| Site | Current authority use | Required change |
| --- | --- | --- |
| [main.ml:23](../../../bin/main.ml#L23) | `delay`'s anonymous error closure obtains `(door ()).caps` and writes stderr. | Pass capabilities into `delay` and let its closure capture that argument. |
| [main.ml:233](../../../bin/main.ml#L233) | `run_http` reads the global Door and writes stdout/stderr. | Take capabilities as an argument from the command callback; thread the Door context through HTTP helpers too. |
| [main.ml:457](../../../bin/main.ml#L457) | `daemon` reads global capabilities for fork, exec, filesystem operations and output. | Receive the Door's authority as an argument and pass it into daemon helpers. |
| [main.ml:490](../../../bin/main.ml#L490) | `stop` reads global capabilities for process checks, kills and output. | Receive and forward argument capabilities to process-control helpers. |
| [main.ml:620](../../../bin/main.ml#L620) | `trace` prints through capabilities obtained from the global Door. | Receive capabilities through its command term and use that argument for output. |

## Implementation Decisions

- Remove the ambient authority channel: `door_slot` and capability retrieval via
  `door ()`. Thread context through other callers such as configuration, server
  and HTTP helpers rather than retaining an indirect route to the same slot.
- Keep `Ox_app` as the only powerbox source; do not mint replacement tokens,
  widen exemptions, use raw operations or suppress the typed rule.
- Preserve CLI arguments, exit codes, output, daemon behavior and cancellation.
- Narrow argument capability types where practical; ordinary closures may
  capture genuine enclosing argument authority.
- Delete the `--allow bin/main.ml` entry and its reason in `scripts/caps-gate`;
  update the temporary-allowance notes in `AGENTS.md` and `README.md`.

## Testing Decisions

Build `@install` with the same shared compiler and dependency graph. Run the
installed capability gate without an allowance for `bin/main.ml`; require zero
findings and zero typed-undecided modules. Exercise the five command paths with
existing tests and add focused behavior-preserving coverage where missing.
Run all four gates from `AGENTS.md`, including the compiled Ox guide test.

## Out of Scope

Changing the lint rule, preserving ambient capabilities as an exception,
changing the CLI contract, deploying Inn, and modernizing the historical
local-source mirror script.

## Verification — 2026-10-04

Implemented ^inndoor-k4px and ^inndoor-m8sw (uncommitted for human review).

- `Ox_app.run_with_args` remains the sole powerbox source. Its
  `commands_with_env_code` callback now calls `commands ~caps ~runtime`; the
  runtime record holds only the existing Eio base and owned-scope callback.
  Command closures capture narrowed argument capabilities. `door_slot`,
  `door ()` and the full-capability record field are gone.
- `delay` takes stderr; `run_http` and `trace` take stdout/stderr; `daemon`
  takes fork/exec/exit/env/signal/time/random/stdout/stderr/fs_read/fs_write;
  `stop` takes signal/time/stdout/stderr/fs_read/fs_write. HTTP and lifecycle
  helpers receive the runtime argument; configuration receives env.
- Removed `--allow bin/main.ml` and its reason from `scripts/caps-gate`, and
  replaced the temporary-allowance notes in `AGENTS.md` and `README.md`. The
  wrapper builds `@install @check` and requires complete typed evidence.
- The initial root `@check` failed because test executable stanzas implicitly
  compiled one another's modules with the wrong dependencies. Explicit
  `(modules ...)` entries in `test/dune` make the required build pass without
  changing runtime behavior.

Every command ran from the repository root with `INN_ETA_GUIDE_SNIPPET=1`;
exit codes were captured directly with `cmd; echo rc=$?`.

| Gate | Before | After |
| --- | --- | --- |
| `nix develop -c dune build @install @check` | 1 (test module ownership above) | 0 |
| `nix develop -c dune test` | 0 | 0 |
| `nix develop -c dune build @fmt` | 0 | 0 |
| `nix develop -c scripts/caps-gate` | 0 (CLI excluded) | 0 (no exclusions) |
| `nix develop -c ox-lint --caps-gate --require-typed lib bin` | 1 | 0 |

Before removing the exemption, the direct strict gate reported exactly five
`ox-caps-signature` findings at original CLI lines 23, 233, 457, 490 and 620,
with zero typed-undecided modules. After threading, both direct and repository
gates report:

```text
caps-gate: 0 findings; 0 modules with typed rules undecided (typed evidence required)
```

Behavior verification:

- Compared a saved original executable against the new one: 38 help/default/
  version/parse/configuration cases have byte-identical stdout and stderr and
  identical exit codes (comparison exit 0).
- Added `test/check_door_cli.py` to the existing Cram suite: a pre-fork exception
  exercises `delay`; isolated daemon start, repeated start, status, HTTP health,
  identity-mismatch stop refusal, stop, start again and idempotent stop all pass.
  The same check passes against both executables (exit 0 each).
- Existing CLI tests retain trace tree/JSON, HTTP error output, MCP, signal
  shutdown/draining and the compiled Ox guide coverage. All 45 Inn and 7 MCP
  unit tests pass.
- The first lifecycle probe expected `restart` to succeed, but both original
  and new executables returned 1. No production behavior was changed to fix
  this pre-existing defect; it is recorded in
  [restart-daemon-exec](../restart-daemon-exec/01-restart-daemon-exec.md).
- `@fmt` passes; it warns on an uncached run that OCaml formatting is disabled
  because the repository has no `.ocamlformat`. No formatter policy was changed.
