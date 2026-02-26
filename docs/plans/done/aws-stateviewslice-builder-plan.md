# AWS StateViewSlice_Builder Implementation Plan

## Status: 🔲 TODO

## Context

The `StateViewSlice_Builder` in `reventless-aws` is currently a no-op placeholder.
The core builder (`reventless-core/StateViewSlice_Builder.res`) was fully implemented
in the `stateviewslice-core-builder-plan` — it is a parametrized functor that accepts
adapters for QueryDb storage/resolvers, EventCollector channel, and a runtime environment.

This plan wires in the AWS adapters (DynamoDB, AppSync, DynamoDB Streams, Lambda) to
produce a production-ready AWS implementation, following the exact same pattern as
`ReadModel_Builder_Single` and `Counter_Builder` in the same package.

---

## Key Files

| File | Change |
|------|--------|
| `reventless/reventless-aws/src/components/StateViewSlice_Builder.res` | Replace no-op placeholder with thin AWS delegating builder |
| `reventless/reventless-aws/src/Platform.res` | Change `StateViewSlice` to use `StateViewSlice_Builder.Make(ApiValues)` directly |

No other files need modification.

---

## Design

### Adapter choices

StateViewSlice subscribes to a DcbEventLog. In AWS:
- DcbEventLog uses `EventTopicPublisher.DynamoDbStream` → its EventTopic resource is a
  DynamoDB Stream.
- `EventCollectorChannel.DynamoDbStream` subscribes Lambda to DynamoDB streams — the
  natural pairing.
- Runtime: `RuntimeEnvironment.Lambda` (same as ReadModel).
- QueryDb storage: `QueryDbStorage.DynamoDb` + `QueryDbResolvers.AppSync` (same as
  ReadModel and Counter).

### api/apiRole pattern

StateViewSlice deliberately bundles api/apiRole into the outer `Api` functor module
(unlike ReadModel which passes them per `make()` call). This keeps `StateViewSlice.T.make`
signature clean: `(~dcbEventLog, ~opts=?)`.

In AWS the api/apiRole values come from `Platform.Make(ApiValues)`. The builder takes
`ApiValues` as a functor parameter and passes it straight to the core builder's `Api`
parameter — identical to how `Counter_Builder.Make(ApiValues)` works.

### Module shape

`StateViewSlice_Builder.Make(ApiValues)` returns `{ module Make(Spec) }`, which satisfies
the `Platform.T.StateViewSlice` module type. Platform.res can therefore write:

```rescript
module StateViewSlice = StateViewSlice_Builder.Make(ApiValues)
```

replacing the current explicit wrapper that calls the no-op placeholder.

---

## Step 1 — Implement AWS StateViewSlice_Builder

**File:** `reventless/reventless-aws/src/components/StateViewSlice_Builder.res`

Replace the no-op placeholder with:

```rescript
// StateViewSlice_Builder (AWS)
// Wires AWS adapters and delegates to the core ReventlessCore.StateViewSlice_Builder.

module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module EventCollectorRuntimeBuilder = ReventlessCore.EventCollectorRuntime_Builder_Single.Make(
  RuntimeEnvironment,
  EventCollectorChannel,
)

module Make = (ApiValues: {
  let api: Types.AppSync.api
  let apiRole: Types.AppSync.role
}) => ReventlessCore.StateViewSlice_Builder.Make(
  RuntimeEnvironment,
  QueryDbStorage.DynamoDb,
  QueryDbResolvers.AppSync,
  EventCollectorChannel,
  EventCollectorRuntimeBuilder,
  ApiValues,
)
```

Reference files with the same structure:
- `reventless-aws/src/components/ReadModel_Builder_Single.res` — same adapter wiring
- `reventless-aws/src/components/Counter_Builder.res` — same `Make(ApiValues)` pattern

**Status**: 🔲 TODO

---

## Step 2 — Update Platform.res

**File:** `reventless/reventless-aws/src/Platform.res`

Replace the explicit `StateViewSlice` wrapper:

```rescript
// Before:
module StateViewSlice = {
  module Make = (
    Spec: Reventless.StateViewSlice.Spec,
  ): (Reventless.StateViewSlice.T
    with type dcbEvent = Spec.DcbEventLogSpec.event
    and module Spec = Spec) => StateViewSlice_Builder.Make(Spec)
}

// After:
module StateViewSlice = StateViewSlice_Builder.Make(ApiValues)
```

This is identical to how `Counter` is wired:
```rescript
module Counter = Counter_Builder.Make(ApiValues)
```

**Status**: 🔲 TODO

---

## Step 3 — Build and verify

```bash
npm run build
cd reventless/reventless-in-memory && npm test
```

All 5 in-memory StateViewSlice E2E tests must still pass (no behaviour change —
only the AWS package now has a real implementation instead of a no-op).

**Status**: 🔲 TODO

---

## Comparison with existing AWS builders

| Aspect | ReadModel_Builder_Single | Counter_Builder | StateViewSlice_Builder (this plan) |
|--------|-------------------------|-----------------|-------------------------------------|
| EventCollector channel | DynamoDbStream | N/A | DynamoDbStream |
| Runtime | Lambda | N/A | Lambda |
| QueryDb storage | DynamoDb | DynamoDbStream | DynamoDb |
| QueryDb resolvers | AppSync | AppSync | AppSync |
| api/apiRole source | per `make()` call | ApiValues functor | ApiValues functor |
| Platform wiring | explicit wrapper | `Make(ApiValues)` | `Make(ApiValues)` |
