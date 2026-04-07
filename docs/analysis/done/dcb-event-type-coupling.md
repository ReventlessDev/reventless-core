# DCB Event Type Coupling: Analysis and Improvement Options

**Date**: 2026-03-26
**Scope**: The coupling between DCB slices and the shared event log type, comparison with other DCB/event sourcing implementations, and potential improvements.

---

## 1. The Problem

In Reventless, a DCB event log defines a single union type for all events:

```rescript
// CatalogEventLog.res
@schema
type event =
  | ProductAdded({productId: @s.matches(DcbTag.string) string, name, description, price})
  | ProductNameChanged({productId: @s.matches(DcbTag.string) string, name})
  | CategoryAdded({categoryId: @s.matches(DcbTag.string) string, name})
  | CategoryArchived({categoryId: @s.matches(DcbTag.string) string})
  | ProductDemandRecorded({productId: @s.matches(DcbTag.string) string, orderId})
  // ... every event from every slice in this DCB
```

Every slice — StateChangeSlice, StateViewSlice, AutomationSlice, etc. — references this type via `module DcbEventLogSpec`:

```rescript
// AddCategory.res (StateChangeSlice)
module DcbEventLogSpec = CatalogEventLog
let evolve = (state, event) => switch event {
  | CategoryAdded(_) => {exists: true, archived: false}
  | CategoryArchived(_) => {...state, archived: true}
  | _ => state  // Must handle all variants, even unrelated ones
}
let decide = (state, cmd) => Ok([CategoryAdded({...})])  // Must return DcbEventLogSpec.event
```

**Adding a new slice requires**:
1. Adding new event variant(s) to the DcbEventLog type
2. Recompiling all existing slices (they depend on the full union type)
3. Existing `evolve`/`project`/`collect` functions already use wildcard `_ => state` for unknown events, so they don't need code changes — but they do need recompilation

**In practice, this means**:
- Slices are not independently deployable — any event schema change forces a rebuild of the entire DCB
- The event log file becomes a coordination bottleneck for teams working on different slices
- The event union grows monotonically (events are immutable facts; variants can never be removed)

---

## 2. Is This Actually a Problem?

### Where It Is Not a Problem

**Within a single bounded context with a small team**: If one team owns the entire Catalog plugin and its ~10 event types, the coupling is benign. The shared type provides compile-time exhaustiveness checking and makes the data model explicit. Adding `| ProductArchived(...)` to the union and recompiling is trivial.

**For correctness**: The shared type is the most type-safe design possible. The compiler guarantees that `evolve` and `decide` only produce events from the declared union. A StateChangeSlice cannot accidentally emit an event that doesn't belong to this DCB.

### Where It Becomes a Problem

**Scaling to many slices**: The Catalog example already has 9 event types across 8 StateChangeSlices, 3 StateViewSlices, and 1 InboundTranslationSlice. A real-world bounded context (e.g., a logistics domain) might have 30-50 event types across 20+ slices. The event union becomes a large, frequently-touched file.

**Cross-team collaboration**: If Product and Category concerns are owned by different sub-teams (even within the same bounded context), they contend on the same file. In Git, this creates merge conflicts not from semantic disagreement but from syntactic proximity.

**Independent slice lifecycle**: In Event Modeling, slices are described as "the smallest independently implementable unit of work." The current design partially violates this — a slice can be implemented independently, but it cannot be deployed without modifying the shared event log.

**Versioning and migration**: When event schemas evolve (adding fields, deprecating variants), the blast radius is the entire DCB rather than just the affected slices.

---

## 3. Comparison with Other Implementations

### 3.1 Sara Pellegrini & Milan Savic's Original DCB Concept (Serialized.io)

The original DCB paper and Serialized.io implementation use a **schemaless event store**. Events are stored as JSON blobs with a `type` discriminator string. There is no compile-time union type — each slice declares which event types it cares about and ignores the rest.

```
// Pseudocode — each slice declares its own event types
CommandHandler:
  reads: ["ProductAdded", "ProductPriceChanged"]
  writes: ["ProductPriceChanged"]

// The event store accepts any JSON with a "type" field
// No central type registry
```

**Trade-off**: No central event type ⇒ slices are fully independent, but there is no compile-time guarantee that an event name or shape is consistent across producers and consumers. Typos in event type strings (`"ProdcutAdded"`) are runtime failures.

### 3.2 Decider Pattern (Jeremie Chassaing / Oskar Dudycz)

The Decider pattern (used in Emmett for TypeScript, Eventuous for .NET) models each "decider" as a self-contained unit:

```typescript
// TypeScript Decider — each decider owns its own event type
type ProductEvent =
  | { type: "ProductAdded"; productId: string; name: string }
  | { type: "ProductPriceChanged"; productId: string; price: number };

const productDecider = {
  evolve: (state, event: ProductEvent) => ...,
  decide: (state, command) => ...,
  initialState: ...
};
```

When multiple deciders share an event store (DCB-style), the **composition happens at the store level**, not the type level:

```typescript
// Composed event store — union is implicit, not a declared type
const dcbStore = createDcbStore([productDecider, categoryDecider]);
// Each decider only sees events matching its declared types
// The store filters by event.type string at runtime
```

**Trade-off**: Each decider is self-contained and independently testable. The composition is runtime, not compile-time. A decider that declares it reads `"ProductAdded"` events will silently miss a renamed `"ProductCreated"` event — no compiler warning.

