# Plan: Add `Flow_GWT.AggregateCommandStep` — Aggregate-Style Steps in Cross-Plugin Flow Tests

## Why

`Flow_GWT` is the cross-slice / end-to-end GWT — it threads one JSON-erased
event log through a chain of slices, so a single declarative test verifies
that the tiles of an Event Modeling board connect the way the diagram says.
Today every step kind (`CommandStep`, `AutomationStep`, `ViewStep`,
`ExtensionPointStep`, `ExtensionStep`) is DCB-shaped. There is no aggregate
step kind.

Concrete consequence: `examples/online-shop-aggregates/` cannot ship a
cross-plugin Flow_GWT test (Step 2.3 of
[bring-aggregates-dcb-examples-to-hybrid-parity.md](../bring-aggregates-dcb-examples-to-hybrid-parity.md)).
Hybrid's existing `HybridFlow_GWT` works around the gap by composing only
StateChangeSlices (`PlaceOrder`, `SyncCatalogProduct`,
`RecordProductDemand`) and never threading an aggregate through
`CommandStep` — same constraint hits anyone who wants to flow-test through
an aggregate-style entity.

## The constraint

`Flow_GWT.CommandStep` is parameterised over `Behavior_GWT.BehaviorSpec`:

```rescript
module type BehaviorSpec = {
  let name: string
  @schema type consumedEvent
  @schema type command
  @schema type error
  @schema type event
}
```

Inside the step:

```rescript
let consumedDecoder = Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema)
let consumedEventTypes = consumedDecoder.eventTypes
// ...
let query = Reventless.DcbTag.buildQueryFromCommand(
  ~eventTypes=consumedEventTypes,
  ~schema=Spec.commandSchema,
  ~value=command,
)
let history = decodeMatching(s.log, consumedDecoder, query)
let state = history->Array.reduce(Behavior.initialState, Behavior.evolve)
```

Two style-specific assumptions:

1. **`Spec.consumedEvent` exists** — `Aggregate.Spec` exposes `event` but
   not `consumedEvent`; an aggregate folds its own event stream, not a DCB
   query result.
2. **DCB tag-filtered history** — `Flow_GWT.CommandStep` rebuilds the
   pre-state by running a DCB query (`buildQueryFromCommand`) over the
   shared log. Aggregates fold by aggregate-ID partition, not by DCB tag
   intersection.

So even if you wrap an aggregate spec with `type consumedEvent = event`,
`buildQueryFromCommand` would still produce the wrong history filter
(empty for an aggregate command, since aggregates carry no `@partitionTag`
DCB annotations).

## Goal

`Flow_GWT.AggregateCommandStep(Spec, Behavior)` — parameterised over
`Aggregate.Spec` + `Behavior.T` (the same shape consumed by
`Behavior_GWT.MakeFromAggregate`) — produces:

```rescript
module type AggregateCommandStep = {
  let givenEvents: (flow, ~id: string, array<Spec.event>) => flow
  let whenCommand: (flow, ~id: string, Spec.command) => flow
  let thenEvent: (flow, Spec.event) => flow
  let thenEvents: (flow, array<Spec.event>) => flow
  let thenError: (flow, Spec.error) => flow
}
```

The aggregate-ID is explicit (no DCB tag inference): each `givenEvents` and
`whenCommand` is partitioned by `~id`. History is filtered to entries
tagged with the same aggregate-ID on the shared log; the per-step `evolve`
folds the matching events through `Behavior.initialState`.

So an aggregates-side cross-plugin flow reads:

```rescript
module Sync = Flow_GWT.AggregateCommandStep(
  OrderingPlugin.CatalogProduct, OrderingPlugin.CatalogProduct_Behavior,
)
module Place = Flow_GWT.AggregateCommandStep(
  OrderingPlugin.Order, OrderingPlugin.Order_Behavior,
)

start
->Sync.whenCommand(~id="p1", SyncNewProduct({name: "Book", price: 9.99}))
->Sync.thenEvent(CatalogProductSynced({productId: "p1", name: "Book", price: 9.99}))
->Place.whenCommand(~id="o1", Place({customerId: "c1", productIds: ["p1"]}))
->Place.thenEvent(Placed({customerId: "c1", productIds: ["p1"]}))
```

## Scope

### Framework (`reventless-gwt/src/Flow_GWT.res`)

- Add an aggregate-ID column to `logEntry`: alongside `eventType` / `tags` /
  `json`, every entry now also carries the source aggregate-ID (a string).
  DCB steps continue to ignore this column; aggregate steps filter on it.
- Add `module AggregateCommandStep = (Spec: Aggregate.Spec, Behavior: Behavior.T with module Spec = Spec) => { ... }`
  mirroring the public surface of `CommandStep` but with `~id`-keyed
  partitioning and no DCB-query semantics.
- Add `givenEvents(~id, events)` to the entry-point modules so flows that
  start mid-stream can seed an aggregate's prior history.

### PPX support (`reventless-ppx`)

`@@reventless.gwt` already auto-injects `include Flow_GWT.{...}` based on
folder name. The `Flow/` folder vocabulary needs no change — what changes
is the user's choice of `Flow_GWT.AggregateCommandStep` vs
`Flow_GWT.CommandStep` inside the test file.

### Example: `examples/online-shop-aggregates/platform-local/tests/Flow/`

Once the framework lands, Step 2.3 of the parity plan resumes. Compose an
end-to-end aggregates-style flow:

```
CatalogProduct (sync) ─→ Place Order ─→ Ship Order ─→ Order_EmailNotification SideEffect
```

The SideEffect tail requires `SideEffect_GWT` (separate plan); without it,
the flow stops at `Ship Order`.

## Sequencing

1. **Framework** — add `Flow_GWT.AggregateCommandStep` + `logEntry`
   aggregate-ID column. Existing DCB steps unchanged; verify hybrid's
   `HybridFlow_GWT` and `OrderingFlow_GWT` still pass.
2. **Examples** — resume Step 2.3 of the parity plan: write
   `AggregatesFlow_GWT.res`.
3. **Docs** — update the Flow_GWT walkthrough in
   `docs/guides/` (or wherever `Flow_GWT` is currently documented) with the
   aggregate-step example.

## Verification

- `pnpm test` from `reventless-gwt` passes new fixtures exercising
  `AggregateCommandStep`.
- Existing DCB Flow_GWT tests in hybrid + DCB examples still pass —
  proves the `logEntry` column addition is backwards-compatible.
- `examples/online-shop-aggregates/platform-local/tests/Flow/AggregatesFlow_GWT.res`
  passes once written.
- Zero warnings under `-44+101`.

## Out of scope

- Touching `CommandStep` semantics. DCB step behaviour is unchanged.
- Hybrid plan: mixing an aggregate-step with DCB-steps in the same flow.
  Mechanically achievable (the shared log already accommodates both) but
  not needed to close the current example gap. Revisit if the hybrid
  example wants to thread its Customer aggregate through `HybridFlow_GWT`.

## Risks

- **`logEntry` schema change** ripples through fixture files. The
  aggregate-ID column has to default to a sentinel (empty string, or
  `option<string>`) so DCB-only step chains keep working without
  modification.
- **Multi-aggregate flows** through a single step's pre-state filter need
  clear `~id` semantics — easy to confuse "all events on this aggregate's
  log" with "events seeded by this step". The API picks the former
  (filter by `~id` on the shared log) for symmetry with the runtime.
