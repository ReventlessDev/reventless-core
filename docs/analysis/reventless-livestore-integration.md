# Reventless + LiveStore Integration Analysis

## Executive Summary

Reventless (server-side event-sourced CQRS framework) and LiveStore (client-side reactive SQLite with event-sourced sync) share a common foundation in event sourcing, making them natural candidates for integration. This analysis explores how a Reventless backend could serve as the sync backend and authority for LiveStore-based clients, enabling local-first applications with full server-side domain logic enforcement.

A key finding is that the event-to-command-to-event translation layer proposed in earlier models is unnecessary. Instead, the client can commit events directly, and the server validates those events using an auto-derived `validate` function — eliminating the mapping overhead while preserving full invariant enforcement. The backend ReScript event definitions serve as the single source of truth, with LiveStore TypeScript event definitions generated from the compiled sury schemas.

## 1. Architecture Overview

### 1.1 Reventless (Server Side)

Reventless is an event-sourced CQRS framework for serverless infrastructure (AWS Lambda, DynamoDB, SQS, SNS). Its key components:

- **Aggregates** process commands and emit events, enforcing business invariants
- **EventLog** provides append-only event storage with replay and optimistic concurrency control
- **EventTopic** fans out events to subscribers (SNS)
- **ReadModels** project events into queryable state (DynamoDB via QueryDb)
- **CommandGenerator** bridges GraphQL mutations to aggregate commands
- **Plugins** group components into bounded contexts / deployment units

The command-to-event flow: `Client -> GraphQL API -> CommandGenerator -> CommandTopic (SQS FIFO) -> Aggregate -> EventLog (DynamoDB) -> EventTopic (SNS) -> ReadModel -> QueryDb`

### 1.2 LiveStore (Client Side)

LiveStore is a client-side state management framework based on reactive SQLite and event sourcing. Its key components:

- **Eventlog** is the append-only log of all events (single source of truth)
- **Materializers** map events to SQL statements that update the local SQLite database
- **Reactive SQLite** provides synchronous, in-memory queries for UI components
- **Sync Engine** implements git-like push/pull with client-side rebasing

The client flow: `User Interaction -> store.commit(event) -> Local Eventlog -> Materializers -> SQLite -> Reactive UI`

The sync flow: `Client pulls upstream events -> Rebases local pending events -> Pushes local events to sync backend`

**Important**: LiveStore has no concept of "commands" — only events. Clients call `store.commit(event)` directly. Validation happens through materializer transactions (rollback on failure) and sync backend rejection on push.

### 1.3 Shared Foundation

Both systems are built on event sourcing:

| Concept | Reventless | LiveStore |
|---------|-----------|-----------|
| Event storage | EventLog (DynamoDB) | Local eventlog (SQLite/IndexedDB) |
| Event projection | ReadModel projections | Materializers (events -> SQL) |
| Ordering | Per-aggregate sequence numbers | Global sequence numbers |
| Concurrency | Optimistic (sequence number check) | Push/pull with rebasing |
| Serialization | sury (JSON schemas) | Effect Schema (JSON) |

## 2. Integration Model: Direct Event Validation

### 2.1 Why Not Event -> Command -> Event?

Earlier analysis considered translating client events into server commands for validation. This is unnecessarily complex for three reasons:

1. **LiveStore is event-only.** There is no command concept. `store.commit(event)` is the API. Introducing a command translation layer fights LiveStore's architecture.

2. **The mapping is almost always 1:1.** Analysis of all existing Reventless example specs shows that ~90% of command-to-event mappings copy fields verbatim with only a name change:

   | Command | Event | Fields |
   |---------|-------|--------|
   | `AddProduct({productId, name, description, price})` | `ProductAdded({productId, name, description, price})` | identical |
   | `ChangeProductName({productId, name})` | `ProductNameChanged({productId, name})` | identical |
   | `RegisterCustomer({customerId, email, address})` | `CustomerRegistered({customerId, email, address})` | identical |
   | `PlaceOrder({orderId, customerId, productIds})` | `OrderPlaced({orderId, customerId, productIds})` | identical |

3. **No server-computed fields.** Across all example aggregates and DCB slices, zero cases were found where the server enriches events with fields not present in the command (no server timestamps, no computed values, no sequential IDs added by the server).

The one exception is `CancelOrder`, where `productIds` is pulled from the decision model rather than the command. This is a state-dependent field expansion — addressed in section 3.2.

### 2.2 Recommended Model: Direct Event Sync with Server Validation

```
LiveStore Client                    Reventless Backend
+------------------+                +---------------------------+
| Local Eventlog   | <-- pull ----> | Sync API (new component)  |
| Materializers    |                |   |                       |
| Reactive SQLite  |                |   v                       |
| UI Components    | --- push ----> | Event Validator           |
+------------------+                |   |  (auto-derived from   |
                                    |   |   decide functions)   |
                                    |   v                       |
                                    | DcbEventLog (append)      |
                                    | EventTopic (fan-out)      |
                                    +---------------------------+
```

**How it works:**