### 3.3 Axon Framework (Java)

Axon uses annotation-based event handling. There is no central event union. Each handler declares which event classes it processes:

```java
@EventSourcingHandler
void on(ProductAdded event) { ... }

@EventSourcingHandler
void on(CategoryAdded event) { ... }  // Different class, no shared union
```

Events are Java classes, stored with their fully-qualified class name as the type discriminator. The event store is schemaless from the framework's perspective — it stores serialized objects.

**Trade-off**: Fully decoupled at the type level. But event class renaming/refactoring requires migration, and there is no exhaustiveness check — a handler that forgets to subscribe to a relevant event type compiles fine.

### 3.4 EventStoreDB (Greg Young)

EventStoreDB stores events as JSON blobs in streams. There is no schema enforcement at the store level. Projections and subscriptions filter by event type string. There is no concept of a shared type union.

**Trade-off**: Maximum flexibility, zero compile-time safety. Type consistency is the developer's responsibility.

### 3.5 EventSourcingDB (the native labs)

EventSourcingDB is a purpose-built event sourcing database with first-class DCB support. It uses CloudEvents as its event format and has explicit concepts for subjects, event types, preconditions, and an SQL-like query language (EventQL).

**Event structure**: Events follow CloudEvents with a `subject` (stream identity, e.g., `/books/42`), a `type` (reverse domain name, e.g., `io.eventsourcingdb.library.book-acquired`), and a `data` payload (arbitrary JSON):

```json
{
  "source": "https://library.eventsourcingdb.io",
  "subject": "/books/42",
  "type": "io.eventsourcingdb.library.book-acquired",
  "data": { "title": "2001 – A Space Odyssey", "author": "Arthur C. Clarke" }
}
```

**Event types are schemaless by default, with optional schema registration**. Schemas use JSON Schema format and are registered per event type via API. Once registered, validation becomes strict and immutable — all future events of that type must conform, and the schema cannot be modified or deleted. Schema evolution is handled via versioned type names (`book-acquired.v1`, `book-acquired.v2`). Crucially, there is no central union type or compile-time type registry — each event type is independently defined.

**DCB implementation**: The conditional write mechanism uses preconditions evaluated atomically within the write transaction. The most powerful precondition type is `isEventQlQueryTrue`, which evaluates an arbitrary EventQL query:

```json
{
  "events": [{ "subject": "/books/42", "type": "...", "data": {...} }],
  "preconditions": [{
    "type": "isEventQlQueryTrue",
    "payload": {
      "query": "FROM e IN events WHERE e.type == 'io.eventsourcingdb.library.book-borrowed' AND e.data.borrowedBy == '/readers/23' PROJECT INTO COUNT() < 3"
    }
  }]
}
```

This is fundamentally different from Reventless's tag-based conditional append. EventSourcingDB's preconditions are arbitrary queries over the full event store — the consistency boundary is literally defined by the query, not by a shared type or tag structure. Each command handler writes its own precondition query; there is no framework-level coupling between handlers.

Additional precondition types (`isSubjectPristine`, `isSubjectPopulated`, `isSubjectOnEventId`) cover common patterns like optimistic locking and initialization guards.

**Slice independence**: Since there is no shared type definition, command handlers are fully independent. Each handler:
1. Queries the events it needs via EventQL (filtering by type, subject, and/or data fields)
2. Builds its decision model from the query results
3. Writes new events with preconditions that re-evaluate the query at write time

Adding a new handler that produces new event types requires zero changes to existing handlers. Existing handlers' EventQL queries simply won't match the new event types unless explicitly updated.

**Trade-off**: Maximum slice independence and a powerful query-based DCB mechanism. But: no compile-time safety across handlers (event type strings, data shapes), precondition queries are evaluated twice (once for the decision, once at write time) making them more expensive, and EventQL scans can be costly on large datasets. The optional JSON Schema registration provides some safety but is per-type, not cross-type — there is no way to enforce that a handler's query references valid event types at registration time.

### 3.6 Summary Comparison

| Aspect | Reventless (current) | Serialized.io | Decider (Emmett) | Axon | EventStoreDB | EventSourcingDB |
|--------|---------------------|---------------|-------------------|------|-------------|-----------------|
| Event type coupling | Strong (union type) | None (schemaless) | Per-decider (local types) | Per-handler (class-based) | None (schemaless) | None (per-type schema, optional) |
| Compile-time safety | Full exhaustiveness | None | Partial (per-decider) | Partial (per-handler) | None | None (runtime JSON Schema) |
| Slice independence | Recompile on change | Fully independent | Fully independent | Fully independent | Fully independent | Fully independent |
| Event consistency | Guaranteed | Runtime only | Runtime only | Runtime only | Runtime only | Optional (JSON Schema per type) |
| Tag/filter support | Schema-derived | API-level | Custom | Annotation-based | Projection-based | EventQL queries + subjects |
| DCB mechanism | Tag-based conditional append | Conditional append | Custom | Annotation-based | N/A | Query-based preconditions (EventQL) |

---

## 4. Root Cause Analysis

The coupling stems from two design choices:

### 4.1 The Union Type as the Single Source of Truth

In ReScript, the `@schema type event = ...` union serves triple duty:
1. **Schema for serialization** — sury generates encode/decode from it
2. **Type for exhaustiveness** — the compiler checks pattern matches
3. **Tag extraction source** — `DcbTag.extractTaggedFields` inspects the schema at build time

