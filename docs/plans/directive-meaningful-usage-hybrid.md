# Meaningful Directive Usage in the Hybrid Example

## Problem

After the `Call` → `HandleDirective` rename (see `docs/plans/done/directive-naming-consistency.md`),
the framework's `directive` vocabulary is consistent — but the hybrid example
still declares `type directive = unit` in both Extension Point specs and never
emits a `HandleDirective` action. New users reading the example see the rename
in the framework types but no example of *why* the abstraction exists or *when*
to use it.

We want two complementary, narrative-driven demonstrations in
`examples/online-shop-hybrid`:

1. an **EP-side** directive fired from the publishing plugin's mapping;
2. an **Extension-side** directive fired from the subscribing plugin's mapping.

The two together cover both shapes of `HandleDirective` and clarify the
boundary between "durable domain action" (PublishCommand / PublishEvent /
PublishStateChangeSliceCommand) and "non-durable side effect" (HandleDirective).

## Findings

### What a directive is

`Spec.directive` is the EP-side **typed contract for side effects**. It lives in
the Extension Point spec (`@@reventless.spec`), is `@schema`-annotated, and is
visible to both:

- the EP-side mapping (`*_ExtensionPointMapping.res`) — which decides what
  side effects to fire alongside its own delegate events and incoming commands;
- any Extension subscribing to the EP (`*_Extension.res`) — which decides what
  side effects to fire when it receives EP events.

The runtime treats directives as a separate channel from the event log — they
are *not* persisted, *not* replayed, and *not* visible to other subscribers.

### EP-side `HandleDirective`

```rescript
// reventless-infra/src/types/ExtensionPointMapping.res
type directiveHandler<'directive> = (
  Reventless.Schedule.create,
  Reventless.Schedule.delete,
  Reventless.QueryEngine.operations,
  'directive,
) => promise<unit>

// used in commandAction / eventAction:
| HandleDirective(directiveHandler<'directive>, 'directive)
```

The handler gets the full EP toolbox: schedule a future command, delete a
schedule, run queries. **Canonical use**:
`reventless-core/src/admin/PluginExtensionPoint_Plugin.res:85-125` — five
directives covering `CreateDisconnectSchedule`, `DeleteDisconnectSchedule`,
`ForwardCommand`, `DoConnectPlugin`, `DoDisconnectPlugin`.

### Extension-side `HandleDirective`

```rescript
// reventless-infra/src/types/ExtensionMapping.res
| HandleDirective(Reventless.Handler.handler<'directive>, 'directive)

// where Reventless.Handler.handler<'msg> = 'msg => promise<unit>
```

The Extension-side handler signature is intentionally narrower — pure
fire-and-forget. No Schedule, no QueryEngine. The mapping itself
(`mapIncomingEvent`) does get `_queryEngine` as its fifth arg, so query-based
*decisions* live in the mapping; the handler executes the resulting side
effect.

### GWT support

`reventless/reventless-gwt/src/Delegate_GWT.res` already exposes:

- `thenHandlesDirective(actions, directive)` — assert a single directive;
- `thenHandlesDirectives(actions, directives)` — assert a set;
- `thenHandlesNoDirective(actions)` — assert none.

Both `EPMapping.HandleDirective(_, dir)` and `ExtMapping.HandleDirective(_, dir)`
serialise through the same `target:"directive"` channel, so existing
`thenPublishesEvent` / `thenPublishesCommand` assertions stay disjoint and
existing tests don't break.

## Use Cases

Both use cases use **standard variants** throughout — no polymorphic variants
(`#foo` syntax) anywhere in the example payloads.

### Use case A — EP-side: `EmitPricingUpdate`

- **Where**: Catalog's `Products_ExtensionPoint` (publishing side).
- **When**: alongside the public `ProductPriceChanged` event in
  `Products_ExtensionPointMapping.mapOutgoingEvent`.
- **Why a directive (not a command/event)**: pricing updates flow to an
  external analytics sink (Datadog, custom pipeline, etc.). That sink is not
  part of the domain, not durable, not replayable, and not addressed at any
  other plugin. A `PublishEvent` would force every downstream subscriber to
  filter it out; a `PublishCommand` would invent a fake aggregate to hold
  non-domain telemetry. `HandleDirective` is the right shape.