1. Client commits events locally (optimistic) and materializes immediately into SQLite
2. On push, the sync API receives events in the same JSON format used by the DcbEventLog
3. The server validates each event using an auto-derived `validate` function (see section 3)
4. If validation succeeds, the event is appended to the DcbEventLog as-is
5. If validation fails (invariant violated), the push is rejected with an error
6. On the next pull, the client receives the canonical event stream and rebases

**Key design decision**: Client events ARE server events — same schema, same JSON wire format, same types. No translation layer. The server's role is validation and ordering, not event transformation.

### 2.3 Comparison with Earlier Models

| Aspect | Event->Command->Event (old) | Direct Event Validation (new) |
|--------|---------------------------|-------------------------------|
| Translation layer | Required (event -> command mapping) | None |
| Schema sources | Two (command + event) | One (event only) |
| Canonical event differs from client event | Possible | Never (same event) |
| Client rebase complexity | Must reconcile different events | Simple (same events) |
| Code generation needed | Command mapping + event mapping | Only frontend event defs |
| Server enrichment | Supported | Not needed (see section 3.2) |
| Invariant enforcement | Full (via Aggregate/decide) | Full (via validate, derived from decide) |

## 3. Auto-Derived Event Validation

### 3.1 From `decide` to `validate`

The DCB `decide` function has this signature:

```rescript
let decide: (decisionModel, command) => Result.t<array<DcbEventLogSpec.event>, error>
```

It does two things: (1) checks invariants against the decision model, and (2) constructs the output event. In the direct event validation model, step (2) is unnecessary — the event already exists. We only need step (1).

An auto-derived `validate` function has this signature:

```rescript
let validate: (decisionModel, DcbEventLogSpec.event) => Result.t<unit, error>
```

It checks the same invariants but against the event payload instead of a command payload. Since the fields are identical in ~90% of cases, the validation logic is structurally the same.

### 3.2 Derivation Patterns

Analysis of all existing `decide` functions reveals three patterns:

#### Pattern 1: Direct Field Match (90% of cases)

The command and event have identical fields. The `validate` function checks the same invariants using the event's fields directly.

**Original decide:**
```rescript
// AddProduct StateChangeSlice
let decide = (model, command) =>
  switch command {
  | AddProduct({productId, name, description, price}) =>
    if model.exists {
      Error(ProductAlreadyExists)
    } else {
      Ok([ProductAdded({productId, name, description, price})])
    }
  }
```

**Derived validate:**
```rescript
let validate = (model, event) =>
  switch event {
  | ProductAdded(_) =>
    if model.exists {
      Error(ProductAlreadyExists)
    } else {
      Ok()
    }
  | _ => Ok() // events not handled by this slice pass through
  }
```

The invariant check (`model.exists`) is identical. The only difference is pattern matching on the event variant instead of the command variant, and not needing to construct the output event.

#### Pattern 2: Idempotency Check (common in update operations)

The `decide` function compares a command field against the decision model to detect no-ops.

**Original decide:**
```rescript
// ChangeProductName StateChangeSlice
let decide = (model, command) =>
  switch command {
  | ChangeProductName({productId, name}) =>
    if !model.exists {
      Error(ProductNotFound)
    } else if name == model.currentName {
      Ok([])  // idempotent: no event emitted
    } else {
      Ok([ProductNameChanged({productId, name})])
    }
  }
```

**Derived validate:**
```rescript
let validate = (model, event) =>
  switch event {
  | ProductNameChanged({name}) =>
    if !model.exists {
      Error(ProductNotFound)
    } else if name == model.currentName {
      Ok()  // idempotent: event is a no-op, but still valid
    } else {
      Ok()
    }
  | _ => Ok()
  }
```

Note: the idempotency check (`name == model.currentName`) could either accept the event silently (append it anyway) or skip appending it. The sync API decides the policy.

#### Pattern 3: State-Dependent Field Expansion (rare)

The `decide` function pulls fields from the decision model that aren't in the command.

**Original decide:**
```rescript
// CancelOrder StateChangeSlice
let decide = (model, command) =>
  switch command {
  | CancelOrder({orderId}) =>
    if !model.exists {
      Error(OrderNotFound)
    } else if model.cancelled {
      Ok([])
    } else if model.shipped {
      Error(OrderAlreadyShipped)
    } else {
      Ok([OrderCancelled({orderId, productIds: model.productIds})])
      //                          ^^^^^^^^^^^^^^^^^^^^^^^^^^
      //                          field from decision model, not command
    }
  }
```

This is the one case where command and event differ structurally. Two options:

**Option A: Include expanded fields in the client event.** The client already has the `productIds` from its local SQLite state (it knows what products are in the order). The client commits `OrderCancelled({orderId, productIds})` with the full payload. The server validates that the `productIds` match the decision model.

