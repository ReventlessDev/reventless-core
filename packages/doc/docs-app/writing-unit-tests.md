---
title: Legacy test helpers
sidebar_label: Legacy test helpers
---

# Legacy test helpers

Older Reventless code tests business logic through per-kind helper modules —
`BehaviorTest`, `ProjectionTest`, `EventMappingTest` — each with its own
vocabulary for setting up prior events, dispatching, and asserting.

**Write new tests as scenarios instead.** The
[Given/When/Then DSL](./given-when-then.md) covers every slice kind with one
shared vocabulary, resolves the spec and DSL from the filename, and runs under
both Jest and its own CLI runner. It is the supported path, and the one the
plugin generator and the example plugins use.

This page exists so that a test you meet in older code is not a mystery. If you
are adding to a file that still uses these helpers, adding to it is fine;
converting the file to scenarios is better, and mechanical — the setup, dispatch,
and assertion steps map one to one.

## Where the equivalents are

| Legacy helper | Scenario DSL |
|---|---|
| `BehaviorTest` (aggregate command handling) | `Behavior_GWT` / `StateChangeSlice_GWT` |
| `ProjectionTest` (event → state) | `Projection_GWT` / `StateViewSlice_GWT` |
| `EventMappingTest` (cross-entity reactions) | `Mapping_GWT` / `Automation_GWT` |

The verbs line up: prior events become `givenEvents`, dispatch becomes `whenCmd`
or `whenEvent`, and the assertion becomes `thenEvents`, `thenState`, or
`thenError`. See [the shared vocabulary](./given-when-then.md#3-shared-vocabulary)
for the full table.

## Running them

Both kinds compile to `.res.mjs` and run under Jest with the ESM flag — see
[Running tests](./running-tests.md). Nothing about the runner changes when you
convert a file.
