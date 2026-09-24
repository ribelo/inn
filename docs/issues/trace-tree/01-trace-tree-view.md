---
status: ready-for-agent
---

# Trace tree view

## Problem Statement

Motel returns a trace as a tree. Each span carries its depth, its parent's
operation, and the root operation. Missing parents are flagged with warnings.
Traces and spans that have not finished are marked as running. Inn returns a
flat list sorted by start time, and the span detail knows nothing about the
span's place in the trace. An agent has to rebuild the hierarchy itself, and it
cannot see at a glance that a parent span never arrived. Losing a parent span
is a common instrumentation bug.

## Solution

The trace detail, the trace spans list, and the span detail all present spans
in tree order: depth-first from the roots, siblings by start time. Each span
has its depth, parent operation, root operation, and running state. Traces
list warnings for spans whose parent is missing and for multiple roots. Inn
keeps its separate `attributes` and `resource` objects, and its inline
correlated logs.

## User Stories

1. As an agent, I want trace spans returned in depth-first tree order with siblings sorted by start time, so that I can read the call structure top to bottom ^tree-tflv
2. As an agent, I want each span in a trace to carry `depth` (roots at 0), so that I can indent or reason about nesting ^tree-3w92
3. As an agent, I want each span to carry `parentOperationName` and the trace's `rootOperationName`, so that I understand a span's context without extra lookups ^tree-sih1
4. As an agent, I want the span detail endpoint to include `depth`, `parentOperationName`, and `rootOperationName`, so that a single-span lookup has its context too ^tree-o79f
5. As an agent, I want a warning on the trace and on the affected span when a span's parent id is not in the trace, and I want that span treated as a root at depth 0, so that instrumentation gaps are obvious ^tree-ffmn
6. As an agent, I want a warning when a trace has more than one root, so that broken context propagation is visible ^tree-ap92
7. As an agent, I want spans with no end time marked `isRunning: true`, and the trace marked running when any of its spans is running, so that I can tell in-flight work from finished work ^tree-78hm
8. As an agent, I want the trace summary list to include `isRunning` and `warningCount`, so that I can find broken or in-flight traces from the list ^tree-6vac
9. As an agent, I want `/traces/{id}/spans` to return the same tree-ordered, annotated spans as the trace detail, so that the two views agree ^tree-uv04
10. As a CLI user, I want `inn trace` to print an indented tree by default and JSON with `--json`, so that I can read a trace in the terminal ^tree-d24c
11. As an agent, I want a trace detail lookup to return 404 only when no span of the trace exists, even if its summary row is missing, so that partly-stored traces are still viewable ^tree-ddll

## Implementation Decisions

- The tree assembly is a pure module over a list of spans. It returns ordered
  spans with depth, parent operation, the root operation, and warnings. The
  store's trace and span lookups call it. The trace JSON shape keeps
  `summary`, `spans`, and `logs`, and adds `warnings` to the trace plus the
  per-span fields.
- The span detail computes its context by loading its trace's spans and
  reusing the same module. A trace is small enough that this is cheap, and it
  avoids a second algorithm.
- Missing parents are not replaced by synthetic spans (motel inserts fake
  rows). Warnings on the span and the trace carry the same information
  without inventing data.
- Running state: an end time of zero, or an end before the start, counts as
  running. A running span's duration is null in JSON.
- The summary gains running and warning-count fields, maintained when the
  summary is refreshed. This bumps the schema version.
- The CLI tree rendering uses one line per span: indentation, operation,
  service, duration, and an error mark.

## Testing Decisions

- Unit tests of the tree module: nested trees, siblings out of order, a
  missing parent, multiple roots, cycles (a span that is its own ancestor
  through bad data must not loop forever), and running spans (tree-tflv …
  tree-78hm).
- Handler tests for the trace, trace spans, and span detail shapes, and for
  the 404 rule (tree-o79f, tree-uv04, tree-ddll, tree-6vac).
- Cram test of the CLI tree output (tree-d24c).

## Out of Scope

- An HTML trace page. The UI is out of scope.

## Further Notes

- Implement after the OTLP ingest spec (the time model).
