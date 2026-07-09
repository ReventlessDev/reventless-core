# Plan: Deployed StateViewSlice runtime drops `subIdConfig` → multi-state projections silently no-op

**Status:** Done (2026-07-09) — root-caused live with debug tracing against a deployed
DynamoDB-backed projection Lambda; fixed and guarded by an entry-point-level integration test
that is red before the fix, green after.

## Summary

The deployed StateViewSlice projection runtime
([`StateViewSliceEntryPoint.mjs`](../../reventless/reventless-aws/src/adapter/Runtime/StateViewSliceEntryPoint.mjs))
calls `handleAction(action, queryDbOps, undefined)` — it **hardcodes `subIdConfig` to
`undefined`** instead of threading the slice's `specModule.subIdConfig`. Every projection
action that needs the sub-id — `UpdateMultiState` (and any other sub-id-dependent multi-state
action) — therefore hits the runtime's `subIdConfig === undefined` guard, returns
`Error "MissingSubIdConfig"`, and **writes nothing**. `Set`/`SetMany`/`Delete` actions don't
need `subIdConfig`, so they persist normally.

Net effect on any `@subId` view slice: its **create-via-`Set`** paths work, but its
**`UpdateMultiState`** paths are silent no-ops. A slice whose *only* (or primary) projection
path is `UpdateMultiState` never persists a single row, even though the events arrive, decode
cleanly, and `project()` returns the correct actions.

## Why it escaped tests

The in-memory/SQLite callback path used by GWT/unit suites
([`StateViewSlice_Callback.res`](../../reventless/reventless-core/src/components/StateViewSlice/StateViewSlice_Callback.res))
calls `Projection.handleActions(allActions, queryDbOps, Spec.subIdConfig)` — it threads
`subIdConfig` **correctly**. Only the deployed `.mjs` entry point drops it. So a slice's
`UpdateMultiState` GWT test is green while the same projection writes nothing in production.
This is a deployed-runtime vs test-harness parity gap (cf. the conformance-kit motivation).

## Live evidence (deployed DynamoDB projection Lambda, 2026-07-09)

Debug-level tracing (`LOG_LEVEL=debug`) on a projection consumer processing an event whose
projection returns `UpdateMultiState`:

```
level:ERROR "failed to decode event" … (benign: sibling slices rejecting an event they don't own)
"UpdateMultiState Error: Missing SubIdConfig !"      ← the owning slice, on its own event
```

- The owning slice **decodes the event successfully** (0 self-rejections for its own event
  type across the batch — it is not a decode failure).
- Its `project()` returns `[UpdateMultiState(id, …)]`.
- The runtime logs `Missing SubIdConfig !` and the view table stays empty.
- Sibling slices whose create path is `Set` populate normally in the same consumer, proving
  delivery + the runtime are otherwise healthy.

Root cause is exact and code-only:
[`StateViewSliceEntryPoint.mjs`](../../reventless/reventless-aws/src/adapter/Runtime/StateViewSliceEntryPoint.mjs)
line ~95:

```js
action => Effect.map(
  Effect.promise(() => handleAction(action, queryDbOps, undefined)),  // ← undefined
  _ => {}
)
```

`specModule.subIdConfig` is already in scope in this function (it is read a few lines up to
derive `subIdField` for the Postgres ops), so the value is available; it is simply not passed.

## Fix

1. Thread the slice's `subIdConfig` into `handleAction`:
   `handleAction(action, queryDbOps, specModule.subIdConfig)`. (`specModule.subIdConfig` is
   `undefined` for slices without an `@subId`, which is correct — those never emit sub-id
   actions.) Consider switching this per-action loop to `Projection.handleActions` (plural,
   which also groups/optimizes actions per id) for parity with the callback path — but the
   minimal, safe fix is threading the config.
2. **Regression test at the entry-point layer** (the gap that let this ship): drive
   `StateViewSliceEntryPoint`'s built handler with an event whose projection returns
   `UpdateMultiState` for an `@subId` slice, against a real DynamoDB (Local/container) or the
   integration QueryDb, and assert the row is persisted. A unit test on the callback path
   cannot catch this — the test must exercise the `.mjs` entry point that production uses.
3. Audit the other `HANDLER_CONFIG`-driven entry points that call `handleAction`/projection
   directly for the same dropped-`subIdConfig` shape (grep `handleAction(.*undefined`).

## Acceptance

- An `@subId` view slice whose projection uses `UpdateMultiState` persists rows in a deployed
  (DynamoDB) run — not only in the in-memory GWT harness.
- New entry-point-level integration test is red before the fix, green after.
- No `Missing SubIdConfig` at runtime for a correctly-annotated `@subId` slice.

## Notes

- Code-only in `reventless-aws` (`.mjs` runtime + a test); no PPX / no schema change.
- The compiled per-slice spec already carries `subIdConfig` (generated from `@subId`); this is
  purely a runtime-wiring omission, not a codegen gap.

## Resolution (2026-07-09)

1. **Fix** — [`StateViewSliceEntryPoint.mjs`](../../reventless/reventless-aws/src/adapter/Runtime/StateViewSliceEntryPoint.mjs)
   now calls `handleAction(action, queryDbOps, specModule.subIdConfig)` (was `undefined`).
2. **Regression test** — [`StateViewSliceEntryPoint_IntegrationTest.res`](../../reventless/reventless-aws/tests/integration/StateViewSliceEntryPoint_IntegrationTest.res)
   drives the *real* exported `buildJsonEventsHandler` from the `.mjs` entry point against
   DynamoDB Local. Fixture `SvsTestSlice` is an `@subId productId` view slice whose only
   projection path is `UpdateMultiState`; the test adds two products to one cart and asserts two
   distinct sub-id rows persist (and that the second append reads back the first). Verified
   **red before** the fix (0 rows, `MissingSubIdConfig`) and **green after** (2 rows). To make
   the entry point testable, `buildJsonEventsHandler` was `export`ed (it already takes
   already-imported module objects, so no loader shim was needed).
3. **Audit** — grepped every `handleAction` call site across the runtime `.mjs` + compiled
   callbacks. Only `StateViewSliceEntryPoint` reimplemented the projection loop in JS and dropped
   `subIdConfig`. `ReadModelEntryPoint.mjs` delegates to the compiled `ReadModel_Callback` (which
   threads `subIdConfig`); `StateViewSlice_Callback` / `StateViewSlice_Builder` thread it too.
   No other carrier of the bug.