All three responsibilities converge on a single type definition. This is elegant for small DCBs but creates a coordination bottleneck as the number of event types grows.

### 4.2 The `evolve` Function Signature

```rescript
let evolve: (state, DcbEventLogSpec.event) => state
```

Each slice's `evolve` receives the **full** DCB event union. Even though most slices only care about 2-3 event variants, they are typed against all variants. This is what forces recompilation — the type parameter changes when variants are added.

---

## 5. Improvement Options

### Option A: Keep the Current Design (Status Quo + Conventions)

**Approach**: Accept the coupling as a trade-off for type safety. Mitigate the coordination cost with conventions:
- Group related events into commented sections in the event log file
- Use CODEOWNERS to require review from relevant sub-teams
- Accept that the event log is a shared contract (like a protobuf schema file)

**Pros**: No framework changes. Maximum type safety. Simple mental model.
**Cons**: Does not solve the coordination bottleneck or independent deployability.

**When to choose**: Small teams (1-3 developers), fewer than ~15 event types per DCB.

### Option B: Per-Slice Event Types with Runtime Union

**Approach**: Each slice declares its own event types — both the events it produces and the events it consumes. The shared `DcbEventLog.Spec` no longer has a `type event`. Instead, the framework collects event schemas from all slices and builds a runtime union for storage. At runtime, events are filtered by type string before being dispatched to each slice.

#### B.1 What Changes for Slice Authors

**StateChangeSlice** — currently the tightest coupling point. Today a slice references `DcbEventLogSpec.event` in both `evolve` and `decide`. Under Option B, each slice declares two local types:

- **`producedEvent`**: The events this slice emits from `decide`. Must include all fields and all `@s.matches(DcbTag.string)` tag annotations — the framework uses these for storage indexing and tag extraction.
- **`consumedEvent`**: The events this slice reads in `evolve` to build its decision model. Only needs the fields required for the decision — extra fields from the produced shape are ignored. Tag annotations are not needed because consumed events are already decoded from storage; tags are only relevant for query construction (from commands) and storage (from produced events).

```rescript
// AddCategory.res (StateChangeSlice)
let name = "AddCategory"

// PRODUCED: full shape, all fields, all tag annotations
@schema type producedEvent =
  | CategoryAdded({categoryId: @s.matches(DcbTag.string) string, name: string})

// CONSUMED: only what matters for the decision — here, nothing beyond "it happened"
// The tag-based query already filtered to the right categoryId, so the evolve
// function only needs to know WHICH event occurred, not what fields it carried.
@schema type consumedEvent =
  | CategoryAdded
  | CategoryArchived

@schema type command = AddCategory({categoryId: @s.matches(DcbTag.string) string, name: string})
@schema type error = CategoryAlreadyExists

type state = {exists: bool, archived: bool}
let initialState = {exists: false, archived: false}

// evolve receives ONLY consumedEvent — no wildcard, no unused fields, no payloads
let evolve = (state, event) => switch event {
  | CategoryAdded => {exists: true, archived: false}
  | CategoryArchived => {...state, archived: true}
}

// decide returns producedEvent — full shape with all fields and tags
let decide = (state, command) => switch command {
  | AddCategory({categoryId, name}) =>
    if state.exists { Error(CategoryAlreadyExists) }
    else { Ok([CategoryAdded({categoryId, name})]) }
}
```

Consumed events exist on a spectrum from payload-less to partial projection to full shape, depending on what the slice's `evolve` function actually needs:

```rescript
// Payload-less — "I only care that it happened"
@schema type consumedEvent = | CategoryAdded | CategoryArchived

// Partial projection — "I need some fields for the decision"
@schema type consumedEvent = | ProductAdded({productId: string})

// Full shape — "I need all fields" (e.g., a view that projects everything)
@schema type consumedEvent = | ProductAdded({productId: string, name: string, description: string, price: float})
```

Key differences from today:
- `evolve` receives `consumedEvent` (a slice-local type), not `CatalogEventLog.event` (the global union). The `_ => state` wildcard is gone — the compiler checks exhaustiveness over only the events this slice declared it cares about.
- Consumed events are **projections** — they declare only the fields needed for the decision, or no fields at all. A `CategoryAdded` event stored with `{categoryId, name}` can be consumed as a payload-less `CategoryAdded` when the slice only needs to know it happened. sury naturally handles field subsetting: extra fields in JSON are ignored when parsing against a schema with fewer fields.
- Tag annotations (`@s.matches`) appear only on `producedEvent` and `command` — never on `consumedEvent`. Tags serve query construction and storage indexing, both of which are producer-side concerns.

**Payload-less consumed events and sury**: There is a known constraint today that payload-less variants serialize as bare JSON strings in sury, while stored events are JSON objects (`{"TAG": "CategoryAdded", "categoryId": "...", ...}`). This means `S.parseJson` with a payload-less variant schema would fail against a stored object. Under Option B, the framework controls the decode path for consumed events and can handle this:

1. The framework already knows the event type from `raw.eventType` (extracted during storage)
2. For payload-less consumed variants: match `raw.eventType` against the variant name and construct the value directly — bypass sury
3. For consumed variants with fields: use sury to parse only the declared fields from `raw.data`

This makes payload-less consumed events a framework-level feature, not a sury limitation. The constraint that produced events must have inline record payloads (needed for tag extraction and storage) remains unchanged — but consumers are free to ignore the payload entirely.

