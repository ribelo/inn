---
status: completed
---

# Build Inn on the latest Eta

## Problem Statement

Inn was last built against Eta commit `1589b3e5` (2026-08-25). The local Eta
checkout at `/home/ribelo/projects/ribelo/ocaml/Eta` is now about 200 commits
ahead, and it has fully moved to OxCaml. Inn still builds against the old Eta
installed in the shared OxCaml opam switch (`~/.cache/opam`, switch `5.4.0+ox`).
Until Inn builds and passes its tests on current Eta, no other Inn work can
land safely. Inn also stays blind to Eta fixes and API changes, including
changes to the Eta SQL gaps recorded in Inn's `.spec/ETA_SQL_DOGFOODING.md`.

## Solution

Inn compiles, and its test suite passes, against the current local Eta master.
There is a documented, repeatable way to build Inn against a local Eta checkout
that does not require upgrading Eta in the shared opam switch. Where current Eta
now provides a capability Inn previously worked around (the dogfooding notes),
Inn uses it, and the notes are updated to say what is resolved and what is not.

## User Stories

1. As the Inn maintainer, I want Inn to compile against the current local Eta master, so that Inn benefits from Eta fixes and keeps up with Eta API changes ^etam-1rrv
2. As the Inn maintainer, I want Inn's full test suite to pass against current Eta, so that I know the migration did not change behavior ^etam-ishh
3. As the Inn maintainer, I want one documented command that builds and tests Inn against a local Eta checkout without mutating the shared opam switch, so that pie and grip, which also depend on Eta in that switch, are not rebuilt or broken as a side effect ^etam-8hoz
4. As the Inn maintainer, I want every Eta API change that forced an Inn source change listed in the commit message, so that I can review the migration quickly ^etam-x02v
5. As the Inn maintainer, I want Inn to use any Eta SQL capability that now removes a workaround from the dogfooding notes (heterogeneous composite indexes, heterogeneous conflict-update sets, transaction bodies with wider error types), so that storage code gets simpler and query planning gets better ^etam-kfmp
6. As the Inn maintainer, I want the dogfooding notes updated to separate resolved gaps from remaining gaps, so that the notes do not describe gaps that no longer exist ^etam-0crr
7. As the Inn maintainer, I want the README build instructions to match the real build path on OxCaml, so that a fresh checkout builds without guesswork ^etam-ynfg
8. As the Inn maintainer, I want warnings that appear on the new Eta or compiler (deprecations, unused values) fixed rather than silenced, so that the build stays clean ^etam-f0ar

## Implementation Decisions

- Target Eta is the local checkout's current `master`. Do not modify Eta in
  this ticket. If an Eta bug blocks the migration, stop and report it with a
  minimal reproduction instead of working around it silently.
- The shared opam switch `5.4.0+ox` under `~/.cache/opam` must not have Eta
  upgraded or reinstalled by this ticket. Installing Inn into that switch for
  the systemd service is a separate ticket. For development builds, use a
  composition that resolves Eta from the local source checkout. Examples: a
  Dune workspace root that contains both source trees (symlinks are acceptable
  in an ignored directory), or a separate local opam switch. The chosen
  mechanism must be scripted or documented, and it must leave the shared switch
  untouched.
- Keep Inn's public module interfaces (the Config, Model, Otlp, Store, and Inn
  interfaces) stable unless an Eta change forces a change.
- Storage keeps using Eta SQL typed builders without raw SQL, as today.
- Leave the flake's Eta input and lock alone. The local Eta master may contain
  commits that are not on GitHub yet.

## Testing Decisions

- The existing Alcotest suite (config, otlp, store, and server handler tests)
  is the regression seam. It must pass unchanged in intent (etam-ishh,
  etam-1rrv).
- If you adopt a new Eta SQL capability, cover it through existing store-level
  behavior tests: ingest followed by a query returns the same results
  (etam-kfmp).
- A clean `dune build` with no warnings on the new setup covers etam-f0ar.
- The documented build and test command must be run exactly as written in the
  README (etam-8hoz, etam-ynfg).

## Out of Scope

- New features, API parity work, and retention changes. Separate specs cover
  them.
- Upgrading Eta in the shared opam switch, and installing the Inn binary for
  the systemd service.
- Changes to Eta itself.

## Further Notes

- Pie and grip also depend on Eta in the shared switch. Whether they build on
  current Eta is unknown. That is why the shared switch is off limits here.
