# Mapping Harmonization Analysis

## Status: Analysis

## Problem Statement

The Reventless framework has four distinct mapping patterns that share structural similarities but don't reuse common parts. Additionally, DCB-style extensions require boilerplate "fake Aggregate" modules to satisfy module types designed for the aggregate approach.

---

## Inventory of Mapping Kinds

### 1. EventMapping (reventless-spec) — Event → Command

**Purpose:** Route events from one aggregate to commands on another aggregate.

**Source/Target pattern:**
```rescript
module type Source = { let name: string; module Id: Id.T; @schema type event }
module type Target = { let name: string; module Id: Id.T; @schema type command }
```

**Map signature:**
```rescript
let map: (Source.Id.t, Source.event, QueryEngine.operations)
  => array<action<Target.Id.t, Target.command>>
```

**Actions:** `Publish`, `PublishDelayed`, `PublishAsync`, `AddToCounterTarget`, `Count`, `CountMulti`

**Used by:** `EventMapper_Builder` / `EventMapper_Callback` (via `MapperNto1`)

---

### 2. Projection (reventless-spec) — Event → State

**Purpose:** Project aggregate events into read model state.

**Source/Target pattern:**
```rescript
module type Source = { let name: string; module Id: Id.T; @schema type event }
module type Target = { let name: string; module Id: Id.T; @schema type state; ... }
```

**Map signature:**
```rescript
let map: Message.event'<string, sourceEvent> => action<string, targetState>
```

**Actions:** `Create`, `Update`, `Set`, `Delete`, and ~16 more variants

**Used by:** `ReadModel_Builder` / `ReadModel_Callback` (via `ProjectionMapper` → `MapperNto1`)

---

### 3. ExtensionMapping (reventless-infra) — ExtensionPoint ↔ Aggregate (bidirectional)

**Purpose:** Route extension point events to aggregate/slice commands (incoming), and optionally route aggregate events back to extension point commands (outgoing).

**Source/Target pattern:**
```rescript
module type Spec = { let name: string; @schema type command; @schema type event; @schema type directive }
// + module Aggregate: Reventless.Aggregate.Spec  (the wrapped aggregate or DCB fake)
```

**Map signatures:**
```rescript
// Incoming: EP event → aggregate commands
let mapIncomingEvent: (string, EP.event, Message.meta, pluginDef, QueryEngine.operations)
  => array<incomingCommandAction<Aggregate.command, EP.command, EP.directive>>

// Outgoing (optional): Aggregate event → EP commands
let mapOutgoingEvent: option<(string, Aggregate.event, Message.meta, pluginDef)
  => array<outgoingCommandAction<EP.command, EP.directive>>>
```

**Incoming actions:** `PublishAggregateCommand`, `PublishAggregateCommandAsync`, `PublishAggregateCommandsAsync`, `PublishExtensionPointCommand`, `ForwardCommand`, `Call`

**Outgoing actions:** `PublishExtensionPointCommand`, `ForwardCommand`, `Call`

**Used by:** `Extension_Builder` / `Extension_Operations`

---

### 4. ExtensionPointMapping (reventless-infra) — Aggregate ↔ ExtensionPoint (reverse direction)

**Purpose:** Route incoming extension commands to aggregate commands, and optionally route aggregate events to extension point events. This is the "host side" mapping (vs ExtensionMapping which is the "subscriber side").

**Source/Target pattern:**
```rescript
module type Spec = { let name: string; @schema type command; @schema type event; @schema type directive }
// + module Aggregate: Reventless.Aggregate.Spec
```

**Map signatures:**
```rescript
// Incoming: EP command → aggregate commands
let mapIncomingCommand: (string, EP.command, Message.meta)
  => array<commandAction<Aggregate.command, EP.directive>>

// Outgoing (optional): Aggregate event → EP events
let mapOutgoingEvent: option<(string, Aggregate.event, Message.meta, QueryEngine.operations)
  => array<eventAction<EP.event, EP.directive>>>
```