**StateViewSlice** — the `project` function currently receives `DcbEventLogSpec.event`. Under Option B, it declares its own consumed event type. Unlike StateChangeSlice, a view typically needs more fields (it builds a read model), but it still only declares the fields it projects:

```rescript
// CategoriesView.res (StateViewSlice)
let name = "CategoriesView"

// No producedEvent — views don't produce events
// consumedEvent includes only the fields needed for the projection, no tags
@schema type consumedEvent =
  | CategoryAdded({categoryId: string, name: string})
  | CategoryRenamed({categoryId: string, name: string})
  | CategoryArchived({categoryId: string})

@schema type state = {categoryId: string, name: string, archived: bool}

// project receives only consumedEvent — no wildcard, no unrelated Product events
let project = event => switch event {
  | CategoryAdded({categoryId, name}) =>
    [Set(categoryId, {categoryId, name, archived: false})]
  | CategoryRenamed({categoryId, name}) =>
    [Update(categoryId, state => {...state, name})]
  | CategoryArchived({categoryId}) =>
    [Update(categoryId, state => {...state, archived: true})]
}
```

Notice that `CategoriesView` consumes `CategoryAdded({categoryId, name})` (needs both fields for the read model) while `AddCategory` consumes `CategoryAdded` with no payload (only needs to know it happened). Each slice declares exactly the projection of fields it needs — from nothing to everything.

**AutomationSlice, OutboundTranslationSlice** — same pattern. `collect` and `resolve` receive `consumedEvent` with only the fields relevant to their work. An `AutoShipOrder` slice might consume `OrderPlaced({orderId})` even though the produced event has `OrderPlaced({orderId, customerId, items, totalPrice})`. A simple completion check might consume `OrderShipped` as payload-less.

**InboundTranslationSlice** — no change needed. It does not consume events from the log; it only produces commands.

#### B.2 What the DcbEventLog Becomes

Today, `DcbEventLog.Spec` requires `@schema type event` — the monolithic union. Under Option B, the DcbEventLog spec becomes minimal:

```rescript
// DcbEventLog.Spec — no event type needed
module type Spec = {
  let moduleUrl: string
  // No `type event` — the framework builds the runtime schema from slices
}
```

The `CatalogEventLog.res` file either disappears entirely or becomes a lightweight marker:

```rescript
// CatalogEventLog.res — just a name, no event type
let moduleUrl: string = %raw(`import.meta.url`)
```

The event union is now an emergent property of the slices, not a declared artifact.

#### B.3 What the Framework Does at Build Time (Deploy Time)

The `Plugin.DcbSpec` module type changes from requiring a shared `type event` to collecting slice-level schemas:

```rescript
// Current DcbSpec — requires shared type
module type DcbSpec = {
  @schema type event
  let stateChangeSlices: array<module(StateChangeSlice.T with type dcbEvent = event)>
  let stateViewSlices: array<module(StateViewSlice.T with type dcbEvent = event)>
  // ...
}

// New DcbSpec — no shared type, slices are self-contained
module type DcbSpec = {
  let stateChangeSlices: array<module(StateChangeSlice.T)>
  let stateViewSlices: array<module(StateViewSlice.T)>
  let automationSlices: array<module(AutomationSlice.T)>
  let outboundTranslationSlices: array<module(OutboundTranslationSlice.T)>
  let inboundTranslationSlices: array<module(InboundTranslationSlice.T)>
}
```

The `with type dcbEvent = event` constraint disappears — it was the mechanism that forced all slices to agree on a single type. Without it, each slice carries its own `producedEventSchema` and `consumedEventSchema`.

**Dcb_Builder.construct** currently creates a `DcbEventLogSpec` from `DcbSpec.event`:

```rescript
// Current: Dcb_Builder creates DcbEventLog from shared type
module DcbEventLogSpec = {
  let moduleUrl = ""
  @schema type event = DcbSpec.event
}
module DcbEventLog = DcbEventLog_Builder.Make(DcbEventLogSpec, ...)
```

Under Option B, the builder instead collects and merges schemas from all slices:

```rescript
// New: Dcb_Builder merges schemas from all slices
let combinedEventSchema: S.t<JSON.t> =
  DcbSpec.stateChangeSlices
  ->Array.flatMap(slice => [slice.producedEventSchema, slice.consumedEventSchema])
  ->Array.concat(DcbSpec.stateViewSlices->Array.map(slice => slice.consumedEventSchema))
  ->Array.concat(DcbSpec.automationSlices->Array.map(slice => slice.consumedEventSchema))
  ->DcbTag.mergeEventSchemas  // New framework function: deduplicates by TAG name
```

This combined schema is used for:
1. **DynamoDB secondary index creation** — `DcbTag.extractTaggedFields` runs on the merged schema to determine which tag indexes to create
2. **EventLog API schema** — the GraphQL introspection / admin API shows all event types
3. **Storage encoding** — the adapter stores events as `{eventType, data, tags}` (already JSON — no typed encoding needed at the log level)

#### B.4 What the Framework Does at Runtime

The critical change is in **StateChangeSlice_Callback.handleSingleCommand**. Today it works like this:

```
1. Extract tags from command (via commandSchema)          — UNCHANGED
2. Build query: {eventTypes: ALL types, tags: [...]}      — CHANGES
3. Read events, decode with Spec.eventSchema              — CHANGES
4. Fold with Spec.evolve(state, event)                    — CHANGES
5. Call Spec.decide(state, command)                        — UNCHANGED
6. Encode new events with Spec.eventSchema                — CHANGES
7. Append with condition                                   — UNCHANGED
```