- **Side benefit**: the EP-side handler signature exposes Schedule and
  QueryEngine. The example's handler intentionally uses **neither** (it only
  emits a structured log line); the file carries a one-line comment
  referencing `PluginExtensionPoint_Plugin.res` for a full multi-capability
  usage. This keeps the hybrid example small without misleading readers about
  what the EP-side handler *can* do.

Spec change (`examples/online-shop-hybrid/catalog-spec/src/Products_ExtensionPoint.res`):

```rescript
@schema
type directive =
  | EmitPricingUpdate({productId: string, price: float})
```

### Use case B — Extension-side: `EmitOrderTelemetry`

- **Where**: Catalog's `Orders_Extension` (subscribing to Ordering's
  `Orders_ExtensionPoint`).
- **When**: alongside `RecordDemand` / `RevokeDemand` commands in
  `Orders_Extension.Mapping.mapIncomingEvent`.
- **Why a directive (not just a logger call in the handler)**: ad-hoc
  side effects buried in handlers are invisible to GWT tests, untyped, and
  resist refactoring. `HandleDirective` carries a typed payload, surfaces in
  `thenHandlesDirective` assertions, and survives schema evolution alongside
  the other EP-vocabulary changes.
- **Why Extension-side**: the telemetry is a *Catalog* concern about
  *Catalog's* product demand. Ordering shouldn't fire it on Catalog's behalf.
  And the side effect needs neither Schedule nor QueryEngine — the narrower
  Extension-side handler signature fits.

Spec change (`examples/online-shop-hybrid/ordering-spec/src/Orders_ExtensionPoint.res`):

```rescript
@schema
type directive =
  | EmitOrderRecordedTelemetry({productId: string, orderId: string})
  | EmitOrderCancelledTelemetry({productId: string, orderId: string})
```

Two constructors instead of a single one with a `kind` field — keeps each
directive's payload tight and avoids a nested telemetry-kind type. Standard
variants, no polymorphic-variant payloads.

### How the two use cases relate

| Dimension | EP-side (`EmitPricingUpdate`) | Extension-side (`EmitOrderTelemetry`) |
|---|---|---|
| Plugin firing the directive | Catalog (publisher) | Catalog (subscriber) |
| Trigger | Catalog's own `ProductPriceChanged` event being mapped to the EP | Ordering's `ItemOrdered`/`ItemOrderCancelled` arriving via the EP |
| EP spec carrying the directive type | `Products_ExtensionPoint` (Catalog) | `Orders_ExtensionPoint` (Ordering) |
| Handler signature | `(Schedule.create, Schedule.delete, QueryEngine.operations, directive) => promise<unit>` | `directive => promise<unit>` |
| Demonstrates | The EP-side handler shape and the EP's right to fire its own typed side effects | The Extension-side handler shape and how a subscriber co-locates domain + non-domain reactions to a single EP event |
| Pairs with the existing `PublishX` action | `PublishEvent(...) + HandleDirective(...)` (line 23 of the mapping) | `PublishStateChangeSliceCommand(...) + HandleDirective(...)` (line 12 of the extension) |

The narrative is symmetric: **the same `HandleDirective` constructor name
works on both sides; the types of `directive` and the runtime capabilities of
the handler differ to match the side's role.** The hybrid example now teaches
both shapes in one read.

## Implementation Steps

### 1. EP-side directive — `Products_ExtensionPoint`

#### 1a. Spec change

File: `examples/online-shop-hybrid/catalog-spec/src/Products_ExtensionPoint.res`

Replace the placeholder:

```rescript
@schema
type directive = unit
```

with:

```rescript
@schema
type directive =
  | EmitPricingUpdate({productId: string, price: float})
```

#### 1b. Mapping change

File: `examples/online-shop-hybrid/catalog/src/ExtensionPoint/Products_ExtensionPointMapping.res`

Add a `directiveHandler` and emit a `HandleDirective` action on
`ProductPriceChanged`:

```rescript
// Side-effect handler for the public Products EP directives.
// EP-side handlers receive Schedule.create / Schedule.delete / QueryEngine
// — see reventless-core/src/admin/PluginExtensionPoint_Plugin.res for a
// canonical multi-capability example. For this demo we only log.
let directiveHandler = async (
  _createSchedule: Reventless.Schedule.create,
  _deleteSchedule: Reventless.Schedule.delete,
  _queryEngine: Reventless.QueryEngine.operations,
  directive: CatalogSpec.Products_ExtensionPoint.directive,
) =>
  switch directive {
  | EmitPricingUpdate({productId, price}) =>
    EffectLogger.logInfo(
      ~comp="Catalog.ProductsExtensionPoint",
      `telemetry: pricing update product=${productId} price=${price->Float.toString}`,
    )->Effect.runSync
  }

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Delegate.ProductAdded({productId, name, price}) => [
      PublishEvent(
        productId,
        CatalogSpec.Products_ExtensionPoint.ProductBecameAvailable({productId, name, price}),
      ),
    ]
  | Delegate.ProductPriceChanged({productId, price}) => [
      PublishEvent(
        productId,
        CatalogSpec.Products_ExtensionPoint.ProductPriceChanged({productId, price}),
      ),
      HandleDirective(
        directiveHandler,
        CatalogSpec.Products_ExtensionPoint.EmitPricingUpdate({productId, price}),
      ),
    ]
  }
)
```

`mapIncomingCommand` is unchanged (still returns `[]`).

#### 1c. GWT test additions

File: `examples/online-shop-hybrid/catalog/tests/ExtensionPoint/Products_ExtensionPointMapping_GWT.res`

Add a test asserting both the public event and the directive:

```rescript
test("ProductPriceChanged emits the public event AND a pricing-update directive", () =>
  whenDelegateEvent(
    Delegate.ProductPriceChanged({productId: "p1", price: 9.99}),
  )
  ->thenPublishesEvent(
    "p1",
    ExtensionPoint.ProductPriceChanged({productId: "p1", price: 9.99}),
  )
  ->thenHandlesDirective(
    ExtensionPoint.EmitPricingUpdate({productId: "p1", price: 9.99}),
  )
)

test("ProductAdded does NOT fire a directive", () =>
  whenDelegateEvent(
    Delegate.ProductAdded({productId: "p1", name: "Widget", description: "", price: 9.99}),
  )
  ->thenPublishesEvent(
    "p1",
    ExtensionPoint.ProductBecameAvailable({productId: "p1", name: "Widget", price: 9.99}),
  )
  ->thenHandlesNoDirective
)
```

If the existing test composes a single chain (`thenPublishesEvents([...])`),
split it into per-event assertions to allow per-event directive checks.

### 2. Extension-side directive — `Orders_ExtensionPoint`

#### 2a. Spec change

File: `examples/online-shop-hybrid/ordering-spec/src/Orders_ExtensionPoint.res`

Replace:

```rescript
@schema
type directive = unit
```

with:

```rescript
@schema
type directive =
  | EmitOrderRecordedTelemetry({productId: string, orderId: string})
  | EmitOrderCancelledTelemetry({productId: string, orderId: string})
```

#### 2b. Extension change

File: `examples/online-shop-hybrid/catalog/src/Extension/Orders_Extension.res`

Add a `directiveHandler` and emit `HandleDirective` alongside the existing
state-change commands:

```rescript
module Mapping = {
  module ExtensionPoint = OrderingSpec.Orders_ExtensionPoint
  module Delegate = RecordProductDemand

  open ExtensionPoint
  open RecordProductDemand

  // Catalog's non-domain telemetry side effect for cross-plugin order events.
  // Extension-side handlers are pure async (`'directive => promise<unit>`):
  // any query-based decision lives in `mapIncomingEvent`, which has access to
  // `_queryEngine`.
  let directiveHandler = async (directive: ExtensionPoint.directive) =>
    switch directive {
    | EmitOrderRecordedTelemetry({productId, orderId}) =>
      EffectLogger.logInfo(
        ~comp="Catalog.OrdersExtension",
        `telemetry: order recorded product=${productId} order=${orderId}`,
      )->Effect.runSync
    | EmitOrderCancelledTelemetry({productId, orderId}) =>
      EffectLogger.logInfo(
        ~comp="Catalog.OrdersExtension",
        `telemetry: order cancelled product=${productId} order=${orderId}`,
      )->Effect.runSync
    }

  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | ItemOrdered({productId, orderId}) => [
        PublishStateChangeSliceCommand(RecordDemand({productId, orderId})),
        HandleDirective(
          directiveHandler,
          EmitOrderRecordedTelemetry({productId, orderId}),
        ),
      ]
    | ItemOrderCancelled({productId, orderId}) => [
        PublishStateChangeSliceCommand(RevokeDemand({productId, orderId})),
        HandleDirective(
          directiveHandler,
          EmitOrderCancelledTelemetry({productId, orderId}),
        ),
      ]
    }

  let mapOutgoingEvent = None
}
```

#### 2c. GWT test additions

File: `examples/online-shop-hybrid/catalog/tests/Extension/Orders_Extension_GWT.res`

```rescript
test("ItemOrdered records demand AND emits an order-recorded telemetry directive", () =>
  whenIncomingEvent(
    ExtensionPoint.ItemOrdered({productId: "p1", orderId: "o1", customerId: "c1"}),
  )
  ->thenPublishesCommand(Delegate.RecordDemand({productId: "p1", orderId: "o1"}))
  ->thenHandlesDirective(
    ExtensionPoint.EmitOrderRecordedTelemetry({productId: "p1", orderId: "o1"}),
  )
)

test("ItemOrderCancelled revokes demand AND emits an order-cancelled telemetry directive", () =>
  whenIncomingEvent(
    ExtensionPoint.ItemOrderCancelled({productId: "p1", orderId: "o1"}),
  )
  ->thenPublishesCommand(Delegate.RevokeDemand({productId: "p1", orderId: "o1"}))
  ->thenHandlesDirective(
    ExtensionPoint.EmitOrderCancelledTelemetry({productId: "p1", orderId: "o1"}),
  )
)
```

(Replace the two existing tests, or keep them and add new combined ones —
the combined form is preferred so each scenario describes the full mapping
output.)

### 3. Compile / verify

After 1 and 2 the ReScript compiler should flag exactly:

- the two spec files;
- the EP-side mapping (new `directiveHandler`, two new `HandleDirective` sites);
- the Extension file (new `directiveHandler`, two new `HandleDirective` sites);
- the two updated GWT tests.

Anything else flagged is a missed touch-point — stop and investigate.

### 4. Cross-plugin sweep (sanity)

```bash
grep -rn "type directive = unit" examples/online-shop-hybrid/
grep -rn "HandleDirective" examples/online-shop-hybrid/
```

After the change, the first sweep should show **zero** hits in
`{catalog,ordering}-spec/src/`; the second should show exactly four hits in
source (`Products_ExtensionPointMapping.res` ×2, `Orders_Extension.res` ×2)
plus the GWT test additions.

### 5. Build + tests

- `pnpm run build` at repo root — clean, zero warnings.
- `pnpm test` — all suites pass. Existing GWT counts may shift (new tests
  added, old single-line tests possibly replaced).

## Documentation Updates

The framework rename commit (`feat!: rename Call directive to HandleDirective`)
did not touch the published docs. The following pages still reference the old
`Call(...)` / `callHandler` names AND describe `type directive = unit` as the
default — both go in one doc-update pass alongside the example.

### `packages/doc/docs-app/components/extensionpoint.md`

| Line | Current | New |
|---|---|---|
| ~107 | `type directive = unit` | `type directive = unit` + a sentence pointing at the hybrid example for a typed directive |
| ~175 | `\| Call(callHandler<'msg>, 'msg)` in `commandAction` | `\| HandleDirective(directiveHandler<'directive>, 'directive)` |
| ~186 | `\| Call(callHandler<'msg>, 'msg)` in `eventAction` | `\| HandleDirective(directiveHandler<'directive>, 'directive)` |
| ~234 | "the `command`, `event`, and `directive` `@schema` types" | unchanged, but add a forward link to the hybrid `EmitPricingUpdate` example |
| ~326 | `Call(async (_create, _delete, _queryEngine, msg) => {...}, SendNotification(...))` | `HandleDirective(directiveHandler, SendNotification(...))` with a separate `let directiveHandler = async (_create, _delete, _queryEngine, directive) => switch directive { ... }` block above |
| (anywhere `callHandler<'msg>` is referenced) | `callHandler<'msg>` | `directiveHandler<'directive>` |