```rescript
let validate = (model, event) =>
  switch event {
  | OrderCancelled({productIds}) =>
    if !model.exists {
      Error(OrderNotFound)
    } else if model.shipped {
      Error(OrderAlreadyShipped)
    } else if model.cancelled {
      Ok()  // idempotent
    } else if productIds != model.productIds {
      Error(StaleProductIds)  // client had outdated state
    } else {
      Ok()
    }
  | _ => Ok()
  }
```

**Option B: Server enriches the event.** The sync API accepts a partial event from the client and fills in the `productIds` from the decision model before appending. This requires the validate function to return the enriched event instead of `unit`:

```rescript
let validate = (model, event) =>
  switch event {
  | OrderCancelled({orderId}) =>
    if !model.exists { Error(OrderNotFound) }
    else if model.shipped { Error(OrderAlreadyShipped) }
    else if model.cancelled { Ok(None) }  // idempotent, skip
    else { Ok(Some(OrderCancelled({orderId, productIds: model.productIds}))) }
  | _ => Ok(None)  // pass through
  }
```

**Recommendation**: Option A (include all fields in the client event) is preferred because it keeps the "client event = server event" invariant and avoids server-side event mutation. The server validates field consistency rather than computing fields.

### 3.3 Auto-Generation Strategy

The `validate` function can be auto-generated from the existing `decide` function at build time. The generation rules:

1. **For each `decide` function** in a StateChangeSlice:
   - Map each command variant to its corresponding event variant (by matching field structure)
   - Copy all invariant checks (the `if/else` conditions against the decision model)
   - Replace `Ok([EventVariant({...fields})])` with `Ok()`
   - Replace `Ok([])` (idempotent) with `Ok()`
   - Keep `Error(...)` branches unchanged

2. **The `reduce` function is reused as-is** — the decision model is built the same way.

3. **The `initialDecisionModel` is reused as-is.**

4. **Implementation options** for the generator:

   **Option A: ReScript PPX (compile-time)**
   A PPX attribute like `@deriveValidate` on the StateChangeSlice module could generate the `validate` function during ReScript compilation. This is the cleanest approach but requires PPX development.

   **Option B: Code generator script (build-time)**
   A Node.js script that reads the compiled `.res.mjs` files, extracts the `decide` function structure, and generates `validate` functions. Less elegant but works with existing tooling.

   **Option C: Runtime derivation**
   Since commands and events share the same sury schemas, the sync API could dynamically map event payloads to command payloads at runtime using schema introspection, then call the existing `decide` function. This requires no code generation:

   ```rescript
   // Runtime approach: convert event to command, call existing decide
   let validateViaDecide = (model, event, ~eventToCommand, ~decide) => {
     switch eventToCommand(event) {
     | Some(command) =>
       switch decide(model, command) {
       | Ok(_events) => Ok()  // discard produced events, we already have ours
       | Error(e) => Error(e)
       }
     | None => Ok()  // event not handled by this slice
     }
   }
   ```

   The `eventToCommand` mapping can be derived at startup by comparing `eventSchema` and `commandSchema` variant structures (matching by field names and types).

### 3.4 Runtime Schema-Based Command Derivation (Detailed)

Since sury schemas are introspectable at runtime, the event-to-command mapping can be built automatically without code generation:

```
sury eventSchema                    sury commandSchema
S.union([                           S.union([
  {TAG: "ProductAdded",               {TAG: "AddProduct",
   productId: S.string,                productId: S.string,
   name: S.string,                     name: S.string,
   ...}                                ...}
  {TAG: "ProductNameChanged",          {TAG: "ChangeProductName",
   productId: S.string,                productId: S.string,
   name: S.string}                     name: S.string}
])                                  ])
```

A schema matcher can pair event variants with command variants by comparing their field sets (field names and sury types). When the fields match, it generates a runtime mapping function that:

1. Parses the event JSON using `eventSchema`
2. Extracts the payload fields
3. Constructs the command JSON using `commandSchema` with the same field values
4. Parses the command JSON into a typed command value

This approach reuses the existing `decide` function entirely — no new validation code needed. The only generated artifact is the field-level mapping between event and command variants.

**Matching heuristic**: Two variants match when they have identical field sets (same names, compatible types). In the ~10% of cases where they don't match (e.g., `CancelOrder` command has fewer fields than `OrderCancelled` event), the mapping is flagged for manual review or hand-written override.

## 4. Backend as Single Source of Truth: Schema Generation

### 4.1 Why Backend-First

The backend ReScript definitions are the authoritative source because:

- **Business invariants live on the server.** The `decide`/`validate` functions enforce domain rules.
- **Event schemas are append-only.** Once an event version is deployed, its schema cannot change (only new versions can be added). The server controls this evolution.
- **sury-ppx generates rich schemas.** The `@schema` annotation produces full serialization/deserialization schemas with type information, variant tags, and field metadata — all available at build time and runtime.

The frontend should never define event schemas independently. Instead, generate LiveStore event definitions from the backend schemas.

### 4.2 What sury Generates

When you write:

```rescript
// CatalogEventLog.res (backend, single source of truth)
@schema
type event =
  | ProductAdded({
      productId: @s.matches(DcbTag.string) string,
      name: string,
      description: string,
      price: float,
    })
  | ProductNameChanged({
      productId: @s.matches(DcbTag.string) string,
      name: string,
    })
```