**Step 2 — Query construction**: Currently `extractEventTypes(Spec.DcbEventLogSpec.eventSchema)` returns ALL event type names in the DCB. Under Option B, the query uses only the event types from the slice's `consumedEventSchema`:

```rescript
// Current: queries ALL event types in the DCB
let queryEventTypes = DcbTag.extractEventTypes(Spec.DcbEventLogSpec.eventSchema)

// New: queries only event types this slice consumes
let queryEventTypes = DcbTag.extractEventTypes(Spec.consumedEventSchema)
```

This is actually an **efficiency improvement** — the query is more selective. A `AddCategory` slice only queries for `CategoryAdded` and `CategoryArchived` events, not all 9 event types.

**Step 3 — Decoding**: Currently the event log decodes with `Spec.eventSchema` (the global union). Under Option B, events are stored as raw JSON (`{eventType, data, tags}`) and decoded with the slice's `consumedEventSchema`. Events whose `eventType` doesn't match any variant in `consumedEventSchema` are skipped at the decode level:

```rescript
// Current: decodes with global event schema
let decodeEvent = raw => {
  let json = Message.combineMessage(raw.eventType, raw.data)
  json->S.parseJsonOrThrow(Spec.DcbEventLogSpec.eventSchema)  // Global union
}

// New: decodes with slice-local consumed event schema, skipping unknown types
let decodeEvent = raw => {
  let json = Message.combineMessage(raw.eventType, raw.data)
  switch json->S.parseJson(Spec.consumedEventSchema) {
  | Ok(event) => Some(event)
  | Error(_) => None  // Unknown event type — skip
  }
}
```

The `readStream` fold becomes:

```rescript
// Current
->Stream.runFold((Spec.initialState, None), ((dm, _pos), se) => (
  Spec.evolve(dm, se.event), Some(se.position)
))

// New: skip events that don't decode to this slice's consumed type
->Stream.filterMap(raw => decodeEvent(raw))
->Stream.runFold((Spec.initialState, None), ((dm, _pos), se) => (
  Spec.evolve(dm, se.event), Some(se.position)
))
```

**Step 6 — Encoding new events**: Currently `decide` returns `array<DcbEventLogSpec.event>` (global type) and `encodeEvent` uses the global schema. Under Option B, `decide` returns `array<Spec.producedEvent>` (slice-local type):

```rescript
// Current: encode with global event schema
let encodeEvent = event => {
  let json = event->S.reverseConvertToJsonOrThrow(Spec.DcbEventLogSpec.eventSchema)
  let (eventType, data) = json->Message.splitMessage
  let tags = DcbTag.extractTags(Spec.DcbEventLogSpec.eventSchema, event)
  {eventType, data, tags}
}

// New: encode with slice-local produced event schema
let encodeEvent = event => {
  let json = event->S.reverseConvertToJsonOrThrow(Spec.producedEventSchema)
  let (eventType, data) = json->Message.splitMessage
  let tags = DcbTag.extractTags(Spec.producedEventSchema, event)
  {eventType, data, tags}
}
```

**EventTopic publishing** remains the same — it already publishes the raw JSON. Downstream subscribers (StateViewSlices, AutomationSlices) decode with their own `consumedEventSchema`.

#### B.5 What Changes in Plugin Wiring

The plugin file becomes simpler — no `DcbSpec.event` type, no `with type dcbEvent = event` constraints:

```rescript
// CatalogPlugin.res under Option B
module Make = (Platform: ReventlessInfra.Platform.T) => {
  module CatalogEventLogMaker = Platform.DcbEventLog.Make(CatalogEventLog)

  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
  module AddCategorySlice = Platform.StateChangeSlice.Make(AddCategory)
  module ProductsViewSlice = Platform.StateViewSlice.Make(ProductsView)
  module CategoriesViewSlice = Platform.StateViewSlice.Make(CategoriesView)

  module DcbSpec = {
    // No shared `type event` — each slice is self-contained
    let stateChangeSlices = [module(AddProductSlice), module(AddCategorySlice)]
    let stateViewSlices = [module(ProductsViewSlice), module(CategoriesViewSlice)]
    let automationSlices = []
    let outboundTranslationSlices = []
    let inboundTranslationSlices = []
  }

  let make = (~scheduler, ~api, ~apiRole) =>
    Platform.Plugin.make(~name="Catalog", ~dcbSpec=module(DcbSpec), ...)
}
```

Adding a new `ArchiveCategory` slice:
1. Create `ArchiveCategory.res` with its own `producedEvent` and `consumedEvent`
2. Add `module(ArchiveCategorySlice)` to `stateChangeSlices` array
3. **No other files change** — existing slices are untouched

#### B.6 Spec Type Changes

The new `StateChangeSlice.Spec`:

```rescript
module type Spec = {
  let name: string
  let moduleUrl: string

  // REMOVED: module DcbEventLogSpec: DcbEventLog.Spec

  @schema type producedEvent   // Events this slice emits (from decide)
  @schema type consumedEvent   // Events this slice reads (in evolve)
  @schema type command
  @schema type error

  type state
  let initialState: state
  let evolve: (state, consumedEvent) => state                       // was: DcbEventLogSpec.event
  let decide: (state, command) => result<array<producedEvent>, error> // was: DcbEventLogSpec.event
  let commandSchema: S.t<command>
}
```