### `packages/doc/docs-app/components/extension.md`

| Line | Current | New |
|---|---|---|
| ~156 | `\| Call('msg => Js.Promise.t<unit>, 'msg)` in `incomingCommandAction` | `\| HandleDirective(Reventless.Handler.handler<'directive>, 'directive)` |
| ~173 | `\| Call('msg => Js.Promise.t<unit>, 'msg)` in `outgoingCommandAction` | `\| HandleDirective(Reventless.Handler.handler<'directive>, 'directive)` |
| ~233 | `type directive = unit` | `type directive = unit` + a sentence pointing at the hybrid `EmitOrderRecordedTelemetry` / `EmitOrderCancelledTelemetry` example |

### `docs/guides/platform-and-plugin-guide.md`

Sweep for any `Call(`, `callHandler`, or "execute side-effect" prose;
substitute `HandleDirective` / `directiveHandler` / "handle directive". The
initial sweep found zero hits, but re-check after the docs above are updated
so the guide stays aligned with example terminology.

### Optional follow-up (not blocking)

`packages/doc/docs-framework/internals/component-structure-pattern.md` and
`packages/doc/docs-framework/architecture/aggregate-extension-connection.md`
mention "extension" but don't reference directives by name. Leave them unless
the sweep surfaces stale `Call`/`callHandler` references.

## Out of Scope

- **Schedule/QueryEngine usage in the EP-side handler.** The hybrid handler
  intentionally takes both params with `_` and ignores them; a one-line
  comment points readers at `PluginExtensionPoint_Plugin.res` for the full
  pattern. Wiring a real `createSchedule` call in the example would require
  inventing a receiver command and corresponding Catalog handler — too much
  scope for a directive-as-shape demo. Could be a follow-up plan.
- **Aggregate-style hybrid plugin coverage.** This plan touches the *hybrid*
  example only. The DCB-style `online-shop-dcb` and Aggregate-style
  `online-shop-aggregates` examples retain `type directive = unit` for now.
  Bringing them to parity is a follow-up; the rename plan already left a
  documented seam.
- **Out-of-tree consumers.** The `directive` spec change is breaking for
  anyone who declared `type directive = unit` and then later referenced it
  in code (no in-repo callers do today). External consumers of the hybrid
  example spec packages would need a one-line rename. Treat as part of the
  same major bump as the `Call` → `HandleDirective` rename rather than a new
  major.

## Open Questions

1. **Should `EmitOrderTelemetry` be one constructor with a `kind` field, or
   two separate constructors?** This plan picks two constructors —
   `EmitOrderRecordedTelemetry` and `EmitOrderCancelledTelemetry` — because:
   (a) the user explicitly ruled out polymorphic variants, which removes the
   ergonomic `~kind=#ordered` shape; (b) a standard variant nested as a
   `kind` field works but adds a separate `@schema type telemetryKind` to
   the spec and shifts the dispatch from `switch directive` to
   `switch directive.kind`; (c) two constructors keeps the spec readable and
   matches the symmetric two-event shape of `ItemOrdered` /
   `ItemOrderCancelled`. Flag if a single-constructor form is preferred.
2. **Should the EP-side handler exercise at least one of Schedule or
   QueryEngine?** This plan says no — the rationale is that wiring a real
   `createSchedule` payload requires inventing a receiver, and showing
   `_create` / `_delete` / `_queryEngine` unused is honest about what the
   demo demonstrates. If the example should showcase Schedule, the EP-side
   directive could become `ScheduleStockReview({productId, daysFromNow})`
   instead and target a (new) Catalog command. Treat as a yes/no before
   starting.

## Outcome

(Filled in on completion: list of touched files, validation results, any
GWT touch-points the audit missed, doc pages updated.)