sury-ppx generates `CatalogEventLog.res.mjs`:

```javascript
let eventSchema = S.union([
  S.schema(s => ({
    TAG: "ProductAdded",
    productId: s.m(DcbTag.string),
    name: s.m(S.string),
    description: s.m(S.string),
    price: s.m(S.float),
  })),
  S.schema(s => ({
    TAG: "ProductNameChanged",
    productId: s.m(DcbTag.string),
    name: s.m(S.string),
  })),
])
```

The JSON wire format is:
```json
{"TAG": "ProductAdded", "productId": "p-1", "name": "Widget", "description": "...", "price": 9.99}
```

### 4.3 Generation Pipeline: Backend -> Frontend

```
ReScript sources (@schema types)
        |
        v
  rescript build (sury-ppx)
        |
        v
  Compiled .res.mjs (sury schemas in JS)
        |
        v
  Schema extractor (new build tool)    <-- reads eventSchema at build time
        |
        v
  Intermediate representation (JSON)   <-- variant names, field names, field types
        |
        v
  LiveStore codegen (new build tool)   <-- generates TypeScript
        |
        v
  events.ts (LiveStore event definitions)
  materializers.ts (skeleton)
```

#### Step 1: Schema Extraction

A Node.js build script imports the compiled `.res.mjs` module and introspects the sury schema:

```javascript
// extract-schema.mjs (build tool)
import { eventSchema } from './CatalogEventLog.res.mjs'

// sury schemas expose their structure:
// eventSchema.anyOf -> array of variant schemas
// each variant: .properties -> {TAG: {const: "VariantName"}, field1: schema, ...}
// each field schema: .type -> "string" | "number" | "boolean" | "array" | ...

function extractVariants(unionSchema) {
  return unionSchema.anyOf.map(variantSchema => ({
    tag: variantSchema.properties.TAG.const,
    fields: Object.entries(variantSchema.properties)
      .filter(([key]) => key !== 'TAG')
      .map(([name, schema]) => ({
        name,
        type: mapSuryTypeToTS(schema),
      })),
  }))
}

// Output: intermediate JSON
// [
//   { tag: "ProductAdded", fields: [
//     { name: "productId", type: "string" },
//     { name: "name", type: "string" },
//     { name: "description", type: "string" },
//     { name: "price", type: "number" }
//   ]},
//   { tag: "ProductNameChanged", fields: [
//     { name: "productId", type: "string" },
//     { name: "name", type: "string" }
//   ]}
// ]
```

#### Step 2: LiveStore TypeScript Generation

From the intermediate representation, generate LiveStore event definitions:

```typescript
// Generated: catalog-events.ts
import { Events, Schema } from '@livestore/livestore'

export const events = {
  productAdded: Events.synced({
    name: 'v1.ProductAdded',
    schema: Schema.Struct({
      TAG: Schema.Literal('ProductAdded'),
      productId: Schema.String,
      name: Schema.String,
      description: Schema.String,
      price: Schema.Number,
    }),
  }),

  productNameChanged: Events.synced({
    name: 'v1.ProductNameChanged',
    schema: Schema.Struct({
      TAG: Schema.Literal('ProductNameChanged'),
      productId: Schema.String,
      name: Schema.String,
    }),
  }),
}
```

The `TAG` field in the generated Effect Schema maps directly to sury's `TAG` discriminator, ensuring the JSON wire format is identical on both sides.

#### Step 3: Materializer Skeleton Generation (Optional)

The generator can also produce materializer skeletons:

```typescript
// Generated: catalog-materializers.ts (skeleton, hand-edit required)
import { State } from '@livestore/livestore'
import { events } from './catalog-events'
import { tables } from './catalog-tables'

export const materializers = State.SQLite.materializers(events, {
  productAdded: ({ productId, name, description, price }) =>
    tables.products.insert({ productId, name, description, price }),

  productNameChanged: ({ productId, name }) =>
    tables.products.update({ name }).where({ productId }),
})
```

### 4.4 Type Mapping: sury -> Effect Schema

| sury Type | Effect Schema Type | JSON |
|-----------|-------------------|------|
| `S.string` | `Schema.String` | `"string"` |
| `S.float` | `Schema.Number` | `number` |
| `S.int` | `Schema.Number` (with `Schema.Int` pipe) | `number` |
| `S.bool` | `Schema.Boolean` | `boolean` |
| `S.array(S.string)` | `Schema.Array(Schema.String)` | `[...]` |
| `S.literal("X")` | `Schema.Literal("X")` | `"X"` |
| `S.option(S.string)` | `Schema.optional(Schema.String)` | `null \| string` |
| Variant union | `Schema.Union(...)` | `{TAG: "...", ...}` |

### 4.5 Why Not ReScript Bindings for LiveStore?