The new `StateViewSlice.Spec`:

```rescript
module type Spec = {
  let name: string
  let moduleUrl: string

  // REMOVED: module DcbEventLogSpec: DcbEventLog.Spec
  // REMOVED: @schema type event (was alias for DcbEventLogSpec.event)

  @schema type consumedEvent   // Events this view projects
  @schema type state
  let stateSchema: S.t<state>
  let project: consumedEvent => array<Projection.action<string, state>>  // was: DcbEventLogSpec.event
}
```

Similarly for `AutomationSlice.Spec` (`collect` and `resolve` receive `consumedEvent`) and `OutboundTranslationSlice.Spec` (`collect` receives `consumedEvent`).

`InboundTranslationSlice.Spec` changes minimally — it already doesn't consume events. The only change is removing `module DcbEventLogSpec`.

#### B.7 Consequences and Trade-offs

**Positive consequences:**

1. **True slice independence**: Adding, removing, or modifying a slice touches only that slice's file and the plugin registration array. No shared type file to contend on.

2. **More efficient queries**: Each StateChangeSlice queries only for event types it actually consumes, rather than all event types in the DCB. For a DCB with 30 event types where a slice only cares about 3, this is a 10x reduction in query scope.

3. **Cleaner evolve/project functions**: No `_ => state` or `_ => []` wildcards. The compiler checks exhaustiveness over the slice's actual consumed events.

4. **Aligns with Event Modeling**: Slices become the independently implementable units they are described as in Event Modeling methodology.

5. **Easier cross-slice consumption**: A StateChangeSlice that needs to read events from another slice just adds those variants to its `consumedEvent` type. The type declarations make the dependency explicit and local.

6. **Consumed events as minimal projections**: Consumed event types exist on a spectrum — from payload-less (`| CategoryAdded`) to partial (`| ProductAdded({productId})`) to full shape. No tag annotations needed. This makes consumed events lightweight and self-documenting: reading a slice's `consumedEvent` immediately tells you exactly which fields from which events drive this slice's logic. It also eliminates the duplication problem — consumed events are intentionally different from produced events, not imperfect copies of them.

7. **Payload-less consumed events become possible**: Today, all DCB events must have inline record payloads (sury limitation). Under Option B, consumed events can be payload-less because the framework handles decoding via TAG matching rather than sury. Many `evolve` functions only check "did this event happen?" — payload-less variants make that pattern explicit and noise-free.

**Negative consequences:**

1. **No compile-time guarantee that consumed fields exist in produced events**: If `ProductsView` consumes `ProductAdded({productId, name, description})` but the producer only emits `ProductAdded({productId, name})` (missing `description`), sury will parse the stored JSON and silently produce `undefined` for the missing field — a runtime error. Today the shared union type prevents this because both sides reference the same type. The deploy-time validation (see B.8) catches this, but it's a later feedback loop than a compile error.

2. **Payload divergence across producers**: Multiple slices may legitimately produce the same event TAG (e.g., `AddProduct` and `CloneProduct` both produce `ProductAdded`). But since each slice declares its own `producedEvent` type independently, the payloads can accidentally diverge. The framework must detect mismatched fields at build time (see "payload equivalence" validation in B.8).

3. **Consumed event declarations diverge from produced shape**: The same event TAG appears in multiple slices' `consumedEvent` types with different field subsets. This is intentional (each slice projects only what it needs), but it means there is no single place to see the "full shape" of an event. The produced event is the authoritative shape; consumed events are projections of it. This is a mental model shift.

4. **Schema merge and validation complexity**: The framework must collect schemas from all slices at build time, match variants by TAG name, verify that every consumed field exists in the corresponding produced event, and produce a combined schema for storage. This is non-trivial new logic — particularly the structural subtype check between consumed and produced schemas.