**Command actions:** `PublishCommand`, `Call`
**Event actions:** `PublishEvent`, `PublishEventAsync`, `Call`

**Used by:** `ExtensionPoint_Builder` / `ExtensionPoint_Callback` / `ExtensionPoint_Operations`

---

## Existing Harmonization Attempt

### MapperNto1 (reventless-core) — Partially used

Already abstracts the N-sources-to-1-target pattern with generic `Source`/`Target` module types:
- `Mapper.GenericSource = { name, type t, decode' }`
- `Mapper.GenericTarget = { name, type t, decode, encode }`

Used by **Projection** (via `ProjectionMapper`) but **not** by EventMapping, ExtensionMapping, or ExtensionPointMapping.

### Mapper1toN (reventless-core) — Fully commented out

Was intended as the inverse (1-source-to-N-targets) but was never completed. The commented code uses old ReasonML syntax (`type action('a)`) and Decco-era APIs.

---

## Structural Comparison

| Aspect | EventMapping | Projection | ExtensionMapping | ExtensionPointMapping |
|--------|-------------|------------|-----------------|----------------------|
| Direction | N→1 (many sources → one target) | N→1 | N→1 (EP events → aggregate) + optional 1→N (aggregate → EP) | N→1 (EP commands → aggregate) + optional 1→N (aggregate → EP events) |
| Source type | `{name, Id, event}` | `{name, Id, event}` | EP Spec `{name, command, event, directive}` | EP Spec `{name, command, event, directive}` |
| Target type | `{name, Id, command}` | `{name, Id, state}` | `Aggregate.Spec` (full) | `Aggregate.Spec` (full) |
| Map input | `(Id.t, event, QueryEngine)` | `Message.event'<string, event>` | `(string, EP.event, meta, pluginDef, QueryEngine)` | `(string, EP.command, meta)` |
| Map output | `action<Id.t, command>` | `action<string, state>` | `incomingCommandAction<...>` | `commandAction<...>` |
| Pre-compilation | No (done in callback) | Via `ProjectionMapper` → `MapperNto1` | Via `ExtensionMapping.Make` functor | Via `ExtensionPointMapping.Make` functor |
| JSON encode/decode | In `EventMapper_Callback` | In `ProjectionMapper` | In `ExtensionMapping.Make` | In `ExtensionPointMapping.Make` |
| Uses MapperNto1 | No | Yes (indirectly) | No | No |

---

## The Fake Aggregate Problem in DCB

In the aggregate approach, extensions naturally have a real `Aggregate` module (e.g., `Product`, `Order`) that satisfies `Aggregate.Spec`. In the DCB approach, there are no aggregates — only `StateChangeSlice` and `DcbEventLog`. The mapping module types (`ExtensionMapping.Impl` and `ExtensionPointMapping.Impl`) both require `module Aggregate: Reventless.Aggregate.Spec`, forcing DCB users to write boilerplate:

```rescript
// Appears in EVERY DCB extension mapping — 6 lines of boilerplate
module Aggregate = {
  let name = Target.name
  module Id = Id.String
  type command = Target.command
  let commandSchema = Target.commandSchema
  @schema type event = unit    // unused
  @schema type error = unit
}
```

There are **4 instances** in the DCB example:
1. `catalog/src/Extension/OrdersExtension.res` — wraps `RecordProductDemand` (StateChangeSlice)
2. `ordering/src/Extension/ProductsExtension.res` — wraps `SyncCatalogProduct` (StateChangeSlice)
3. `catalog/src/ExtensionPoint/ProductsExtensionPointMapping.res` — wraps `CatalogEventLog` (DcbEventLog)
4. `ordering/src/ExtensionPoint/OrdersExtensionPointMapping.res` — wraps `OrderingEventLog` (DcbEventLog)

### What the Aggregate module is actually used for

