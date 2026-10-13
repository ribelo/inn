# Repository Guidelines

Dangerous calls go through `Ox_caps.Cap_*` and require a capability in the signature. ^inncap-w5qo

## Landing: work is done when it is committed

You are the only agent working in this repository. Each session starts with no
memory of earlier ones. The git history is the only memory that lasts, so
uncommitted work is effectively lost work.

- A task is finished only when its verified change is committed to local
  `master`. A passing build or a green test run is not finished work.
- Commit each coherent, verified slice as soon as it is done. Do not batch a
  whole session into one commit at the end. The commit message names what
  changed and cites the issue or story IDs it covers.
- Never end a session with uncommitted changes. If something is unfinished,
  commit it anyway with a message that says what is unfinished and why, or
  record it in `docs/issues`.
- Uncommitted changes you find at the start of a session came from an earlier
  session of yours that did not land its work. There is no other author. Read
  the diff, verify it (build and tests), and then commit it or finish it. Do not
  work around it, stash it, or treat it as someone else's change.
- When subagents implement slices, the coordinating session reviews each result
  and commits it before starting dependent work.
- After a commit that changes the server, the CLI, or the store, install it into
  the running service with `./scripts/install-inn-service.sh` and confirm that
  it reports healthy. The service runs the installed binary, so a change that is
  committed but not installed is not finished. ^bcache-i9st
- Push only when the user asks.

## Gates (before any commit)

```sh
export INN_ETA_GUIDE_SNIPPET=1
nix develop -c dune build @install @check
nix develop -c dune test
nix develop -c dune build @fmt
nix develop -c scripts/caps-gate
```

Build before the capability gate with the same shared OxCaml switch and
dependencies. The source tier needs no build artefacts; the typed tier needs this
tree's fresh `.cmt`/`.cmti` evidence with matching CMI fingerprints.
`scripts/caps-gate` rebuilds `@install @check` before forwarding to the installed
`share/ox_caps/caps-gate`, which resolves `bin/ox-lint` in the same prefix.
A green full gate has no findings and no typed-undecided modules among checked
sources. ^innlint-b7km

The CLI receives capabilities through arguments from the Door; every production
source is checked without allowances. ^inndoor-m8sw

## Agent skills

### Issue tracker

Issues and specs live as committed markdown files under `docs/issues/`; wayfinder maps under `docs/wayfinder/`. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, with label strings equal to their names. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` at the repo root once terms are resolved. See `docs/agents/domain.md`.
