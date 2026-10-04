---
status: ready-for-agent
category: bug
package: inn CLI entry point
consumer: Inn managed daemon
---

# Restart must exec the server rather than restart again

## Problem Statement

During ^inndoor-k4px verification, `inn restart` returned exit 1 against both
the original executable and the capability-threaded executable. Each run stopped
the managed daemon, printed stopped status and then failed startup with a
connection error. Ordinary `inn daemon` and `inn stop` succeeded.

`exec_server` in [main.ml](../../../bin/main.ml) copies `Sys.argv` and rewrites
`argv[1]` from `daemon` to `server` only. When called by `restart`, it leaves
`restart` unchanged and execs that command again instead of the server. The
capability-plumbing change deliberately preserves this pre-existing behavior.

## User Stories

1. As an Inn operator, I want `inn restart` to start a server after stopping the
   identity-verified daemon, so that a successful restart leaves Inn healthy
   instead of recursively executing the restart command. ^innrestart-p7vk

## Implementation and Testing Decisions

- Correct the executable command selection without changing inherited flags or
  the instance identity passed through the environment.
- Exercise a real daemon in an isolated state directory and free port: start,
  restart, verify a new healthy managed identity and exit 0, then stop.
- Preserve identity-verification refusals, stdout/stderr conventions and the
  nonzero-stop short circuit. Run all repository gates.