In `ExtensionMapping.Make`:
- **`Aggregate.name`** — for logging and routing (`aggregateName`)
- **`Aggregate.commandSchema`** — to encode aggregate commands to JSON (incoming direction)
- **`Aggregate.eventSchema` + `Aggregate.Id.schema`** — to decode aggregate event JSON (outgoing direction)

In `ExtensionPointMapping.Make`:
- **`Aggregate.name`** — for logging and routing
- **`Aggregate.commandSchema`** — to encode aggregate commands to JSON (incoming direction)
- **`Aggregate.eventSchema` + `Aggregate.Id.schema`** — to decode aggregate event JSON (outgoing direction)

### What could replace it

The `Make` functors actually only need:
- **For incoming (command encoding):** `name`, `commandSchema` — a `CommandTarget`-like module
- **For outgoing (event decoding):** `name`, `Id.schema`, `eventSchema` — an `EventSource`-like module

This maps naturally to the `Source`/`Target` pattern already used by `EventMapping` and `Projection`.

---

## Harmonization Proposal

### Step 1: Introduce lightweight Source/Target module types for Extension mappings

Instead of requiring full `Aggregate.Spec`, define narrower module types that capture only what's needed:

```rescript
// In ExtensionMapping.res — replace module Aggregate: Reventless.Aggregate.Spec
module type CommandTarget = {
  let name: string
  @schema type command
}

// Only needed when mapOutgoingEvent is Some
module type EventSource = {
  let name: string
  module Id: Id.T
  @schema type event
}
```

This eliminates the fake `@schema type event = unit` and `@schema type error = unit` boilerplate in incoming-only mappings (Extensions). For ExtensionPointMappings that have outgoing events, an EventSource is needed but the `error` type is still unnecessary.

### Step 2: Split ExtensionMapping.Impl into two variants

```rescript
// Incoming-only (most common for DCB extensions)
module type IncomingImpl = {
  module ExtensionPoint: Spec
  module Target: CommandTarget  // was: module Aggregate: Aggregate.Spec

  let mapIncomingEvent: mapIncomingEvent<
    ExtensionPoint.event,
    Target.command,
    ExtensionPoint.command,
    ExtensionPoint.directive,
  >
}

// Bidirectional (when mapOutgoingEvent is needed)
module type BidirectionalImpl = {
  module ExtensionPoint: Spec
  module Target: CommandTarget
  module Source: EventSource  // for decoding outgoing events

  let mapIncomingEvent: mapIncomingEvent<...>
  let mapOutgoingEvent: mapOutgoingEvent<Source.event, ExtensionPoint.command, ExtensionPoint.directive>
}
```

**DCB extension code simplifies to:**
```rescript
module DemandMapping = {
  module Source = OrderingSpec.OrdersExtensionPoint
  module Target = RecordProductDemand  // already has {name, @schema type command}

  // No module Aggregate needed!

  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event { ... }
  let mapOutgoingEvent = None
}
```

### Step 3: Apply the same pattern to ExtensionPointMapping

```rescript
// For incoming commands (EP command → aggregate commands)
module type CommandTarget = {
  let name: string
  @schema type command
}

// For outgoing events (aggregate event → EP events), only when mapOutgoingEvent is Some
module type EventSource = {
  let name: string
  module Id: Id.T
  @schema type event
}
```

DCB ExtensionPointMapping simplifies:
```rescript
// Before: 6-line fake Aggregate block
// After:
module Source = {
  let name = "CatalogEventLog"
  module Id = Id.String
  @schema type event = CatalogEventLog.event
}
// No command/error needed since this EP only does outgoing mapping
```

### Step 4: Reuse existing Mapper module types

`Mapper.res` already defines `EventSource` and `CommandTarget`. Reuse them:

```rescript
// Already exists in Mapper.res:
module type EventSource = { module Id: Id.T; let name: string; @schema type event }
module type CommandTarget = { let name: string; @schema type command }
```