LiveStore is deeply coupled to **Effect Schema** and the **Effect** TypeScript library for:
- Event definition (`Events.synced` requires Effect Schema instances)
- Materializer return types (Effect monads)
- Sync engine internals (Effect streams and fibers)
- Reactive query layer (Effect-based subscriptions)

Writing ReScript bindings would mean binding the entire Effect ecosystem — a massive undertaking with poor ergonomics since Effect's advanced TypeScript generics (branded types, conditional types, variadic tuples) don't map to ReScript's type system.

The code generation approach is superior: the backend stays pure ReScript, the frontend stays pure TypeScript, and the generated event definitions are the thin bridge between them. Each side uses its native schema library with full type safety.

### 4.6 Keeping Schemas in Sync

The generation pipeline runs as a build step:

```
npm run build:schemas   # extract -> generate -> write to frontend package
```

**CI enforcement**: A CI check verifies that the generated frontend event definitions match the current backend schemas. If a developer changes a backend event type without regenerating, the build fails.

**Schema versioning**: Event names include a version prefix (e.g., `v1.ProductAdded`). When a schema evolves:
1. Add a new event variant (`ProductAddedV2`) on the backend
2. Regenerate frontend definitions — the new variant appears automatically
3. Old materializers continue to work; new materializers handle the v2 event
4. LiveStore's `Events.synced` allows multiple event versions to coexist

## 5. Sync API Design

### 5.1 Sync API Component

A new Reventless component (`SyncApi`) that acts as the LiveStore sync backend.

**Required operations (LiveStore sync provider interface):**

```typescript
type SyncBackend = {
  pull: (cursor: EventSequenceNumber) => Stream<{ batch: LiveStoreEvent[] }>
  push: (batch: LiveStoreEvent[]) => Effect<void, InvalidPushError>
}
```

**Pull implementation:**

```
1. Receive cursor (last known global sequence number)
2. Query DcbEventLog for events with sequence > cursor
3. Return ordered event list + new cursor
4. No event format transformation needed (same JSON wire format)
```

**Push implementation:**

```
1. Receive batch of client events + client's current cursor
2. Check if cursor matches server head (no new events since client last pulled)
   - If not: return "pull required" with new events
3. For each client event:
   a. Parse using sury eventSchema (validates structure)
   b. Extract DCB tags (DcbTag.extractTags)
   c. Query DcbEventLog for relevant prior events (tag-based)
   d. Build decisionModel via reduce()
   e. validate(decisionModel, event) -> Ok/Error
   f. If Ok: append event to DcbEventLog
   g. If Error: reject entire push batch
4. Fan out appended events via EventTopic
5. Return success + new cursor
6. Important: serialize push requests to maintain total ordering
```

### 5.2 Sequence Number Mapping

The DcbEventLog already provides a shared event log with global ordering, making it the natural fit. LiveStore expects a single monotonically increasing sequence number, which maps directly to the DcbEventLog's sequence.

For aggregate-based plugins (non-DCB), a global sequence counter would be needed. But the recommended approach is DCB-first, which avoids this problem entirely.

### 5.3 Event Scoping

LiveStore syncs all events for a "store" (typically per-user or per-workspace). The sync API needs to scope which events a client receives.

**Recommended scoping**: One LiveStore store per Reventless Plugin (bounded context). The Plugin's DcbEventLog contains all events for that context, and the sync API streams the entire log to subscribed clients. Tag-based filtering can further narrow the scope (e.g., only events for a specific workspace/tenant).

### 5.4 Conflict Resolution

```
1. Client commits event optimistically (instant local feedback)
2. Client pushes event to sync API
3. Sync API validates event through validate function
4. If rejected (invariant violated):
   - Sync API returns error to client
   - Client drops the local event (undo optimistic update)
   - Or: client modifies the event and retries
5. If concurrent modification (sequence number conflict):
   - Follow standard LiveStore rebase flow
   - Client pulls new events, rebases local pending events
   - Re-pushes; server re-validates rebased events
```

### 5.5 Offline Support

LiveStore's offline-first architecture pairs well with Reventless:

- **Offline reads**: Client reads from local SQLite (always available)
- **Offline writes**: Client commits events locally, queues for push
- **Reconnection**: Client pulls missed events, rebases local pending events, pushes
- **Server validation on reconnect**: Queued events are validated through the `validate` function when connectivity returns. Some may be rejected if state has changed.

### 5.6 Security Considerations

- **Event authorization**: The sync API must verify the client has permission to commit each event type. Reventless's `Message.meta.user` field carries the authenticated user.
- **Event filtering**: Clients should only receive events they are authorized to see. The sync API must filter events based on user permissions before sending.
- **Input validation**: All client events are validated through the `validate` function before appending. Never bypass validation for writes.
- **Payload validation**: The sync backend's `validatePayload` hook (part of LiveStore's sync provider interface) can perform authentication checks before processing any events.

## 6. Transport Layer: GraphQL Subscriptions Analysis

### 6.1 LiveStore's Pull Interface is Stream-Based

LiveStore's sync provider `pull` operation returns an **Effect-TS `Stream.Stream`** — a lazy, potentially infinite sequence of event batches:

```typescript
pull: (
  cursor: Option<{
    eventSequenceNumber: EventSequenceNumber.Global.Type
    metadata: Option<TSyncMetadata>
  }>,
  options?: { live?: boolean }
) => Stream.Stream<PullResItem<TSyncMetadata>, IsOfflineError | InvalidPullError>
```

The `live` option (default `false`) controls reactivity:
- **`live: false`**: The stream emits batches until it catches up with the server head, then terminates (`pageInfo: 'NoMore'`).
- **`live: true`**: After catching up, the stream stays open and continues emitting new batches as events arrive on the server — a persistent, push-based tail.

The sync provider advertises live pull support via `supports: { pullLive: boolean }`. LiveStore clients default to `livePull: true` when available.

This two-phase design (bulk catch-up + live tail) is central to how LiveStore syncs. Any transport that delivers events to the client must map to this stream interface.

### 6.2 LiveStore is Transport-Agnostic

The `SyncBackend` interface defines the logical protocol; transport is an implementation detail. LiveStore's existing Cloudflare sync provider ships three transport implementations:

| Transport | Protocol | Live Pull | Use Case |
|-----------|----------|-----------|----------|
| WebSocket | `wss://` | Yes | Primary — bidirectional, persistent connection |
| HTTP | `https://` | Limited (chunked streaming) | Fallback for restricted environments |
| Durable Object RPC | Direct calls | N/A | Co-located Cloudflare Workers |

WebSocket is the primary and recommended transport. Both pull and push operations multiplex over the same WebSocket connection using an Effect-TS RPC protocol.

### 6.3 Could GraphQL Subscriptions Serve as Transport?

**Yes, but with caveats.** GraphQL subscriptions are a natural fit for the live pull phase (server pushes new events to the client), but they only cover half of the sync protocol.

#### What GraphQL Subscriptions Can Do

GraphQL subscriptions deliver server-initiated events to clients over a persistent connection (typically WebSocket via the `graphql-ws` protocol). This maps well to LiveStore's `pull(cursor, { live: true })`:

```graphql
# Server schema
type Subscription {
  eventStream(cursor: Int!, scope: String!): EventBatch!
}

type EventBatch {
  events: [Event!]!
  cursor: Int!
  pageInfo: PageInfo!
}

type Event {
  sequenceNumber: Int!
  payload: JSON!
}
```

The subscription would:
1. On subscribe, emit catch-up batches (events after `cursor`)
2. After catch-up, keep the subscription open and emit new events as they're appended to the DcbEventLog
3. The client's LiveStore sync provider wraps the subscription as an Effect-TS `Stream`

#### What GraphQL Subscriptions Cannot Do

1. **Push (client → server)**: GraphQL subscriptions are unidirectional (server → client). The `push` operation (client sending events for validation) needs a separate channel — either a GraphQL **mutation** or an HTTP POST endpoint.

2. **Backpressure**: GraphQL subscriptions have no built-in backpressure mechanism. If the server emits events faster than the client can process them, events buffer unboundedly. LiveStore's WebSocket RPC protocol handles this with frame-level flow control.

3. **Binary payloads**: GraphQL subscriptions transmit JSON text. This is fine for event payloads (already JSON), but adds overhead compared to binary WebSocket frames for large event batches.

### 6.4 Architecture with GraphQL Subscriptions

```
LiveStore Client                         Reventless Backend
+------------------+                     +---------------------------+
| Sync Provider    |                     | GraphQL API (AppSync)     |
|   pull() --------+-- subscription ---> |   Subscription resolver   |
|                  |   (live event       |     |                     |
|                  |    stream)          |     v                     |
|   push() --------+-- mutation -------> |   Mutation resolver       |
|                  |   (event batch      |     |                     |
|                  |    for validation)  |     v                     |
+------------------+                     | Sync API / Validator      |
                                         |     |                     |
                                         |     v                     |
                                         | DcbEventLog               |
                                         | EventTopic (fan-out)      |
                                         +---------------------------+
```

**Pull (subscription)**:
1. Client opens a GraphQL subscription with its current cursor
2. Server queries DcbEventLog for events after cursor, emits catch-up batches
3. Server subscribes to EventTopic for new events, emits them as they arrive
4. Client's sync provider wraps the subscription as an Effect-TS `Stream<PullResItem>`

**Push (mutation)**:
1. Client sends event batch via GraphQL mutation
2. Server validates each event through the `validate` function (section 3)
3. Server appends valid events to DcbEventLog
4. Server returns success/error result
5. Appended events fan out via EventTopic → subscription receivers

```graphql
type Mutation {
  pushEvents(batch: [EventInput!]!, cursor: Int!): PushResult!
}

type PushResult {
  success: Boolean!
  newCursor: Int
  error: PushError
}

type Subscription {
  pullEvents(cursor: Int!, scope: String!): EventBatch!
}
```

### 6.5 AWS AppSync as Subscription Transport

Reventless already uses **AWS AppSync** for its GraphQL API. AppSync natively supports GraphQL subscriptions over WebSocket, making it a viable transport without additional infrastructure.