5. **Conditional append scope**: Currently the conditional append checks against `queryEventTypes` derived from the global union. Under Option B, the query uses only the slice's consumed event types. This means a StateChangeSlice for Categories won't detect concurrent Product events — which is actually correct (it shouldn't care), but it's a subtle change in the concurrency model.

6. **Breaking change**: Every existing slice spec must be updated to split `DcbEventLogSpec.event` into `producedEvent` and `consumedEvent`. Every existing plugin's `DcbSpec` must remove the `type event` line.

#### B.8 Mitigations for the Downsides

**Deploy-time structural subtype validation** — the framework's schema merge step validates consumed events against produced events at deploy time (Pulumi). This is the primary safety mechanism that replaces the compile-time shared union:

1. **Payload equivalence across producers**: Multiple slices may produce the same event type TAG — this is a valid pattern (e.g., `AddProduct` and `CloneProduct` both produce `ProductAdded`). However, all producers of the same TAG must declare identical field names, types, and tag annotations (`@s.matches`). If `AddProduct` produces `ProductAdded({productId: @s.matches(DcbTag.string) string, name, price})` and `CloneProduct` produces `ProductAdded({productId: string, name})`, the deploy fails for two reasons: missing `price` field and missing `@s.matches` tag annotation on `productId`. Tag annotations must match because they determine storage indexing (`tag_productId` secondary index entries) and query routing — if one producer tags a field and another doesn't, consumers relying on tag-filtered queries would miss events from the untagged producer.

2. **Consumed fields must exist in produced shape**: For each consumed event variant, the framework looks up the produced event with the same TAG name and verifies that every field in the consumed schema exists in the produced schema with a compatible type. Payload-less consumed variants are always valid — they require no fields at all. Examples:
   - Produced: `ProductAdded({productId: string, name: string, description: string, price: float})`
   - Consumed: `ProductAdded` — valid (payload-less, only checks existence)
   - Consumed: `ProductAdded({productId: string, name: string})` — valid (field subset)
   - Consumed: `ProductAdded({productId: string, rating: float})` — **deploy error**: `rating` not found in produced `ProductAdded`

3. **Every consumed event type has a producer**: If a slice consumes `| ProductArchived(...)` but no slice produces it, the deploy fails. This catches typos and stale references.

4. **Tag completeness on produced events**: The framework verifies that produced events carry the same tag annotations needed for query routing. Since tags only appear on `producedEvent`, this is a straightforward check against the DynamoDB secondary index configuration.

These checks provide safety comparable to the compile-time union — the feedback loop is slightly later (deploy time vs compile time) but still before any code reaches runtime. sury's schema introspection API (`S.toDefinition`, field enumeration) makes the structural comparison implementable without custom parsing.

**Validation must run in all environments, not just AWS deploys** — the structural subtype validation logic must be provider-agnostic and run identically in the InMemory provider. This ensures that local development and integration tests catch mismatches before code reaches a Pulumi deploy. The validation function should live in `reventless-core` (not `reventless-aws`) and be called by every platform's `Plugin.make` / `Dcb_Builder.construct`, including `InMemory_Plugin`. A consumed event that references a nonexistent produced field should fail just as loudly in `npm test` as in `pulumi up`.

**Automated validation tests** — beyond the framework's built-in deploy-time check, each plugin should include a unit test that validates all consumed events against produced events. This test imports the plugin's `DcbSpec` and calls the framework's validation function directly:

```rescript
// CatalogPluginValidationTest.res
testPromise("all consumed events are compatible with produced events", async () => {
  let result = DcbValidation.validateConsumedEvents(module(CatalogPlugin.DcbSpec))
  expect(result)->toEqual(Ok())
})
```

This test runs on every test run (`npm test`) — it is the earliest possible feedback loop, faster than both deploy-time and InMemory platform startup. It catches:
- Consumed fields that don't exist in the produced event
- Consumed events with no matching producer
- Payload divergence across multiple producers of the same event TAG
- Type mismatches between consumed and produced field types

The framework should provide `DcbValidation.validateConsumedEvents` as a first-class testing utility, making it trivial for every plugin to add this one-line test. For projects using the example structure, the test can even be auto-generated by `reventless-gen`.

**Optional shared event payload modules** — for teams that want compile-time consistency within the same codebase, provide a pattern for shared event payload definitions:

```rescript
// catalog-events/ProductAdded.res — canonical payload definition
@schema type t = {productId: @s.matches(DcbTag.string) string, name: string, description: string, price: float}

// AddProduct.res — produced event references the full canonical type
@schema type producedEvent = | ProductAdded(ProductAdded.t)

// AddCategory.res — consumed event can still use a local projection
// (only needs productId to check cross-entity constraints)
@schema type consumedEvent =
  | ProductAdded({productId: string})
  | CategoryAdded({categoryId: string})
```

This is strictly optional. Slices can always inline their consumed event payloads with only the fields they need. But sharing the `ProductAdded.t` module across producers ensures that the produced shape is defined in exactly one place. Consumers choose whether to reference the full type or declare a minimal projection.

**Migration path** — the transition can be incremental:
1. Add `producedEvent` and `consumedEvent` as optional new fields in the spec types
2. When present, the framework uses them; when absent, falls back to `DcbEventLogSpec.event`
3. Slices can be migrated one at a time
4. Once all slices are migrated, deprecate the `DcbEventLogSpec.event` path

### Option C: Shared Event Registry with Per-Slice Subsets

**Approach**: Keep the shared event type for serialization and storage, but let each slice declare which **subset** of events it reads. The framework filters at runtime; the compiler checks per-slice exhaustiveness on the subset.

```rescript
// CatalogEventLog.res — still the central registry
@schema type event = | ProductAdded(...) | CategoryAdded(...) | ...

// AddCategory.res
module DcbEventLogSpec = CatalogEventLog

// Declares which events this slice evolves over
@schema type relevantEvent =
  | CategoryAdded({categoryId: @s.matches(DcbTag.string) string, name})
  | CategoryArchived({categoryId: @s.matches(DcbTag.string) string})

let evolve = (state, event: relevantEvent) => switch event {
  | CategoryAdded(_) => {exists: true, archived: false}
  | CategoryArchived(_) => {...state, archived: true}
  // No wildcard — exhaustive over the subset
}
```

The framework would:
1. Verify at build time that `relevantEvent` is a valid subset of `DcbEventLogSpec.event`
2. Filter events by type at runtime before calling `evolve`
3. Use the full event union for storage and tag extraction

**Pros**: Retains the shared event registry (consistency). Per-slice exhaustiveness (no wildcards). Slice `evolve` is cleaner — no `_ => state` noise.
**Cons**: Still requires modifying the shared event log when adding events. Subset validation adds complexity. Two type definitions per slice (full + subset) adds verbosity.

### Option D: Event Modules Instead of Variants

**Approach**: Replace the monolithic variant type with a module-per-event pattern. Each event is a separate module with its own schema. The DCB event log composes events as a list of modules.

```rescript
// ProductAdded.res
@schema type t = {productId: @s.matches(DcbTag.string) string, name, description, price}
let name = "ProductAdded"

// CategoryAdded.res
@schema type t = {categoryId: @s.matches(DcbTag.string) string, name}
let name = "CategoryAdded"

// CatalogEventLog.res — composition, not definition
module type EventModule = { @schema type t; let name: string }
let events: array<module(EventModule)> = [
  module(ProductAdded), module(CategoryAdded), ...
]

// AddCategory.res — references only the modules it needs
let evolve = (state, eventName, json) => switch eventName {
  | "CategoryAdded" =>
    let e = json->S.parseOrThrow(CategoryAdded.schema)
    {exists: true, archived: false}
  | "CategoryArchived" => ...
  | _ => state
}
```

**Pros**: Each event is independently defined. Adding an event means creating one new file and registering it. No existing code changes.
**Cons**: Loses variant pattern matching — falls back to string-based dispatch. Significantly less idiomatic ReScript. Defeats the purpose of using a typed language.

### Option E: Hybrid — Shared Type with Automatic Wildcard

**Approach**: Keep the current shared union type but generate the `evolve` wrapper automatically. Each slice declares which events it handles; the framework wraps it with a catch-all.

```rescript
// AddCategory.res — only lists events it cares about
type relevantEvent = CategoryAdded(CategoryAdded.payload) | CategoryArchived(CategoryArchived.payload)

let evolveRelevant = (state, event: relevantEvent) => switch event {
  | CategoryAdded(_) => {exists: true, archived: false}
  | CategoryArchived(_) => {...state, archived: true}
}

// Framework-generated wrapper (via ppx or builder):
let evolve = (state, event: CatalogEventLog.event) =>
  switch toRelevant(event) {
  | Some(relevant) => evolveRelevant(state, relevant)
  | None => state
  }
```

**Pros**: Slices are cleaner (no wildcards). Still type-safe. Shared type remains.
**Cons**: Still requires recompilation. Adds mapping boilerplate or ppx complexity. The central event type remains a coordination point.

---

## 6. Recommendation

### Short Term: Option A (Status Quo)

The current design is appropriate for the project's current scale. The Catalog example has 9 events and 12 slices — well within the comfort zone. The type safety benefits outweigh the coordination cost.

Practical mitigations:
- Document the event log as a **shared contract** in the plugin's README
- Keep events grouped by entity (Products, Categories) with blank lines as visual separators (already done in `CatalogEventLog.res`)
- Consider bounded context boundaries carefully — a DCB with too many unrelated event types may signal that it should be split into multiple DCBs

### Medium Term: Option B (Per-Slice Event Types)

When the framework needs to support larger bounded contexts (20+ event types, multiple sub-teams), Option B is the strongest path forward. It aligns with how the broader event sourcing ecosystem handles this (Decider pattern, Axon, EventStoreDB). The key insight is:

> **The DCB is a runtime consistency mechanism, not a compile-time type mechanism.**

The conditional append with tag-based filtering already works at the JSON/storage level. The compile-time union type provides safety but is not structurally necessary for correctness — the tags and event type strings are what enforce the Dynamic Consistency Boundary at runtime.

**Migration path from current to Option B**:
1. Add a `type sliceEvent` to each slice spec (the events this slice produces/consumes)
2. Make the framework collect slice events into a runtime registry at build time
3. Filter events by type string before calling `evolve` — each slice only sees its declared events
4. Deprecate (but continue supporting) the monolithic `DcbEventLog.event` union for backward compatibility
5. Eventually remove the shared type when all slices have migrated

### Not Recommended: Options D and E

Option D (event modules) sacrifices too much of ReScript's type system. Option E (hybrid with auto-wildcard) adds complexity without solving the core coupling — slices still recompile when the shared type changes.

### Option C: Worth Exploring as a Middle Ground

If Option B feels too loose (losing the shared event registry), Option C offers a compromise. The shared type remains as documentation and storage schema, but per-slice subsets reduce the `evolve` noise and enable focused exhaustiveness checking. However, it doesn't solve the recompilation problem.

---

## 7. Broader Considerations

### DCB Boundary Size Matters More Than Type Coupling

The most effective way to reduce event type coupling is to **keep DCBs small**. If Products and Categories don't need cross-entity consistency, they can be separate DCBs (or even separate aggregates). The coupling problem is largely a symptom of over-inclusive boundaries.

Guidelines for DCB boundary sizing:
- A DCB should contain entities that **must** be validated together in a single decision
- If two entity types never appear in the same `evolve` function, they likely belong in separate DCBs
- Cross-DCB communication should use ExtensionPoints (already supported)

### The Event Modeling Perspective

In Event Modeling, slices are designed to be **independently implementable and testable**. The Reventless implementation achieves independent testability (each slice has its own unit tests) but not independent deployability. This is an acceptable deviation for a compiled, type-safe language — the compilation step is the deployment gate, and recompilation of unchanged slices is cheap.

The Event Modeling community generally works with dynamically typed or schemaless event stores (JSON over HTTP APIs), where the coupling question doesn't arise. Reventless's approach of encoding the event model in the type system is distinctive and provides guarantees that other implementations lack.

### Payload-less Variant Constraint

The existing constraint that DCB events must have inline record payloads (no payload-less variants like `| ProductArchived`) is orthogonal to this analysis but compounds the coupling — every event variant must carry a record, even if semantically empty. This should be addressed separately (tracked in memory as a known limitation).
