---
status: done
category: enhancement
package: inn development gates
consumer: Inn maintainers
---

# Inn capability gate on compiler-backed ox-lint

## Problem Statement

Ox row 90 replaces the Semgrep capability gate with a compiler-matched build
tool. Inn pins an older Ox and does not explicitly install `ox_lint`; its gate
workflow does not ensure fresh typed evidence from this repository.

## Solution

Pin Ox `c03cbf9af329a9d575b88eaf074e7b578df8ff97`, declare build-only
`ox_lint` alongside the existing Ox packages, and make `@install` precede the
installed capability gate. Keep the normal shared OxCaml switch. Record genuine
CLI provenance debt with one explicitly authorized temporary allowance.
This consumes Ox stories ^ncapslint-ebh6 and ^ncapslint-x3gi.

## User Stories

1. As an Inn maintainer, I want the row-90 Ox pin and build-only `ox_lint`
   installed alongside `ox_caps`, so that the normal shell runs the
   compiler-backed installed gate without Semgrep. ^innlint-p3hx
2. As an Inn maintainer, I want the gate launcher to build `@install` before
   checking, with build-first instructions in the agent and build notes, so that
   typed capability rules have fresh matching evidence. ^innlint-b7km

## Implementation Decisions

- The pin includes the executable-install fix after row 90: `bin/ox-lint`
  is executable, `share/ox_lint` contains rule pages and fixtures, and the
  installed launcher resolves `OX_LINT`, its prefix's `bin/ox-lint`, then `PATH`.
- Ox owns shared package pins and installation; Inn continues using
  `$HOME/.cache/opam`, switch `5.4.0+ox`. No private installation replaces it.
- `dune-project` is the dependency source of truth; `inn.opam` is generated.
- Inn declares no Semgrep dependency in its shell, so there is none to remove.
- The mandatory source tier remains build-independent. Full typed coverage
  needs this tree's annotations with current CMI fingerprints. The native
  executable uses `(modes byte exe)` with an install alias depending on
  `main.bc`, retaining implementation `.cmt` evidence alongside the native binary.
- Keep the gate's installed launcher, source scope `lib bin` and argument forwarding.
- After five genuine typed-signature findings, the human authorized exactly one
  temporary allowance: `bin/main.ml` uses a mutable global Door slot, and five
  entry points draw their authority from it.
  [Issue row 16](../thread-door-capabilities/01-thread-door-capabilities.md) threads
  capabilities through arguments and removes this allowance. No application
  code is changed by the migration.

## Testing Decisions

Run the installed gate directly before a build to record undecided modules,
then run the normal shared-shell build, full tests (including the Ox guide),
formatting and capability gate. Capture each command's exit code directly.
Accept only zero findings and zero typed-undecided modules among non-allowed
sources after building. Record the five findings before the authorized allowance.

## Out of Scope

Application changes, further allowance changes, deployment, shared-switch pin
ownership and modernization of the historical `scripts/test-local-ox.sh` mirror.

## Verification

Verified against Ox `c03cbf9af329a9d575b88eaf074e7b578df8ff97` in the normal
shared `5.4.0+ox` switch; no private install or shared-switch mutation by Inn.

- Installed gate before building: exit 0, zero findings, eight typed-undecided
  modules. A native-only build reduced the undecided count to one.
- With the byte target in `@install`: build exit 0, gate exit 1, five genuine
  `ox-caps-signature` findings and zero typed-undecided modules. The sites and
  required follow-up are recorded in issue row 16.
- After the explicitly authorized allowance, all four normal gates exited 0:
  `dune build @install`, `dune test`, `dune build @fmt`, `scripts/caps-gate`,
  each through `nix develop` with its exit code captured directly.
- Tests include the full Inn and MCP suites and the compiled exporter snippet
  against an isolated Inn (`INN_ETA_GUIDE_SNIPPET=1`).
- The strict capability gate (`--require-typed`) also exits 0 and reports zero
  findings and zero typed-undecided modules among non-allowed sources.
  `bin/main.ml` remains explicit debt.
- Formatting exited 0 but warned that OCaml formatting is disabled because the
  repository has no `.ocamlformat`; changing that policy is not this migration.