**How AppSync subscriptions work:**
- Client connects to the AppSync real-time endpoint (`wss://`)
- Client sends a subscription query; AppSync maintains the WebSocket connection
- Server-side events are pushed to subscribers via the **AppSync Events HTTP API** (Lambda calls AppSync to push data to subscribed clients)
- Supports **server-side filter expressions** on subscription arguments (e.g., filter by scope/tenant)

**Event delivery flow with AppSync:**

```
DcbEventLog (event appended)
    ↓
EventTopic (SNS FIFO)
    ↓
Lambda subscriber (new component)
    ↓
AppSync Events HTTP API  →  push to WebSocket subscribers
    ↓
Client GraphQL subscription
    ↓
LiveStore sync provider pull stream
```

**Advantages of AppSync subscriptions:**
- **No new infrastructure**: AppSync is already deployed for the GraphQL API
- **Managed WebSocket**: AWS handles connection management, scaling, keep-alive
- **Built-in auth**: Cognito/IAM/API key authorization on subscriptions
- **Server-side filtering**: Scope events to the right clients without custom logic
- **`@aws_subscribe` directive**: For mutation-triggered subscriptions (zero extra infrastructure)

**Limitations of AppSync subscriptions:**
- **Payload size limit**: 240 KB per subscription payload (sufficient for most event batches, but large batches need chunking)
- **Connection limit**: 100 concurrent subscriptions per WebSocket connection
- **No backpressure**: Events buffer on the server if the client is slow
- **Latency**: AppSync adds a hop (SNS → Lambda → AppSync → client) compared to a direct WebSocket

### 6.6 Comparison: GraphQL Subscriptions vs Direct WebSocket

| Aspect | GraphQL Subscriptions (AppSync) | Direct WebSocket |
|--------|-------------------------------|-----------------|
| **Pull (live tail)** | Subscription query — good fit | Native — ideal fit |
| **Pull (catch-up)** | Must emit batches via subscription or separate query | Native — stream over same connection |
| **Push** | Separate mutation — two channels | Same connection — single channel |
| **Infrastructure** | AppSync already deployed | New WebSocket API Gateway + Lambda |
| **Auth** | Built-in (Cognito/IAM) | Must implement |
| **Backpressure** | None | Frame-level control possible |
| **Payload format** | JSON only | JSON or binary |
| **Connection management** | Managed by AWS | Self-managed |
| **Latency** | +1 hop (SNS → Lambda → AppSync) | Direct (Lambda → client) |
| **Max payload** | 240 KB per push | 128 KB per frame (standard), chunking available |

### 6.7 Hybrid Approach (Recommended)

The most practical approach combines both:

1. **GraphQL subscription for live pull**: Use AppSync subscriptions to push new events to connected clients in real-time. This leverages existing infrastructure and is the natural extension of the planned Reventless subscription support (see `docs/plans/Backlog/graphql-subscriptions-realtime.md`).

2. **GraphQL mutation for push**: Client sends event batches via a `pushEvents` mutation. The mutation resolver validates events and appends to the DcbEventLog. This reuses the existing AppSync API.

3. **GraphQL query for catch-up pull**: On initial connect or reconnect, the client queries for missed events via a paginated `pullEvents` query. This avoids streaming large catch-up batches through the subscription channel.

```graphql
type Query {
  pullEvents(cursor: Int!, scope: String!, limit: Int): EventBatch!
}

type Mutation {
  pushEvents(batch: [EventInput!]!, cursor: Int!): PushResult!
}

type Subscription {
  newEvents(scope: String!): EventBatch!
}
```

The LiveStore sync provider implementation:

```typescript
// @livestore/sync-reventless (client library)
const pull = (cursor, options) => {
  // Phase 1: Catch-up via paginated query
  const catchUp = Stream.paginateEffect(cursor, (c) =>
    graphqlQuery({ query: PullEventsDocument, variables: { cursor: c, scope } })
      .pipe(Effect.map(({ events, cursor, pageInfo }) => [
        { batch: events, pageInfo },
        pageInfo === 'NoMore' ? Option.none() : Option.some(cursor)
      ]))
  )

  if (!options?.live) return catchUp

  // Phase 2: Live tail via subscription
  const liveTail = Stream.fromAsyncIterable(
    graphqlSubscription({ query: NewEventsDocument, variables: { scope } })
  )

  return Stream.concat(catchUp, liveTail)
}

const push = (batch) =>
  graphqlMutation({ query: PushEventsDocument, variables: { batch, cursor } })
```

### 6.8 Alignment with Existing Reventless Plans

The backlog plan at `docs/plans/Backlog/graphql-subscriptions-realtime.md` already outlines an 8-phase implementation for GraphQL subscriptions with three event sources:

- **Source A (Domain Events)**: EventLog/DcbEventLog → SNS EventTopic → Lambda → AppSync realtime push
- **Source B (State Changes)**: QueryDb (DynamoDB Stream) → Lambda → AppSync realtime push
- **Source C (Mutation Ack)**: `@aws_subscribe` directive for mutation-triggered subscriptions