Both `ExtensionMapping` and `ExtensionPointMapping` can reference these instead of `Aggregate.Spec`.

### Step 5: Provide adapter functors for backward compatibility

For aggregate-approach users who already have `Aggregate.Spec` modules:

```rescript
// In ExtensionMapping.res
module AggregateAsCommandTarget = (A: Reventless.Aggregate.Spec): CommandTarget => {
  let name = A.name
  type command = A.command
  let commandSchema = A.commandSchema
}

module AggregateAsEventSource = (A: Reventless.Aggregate.Spec): EventSource => {
  let name = A.name
  module Id = A.Id
  type event = A.event
  let eventSchema = A.eventSchema
}
```

This lets aggregate-approach users write `module Target = AggregateAsCommandTarget(Product)` — though in practice they can continue using `module Aggregate = Product` via the old `Impl` (deprecated but kept for backward compatibility).

### Step 6: Consider unifying the Make functors

Both `ExtensionMapping.Make` and `ExtensionPointMapping.Make` follow the same pattern:
1. Accept Source/Target + EP Spec
2. Pre-encode commands/events to JSON using schemas
3. Produce abstract action types
4. Handle logging

A shared `MappingCompiler` could abstract the encode/decode + logging, but this is lower priority since the functor internals are stable and don't affect user-facing API.

---

## Impact on Mapper1toN

The commented-out `Mapper1toN` was designed for the reverse direction (1 source → N targets). Looking at the actual patterns:

- **ExtensionPointMapping outgoing** = 1 aggregate → 1 EP (not truly 1-to-N)
- **ExtensionMapping outgoing** = 1 aggregate → 1 EP (not truly 1-to-N)
- **EventMapping** = N-to-1 (already handled by `MapperNto1`)

There is no real 1-to-N mapping pattern in the framework. The "outgoing" mappings are always 1-to-1 (one aggregate to one EP). **Recommendation: Delete `Mapper1toN.res` entirely** — it's unused, uses obsolete syntax, and represents a pattern that doesn't exist.

---

## Summary of Recommended Changes

| Change | Effort | Impact |
|--------|--------|--------|
| Replace `module Aggregate` requirement with `CommandTarget` + optional `EventSource` in ExtensionMapping | Medium | Eliminates fake Aggregate boilerplate in all DCB extensions |
| Same for ExtensionPointMapping | Medium | Eliminates fake Aggregate boilerplate in all DCB EP mappings |
| Reuse `Mapper.EventSource` / `Mapper.CommandTarget` types | Low | Consistent Source/Target vocabulary across all mapping types |
| Provide `AggregateAsCommandTarget`/`AggregateAsEventSource` adapter functors | Low | Backward compatibility for aggregate approach |
| Delete `Mapper1toN.res` | Trivial | Remove dead code |
| Consider unifying `Make` functor internals | Low priority | Internal cleanup, no user-facing change |

### Migration path for existing code

1. **Aggregate-approach extensions** (e.g., `online-shop-aggregates/`): No change needed if using adapter functors. The existing `module Aggregate = Product` continues to work because `Product` already satisfies both `CommandTarget` and `EventSource`.

2. **DCB-approach extensions** (e.g., `online-shop-dcb/`): Remove fake `module Aggregate` blocks. Replace with direct `module Target = RecordProductDemand` (already satisfies `CommandTarget`). For EP mappings with outgoing events, add `module Source = { let name = "CatalogEventLog"; module Id = Id.String; @schema type event = CatalogEventLog.event }`.

3. **Framework internals** (`ExtensionMapping.Make`, `ExtensionPointMapping.Make`): Update to accept `CommandTarget` + optional `EventSource` instead of `Aggregate.Spec`. The `Make` functor body changes minimally — replace `Aggregate.commandSchema` with `Target.commandSchema`, `Aggregate.eventSchema` with `Source.eventSchema`, etc.
