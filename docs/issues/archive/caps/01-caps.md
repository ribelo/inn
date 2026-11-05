---
status: completed
package: inn
consumer: Inn service and CLI
---

# Inn onto capabilities

## Problem Statement

Inn reads the environment, the clock, the console, process signals, and files, forks a daemon, and opens a probe socket, without those acts appearing in the types of the functions that do them. The capability gate reports 54 such calls in 5 production files. A reviewer cannot tell from a signature what a function may touch.

## Solution

The Ox Door supplies the process powerbox. Inn narrows it and passes only the row each function needs. Dangerous standard-library and Unix calls go through `Ox_caps` wrappers. The store's pool receives a time capability. The compilable Ox guide passes a random capability to `Ox_otel.create`. Tests receive a powerbox from `Ox_test`. Inn's fourth gate runs the installed Ox gate with no allow-list. Operational behaviour of commands, queries, and the server does not change.

## User Stories

1. As an Inn maintainer, I want commands and the server to receive capabilities from `Ox_app.Env.caps` and to pass only the rows each library function names, so that library code never mints a powerbox. ^inncap-k4mw
2. As an Inn maintainer, I want production environment, file, clock, console, process, signal, random, and network operations to use `Ox_caps` wrappers with the narrowest row in the caller's signature, so that no raw dangerous call remains under the gate. ^inncap-q8hn
3. As an Inn maintainer, I want `Ox_sql.Pool.create` to take a time capability, migration reads to take filesystem-read and time, and the temporary-database helper to take tmp and filesystem-write, so that opening a store declares the authority those calls use. ^inncap-b8ts
4. As an Inn maintainer, I want the Ox guide's `Ox_otel.create` call to receive a random capability, so that the documented exporter declares trace-identifier authority. ^inncap-v3cj
5. As an Inn maintainer, I want tests of functions that now take capabilities to pass `Ox_test.powerbox ()`, so that existing assertions exercise the same behaviour with explicit authority. ^inncap-r6ya
6. As an Inn maintainer, I want `scripts/caps-gate` to run the Ox gate installed beside `ox_caps`, with no allow-list, so that production raw calls fail a fourth gate beside build, test, and formatting. ^inncap-m2pd
7. As an Inn user, I want queries, configuration, daemon start and stop, and server shutdown to behave as they do today, so that granting authority does not change what Inn does. ^inncap-h9le
8. As an Inn maintainer, I want `AGENTS.md` to state that dangerous calls go through `Ox_caps.Cap_*` and require a capability in the signature, so that the rule is in the file agents read first. ^inncap-w5qo

## Implementation Decisions

- Capabilities come from the Door. The existing Cmdliner commands are registered through `commands_with_env_code`, which receives `env.caps`. A bare `inn` still prints help. The Door does not load an Inn config file (`Config.none`); Inn's flags and environment stay the configuration.
- `inn server` runs on the Door's switch. It does not start a second `Eio_main`. Its own SIGINT and SIGTERM handlers still drain in-flight requests, then the process exits 0.
- `inn daemon` still forks and detaches. The child execs `inn server` with the same flags and `INN_INSTANCE_ID` set, so the child does not continue the parent's Eio runtime. A foreground `inn server` does not read that variable and still has no instance id.
- Library functions take `~caps` with an open row listing only what that function uses. The store captures the wall clock at open for row ids; the injectable `now_ms` remains the query clock.
- The Ox guide example is not a Door program. It passes `Ox_test.powerbox ()` so the documented call compiles and names the random capability. A service passes `env.caps`.
- `tools/gen_docs` is a Dune generator outside `lib/` and `bin/`. The gate does not scan it, and it is not an allow-list entry.

## Testing Decisions

The seam is the existing build, the full test suite, and `scripts/caps-gate`. Tests stay outside the production scan and pass `Ox_test.powerbox ()` where a signature now asks. No new behavioural assertions: the migration is authority in the types, and the current suites cover ^inncap-h9le. The installed binary, the database, and `inn.service` are not touched.

## Out of Scope

Eio's own capabilities, redesigning the service, deploying or replacing the installed Inn executable, and grip's caps row.