The LiveStore integration aligns with **Source A** — domain events pushed via EventTopic to subscribed clients. The same infrastructure (EventTopic → Lambda → AppSync subscription push) serves both traditional GraphQL subscription clients and LiveStore sync providers. The only difference is the client-side consumer: a React hook for traditional subscriptions vs the LiveStore sync provider's `pull` stream.

This means the LiveStore sync transport is not a separate system — it's a consumer of the same subscription infrastructure planned for the broader Reventless platform.

## 7. DCB-Based Plugins as Natural Fit

Reventless's DCB (Dynamic Consistency Boundary) model is the ideal fit for LiveStore integration:

1. **Shared event log**: DCB plugins use a shared `DcbEventLog` across all StateChangeSlices, which maps 1:1 to LiveStore's single eventlog
2. **Tag-based queries**: DCB events support tag-based queries for efficient event filtering during validation
3. **StateViewSlice**: Combines event collection and projection (analogous to LiveStore's materializers)
4. **Global ordering**: DcbEventLog inherently provides the global sequence numbering LiveStore expects
5. **Direct validation**: The `decide` function pattern maps cleanly to `validate`

The mapping:

```
LiveStore Concept        <->  DCB Concept
Eventlog                 <->  DcbEventLog
Materializer             <->  StateViewSlice
store.commit(event)      <->  SyncApi.validate(event) + EventLog.append(event)
SQLite table             <->  QueryDb table
Event schema (generated) <->  @schema type event (source of truth)
```

## 8. Advantages of Integration

1. **Local-first UX**: Instant UI responses with optimistic updates, offline support
2. **Server-side authority**: Business invariants enforced by auto-derived `validate` functions
3. **Reactive queries**: LiveStore's reactive SQLite eliminates loading states
4. **Event sourcing end-to-end**: Same event types from client to server, no translation layer
5. **Single source of truth**: Backend ReScript event definitions generate frontend TypeScript
6. **Existing infrastructure**: Reventless's serverless infrastructure (Lambda, DynamoDB, SQS) handles scaling
7. **Multi-client sync**: LiveStore's sync engine handles multi-device/multi-user synchronization
8. **No schema drift**: Generated frontend schemas are always in sync with backend

## 9. Challenges and Risks

1. **Schema evolution**: Event versions must be forward-compatible. The generation pipeline helps enforce this, but requires discipline.
2. **Global ordering bottleneck**: DynamoDB atomic counters support ~1000 writes/second. For higher throughput, consider partitioned ordering with per-scope sequences.
3. **Unbounded data**: LiveStore syncs full event logs. If a DcbEventLog grows very large, the client eventlog grows large too. Snapshots/compaction would be needed.
4. **State-dependent field expansion**: The ~10% of cases where events have fields not in commands (e.g., CancelOrder) require either client-side state inclusion or server-side enrichment (section 3.2, Pattern 3).
5. **Latency**: LiveStore expects fast push/pull round-trips. Lambda cold starts could add latency. Consider provisioned concurrency or edge deployment.
6. **Effect Schema compatibility**: The generated Effect Schema definitions must produce the exact same JSON wire format as sury. The `TAG` discriminator field is the critical alignment point.
7. **Build tooling**: The schema extraction pipeline requires maintaining a build tool that understands sury's internal schema representation, which may change between sury versions.

## 10. Recommended Next Steps

1. **Schema extraction prototype**: Build the Node.js script that reads compiled sury schemas from `.res.mjs` and produces the intermediate JSON representation
2. **LiveStore codegen prototype**: Generate `events.ts` from the intermediate representation for one example (Catalog)
3. **Validate wire format compatibility**: Confirm that sury JSON output and Effect Schema JSON output produce byte-identical payloads for the same event
4. **Proof of concept**: Build a minimal SyncApi component using the in-memory platform with the `validate` approach
5. **Auto-derive validate**: Implement the runtime schema-based command derivation (section 3.4) to reuse existing `decide` functions without code generation
6. **AWS adapter**: Implement the SyncApi AWS adapter (API Gateway WebSocket + Lambda)
7. **Client library**: Build a LiveStore sync provider package (`@livestore/sync-reventless`) implementing the custom sync provider interface

## 11. Conclusion

Reventless and LiveStore are architecturally complementary. Both are built on event sourcing, but they operate at different layers: Reventless handles server-side domain logic, infrastructure, and persistence; LiveStore handles client-side state management, reactivity, and offline support.

The key insight is that the integration does NOT require an event-to-command translation layer. Client events and server events can be the same types, defined once in backend ReScript and generated for the frontend TypeScript. The server validates events using `validate` functions auto-derived from existing DCB `decide` functions, preserving full business invariant enforcement without the complexity of a mapping layer.

The DCB-based plugin model in Reventless is the natural fit due to its shared event log, global ordering, and tag-based validation — all of which align directly with LiveStore's single-eventlog, sequence-number-based sync protocol.
